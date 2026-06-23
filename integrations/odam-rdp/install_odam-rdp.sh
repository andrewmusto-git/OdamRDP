#!/usr/bin/env bash
# =============================================================================
# install_odam-rdp.sh — One-command installer for Odam RDP → Veza OAA
#
# Usage (interactive):
#   bash install_odam-rdp.sh
#
# Usage (non-interactive / CI):
#   VEZA_URL=https://... VEZA_API_KEY=... \
#   bash install_odam-rdp.sh --non-interactive
#
# Optional flags:
#   --non-interactive   Skip all prompts; read values from env vars
#   --overwrite-env     Overwrite an existing .env file
#   --install-dir PATH  Install root (default: /opt/odam-rdp-veza)
#   --repo-url URL      Git repo to clone from
#   --branch NAME       Branch to clone (default: main)
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Configurable defaults
# ---------------------------------------------------------------------------
REPO_URL="https://github.com/andrewmusto-git/OdamRDP"
BRANCH="main"
INTEGRATION_SUBDIR="integrations/odam-rdp"
INSTALL_DIR="/opt/odam-rdp-veza"
SCRIPTS_DIR="${INSTALL_DIR}/scripts"
LOG_DIR="${INSTALL_DIR}/logs"
NON_INTERACTIVE=false
OVERWRITE_ENV=false

# ---------------------------------------------------------------------------
# Milestone tracking
# ---------------------------------------------------------------------------
MILESTONE_TOTAL=9
MILESTONE_CURRENT=0

milestone() {
    MILESTONE_CURRENT=$(( MILESTONE_CURRENT + 1 ))
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  [${MILESTONE_CURRENT}/${MILESTONE_TOTAL}] $*"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=true ;;
        --overwrite-env)   OVERWRITE_ENV=true ;;
        --install-dir)     INSTALL_DIR="$2"; SCRIPTS_DIR="${INSTALL_DIR}/scripts"; LOG_DIR="${INSTALL_DIR}/logs"; shift ;;
        --repo-url)        REPO_URL="$2"; shift ;;
        --branch)          BRANCH="$2"; shift ;;
        *) warn "Unknown flag: $1" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# MILESTONE 1 — Detect OS and package manager
# ---------------------------------------------------------------------------
milestone "Detecting operating system"

OS_ID=""
PKG_MGR=""

if [[ -f /etc/os-release ]]; then
    OS_ID=$(grep -E "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
fi

if command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
elif command -v yum &>/dev/null; then
    PKG_MGR="yum"
elif command -v apt-get &>/dev/null; then
    PKG_MGR="apt-get"
else
    die "No supported package manager found (dnf, yum, apt-get). Please install dependencies manually."
fi

info "OS: ${OS_ID:-unknown}  |  Package manager: ${PKG_MGR}"

# ---------------------------------------------------------------------------
# Helper: install a single package with a pre-check
# ---------------------------------------------------------------------------
_install_pkg() {
    local pkg="$1"
    info "Installing ${pkg} ..."
    case "${PKG_MGR}" in
        dnf|yum) "${PKG_MGR}" install -y "${pkg}" >/dev/null 2>&1 ;;
        apt-get) apt-get install -y "${pkg}" >/dev/null 2>&1 ;;
    esac
}

# ---------------------------------------------------------------------------
# MILESTONE 2 — Install system prerequisites
# ---------------------------------------------------------------------------
milestone "Installing system prerequisites"

command -v git     &>/dev/null || _install_pkg git
command -v python3 &>/dev/null || _install_pkg python3
python3 -m pip --version &>/dev/null || _install_pkg python3-pip

# curl — skip on Amazon Linux if curl-minimal already present
if ! command -v curl &>/dev/null; then
    if [[ "${OS_ID}" == "amzn" ]]; then
        warn "Skipping curl install on Amazon Linux (curl-minimal conflict). curl already present."
    else
        _install_pkg curl
    fi
fi

# python3-venv — built into python3 on AL2023 / RHEL 9+
if ! python3 -m venv --help &>/dev/null 2>&1; then
    case "${PKG_MGR}" in
        dnf|yum) _install_pkg python3-virtualenv ;;
        apt-get) _install_pkg python3-venv ;;
    esac
fi

ok "System prerequisites ready."

# ---------------------------------------------------------------------------
# MILESTONE 3 — Validate Python version
# ---------------------------------------------------------------------------
milestone "Validating Python version (≥ 3.8 required)"

PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PY_MAJOR=$(echo "${PY_VER}" | cut -d. -f1)
PY_MINOR=$(echo "${PY_VER}" | cut -d. -f2)

if [[ "${PY_MAJOR}" -lt 3 ]] || { [[ "${PY_MAJOR}" -eq 3 ]] && [[ "${PY_MINOR}" -lt 8 ]]; }; then
    die "Python ${PY_VER} detected. Python 3.8+ is required."
fi
ok "Python ${PY_VER} — OK"

# ---------------------------------------------------------------------------
# MILESTONE 4 — Create directory structure
# ---------------------------------------------------------------------------
milestone "Creating installation directories"

mkdir -p "${SCRIPTS_DIR}" "${LOG_DIR}"
ok "Directories created:"
info "  Scripts : ${SCRIPTS_DIR}"
info "  Logs    : ${LOG_DIR}"

# ---------------------------------------------------------------------------
# MILESTONE 5 — Clone repository and copy integration files
# ---------------------------------------------------------------------------
milestone "Downloading integration files from repository"

tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}"' EXIT

info "Cloning ${REPO_URL} (branch: ${BRANCH}) ..."
GIT_TERMINAL_PROMPT=0 git clone --branch "${BRANCH}" --depth 1 --single-branch \
    "${REPO_URL}" "${tmp_dir}" || die "git clone failed. Check REPO_URL and network connectivity."

