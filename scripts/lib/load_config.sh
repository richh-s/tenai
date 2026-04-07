#!/bin/bash
# scripts/lib/load_config.sh — Shell helper for config loading.
# Sources this file to get _tenai_config_get() function and CONFIG_FILE variable.
#
# Usage:
#   source "$(dirname "$0")/../lib/load_config.sh"
#   model=$(_tenai_config_get conductor.gemini_model)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SCRIPT_DIR}/../.."

# Resolve Python — same logic as detect.sh
if [[ -x "${INFRA_DIR}/.venv/bin/python3" ]]; then
    _TENAI_PYTHON="${INFRA_DIR}/.venv/bin/python3"
elif command -v python3 &>/dev/null; then
    _TENAI_PYTHON="python3"
else
    _TENAI_PYTHON="python"
fi

# Effective config file (for legacy scripts that need the path)
CONFIG_FILE="${INFRA_DIR}/config/defaults.yaml"
LOCAL_CONFIG_FILE="${TENAI_CONFIG:-${INFRA_DIR}/config/local.yaml}"

_tenai_config_get() {
    # Usage: _tenai_config_get <dot.path> [default_value]
    local key="$1"
    local default="${2:-}"
    local result
    result=$("$_TENAI_PYTHON" "${INFRA_DIR}/scripts/lib/load_config.py" --get "$key" 2>/dev/null)
    if [[ -z "$result" ]]; then
        echo "$default"
    else
        echo "$result"
    fi
}
