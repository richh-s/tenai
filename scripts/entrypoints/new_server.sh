#!/bin/bash
# scripts/entrypoints/new_server.sh — Bootstrap a remote device
#
# Usage: bash scripts/entrypoints/new_server.sh <HOST|IP> [NAME]
#
# Supports:
#   - Devices already in config/defaults.yaml (by name or IP)
#   - SSH config aliases (~/.ssh/config)
#   - Raw IP addresses (auto-detects type via remote detection)
#   - SSH_KEY env var for initial key-based access
#
# Expects PYTHON env var to point to the project's python interpreter.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$INFRA_DIR"

PYTHON="${PYTHON:-$INFRA_DIR/.venv/bin/python3}"
[[ -x "$PYTHON" ]] || PYTHON="$(command -v python3)"

# Remote infra directory name (read from repos.infra_dir config; default: tenai)
REMOTE_INFRA_DIR=$("$PYTHON" -c "
import sys; sys.path.insert(0, '$INFRA_DIR')
from scripts.lib.load_config import load_config
c = load_config()
print(c.get('repos', {}).get('infra_dir', 'tenai'))
" 2>/dev/null || echo "tenai")

HOST="${1:?Usage: new_server.sh <HOST|IP> [NAME]}"
NAME="${2:-}"

# Colors (matching Makefile/onboard)
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
err()   { echo -e "${RED}✗${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}──${NC} $* ${CYAN}──${NC}"; }

# ── Resolve host info (with fallback chain) ──────────────────────────────────
step "Resolving ${HOST}"

resolve_output=$("$PYTHON" scripts/configure/resolve_host.py "$HOST" --allow-unknown 2>&1) || true

if echo "$resolve_output" | grep -q "^RESOLVED_"; then
  eval "$resolve_output"
else
  # Fallback: treat HOST as raw IP/hostname
  warn "Could not resolve '${HOST}' from config — treating as raw address"
  RESOLVED_NAME="${NAME:-$HOST}"
  RESOLVED_USER=""
  RESOLVED_TYPE="server"
  RESOLVED_IP="$HOST"
  RESOLVED_SSH_PORT=22
  RESOLVED_SKIP_TOOLS=""
  RESOLVED_SSH_KEY="${SSH_KEY:-}"
  RESOLVED_SOURCE="raw"
fi

NAME_VAL="${NAME:-${RESOLVED_NAME:-$HOST}}"
USER_VAL="${RESOLVED_USER:-}"
TYPE_VAL="${RESOLVED_TYPE:-server}"
SKIP="${RESOLVED_SKIP_TOOLS:-}"
IP_VAL="${RESOLVED_IP:-$HOST}"
PORT="${RESOLVED_SSH_PORT:-22}"
SSH_KEY_VAL="${RESOLVED_SSH_KEY:-${SSH_KEY:-}}"

# Build SSH command
SSH_CMD="ssh -p ${PORT}"
if [[ -n "$SSH_KEY_VAL" ]] && [[ -f "$SSH_KEY_VAL" ]]; then
  SSH_CMD="$SSH_CMD -i $SSH_KEY_VAL"
fi

# ── Check SSH connectivity (with user auto-detection) ────────────────────────
step "Checking SSH connectivity"

# If no user, try common users
if [[ -z "$USER_VAL" ]]; then
  for try_user in ubuntu root "$(whoami)"; do
    if $SSH_CMD -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${try_user}@${IP_VAL}" "echo ok" &>/dev/null; then
      USER_VAL="$try_user"
      info "SSH OK: ${USER_VAL}@${IP_VAL}:${PORT}"
      break
    fi
  done
  if [[ -z "$USER_VAL" ]]; then
    err "Cannot SSH into ${IP_VAL}:${PORT} with any default user"
    echo ""
    echo "  Try specifying a user: make new-server HOST=${HOST} USER=myuser"
    echo "  Or provide a key:      make new-server HOST=${HOST} SSH_KEY=~/.ssh/mykey"
    exit 1
  fi
else
  if ! $SSH_CMD -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${USER_VAL}@${IP_VAL}" "echo ok" 2>/dev/null; then
    # Try password auth
    warn "Key-based auth failed. Trying password auth..."
    if ! ssh -p "${PORT}" -o ConnectTimeout=10 "${USER_VAL}@${IP_VAL}" "echo ok" 2>/dev/null; then
      err "Cannot SSH into ${NAME_VAL} at ${USER_VAL}@${IP_VAL}:${PORT}"
      echo ""
      case "${TYPE_VAL}" in
        android)
          echo "  Prerequisites for Termux (run ON THE PHONE):"
          echo "    1. Install Termux from F-Droid"
          echo "    2. pkg update && pkg install openssh"
          echo "    3. sshd"
          echo "    4. passwd  (set a password)"
          echo "    5. From this machine: ssh-copy-id -p ${PORT} ${USER_VAL}@${IP_VAL}"
          ;;
        ios_ish)
          echo "  Prerequisites for iSH (run ON THE IPHONE):"
          echo "    1. Install iSH from App Store"
          echo "    2. apk add openssh"
          echo "    3. ssh-keygen -A"
          echo "    4. passwd  (set root password)"
          echo "    5. /usr/sbin/sshd"
          ;;
        ios_termius)
          echo "  Termius is client-only. Use: make onboard TYPE=ios_termius"
          exit 0
          ;;
        mac)
          echo "  Prerequisites for macOS (run ON THE MAC):"
          echo "    1. Enable Remote Login:"
          echo "       sudo systemsetup -setremotelogin on"
          echo "       Or: System Settings → General → Sharing → Remote Login"
          echo "    2. Allow access for your user (or All users)"
          echo "    3. If firewall is on, allow incoming SSH connections"
          echo "    4. Ensure Tailscale is connected on the Mac"
          echo "    5. From this machine: ssh-copy-id ${USER_VAL}@${IP_VAL}"
          ;;
        windows)
          echo "  Prerequisites for Windows:"
          echo "    1. Install Tailscale"
          echo "    2. Enable OpenSSH Server (Settings > Apps > Optional Features)"
          echo "    3. Start sshd: Start-Service sshd"
          ;;
        *)
          echo "  Ensure the device is online and SSH is configured."
          echo "  Try: ssh-copy-id -p ${PORT} ${USER_VAL}@${IP_VAL}"
          ;;
      esac
      exit 1
    fi
  fi
  info "SSH OK: ${USER_VAL}@${IP_VAL}:${PORT}"
