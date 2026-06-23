#!/usr/bin/env bash
# =============================================================================
# preflight.sh — Pre-deployment validation for Odam RDP → Veza OAA
#
# Usage:
#   bash preflight.sh          → Interactive numbered menu
#   bash preflight.sh --all    → Run all checks non-interactively (exit 0=pass, 1=fail)
# =============================================================================
# NOTE: do NOT use set -e — checks must continue past individual failures
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
PYTHON_SCRIPT="${SCRIPT_DIR}/odam-rdp.py"
REQUIREMENTS="${SCRIPT_DIR}/requirements.txt"
VENV_PYTHON="${SCRIPT_DIR}/venv/bin/python3"
LOG_DIR="${SCRIPT_DIR}/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${SCRIPT_DIR}/preflight_${TIMESTAMP}.log"

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_WARNING=0

# ---------------------------------------------------------------------------
# Colour output & logging
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'

_log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') $*" >> "${LOG_FILE}"; }
print_pass()  { echo -e "${GREEN}  ✓ PASS${NC}  $*"; _log "PASS  $*"; (( TESTS_PASSED++ )) || true; }
print_fail()  { echo -e "${RED}  ✗ FAIL${NC}  $*"; _log "FAIL  $*"; (( TESTS_FAILED++ )) || true; }
print_warn()  { echo -e "${YELLOW}  ⚠ WARN${NC}  $*"; _log "WARN  $*"; (( TESTS_WARNING++ )) || true; }
print_info()  { echo -e "${BLUE}  ℹ INFO${NC}  $*"; _log "INFO  $*"; }
print_header(){ echo ""; echo -e "${BLUE}──────────────────────────────────────────────${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}──────────────────────────────────────────────${NC}"; _log "=== $* ==="; }

