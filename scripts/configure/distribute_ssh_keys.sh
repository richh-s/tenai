#!/bin/bash
# scripts/configure/distribute_ssh_keys.sh
# Distribute SSH public keys across all devices in the tailnet.
#
# Usage:
#   bash distribute_ssh_keys.sh           # full mesh: all devices ↔ all devices
#   bash distribute_ssh_keys.sh mydevice   # single device: mydevice ↔ all others
#
# Runs from the local machine (which must be able to reach all devices).
# Uses resolve_host.py to get ssh connection details per device.
set -euo pipefail

# This script uses associative arrays (declare -A) which require bash 4+.
# macOS /bin/bash is 3.2 — re-exec with Homebrew bash if available.
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  if [[ -x "/opt/homebrew/bin/bash" ]]; then
    exec /opt/homebrew/bin/bash "$0" "$@"
  elif [[ -x "/usr/local/bin/bash" ]]; then
    exec /usr/local/bin/bash "$0" "$@"
  fi
  echo "This script requires bash 4+ (for associative arrays). Install: brew install bash" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$INFRA_DIR/scripts/lib/state_track.sh"
PYTHON="${INFRA_DIR}/.venv/bin/python3"
[[ -x "$PYTHON" ]] || PYTHON="$(command -v python3)"


# Read SSH_KEY_NAME from config (ssh.key_name in defaults.yaml / local.yaml).
# Env var SSH_KEY_NAME overrides config if already set.
if [[ -z "${SSH_KEY_NAME:-}" ]]; then
  SSH_KEY_NAME=$("$PYTHON" -c "
import sys; sys.path.insert(0, '$INFRA_DIR')
from scripts.lib.load_config import load_config
c = load_config()
print(c.get('ssh', {}).get('key_name', 'tenai-ssh-key'))
" 2>/dev/null || echo "tenai-ssh-key")
fi

# Detect local device name
LOCAL_DEVICE="${DEVICE_NAME:-}"
if [ -z "$LOCAL_DEVICE" ]; then
  # Try to detect from Tailscale IP
  LOCAL_IP=$(tailscale ip -4 2>/dev/null || echo "")
  if [ -n "$LOCAL_IP" ]; then
    LOCAL_DEVICE=$("$PYTHON" -c "
import sys; sys.path.insert(0, '$INFRA_DIR')
from scripts.lib.load_config import load_config
cfg = load_config()
for name, info in cfg.get('tailscale',{}).get('devices',{}).items():
    if info.get('ip','') == '$LOCAL_IP':
        print(name); break
" 2>/dev/null || echo "")
  fi
fi

is_local() {
  [ "$1" = "$LOCAL_DEVICE" ]
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# Get SSH command for a device (handles port)
ssh_cmd_for() {
  local name="$1"
  eval "$("$PYTHON" "$SCRIPT_DIR/resolve_host.py" "$name")"
  local port="${RESOLVED_SSH_PORT:-22}"
  echo "ssh -p ${port} -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
}

# Get user@ip for a device
user_host_for() {
  local name="$1"
  eval "$("$PYTHON" "$SCRIPT_DIR/resolve_host.py" "$name")"
  echo "${RESOLVED_USER}@${RESOLVED_IP}"
}

# Check if we can SSH into a device (non-interactive)
can_reach() {
  local name="$1"
  if is_local "$name"; then return 0; fi
  local ssh_cmd user_host
  ssh_cmd=$(ssh_cmd_for "$name")
  user_host=$(user_host_for "$name")
  $ssh_cmd "$user_host" "echo ok" &>/dev/null
}

# Generate SSH key on a remote device if it doesn't exist
ensure_key_on_device() {
  local name="$1"
  echo "  Ensuring SSH key on ${name}..."

  if is_local "$name"; then
    # Local device: generate key directly
    local KEY="$HOME/.ssh/${SSH_KEY_NAME}"
    if [ ! -f "$KEY" ]; then
      mkdir -p ~/.ssh && chmod 700 ~/.ssh
      ssh-keygen -t ed25519 -f "$KEY" -N '' -C "${name}-tenai" >/dev/null 2>&1
      tenai_track ssh_key_created --path "~/.ssh/${SSH_KEY_NAME}"
      echo "  → Generated new key: ${SSH_KEY_NAME}"
    else
      echo "  ✓ Key exists"
    fi
    return
  fi

  local ssh_cmd user_host
  ssh_cmd=$(ssh_cmd_for "$name")
  user_host=$(user_host_for "$name")
  $ssh_cmd "$user_host" "
    KEY=~/.ssh/${SSH_KEY_NAME}
    if [ ! -f \"\$KEY\" ]; then
      mkdir -p ~/.ssh && chmod 700 ~/.ssh
      ssh-keygen -t ed25519 -f \"\$KEY\" -N '' -C \"${name}-tenai\" >/dev/null 2>&1
      echo '  → Generated new key: ${SSH_KEY_NAME}'
    else
      echo '  ✓ Key exists'
    fi
  "
}

# Fetch public key from a device
get_pubkey() {
  local name="$1"

  if is_local "$name"; then
    cat "$HOME/.ssh/${SSH_KEY_NAME}.pub" 2>/dev/null || cat "$HOME/.ssh/id_ed25519.pub" 2>/dev/null || echo ""
    return
  fi

  local ssh_cmd user_host
  ssh_cmd=$(ssh_cmd_for "$name")
  user_host=$(user_host_for "$name")

  $ssh_cmd "$user_host" "cat ~/.ssh/${SSH_KEY_NAME}.pub 2>/dev/null || cat ~/.ssh/id_ed25519.pub 2>/dev/null || echo ''" | head -1
}

# Add a public key to a device's authorized_keys (idempotent)
add_key_to_device() {
  local name="$1"
  local pubkey="$2"

  if [ -z "$pubkey" ]; then return; fi

  if is_local "$name"; then
    # Local device: write directly
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
    if ! grep -qF "$pubkey" ~/.ssh/authorized_keys 2>/dev/null; then
      echo "$pubkey" >> ~/.ssh/authorized_keys
      echo "    → Added key"
    else
      echo "    ✓ Already authorized"
    fi
    return
  fi

  local ssh_cmd user_host
  ssh_cmd=$(ssh_cmd_for "$name")
  user_host=$(user_host_for "$name")

  $ssh_cmd "$user_host" "
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
    if ! grep -qF '${pubkey}' ~/.ssh/authorized_keys 2>/dev/null; then
      echo '${pubkey}' >> ~/.ssh/authorized_keys
      echo '    → Added key'
    else
      echo '    ✓ Already authorized'
    fi
  "
}

# ── Get list of devices ───────────────────────────────────────────────────────

get_all_devices() {
  "$PYTHON" "$SCRIPT_DIR/list_devices.py" 2>/dev/null
}

# ── Main logic ────────────────────────────────────────────────────────────────

TARGET="${1:-}"

if [ -n "$TARGET" ]; then
  # Single device mode: distribute keys between TARGET and all others
  DEVICES=("$TARGET")
  ALL_DEVICES=($(get_all_devices))
else
  # Full mesh mode: all devices
  DEVICES=($(get_all_devices))
  ALL_DEVICES=("${DEVICES[@]}")
fi

echo "══════════════════════════════════════════════════"
echo "  SSH Key Distribution"
echo "══════════════════════════════════════════════════"
echo "  Key name: ${SSH_KEY_NAME}"
echo "  Devices:  ${DEVICES[*]}"
echo ""

# Phase 1: Ensure keys exist on all target devices and collect pubkeys
declare -A PUBKEYS

for dev in "${ALL_DEVICES[@]}"; do
  echo "── ${dev} ──"
  if ! can_reach "$dev"; then
    echo "  ⊘ Cannot reach ${dev} (skipping)"
    PUBKEYS[$dev]=""
    continue
  fi
  ensure_key_on_device "$dev"
  pubkey=$(get_pubkey "$dev")
  if [ -z "$pubkey" ]; then
    echo "  ⚠ No public key found on ${dev}"
  else
    echo "  ✓ Got pubkey: ${pubkey:0:40}..."
  fi
  PUBKEYS[$dev]="$pubkey"
done

echo ""

# Phase 2: Distribute keys
echo "── Distributing keys ──"
for src in "${DEVICES[@]}"; do
  src_key="${PUBKEYS[$src]:-}"
  if [ -z "$src_key" ]; then
    echo "  ⊘ No key for ${src}, skipping"
    continue
  fi

  for dst in "${ALL_DEVICES[@]}"; do
    [ "$src" = "$dst" ] && continue
    if [ -z "${PUBKEYS[$dst]:-}" ] && ! can_reach "$dst"; then
      echo "  ⊘ ${src} → ${dst}: unreachable"
      continue
    fi

    echo "  ${src} → ${dst}:"
    add_key_to_device "$dst" "$src_key"
  done
done

# Phase 2b: If single device mode, also add all other devices' keys TO the target
if [ -n "$TARGET" ]; then
  echo ""
  echo "── Adding other devices' keys to ${TARGET} ──"
  for other in "${ALL_DEVICES[@]}"; do
    [ "$other" = "$TARGET" ] && continue
    other_key="${PUBKEYS[$other]:-}"
    if [ -z "$other_key" ]; then
      echo "  ⊘ No key for ${other}, skipping"
      continue
    fi
    echo "  ${other} → ${TARGET}:"
    add_key_to_device "$TARGET" "$other_key"
  done
fi

echo ""
echo "✓ SSH key distribution complete"