fi

# ── Auto-detect type if from raw/ssh_config source ──────────────────────────
if [[ "${RESOLVED_SOURCE:-}" == "raw" || "${RESOLVED_SOURCE:-}" == "ssh_config" ]]; then
  step "Detecting remote system type"
  local_detect_args=("${USER_VAL}@${IP_VAL}" "-p" "$PORT")
  if [[ -n "$SSH_KEY_VAL" ]] && [[ -f "$SSH_KEY_VAL" ]]; then
    local_detect_args+=("-i" "$SSH_KEY_VAL")
  fi

  detect_output=$(bash "$INFRA_DIR/scripts/configure/detect_remote.sh" "${local_detect_args[@]}" 2>/dev/null) || true
  if [[ -n "$detect_output" ]] && echo "$detect_output" | grep -q "^REMOTE_"; then
    eval "$detect_output"
    TYPE_VAL="${REMOTE_DEVICE_TYPE:-server}"
    NAME_VAL="${NAME:-${REMOTE_HOSTNAME:-$HOST}}"
    info "Detected: type=${TYPE_VAL}, hostname=${NAME_VAL}"
  else
    warn "Remote detection failed — using TYPE=${TYPE_VAL}"
  fi

  # Auto-register this new device
  step "Registering new device in config"
  "$PYTHON" scripts/configure/register_device.py \
    --name "$NAME_VAL" --ip "$IP_VAL" --user "$USER_VAL" --type "$TYPE_VAL" \
    --ssh-port "$PORT" --force-update
