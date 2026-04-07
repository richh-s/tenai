#!/usr/bin/env bash
# scripts/lib/state_track.sh — Shell wrapper for the state tracker
#
# Source this after detect.sh in any install/configure script:
#   source "$INFRA_DIR/scripts/lib/state_track.sh"
#
# Exports:
#   tenai_track <type> [--key value ...]  — record an entry (always non-fatal)
#   sudo_prompt "<reason>"               — print contextual sudo box before sudo
#   TENAI_MANIFEST_DIR                   — ~/.tenai/state/<device>

# ── Resolve PYTHON if not already set ────────────────────────────────────────
if [[ -z "${PYTHON:-}" ]]; then
  INFRA_DIR="${INFRA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  PYTHON="${INFRA_DIR}/.venv/bin/python3"
  [[ -x "$PYTHON" ]] || PYTHON="$(command -v python3 2>/dev/null || echo python3)"
fi

# ── Resolve DEVICE_NAME if not already set ───────────────────────────────────
# Prefer NAME (from make onboard NAME=x), fall back to hostname -s
if [[ -z "${DEVICE_NAME:-}" ]]; then
  DEVICE_NAME="${NAME:-$(hostname -s 2>/dev/null || echo local)}"
fi
export DEVICE_NAME

# ── Manifest directory export ─────────────────────────────────────────────────
TENAI_MANIFEST_DIR="${HOME}/.tenai/state/${DEVICE_NAME}"
export TENAI_MANIFEST_DIR

# ── Core tracking function ────────────────────────────────────────────────────
# Usage: tenai_track <type> [--key value ...]
# Always runs with || true — tracking NEVER aborts an install step.
tenai_track() {
  local type="$1"; shift
  local infra_dir="${INFRA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  "$PYTHON" "${infra_dir}/scripts/lib/state_tracker.py" track \
    --device "$DEVICE_NAME" \
    --type   "$type" \
    "$@" 2>/dev/null || true
}
export -f tenai_track

# ── Provisional rename (call after register_device.py succeeds) ───────────────
# Usage: tenai_finalize_device_name "<final-name>"
tenai_finalize_device_name() {
  local final_name="$1"
  local old_name="$DEVICE_NAME"
  if [[ "$final_name" == "$old_name" ]]; then return; fi
  local infra_dir="${INFRA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  "$PYTHON" "${infra_dir}/scripts/lib/state_tracker.py" rename-provisional \
    --from "$old_name" --to "$final_name" 2>/dev/null || true
  export DEVICE_NAME="$final_name"
  export TENAI_MANIFEST_DIR="${HOME}/.tenai/state/${DEVICE_NAME}"
}
export -f tenai_finalize_device_name

# ── Contextual sudo prompt ────────────────────────────────────────────────────
# Usage: sudo_prompt "Installing Tailscale (system daemon)"
# Call immediately before any sudo command.
sudo_prompt() {
  local reason="${1:-tenai needs elevated privileges}"
  local width=61
  local inner
  inner="  ${reason}"
  # Pad or trim to width
  printf '\n'
  printf '  ┌─ sudo required '
  printf '%.0s─' $(seq 1 $((width - 16)))
  printf '┐\n'
  printf '  │  %-*s│\n' "$((width - 3))" "$reason"
  printf '  │  %-*s│\n' "$((width - 3))" "Enter YOUR SYSTEM password — not a tenai credential."
  printf '  └'
  printf '%.0s─' $(seq 1 $((width - 1)))
  printf '┘\n\n'
}
export -f sudo_prompt