if [[ ! -d "${tmp_dir}/${INTEGRATION_SUBDIR}" ]]; then
    die "Integration directory '${INTEGRATION_SUBDIR}' not found in cloned repository."
fi

cp -f "${tmp_dir}/${INTEGRATION_SUBDIR}"/*.py          "${SCRIPTS_DIR}/" 2>/dev/null || true
cp -f "${tmp_dir}/${INTEGRATION_SUBDIR}/requirements.txt" "${SCRIPTS_DIR}/"

ok "Integration files copied to ${SCRIPTS_DIR}"

# ---------------------------------------------------------------------------
# MILESTONE 6 — Create Python virtual environment
# ---------------------------------------------------------------------------
milestone "Creating Python virtual environment"

VENV_DIR="${SCRIPTS_DIR}/venv"
if [[ -d "${VENV_DIR}" ]]; then
    info "Virtual environment already exists at ${VENV_DIR} — reusing."
else
    python3 -m venv "${VENV_DIR}" || die "Failed to create virtual environment."
    ok "Virtual environment created at ${VENV_DIR}"
fi

# ---------------------------------------------------------------------------
# MILESTONE 7 — Install Python dependencies
# ---------------------------------------------------------------------------
milestone "Installing Python dependencies (oaaclient>=1.1.0 and others)"

"${VENV_DIR}/bin/pip" install --quiet --upgrade pip
"${VENV_DIR}/bin/pip" install --quiet -r "${SCRIPTS_DIR}/requirements.txt" \
    || die "pip install failed. Check ${SCRIPTS_DIR}/requirements.txt and network connectivity."

ok "Python dependencies installed."
info "Installed packages:"
"${VENV_DIR}/bin/pip" list --format=columns 2>/dev/null | grep -E "oaaclient|python-dotenv|requests|urllib3" | while read -r line; do
    info "  ${line}"
done

# ---------------------------------------------------------------------------
# MILESTONE 8 — Generate .env configuration file
# ---------------------------------------------------------------------------
milestone "Configuring environment (.env)"

ENV_FILE="${SCRIPTS_DIR}/.env"

if [[ -f "${ENV_FILE}" ]] && [[ "${OVERWRITE_ENV}" != "true" ]]; then
    warn ".env already exists at ${ENV_FILE}. Use --overwrite-env to replace it."
else
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        # Non-interactive: read from env vars
        VEZA_URL_VAL="${VEZA_URL:-}"
        VEZA_API_KEY_VAL="${VEZA_API_KEY:-}"
        DATA_DIR_VAL="${DATA_DIR:-}"
        [[ -z "${VEZA_URL_VAL}" ]]     && die "VEZA_URL env var is required in non-interactive mode."
        [[ -z "${VEZA_API_KEY_VAL}" ]] && die "VEZA_API_KEY env var is required in non-interactive mode."
    else
        # Interactive: prompt using /dev/tty (works when piped via curl | bash)
        echo ""
        IFS= read -r -p "  Veza URL (e.g. https://example.veza.com): " VEZA_URL_VAL </dev/tty
        IFS= read -r -s -p "  Veza API Key: " VEZA_API_KEY_VAL </dev/tty; echo >/dev/tty
        IFS= read -r -p "  Data directory (leave blank for default 'samples/'): " DATA_DIR_VAL </dev/tty
    fi

    cat > "${ENV_FILE}" <<EOF
# Odam RDP → Veza OAA — Environment Configuration
# Generated by install_odam-rdp.sh on $(date)
# chmod 600 ${ENV_FILE}

VEZA_URL=${VEZA_URL_VAL}
VEZA_API_KEY=${VEZA_API_KEY_VAL}

# Optional: override the CSV data directory
EOF
    if [[ -n "${DATA_DIR_VAL:-}" ]]; then
        echo "DATA_DIR=${DATA_DIR_VAL}" >> "${ENV_FILE}"
    else
        echo "# DATA_DIR=/path/to/csv/exports" >> "${ENV_FILE}"
    fi

    cat >> "${ENV_FILE}" <<'EOF'

# Optional: override OAA provider / datasource labels
# PROVIDER_NAME=Odam RDP
# DATASOURCE_NAME=CrowdStrike RDP Sessions
EOF

    chmod 600 "${ENV_FILE}"
    ok ".env created and secured (chmod 600) at ${ENV_FILE}"
fi

# ---------------------------------------------------------------------------
# MILESTONE 9 — Final summary
# ---------------------------------------------------------------------------
milestone "Installation complete"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         Odam RDP → Veza OAA — Install Complete       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Install root : ${INSTALL_DIR}"
echo "  Scripts      : ${SCRIPTS_DIR}"
echo "  Logs         : ${LOG_DIR}"
echo "  .env file    : ${ENV_FILE}"
echo ""
echo "  Next steps:"
echo ""
echo "  1. Verify/edit your credentials:"
echo "     ${ENV_FILE}"
echo ""
echo "  2. Place or copy your CrowdStrike RDP CSV export(s) to a data directory."
echo ""
echo "  3. Run a dry-run to validate the payload:"
echo "     cd ${SCRIPTS_DIR}"
echo "     source venv/bin/activate"
echo "     python3 odam-rdp.py --env-file .env --dry-run --save-json --log-level DEBUG"
echo ""
echo "  4. Run the full integration:"
echo "     python3 odam-rdp.py --env-file .env --log-level INFO"
echo ""
echo "  5. (Optional) Schedule via cron:"
echo "     0 */6 * * * ${SCRIPTS_DIR}/venv/bin/python3 ${SCRIPTS_DIR}/odam-rdp.py --env-file ${SCRIPTS_DIR}/.env >> ${LOG_DIR}/cron.log 2>&1"
echo ""
