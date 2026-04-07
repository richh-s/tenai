#!/bin/bash
# scripts/configure/push_aliases.sh — generate and push aliases to a remote device
# Usage: bash scripts/configure/push_aliases.sh <HOST>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

HOST="${1:?Usage: push_aliases.sh <HOST>}"

# ── Resolve host from config ─────────────────────────────────────────────────
PYTHON="$INFRA_DIR/.venv/bin/python3"
if [[ ! -x "$PYTHON" ]]; then
  PYTHON="$(command -v python3)"
fi

eval "$("$PYTHON" "$SCRIPT_DIR/resolve_host.py" "$HOST")"

REMOTE_USER="${RESOLVED_USER}"
REMOTE_IP="${RESOLVED_IP:-$HOST}"
REMOTE_TYPE="${RESOLVED_TYPE}"
DEVICE_NAME="${RESOLVED_NAME}"
SSH_PORT="${RESOLVED_SSH_PORT:-22}"

# ── Determine remote shell rc ────────────────────────────────────────────────
case "$REMOTE_TYPE" in
  android)      REMOTE_RC=".bashrc" ;;
  ios_ish)      REMOTE_RC=".profile" ;;
  mac)          REMOTE_RC=".zshrc" ;;
  windows)      REMOTE_RC=".bashrc" ;;
  ios_termius)
    echo "✗ Termius is a client-only SSH app — no aliases to push."
    echo "  Configure hosts directly in the Termius app."
    exit 0
    ;;
  *)            REMOTE_RC=".bashrc" ;;
esac

# ── SSH preflight check ──────────────────────────────────────────────────────
echo "── Checking SSH connectivity to ${DEVICE_NAME} (${REMOTE_USER}@${REMOTE_IP}:${SSH_PORT}) ──"
if ! ssh -p "${SSH_PORT}" -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${REMOTE_USER}@${REMOTE_IP}" "echo ok" &>/dev/null; then
  echo ""
  echo "✗ Cannot SSH into ${DEVICE_NAME} at ${REMOTE_USER}@${REMOTE_IP}:${SSH_PORT}"
  echo ""
  if [[ "$REMOTE_TYPE" == "android" ]]; then
    echo "  To set up your android device (Termux), run these commands ON THE PHONE:"
    echo ""
    echo "    1. Install Termux from F-Droid (not Play Store)"
    echo "    2. Open Termux and run:"
    echo "       pkg update && pkg install openssh"
    echo "       sshd"
    echo "    3. Set a password (for initial key copy):"
    echo "       passwd"
    echo "    4. From this machine, copy your SSH key:"
    echo "       ssh-copy-id -p ${SSH_PORT} ${REMOTE_USER}@${REMOTE_IP}"
    echo "    5. Ensure Tailscale is connected on the phone"
    echo ""
    echo "  After setup, re-run: make push-aliases HOST=${HOST}"
  elif [[ "$REMOTE_TYPE" == "ios_ish" ]]; then
    echo "  To set up iSH (run ON THE IPHONE):"
    echo ""
    echo "    1. Install iSH from the App Store"
    echo "    2. apk add openssh"
    echo "    3. ssh-keygen -A"
    echo "    4. passwd  (set root password)"
    echo "    5. /usr/sbin/sshd"
    echo "    6. From this machine: ssh-copy-id ${REMOTE_USER}@${REMOTE_IP}"
    echo "    7. Ensure Tailscale iOS app is connected"
    echo ""
    echo "  After setup, re-run: make push-aliases HOST=${HOST}"
  elif [[ "$REMOTE_TYPE" == "mac" ]]; then
    echo "  Prerequisites for macOS:"
    echo "    1. Enable Remote Login:"
    echo "       sudo systemsetup -setremotelogin on"
    echo "       Or: System Settings → General → Sharing → Remote Login"
    echo "    2. Allow access for your user or All users"
    echo "    3. If firewall is on, allow incoming SSH connections"
    echo "    4. Ensure Tailscale is connected on the Mac"
    echo "    5. From this machine: ssh-copy-id ${REMOTE_USER}@${REMOTE_IP}"
  elif [[ "$REMOTE_TYPE" == "windows" ]]; then
    echo "  Prerequisites for Windows:"
    echo "    1. Enable OpenSSH Server (Settings > Apps > Optional Features)"
    echo "    2. Start-Service sshd (in PowerShell as Admin)"
    echo "    3. From this machine: ssh-copy-id ${REMOTE_USER}@${REMOTE_IP}"
    echo "    4. Ensure Tailscale is connected"
  else
    echo "  Ensure the device is online and SSH is configured."
    echo "  Try: ssh -p ${SSH_PORT} ${REMOTE_USER}@${REMOTE_IP}"
  fi
  exit 1
fi
echo "✓ SSH connection OK"

# ── Generate aliases for the target device ───────────────────────────────────
TMP_ALIASES="/tmp/.tenai_aliases_${DEVICE_NAME}"
echo "── Generating aliases for ${DEVICE_NAME} (${REMOTE_TYPE}) ──"
"$PYTHON" "$SCRIPT_DIR/generate_aliases.py" --for-device "$DEVICE_NAME" --output "$TMP_ALIASES"

# ── Push aliases to remote device ────────────────────────────────────────────
echo "── Pushing aliases to ${DEVICE_NAME} ──"
# Try scp first; fall back to base64-over-ssh for devices where scp fails (e.g. iSH)
if ! scp -P "${SSH_PORT}" "$TMP_ALIASES" "${REMOTE_USER}@${REMOTE_IP}:~/.tenai_aliases" 2>/dev/null; then
  echo "  scp failed, falling back to ssh pipe..."
  ALIASES_B64=$(base64 < "$TMP_ALIASES")
  ssh -p "${SSH_PORT}" "${REMOTE_USER}@${REMOTE_IP}" "echo '${ALIASES_B64}' | base64 -d > ~/.tenai_aliases"
fi

# ── Ensure source line in remote shell rc ────────────────────────────────────
echo "── Ensuring aliases are sourced in ~/${REMOTE_RC} ──"
ssh -p "${SSH_PORT}" "${REMOTE_USER}@${REMOTE_IP}" "
  SOURCE_LINE='source ~/.tenai_aliases'
  if ! grep -qF \"\$SOURCE_LINE\" ~/${REMOTE_RC} 2>/dev/null; then
    echo '' >> ~/${REMOTE_RC}
    echo \"\$SOURCE_LINE\" >> ~/${REMOTE_RC}
    echo '✓ Added source line to ~/${REMOTE_RC}'
  else
    echo '✓ Source line already in ~/${REMOTE_RC}'
  fi
"

rm -f "$TMP_ALIASES"
echo "✓ Aliases pushed to ${DEVICE_NAME}"
echo "  SSH into ${DEVICE_NAME} and run: source ~/${REMOTE_RC}"
