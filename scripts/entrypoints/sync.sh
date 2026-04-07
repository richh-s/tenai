#!/bin/bash
# scripts/entrypoints/sync.sh — Sync code + config to a remote device
#
# Usage: bash scripts/entrypoints/sync.sh <HOST> [GIT_PULL=0|1]
#
# Syncs code (rsync or git pull), sets up git if missing, propagates .env,
# ensures SSH key auth, restarts webapp if running, pushes aliases.
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

# SSH key name (read from config; default: tenai-ssh-key)
SSH_KEY_NAME=$("$PYTHON" -c "
import sys; sys.path.insert(0, '$INFRA_DIR')
from scripts.lib.load_config import load_config
c = load_config()
print(c.get('ssh', {}).get('key_name', 'tenai-ssh-key'))
" 2>/dev/null || echo "tenai-ssh-key")

HOST="${1:?Usage: sync.sh <HOST> [GIT_PULL]}"
GIT_PULL="${2:-0}"

# ── Resolve host info ────────────────────────────────────────────────────────
eval "$("$PYTHON" scripts/configure/resolve_host.py "$HOST")"
PORT="${RESOLVED_SSH_PORT:-22}"
SSH_CMD="ssh -p ${PORT}"
TARGET="${RESOLVED_USER}@${RESOLVED_IP}"

echo "── Syncing $REMOTE_INFRA_DIR → ${RESOLVED_NAME} (${TARGET}) ──"

# ── Sync code ────────────────────────────────────────────────────────────────
if [ "$GIT_PULL" = "1" ]; then
  echo "  Mode: git pull"
  $SSH_CMD "$TARGET" "cd ~/$REMOTE_INFRA_DIR && git pull --ff-only" || \
    { echo "✗ git pull failed (dirty tree or no remote?)"; exit 1; }
else
  echo "  Mode: rsync from local"
  rsync -az --delete -e "ssh -p ${PORT}" \
    --exclude='.git/' --exclude='.venv/' --exclude='node_modules/' \
    --exclude='__pycache__/' --exclude='*.pyc' --exclude='.DS_Store' \
    --exclude='.env' \
    ./ "${TARGET}:~/$REMOTE_INFRA_DIR/"
fi

# ── Ensure git is set up ────────────────────────────────────────────────────
echo "── Checking git setup ──"
if ! $SSH_CMD "$TARGET" "test -d ~/$REMOTE_INFRA_DIR/.git" 2>/dev/null; then
  ORIGIN_URL=$(git remote get-url origin 2>/dev/null || echo "")
  if [ -n "$ORIGIN_URL" ]; then
    echo "  Initializing git + setting origin: ${ORIGIN_URL}"
    $SSH_CMD "$TARGET" \
      "cd ~/$REMOTE_INFRA_DIR && git init && git remote add origin ${ORIGIN_URL} && git fetch origin && git checkout -b main origin/main 2>/dev/null || git reset --mixed origin/main 2>/dev/null || true"
  else
    echo "  ⊘ No local origin URL to copy, skipping git init"
  fi
else
  echo "  ✓ .git already exists"
fi

echo "✓ Code synced to ${RESOLVED_NAME}"

# ── Propagate .env ───────────────────────────────────────────────────────────
echo "── Propagating .env ──"
if [ -f .env ]; then
  sed -e "s/^DEVICE_NAME=.*/DEVICE_NAME=${RESOLVED_NAME}/" \
      -e "s/^DEVICE_TYPE=.*/DEVICE_TYPE=${RESOLVED_TYPE}/" .env \
    | $SSH_CMD "$TARGET" "cat > ~/$REMOTE_INFRA_DIR/.env"
  echo "  ✓ .env sent (DEVICE_NAME=${RESOLVED_NAME}, DEVICE_TYPE=${RESOLVED_TYPE})"
else
  echo "  ⊘ No local .env to propagate"
fi

# ── Ensure SSH key authorization ─────────────────────────────────────────────
echo "── Ensuring SSH key authorization ──"
$SSH_CMD "$TARGET" \
  "if [ -f ~/.ssh/${SSH_KEY_NAME}.pub ]; then
     grep -qf ~/.ssh/${SSH_KEY_NAME}.pub ~/.ssh/authorized_keys 2>/dev/null || \\
       cat ~/.ssh/${SSH_KEY_NAME}.pub >> ~/.ssh/authorized_keys && \\
       echo '  ✓ SSH key added to authorized_keys'
   else
     echo '  ⊘ No ${SSH_KEY_NAME}.pub found'
   fi" || true

# ── Restart webapp if running (servers only) ─────────────────────────────────
if [[ "$RESOLVED_TYPE" == "server" || "$RESOLVED_TYPE" == "mac" || "$RESOLVED_TYPE" == "wsl" ]]; then
if $SSH_CMD "$TARGET" "docker ps --format '{{.Names}}' 2>/dev/null | grep -q webapp"; then
  echo "── Restarting webapp (Docker) ──"
  # Pre-create volume mount dirs/files so Docker doesn't create them as root
  $SSH_CMD "$TARGET" "mkdir -p ~/.tenai && chmod 700 ~/.tenai 2>/dev/null || true; \
    if [ -d ~/$REMOTE_INFRA_DIR/.env ]; then rm -rf ~/$REMOTE_INFRA_DIR/.env; fi; \
    [ -f ~/$REMOTE_INFRA_DIR/.env ] || touch ~/$REMOTE_INFRA_DIR/.env"
  $SSH_CMD "$TARGET" "cd ~/$REMOTE_INFRA_DIR && docker compose down && docker compose up -d --build webapp"
  echo "✓ Webapp Docker container rebuilt and restarted"
elif $SSH_CMD "$TARGET" "tmux has-session -t tenai-webapp 2>/dev/null || tmux has-session -t tenacious-webapp 2>/dev/null"; then
  echo "── Restarting webapp (tmux) ──"
  $SSH_CMD "$TARGET" \
    "tmux send-keys -t tenai-webapp C-c 2>/dev/null; tmux send-keys -t tenacious-webapp C-c 2>/dev/null; sleep 1; tmux send-keys -t tenai-webapp 'cd ~/$REMOTE_INFRA_DIR && make webapp-bg' Enter 2>/dev/null; tmux send-keys -t tenacious-webapp 'cd ~/$REMOTE_INFRA_DIR && make webapp-bg' Enter 2>/dev/null || true"
  echo "✓ Webapp restarted"
fi
else
  echo "── Skipping webapp restart (${RESOLVED_TYPE} device) ──"
fi

# ── Ensure VibeTunnel server is running (workstation only) ───────────────────
if [[ "$RESOLVED_TYPE" == "server" || "$RESOLVED_TYPE" == "mac" || "$RESOLVED_TYPE" == "wsl" ]]; then
VT_PORT="${VT_PORT:-4020}"
if $SSH_CMD "$TARGET" "command -v vibetunnel >/dev/null 2>&1 || test -d \$(npm root -g 2>/dev/null)/vibetunnel 2>/dev/null" 2>/dev/null; then
  if $SSH_CMD "$TARGET" "systemctl --user is-active vibetunnel >/dev/null 2>&1 || ss -tlnp 2>/dev/null | grep -q :${VT_PORT}" 2>/dev/null; then
    echo "✓ VibeTunnel already running"
  else
    echo "── Starting VibeTunnel server ──"
    $SSH_CMD "$TARGET" "\
      if systemctl --user start vibetunnel 2>/dev/null; then \
        sleep 2; echo '✓ VibeTunnel started (systemd)'; \
      else \
        VT_DIR=\$(npm root -g)/vibetunnel; \
        tmux new-session -d -s vt-server \"cd \$VT_DIR && exec node dist/cli.js --no-auth --port ${VT_PORT}\" 2>/dev/null; \
        sleep 3; echo '✓ VibeTunnel started (tmux fallback)'; \
      fi" || echo "  ⊘ VibeTunnel start skipped"
  fi
fi
fi

# ── Sync CLI skills/extensions/settings (workstation only) ───────────────────
if [[ "$RESOLVED_TYPE" == "server" || "$RESOLVED_TYPE" == "mac" || "$RESOLVED_TYPE" == "wsl" ]]; then
  echo "── Setting up CLI skills on ${RESOLVED_NAME} ──"
  $SSH_CMD "$TARGET" \
    "cd ~/$REMOTE_INFRA_DIR && bash scripts/install/cli_setup.sh" 2>&1 | \
    sed 's/^/  /' || echo "  ⚠ CLI setup failed (non-fatal)"
else
  echo "── Skipping CLI setup (${RESOLVED_TYPE} device) ──"
fi

# ── Push aliases ─────────────────────────────────────────────────────────────
echo "── Updating aliases on ${HOST} ──"
bash scripts/configure/push_aliases.sh "$HOST"

# ── Sync named env files ─────────────────────────────────────────────────────
if [ -d "$HOME/.tenai_envs" ] && [ -n "$(ls -A "$HOME/.tenai_envs/" 2>/dev/null)" ]; then
  echo "── Syncing env files to ${RESOLVED_NAME} ──"
  # Ensure remote directory exists with correct permissions
  $SSH_CMD "$TARGET" "mkdir -p ~/.tenai_envs && chmod 700 ~/.tenai_envs" 2>/dev/null || true
  rsync -az --chmod=D700,F600 -e "ssh -p ${PORT}" \
    "$HOME/.tenai_envs/" "${TARGET}:~/.tenai_envs/" && \
    echo "✓ Env files synced" || echo "  ⚠ Env sync failed (check permissions on remote)"
else
  echo "── Skipping env sync (no files in ~/.tenai_envs/) ──"
fi
