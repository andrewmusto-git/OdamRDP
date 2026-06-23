#!/usr/bin/env python3
"""
Odam RDP to Veza OAA Integration Script
Reads CrowdStrike RDP session data (CSV) and pushes identity/permission data
to Veza as a CustomApplication.

Entity model:
  User  (col A: domain\\username)
    └── has RDP access to → Target  (col B: target hostname)
                              └── sub-resource → Source  (col C: source IP / hostname)
"""

import argparse
import csv
import logging
import os
import sys
from datetime import datetime
from logging.handlers import TimedRotatingFileHandler

from dotenv import load_dotenv
from oaaclient.client import OAAClient, OAAClientError
from oaaclient.templates import CustomApplication, OAAPermission

# ---------------------------------------------------------------------------
# Module-level logger (populated by _setup_logging)
# ---------------------------------------------------------------------------
log = logging.getLogger(__name__)

PROVIDER_NAME_DEFAULT = "Odam RDP"
DATASOURCE_NAME_DEFAULT = "CrowdStrike RDP Sessions"


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
def _setup_logging(log_level: str = "INFO") -> None:
    """Configure file-only logging with hourly rotation to the logs/ folder."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    log_dir = os.path.join(script_dir, "logs")
    os.makedirs(log_dir, exist_ok=True)

    timestamp = datetime.now().strftime("%d%m%Y-%H%M")
    script_name = os.path.splitext(os.path.basename(__file__))[0]
    log_file = os.path.join(log_dir, f"{script_name}_{timestamp}.log")

    handler = TimedRotatingFileHandler(
        log_file,
        when="h",
        interval=1,
        backupCount=24,
        encoding="utf-8",
    )
    handler.setFormatter(
        logging.Formatter(
            fmt="%(asctime)s %(levelname)-8s %(message)s",
            datefmt="%Y-%m-%dT%H:%M:%S",
        )
    )

    root = logging.getLogger()
    root.setLevel(getattr(logging, log_level.upper(), logging.INFO))
    root.addHandler(handler)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Push Odam RDP CrowdStrike session data to Veza via OAA.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )

    # Source data
    parser.add_argument(
        "--data-dir",
        default=None,
        help="Directory containing the RDP CSV export(s). "
             "Defaults to the 'samples/' sub-directory next to this script.",
    )
    parser.add_argument(
        "--csv-file",
        default=None,
        help="Explicit path to a single CSV file. Overrides --data-dir.",
    )

    # Veza connection
    parser.add_argument("--env-file", default=".env", help="Path to .env file.")
    parser.add_argument(
        "--veza-url",
        default=None,
        help="Veza tenant URL (e.g. https://example.veza.com). Also reads VEZA_URL.",
    )
    parser.add_argument(
        "--veza-api-key",
        default=None,
        help="Veza API key. Also reads VEZA_API_KEY.",
    )

    # OAA provider / datasource labels
    parser.add_argument(
        "--provider-name",
        default=None,
        help=f"Provider name shown in Veza. Default: '{PROVIDER_NAME_DEFAULT}'.",
    )
    parser.add_argument(
        "--datasource-name",
        default=None,
        help=f"Datasource name shown in Veza. Default: '{DATASOURCE_NAME_DEFAULT}'.",
    )

    # Execution flags
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Build OAA payload but skip the push to Veza.",
    )
    parser.add_argument(
        "--save-json",
        action="store_true",
        help="Save the OAA payload JSON to disk for inspection.",
    )
    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Logging verbosity.",
    )

    return parser.parse_args(argv)


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
def load_config(args: argparse.Namespace) -> dict:
    """Load configuration with precedence: CLI arg → env var → .env file."""
    env_path = args.env_file
    if env_path and os.path.exists(env_path):
        load_dotenv(env_path)
        log.debug("Loaded environment from %s", env_path)
    else:
        log.debug("No .env file found at '%s' — relying on environment variables", env_path)

    veza_url = args.veza_url or os.getenv("VEZA_URL")
    veza_api_key = args.veza_api_key or os.getenv("VEZA_API_KEY")
    provider_name = args.provider_name or os.getenv("PROVIDER_NAME") or PROVIDER_NAME_DEFAULT
    datasource_name = args.datasource_name or os.getenv("DATASOURCE_NAME") or DATASOURCE_NAME_DEFAULT

    return {
        "veza_url": veza_url,
        "veza_api_key": veza_api_key,
        "provider_name": provider_name,
        "datasource_name": datasource_name,
    }


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------
def find_csv_files(args: argparse.Namespace) -> list[str]:
    """Return a list of CSV file paths to process."""
    if args.csv_file:
        if not os.path.isfile(args.csv_file):
            log.error("Specified --csv-file does not exist: %s", args.csv_file)
            sys.exit(1)
        return [args.csv_file]

    data_dir = args.data_dir
    if not data_dir:
        # Default: samples/ next to this script
        data_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "samples")

    if not os.path.isdir(data_dir):
        log.error("Data directory does not exist: %s", data_dir)
        sys.exit(1)

    csv_files = [
        os.path.join(data_dir, f)
        for f in os.listdir(data_dir)
        if f.lower().endswith(".csv")
    ]
    if not csv_files:
        log.error("No CSV files found in %s", data_dir)
        sys.exit(1)

    log.info("Found %d CSV file(s) in %s", len(csv_files), data_dir)
    return csv_files


def load_rdp_rows(csv_files: list[str]) -> list[dict]:
    """
    Read one or more CSV files.
    Expected columns (case-insensitive, extra whitespace stripped):
      User   — domain\\username          (col A)
      Target — RDP target hostname       (col B)
      Source — source IP / hostname      (col C)
    Returns a list of dicts with keys: user, target, source.
    """
    rows = []
    for path in csv_files:
        log.info("Reading %s", path)
        try:
            with open(path, newline="", encoding="utf-8-sig") as fh:
                reader = csv.DictReader(fh)
                # Normalise header names
                if reader.fieldnames is None:
                    log.warning("Empty or header-less file: %s — skipping", path)
                    continue
                headers = [h.strip().lower() for h in reader.fieldnames]
                if not {"user", "target", "source"}.issubset(set(headers)):
                    log.error(
                        "CSV %s is missing required columns. "
                        "Expected: User, Target, Source. Got: %s",
                        path,
                        reader.fieldnames,
                    )
                    sys.exit(1)

                for raw in reader:
                    normalised = {k.strip().lower(): (v or "").strip() for k, v in raw.items()}
                    user = normalised.get("user", "")
                    target = normalised.get("target", "")
                    source = normalised.get("source", "")

                    # Skip rows with no meaningful data
                    if not user or not target:
                        log.debug("Skipping incomplete row: %s", dict(raw))
                        continue

                    # Treat 'null' as an empty/unknown source
                    if source.lower() == "null":
                        source = ""

                    rows.append({"user": user, "target": target, "source": source})
        except OSError as exc:
            log.error("Cannot read %s: %s", path, exc)
            sys.exit(1)

    log.info("Loaded %d RDP rows from %d file(s)", len(rows), len(csv_files))
    return rows


# ---------------------------------------------------------------------------
# OAA payload builder
# ---------------------------------------------------------------------------
def build_oaa_payload(rows: list[dict], config: dict) -> CustomApplication:
    """
    Construct an OAA CustomApplication from RDP session rows.

    OAA model:
      Local User  ──(rdp_access)──► Application Resource (Target)
                                         └── Sub-Resource (Source IP)
    """
    app = CustomApplication(
        name=config["datasource_name"],
        application_type=config["provider_name"],
    )

    # Single permission: an RDP session implies the user can reach the target
    app.add_custom_permission(
        "rdp_access",
        [OAAPermission.DataRead, OAAPermission.MetadataRead],
    )

    users_seen: set[str] = set()
    targets_seen: set[str] = set()
    # target → set of source IPs already added as sub-resources
    sources_seen: dict[str, set[str]] = {}

    for row in rows:
        user_id = row["user"]
        target_id = row["target"]
        source_id = row["source"]

        # --- Local User -------------------------------------------------
        if user_id not in users_seen:
            # Strip domain prefix for the display name if present
            display_name = user_id.split("\\")[-1] if "\\" in user_id else user_id
            u = app.add_local_user(user_id)
            u.name = display_name
            users_seen.add(user_id)
            log.debug("Added user: %s", user_id)

        # --- Application Resource (Target) ------------------------------
        if target_id not in targets_seen:
            app.add_resource(resource_name=target_id, resource_type="RDP Target")
            targets_seen.add(target_id)
            sources_seen[target_id] = set()
            log.debug("Added resource (target): %s", target_id)

        # --- Sub-Resource (Source IP) -----------------------------------
        if source_id and source_id not in sources_seen[target_id]:
            app.add_sub_resource(
                resource_name=target_id,
                sub_resource_name=source_id,
                sub_resource_type="Source IP",
            )
            sources_seen[target_id].add(source_id)
            log.debug("Added sub-resource (source): %s → %s", target_id, source_id)

        # --- Permission assignment: user → rdp_access → target ----------
        app.local_users[user_id].add_permission(
            permission="rdp_access",
            apply_to_application=False,
            resources=[app.resources[target_id]],
        )

    log.info(
        "Payload built — Users: %d | Targets (Resources): %d | Sources (Sub-Resources): %d",
        len(users_seen),
        len(targets_seen),
        sum(len(v) for v in sources_seen.values()),
    )
    return app


# ---------------------------------------------------------------------------
# Veza push
# ---------------------------------------------------------------------------
def push_to_veza(
    veza_url: str,
    veza_api_key: str,
    provider_name: str,
    datasource_name: str,
    app: CustomApplication,
    dry_run: bool = False,
    save_json: bool = False,
) -> None:
    """Push the OAA payload to Veza, optionally saving JSON to disk."""
    if save_json:
        import json

        script_dir = os.path.dirname(os.path.abspath(__file__))
        json_path = os.path.join(
            script_dir,
            f"oaa_payload_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json",
        )
        with open(json_path, "w", encoding="utf-8") as jf:
            json.dump(app.get_payload(), jf, indent=2, default=str)
        log.info("Payload saved to %s", json_path)
        print(f"[INFO] JSON payload saved → {json_path}")

    if dry_run:
        log.info("[DRY RUN] Payload built successfully — skipping Veza push")
        print("[DRY RUN] Payload built successfully — Veza push skipped.")
        return

    if not veza_url or not veza_api_key:
        log.error("VEZA_URL and VEZA_API_KEY are required when not using --dry-run")
        sys.exit(1)

    log.info("Connecting to Veza at %s", veza_url)
    veza_con = OAAClient(url=veza_url, token=veza_api_key)
    try:
        response = veza_con.push_application(
            provider_name=provider_name,
            data_source_name=datasource_name,
            application_object=app,
            create_provider=True,
        )
        if response and response.get("warnings"):
            for w in response["warnings"]:
                log.warning("Veza warning: %s", w)
        log.info("Successfully pushed to Veza — provider=%s datasource=%s", provider_name, datasource_name)
        print(f"[INFO] Successfully pushed to Veza → provider='{provider_name}' datasource='{datasource_name}'")
    except OAAClientError as exc:
        log.error(
            "Veza push failed: %s — %s (HTTP %s)",
            exc.error,
            exc.message,
            exc.status_code,
        )
        if hasattr(exc, "details"):
            for detail in exc.details:
                log.error("  Detail: %s", detail)
        sys.exit(1)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main(argv=None) -> None:
    args = parse_args(argv)
    _setup_logging(args.log_level)

    # Startup banner (print only — intentional exception to logging-only rule)
    print("=" * 60)
    print("  Odam RDP → Veza OAA Integration")
    print(f"  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)

    log.info("Starting Odam RDP OAA integration (log-level=%s)", args.log_level)

    config = load_config(args)
    log.debug("Config: provider=%s datasource=%s dry_run=%s", config["provider_name"], config["datasource_name"], args.dry_run)

    csv_files = find_csv_files(args)
    rows = load_rdp_rows(csv_files)

    if not rows:
        log.error("No valid RDP rows found — nothing to push")
        sys.exit(1)

    app = build_oaa_payload(rows, config)

    push_to_veza(
        veza_url=config["veza_url"],
        veza_api_key=config["veza_api_key"],
        provider_name=config["provider_name"],
        datasource_name=config["datasource_name"],
        app=app,
        dry_run=args.dry_run,
        save_json=args.save_json,
    )

    log.info("Integration complete")
    print("[INFO] Integration complete.")


if __name__ == "__main__":
    main()