# ---------------------------------------------------------------------------
# Mask secrets in output
# ---------------------------------------------------------------------------
_mask() {
    local val="$1"
    if [[ ${#val} -gt 8 ]]; then
        echo "${val:0:8}..."
    else
        echo "****"
    fi
}

# ---------------------------------------------------------------------------
# 1 — System Requirements
# ---------------------------------------------------------------------------
check_system() {
    print_header "1 — System Requirements"

    # Python version
    if command -v python3 &>/dev/null; then
        PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')")
        PY_MAJOR=$(echo "${PY_VER}" | cut -d. -f1)
        PY_MINOR=$(echo "${PY_VER}" | cut -d. -f2)
        if [[ "${PY_MAJOR}" -ge 3 ]] && [[ "${PY_MINOR}" -ge 9 ]]; then
            print_pass "Python ${PY_VER}"
        elif [[ "${PY_MAJOR}" -ge 3 ]] && [[ "${PY_MINOR}" -ge 8 ]]; then
            print_warn "Python ${PY_VER} (3.9+ recommended)"
        else
            print_fail "Python ${PY_VER} — 3.8+ required"
        fi
    else
        print_fail "python3 not found"
    fi

    # pip3
    if python3 -m pip --version &>/dev/null; then
        PIP_VER=$(python3 -m pip --version | awk '{print $2}')
        print_pass "pip ${PIP_VER}"
    else
        print_fail "pip3 not found — install python3-pip"
    fi

    # virtual environment
    if [[ -d "${SCRIPT_DIR}/venv" ]]; then
        print_pass "venv exists at ${SCRIPT_DIR}/venv"
    else
        print_warn "No venv found at ${SCRIPT_DIR}/venv — run install_odam-rdp.sh or: python3 -m venv venv && venv/bin/pip install -r requirements.txt"
    fi

    # curl
    if command -v curl &>/dev/null; then
        CURL_VER=$(curl --version 2>/dev/null | head -1 | awk '{print $2}')
        print_pass "curl ${CURL_VER}"
    else
        print_fail "curl not found — required for API auth tests"
    fi

    # jq (optional)
    if command -v jq &>/dev/null; then
        print_pass "jq $(jq --version 2>/dev/null)"
    else
        print_warn "jq not found (optional — install with: dnf install jq / apt install jq)"
    fi
}

# ---------------------------------------------------------------------------
# 2 — Python Dependencies
# ---------------------------------------------------------------------------
check_python_deps() {
    print_header "2 — Python Dependencies"

    PYTHON_BIN="python3"
    if [[ -x "${VENV_PYTHON}" ]]; then
        PYTHON_BIN="${VENV_PYTHON}"
        print_info "Using venv python: ${VENV_PYTHON}"
    else
        print_warn "venv not found — using system python3"
    fi

    if [[ ! -f "${REQUIREMENTS}" ]]; then
        print_fail "requirements.txt not found at ${REQUIREMENTS}"
        return
    fi

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Strip version specifiers and comments
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [[ -z "${line}" ]] && continue
        pkg="${line%%[><=!]*}"
        pkg_import="${pkg//-/_}"

        if "${PYTHON_BIN}" -c "import importlib; m=importlib.import_module('${pkg_import}'); print(getattr(m,'__version__','unknown'))" 2>/dev/null; then
            ver=$("${PYTHON_BIN}" -c "import importlib; m=importlib.import_module('${pkg_import}'); print(getattr(m,'__version__','unknown'))" 2>/dev/null)
            print_pass "${pkg} ${ver}"
        else
            # Try oaaclient specifically (module name differs from package name)
            if [[ "${pkg}" == "oaaclient" ]]; then
                if "${PYTHON_BIN}" -c "import oaaclient" &>/dev/null; then
                    ver=$("${PYTHON_BIN}" -c "import oaaclient; print(getattr(oaaclient,'__version__','unknown'))" 2>/dev/null)
                    print_pass "oaaclient ${ver}"
                else
                    print_fail "oaaclient not importable — run: ${PYTHON_BIN} -m pip install -r ${REQUIREMENTS}"
                fi
            else
                print_fail "${pkg} not importable — run: ${PYTHON_BIN} -m pip install -r ${REQUIREMENTS}"
            fi
        fi
    done < "${REQUIREMENTS}"
}

# ---------------------------------------------------------------------------
# 3 — Configuration File
# ---------------------------------------------------------------------------
check_config() {
    print_header "3 — Configuration File"

    if [[ ! -f "${ENV_FILE}" ]]; then
        print_fail ".env not found at ${ENV_FILE}"
        print_info "  Generate a template: cp ${SCRIPT_DIR}/.env.example ${ENV_FILE}"
        return
    fi
    print_pass ".env found at ${ENV_FILE}"

    # Check permissions (octal)
    PERMS=$(stat -c "%a" "${ENV_FILE}" 2>/dev/null || stat -f "%OLp" "${ENV_FILE}" 2>/dev/null || echo "unknown")
    if [[ "${PERMS}" == "600" ]]; then
        print_pass ".env permissions: ${PERMS}"
    else
        print_warn ".env permissions: ${PERMS} — should be 600. Fix: chmod 600 ${ENV_FILE}"
    fi

    # Source the env file
    # shellcheck disable=SC1090
    set -a; source "${ENV_FILE}" 2>/dev/null; set +a

    # Validate required variables
    _check_var() {
        local name="$1"
        local val="${!name:-}"
        local sensitive="${2:-false}"
        if [[ -z "${val}" ]]; then
            print_fail "${name} is not set"
        elif [[ "${val}" =~ ^your_ ]] || [[ "${val}" =~ ^https://your- ]]; then
            print_fail "${name} still has placeholder value"
        else
            if [[ "${sensitive}" == "true" ]]; then
                print_pass "${name} = $(_mask "${val}")"
            else
                print_pass "${name} = ${val}"
            fi
        fi
    }

    _check_var "VEZA_URL"
    _check_var "VEZA_API_KEY" "true"

    # Optional vars
    [[ -n "${DATA_DIR:-}" ]]        && print_info "DATA_DIR = ${DATA_DIR}" || print_info "DATA_DIR not set (will use default samples/)"
    [[ -n "${PROVIDER_NAME:-}" ]]   && print_info "PROVIDER_NAME = ${PROVIDER_NAME}" || print_info "PROVIDER_NAME not set (default: Odam RDP)"
    [[ -n "${DATASOURCE_NAME:-}" ]] && print_info "DATASOURCE_NAME = ${DATASOURCE_NAME}" || print_info "DATASOURCE_NAME not set (default: CrowdStrike RDP Sessions)"
}

# ---------------------------------------------------------------------------
# 4 — Network Connectivity
# ---------------------------------------------------------------------------
check_network() {
    print_header "4 — Network Connectivity"

    # shellcheck disable=SC1090
    [[ -f "${ENV_FILE}" ]] && { set -a; source "${ENV_FILE}" 2>/dev/null; set +a; }

    _check_https() {
        local label="$1"
        local url="$2"
        local result
        result=$(curl -s -o /dev/null -w "%{http_code}|%{time_total}" -m 10 "${url}" 2>/dev/null || echo "000|0")
        local http_code; http_code=$(echo "${result}" | cut -d'|' -f1)
        local latency;   latency=$(echo "${result}" | cut -d'|' -f2)
        if [[ "${http_code}" != "000" ]]; then
            print_pass "${label} reachable (HTTP ${http_code}, ${latency}s)"
        else
            print_fail "${label} unreachable — check network/firewall"
        fi
    }

    # Veza endpoint
    if [[ -n "${VEZA_URL:-}" ]]; then
        _check_https "Veza (${VEZA_URL})" "${VEZA_URL}/api/v1/providers"
    else
        print_warn "VEZA_URL not set — skipping Veza connectivity check"
    fi

    # Data directory reachability (local path — just check it exists)
    DATA_DIR_CHECK="${DATA_DIR:-${SCRIPT_DIR}/samples}"
    if [[ -d "${DATA_DIR_CHECK}" ]]; then
        CSV_COUNT=$(find "${DATA_DIR_CHECK}" -maxdepth 1 -iname "*.csv" 2>/dev/null | wc -l | tr -d ' ')
        print_pass "Data directory exists: ${DATA_DIR_CHECK} (${CSV_COUNT} CSV file(s))"
    else
        print_fail "Data directory not found: ${DATA_DIR_CHECK}"
    fi
}

# ---------------------------------------------------------------------------
# 5 — API Authentication
# ---------------------------------------------------------------------------
check_auth() {
    print_header "5 — API Authentication"

    # shellcheck disable=SC1090
    [[ -f "${ENV_FILE}" ]] && { set -a; source "${ENV_FILE}" 2>/dev/null; set +a; }

    if [[ -z "${VEZA_URL:-}" ]] || [[ -z "${VEZA_API_KEY:-}" ]]; then
        print_warn "VEZA_URL or VEZA_API_KEY not set — skipping auth test"
        return
    fi

    HTTP_RESULT=$(curl -s -o /tmp/veza_auth_test.json \
        -w "%{http_code}" \
        -H "Authorization: Bearer ${VEZA_API_KEY}" \
        -H "Content-Type: application/json" \
        -m 15 \
        "${VEZA_URL}/api/v1/providers" 2>/dev/null || echo "000")

    if [[ "${HTTP_RESULT}" == "200" ]]; then
        print_pass "Veza API authentication successful (HTTP 200)"
    elif [[ "${HTTP_RESULT}" == "401" ]]; then
        print_fail "Veza API key invalid (HTTP 401) — check VEZA_API_KEY"
    elif [[ "${HTTP_RESULT}" == "403" ]]; then
        print_fail "Veza API key lacks permission (HTTP 403) — check key scopes"
    elif [[ "${HTTP_RESULT}" == "000" ]]; then
        print_fail "Could not reach Veza — check VEZA_URL and network"
    else
        print_warn "Unexpected HTTP ${HTTP_RESULT} from Veza"
    fi
    rm -f /tmp/veza_auth_test.json
}

# ---------------------------------------------------------------------------
# 6 — Veza Endpoint Access (Query API)
# ---------------------------------------------------------------------------
check_veza_access() {
    print_header "6 — Veza Endpoint Access"

    # shellcheck disable=SC1090
    [[ -f "${ENV_FILE}" ]] && { set -a; source "${ENV_FILE}" 2>/dev/null; set +a; }

    if [[ -z "${VEZA_URL:-}" ]] || [[ -z "${VEZA_API_KEY:-}" ]]; then
        print_warn "VEZA_URL or VEZA_API_KEY not set — skipping"
        return
    fi

    HTTP_RESULT=$(curl -s -o /dev/null \
        -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${VEZA_API_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"query":"{ nodes { id } }"}' \
        -m 15 \
        "${VEZA_URL}/api/v1/providers" 2>/dev/null || echo "000")

    if [[ "${HTTP_RESULT}" =~ ^(200|400|404)$ ]]; then
        print_pass "Veza API key has read access (HTTP ${HTTP_RESULT})"
    elif [[ "${HTTP_RESULT}" == "401" ]]; then
        print_fail "Unauthorized (HTTP 401) — API key is invalid"
    elif [[ "${HTTP_RESULT}" == "403" ]]; then
        print_fail "Forbidden (HTTP 403) — API key lacks read permissions"
    else
        print_warn "Unexpected response: HTTP ${HTTP_RESULT}"
    fi
}

# ---------------------------------------------------------------------------
# 7 — Deployment Structure
# ---------------------------------------------------------------------------
check_structure() {
    print_header "7 — Deployment Structure"

    # Python script
    if [[ -f "${PYTHON_SCRIPT}" ]] && [[ -r "${PYTHON_SCRIPT}" ]]; then
        print_pass "odam-rdp.py found and readable"
    else
        print_fail "odam-rdp.py not found at ${PYTHON_SCRIPT}"
    fi

    # requirements.txt
    if [[ -f "${REQUIREMENTS}" ]]; then
        print_pass "requirements.txt found"
    else
        print_fail "requirements.txt not found at ${REQUIREMENTS}"
    fi

    # logs/ directory
    if [[ -d "${LOG_DIR}" ]]; then
        if [[ -w "${LOG_DIR}" ]]; then
            print_pass "logs/ directory exists and is writable"
        else
            print_fail "logs/ directory exists but is not writable — check permissions"
        fi
    else
        print_warn "logs/ directory not found — will be created on first run"
    fi

    # Running user
    print_info "Running as: $(whoami)"

    # --help test
    PYTHON_BIN="python3"
    [[ -x "${VENV_PYTHON}" ]] && PYTHON_BIN="${VENV_PYTHON}"
    if "${PYTHON_BIN}" "${PYTHON_SCRIPT}" --help &>/dev/null; then
        print_pass "odam-rdp.py --help executes without errors"
    else
        print_fail "odam-rdp.py --help failed — check Python script for syntax errors"
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Preflight Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${GREEN}Passed  : ${TESTS_PASSED}${NC}"
    echo -e "  ${YELLOW}Warnings: ${TESTS_WARNING}${NC}"
    echo -e "  ${RED}Failed  : ${TESTS_FAILED}${NC}"
    echo ""
    echo "  Log file: ${LOG_FILE}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ---------------------------------------------------------------------------
# Interactive menu (no args)
# ---------------------------------------------------------------------------
interactive_menu() {
    while true; do
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Odam RDP → Veza OAA — Preflight Menu"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  1) Check system requirements"
        echo "  2) Check Python dependencies"
        echo "  3) Validate configuration (.env)"
        echo "  4) Test network connectivity"
        echo "  5) Test API authentication"
        echo "  6) Test Veza endpoint access"
        echo "  7) Check deployment structure"
        echo "  8) Run ALL checks"
        echo "  9) Display current configuration"
        echo " 10) Generate .env template"
        echo "  q) Quit"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        IFS= read -r -p "  Select an option: " choice </dev/tty
        case "${choice}" in
            1) check_system ;;
            2) check_python_deps ;;
            3) check_config ;;
            4) check_network ;;
            5) check_auth ;;
            6) check_veza_access ;;
            7) check_structure ;;
            8) run_all_checks ;;
            9) display_config ;;
            10) generate_env_template ;;
            q|Q) echo "Exiting."; exit 0 ;;
            *) echo "Invalid option." ;;
        esac
        print_summary
    done
}

