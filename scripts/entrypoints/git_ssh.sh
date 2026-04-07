#!/bin/bash
# scripts/entrypoints/git_ssh.sh — Set up per-org SSH keys for GitHub
#
# Usage:
#   bash scripts/entrypoints/git_ssh.sh                         # all orgs, local
#   bash scripts/entrypoints/git_ssh.sh <HOST>                  # all orgs on remote
#   bash scripts/entrypoints/git_ssh.sh <HOST> <ORG> [KEY]      # single org on remote
#   ORG=yabebalFantaye bash scripts/entrypoints/git_ssh.sh         # single org, local
#
# Env vars: HOST, ORG, KEY, TOKEN, GENERATE_GIT_SSH_KEY
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$INFRA_DIR"

PYTHON="${PYTHON:-$INFRA_DIR/.venv/bin/python3}"
[[ -x "$PYTHON" ]] || PYTHON="$(command -v python3)"

# Remote infra directory name (read from config; default: tenai)
REMOTE_INFRA_DIR=$("$PYTHON" -c "
import sys; sys.path.insert(0, '$INFRA_DIR')
from scripts.lib.load_config import load_config
c = load_config()
print(c.get('repos', {}).get('infra_dir', 'tenai'))
" 2>/dev/null || echo "tenai")

# Accept positional args or env vars
HOST="${1:-${HOST:-}}"
ORG="${2:-${ORG:-}}"
KEY="${3:-${KEY:-}}"
TOKEN="${TOKEN:-}"
GENERATE_GIT_SSH_KEY="${GENERATE_GIT_SSH_KEY:-0}"

# ── Helper: run git-ssh for one org ──────────────────────────────────────────
run_git_ssh_for_org() {
  local org="$1" key="$2"

  if [ -n "$HOST" ]; then
    eval "$("$PYTHON" scripts/configure/resolve_host.py "$HOST")"
    local SCP_CMD="scp -P ${RESOLVED_SSH_PORT:-22}"
    local SSH_CMD="ssh -p ${RESOLVED_SSH_PORT:-22}"
    local TARGET="${RESOLVED_USER}@${RESOLVED_IP}"

    # Copy or generate key on remote
    if [ "$GENERATE_GIT_SSH_KEY" != "1" ] && [ -f "$HOME/.ssh/$key" ]; then
      echo "  📋 Copying $key to ${RESOLVED_NAME}..."
      $SSH_CMD "$TARGET" "mkdir -p ~/.ssh && chmod 700 ~/.ssh" < /dev/null
      $SCP_CMD "$HOME/.ssh/$key" "$TARGET:~/.ssh/$key" < /dev/null 2>/dev/null || true
      $SCP_CMD "$HOME/.ssh/${key}.pub" "$TARGET:~/.ssh/${key}.pub" < /dev/null 2>/dev/null || true
      $SSH_CMD "$TARGET" "chmod 600 ~/.ssh/$key; chmod 644 ~/.ssh/${key}.pub" < /dev/null
      echo "  ✓ Key copied"
    elif [ "$GENERATE_GIT_SSH_KEY" = "1" ]; then
      echo "  🔑 Will generate new key on ${RESOLVED_NAME}"
    else
      echo "  ⚠ Local key ~/.ssh/$key not found — will generate on remote"
    fi

    # Run git-ssh-setup on remote
    $SSH_CMD "$TARGET" \
      "cd ~/$REMOTE_INFRA_DIR && bash scripts/configure/git-ssh-setup.sh --org $org --key $key" \
      < /dev/null
  else
    # Run locally
    local extra_args=""
    if [ -n "$TOKEN" ]; then extra_args="--upload --token $TOKEN"; fi
    bash scripts/configure/git-ssh-setup.sh --org "$org" --key "$key" $extra_args < /dev/null
  fi
}

# ── Main logic ───────────────────────────────────────────────────────────────
if [ -n "$ORG" ]; then
  # Single org
  if [ -z "$KEY" ]; then
    KEY=$("$PYTHON" scripts/configure/list_orgs.py --org "$ORG" | awk '{print $2}')
  fi
  echo "── Setting up git-ssh for ${ORG} (key=${KEY}) ──"
  run_git_ssh_for_org "$ORG" "$KEY"
else
  # All orgs from config
  echo "── Setting up git-ssh for all orgs ──"
  "$PYTHON" scripts/configure/list_orgs.py | while read -r org key; do
    echo ""
    echo "━━━ ${org} (key=${key}) ━━━"
    run_git_ssh_for_org "$org" "$key"
  done
fi

echo ""
echo "✓ Git SSH setup complete"