fi

echo ""
echo "── Bootstrapping: ${NAME_VAL} (${TYPE_VAL}) at ${IP_VAL}:${PORT} ──"
echo "  User: ${USER_VAL}"
echo "  Skip tools: ${SKIP:-none}"
echo ""

# ── Install remote prerequisites ─────────────────────────────────────────────
step "Installing remote prerequisites"
case "${TYPE_VAL}" in
  android)  $SSH_CMD "${USER_VAL}@${IP_VAL}" "pkg install -y rsync make curl" 2>&1 || true ;;
  ios_ish)  $SSH_CMD "${USER_VAL}@${IP_VAL}" "apk add rsync make curl bash" 2>&1 || true ;;
  *)        $SSH_CMD "${USER_VAL}@${IP_VAL}" "command -v rsync &>/dev/null || sudo apt-get install -y rsync 2>/dev/null || true" 2>&1 || true ;;
esac

# ── Sync infra files ─────────────────────────────────────────────────────────
step "Syncing infra files (rsync)"
$SSH_CMD -o StrictHostKeyChecking=accept-new "${USER_VAL}@${IP_VAL}" "mkdir -p ~/$REMOTE_INFRA_DIR"
rsync -az -e "ssh -p ${PORT}$([ -n "$SSH_KEY_VAL" ] && [ -f "$SSH_KEY_VAL" ] && echo " -i $SSH_KEY_VAL")" \
  --exclude='.git/' --exclude='.venv/' --exclude='node_modules/' \
  --exclude='__pycache__/' --exclude='*.pyc' --exclude='.DS_Store' \
  --exclude='.env' \
  ./ "${USER_VAL}@${IP_VAL}:~/$REMOTE_INFRA_DIR/"

# ── Set up remote .env ───────────────────────────────────────────────────────
step "Setting up remote .env"
if [ -f .env ]; then
  sed -e "s/^DEVICE_NAME=.*/DEVICE_NAME=${NAME_VAL}/" \
      -e "s/^DEVICE_TYPE=.*/DEVICE_TYPE=${TYPE_VAL}/" \
      -e "s/^SKIP_TOOLS=.*/SKIP_TOOLS=${SKIP}/" .env \
    | $SSH_CMD "${USER_VAL}@${IP_VAL}" "cat > ~/$REMOTE_INFRA_DIR/.env"
  info ".env propagated (DEVICE_NAME=${NAME_VAL}, DEVICE_TYPE=${TYPE_VAL})"
fi

# ── Run remote setup ─────────────────────────────────────────────────────────
step "Running remote setup"
$SSH_CMD "${USER_VAL}@${IP_VAL}" "cd ~/$REMOTE_INFRA_DIR && make DEVICE_TYPE=${TYPE_VAL} SKIP_TOOLS='${SKIP}'" || {
  warn "Remote 'make' had errors — some tools may not have installed"
  echo "  Try again: make sync HOST=${NAME_VAL} && make install HOST=${NAME_VAL}"
}
echo ""

# ── Distribute SSH keys ──────────────────────────────────────────────────────
step "Distributing SSH keys"
bash scripts/configure/distribute_ssh_keys.sh "$HOST" || warn "Key distribution incomplete"
echo ""

# ── Git SSH (per-org keys) ────────────────────────────────────────────────────
step "Setting up Git SSH (per-org keys)"
bash scripts/entrypoints/git_ssh.sh "$HOST" || warn "Git SSH setup incomplete"
echo ""

echo "═══════════════════════════════════════════════════"
echo "  ✓ ${NAME_VAL} fully bootstrapped"
echo "═══════════════════════════════════════════════════"
echo "  Connect:  ssh ${USER_VAL}@${IP_VAL} -p ${PORT}"
echo "  Check:    make check HOST=${NAME_VAL}"
echo "  Sync:     make sync HOST=${NAME_VAL}"
echo ""