# ---------------------------------------------------------------------------
# Utility: display current config (masking secrets)
# ---------------------------------------------------------------------------
display_config() {
    print_header "Current Configuration"
    # shellcheck disable=SC1090
    [[ -f "${ENV_FILE}" ]] && { set -a; source "${ENV_FILE}" 2>/dev/null; set +a; }
    print_info "VEZA_URL         = ${VEZA_URL:-<not set>}"
    print_info "VEZA_API_KEY     = $([[ -n "${VEZA_API_KEY:-}" ]] && _mask "${VEZA_API_KEY}" || echo '<not set>')"
    print_info "DATA_DIR         = ${DATA_DIR:-<default: samples/>}"
    print_info "PROVIDER_NAME    = ${PROVIDER_NAME:-<default: Odam RDP>}"
    print_info "DATASOURCE_NAME  = ${DATASOURCE_NAME:-<default: CrowdStrike RDP Sessions>}"
    print_info "Script           = ${PYTHON_SCRIPT}"
    print_info "venv             = ${SCRIPT_DIR}/venv"
}

# ---------------------------------------------------------------------------
# Utility: generate .env template
# ---------------------------------------------------------------------------
generate_env_template() {
    print_header "Generate .env Template"
    TEMPLATE="${SCRIPT_DIR}/.env.example"
    if [[ -f "${TEMPLATE}" ]]; then
        print_info "Template already exists at ${TEMPLATE}"
        print_info "Copy with: cp ${TEMPLATE} ${ENV_FILE} && chmod 600 ${ENV_FILE}"
    else
        cat > "${TEMPLATE}" <<'EOF'
# Odam RDP → Veza OAA — Environment Template
VEZA_URL=https://your-tenant.veza.com
VEZA_API_KEY=your_veza_api_key_here
# DATA_DIR=/path/to/csv/exports
# PROVIDER_NAME=Odam RDP
# DATASOURCE_NAME=CrowdStrike RDP Sessions
EOF
        print_pass "Template created at ${TEMPLATE}"
        print_info "Copy with: cp ${TEMPLATE} ${ENV_FILE} && chmod 600 ${ENV_FILE}"
    fi
}

# ---------------------------------------------------------------------------
# Run all checks
# ---------------------------------------------------------------------------
run_all_checks() {
    check_system
    check_python_deps
    check_config
    check_network
    check_auth
    check_veza_access
    check_structure
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "${LOG_FILE}")"
_log "Preflight started"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Odam RDP → Veza OAA — Preflight Validation"
echo "  $(date)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "${1:-}" == "--all" ]]; then
    run_all_checks
    print_summary
    [[ "${TESTS_FAILED}" -eq 0 ]] && exit 0 || exit 1
else
    interactive_menu
fi
