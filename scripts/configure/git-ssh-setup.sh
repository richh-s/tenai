#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# git-ssh-setup.sh — Portable PAT → SSH migration for GitHub
#
# Generates or reuses per-org SSH keys, configures ~/.ssh/config,
# and sets git to route all GitHub traffic through SSH.
#
# Usage:
#   # Interactive (prompts for org name):
#   bash git-ssh-setup.sh
#
#   # Non-interactive:
#   bash git-ssh-setup.sh --org example-org --key tenai-git-ssh-key
#
#   # Just enable global SSH rewrite (no key setup):
#   bash git-ssh-setup.sh --rewrite-only
#
#   # List configured orgs:
#   bash git-ssh-setup.sh --list
#
#   # Upload key to GitHub (requires PAT with admin:public_key scope):
#   bash git-ssh-setup.sh --org example-org --key tenai-git-ssh-key --upload --token ghp_xxx
#
# Workflow for a new machine:
#   1. Copy your existing key files to ~/.ssh/ on the new machine
#      (e.g., tenai-git-ssh-key and tenai-git-ssh-key.pub)
#   2. Run this script — it detects existing keys and skips generation
#   3. Done! Git uses SSH everywhere.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
info() { echo -e "${BLUE}[→]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
header() { echo -e "\n${BOLD}── $* ──${NC}"; }

# ── Defaults ────────────────────────────────────────────────────────────────
SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Pre-populate known_hosts for github.com to prevent interactive prompts on first clone
if ! grep -q "github.com" "$SSH_DIR/known_hosts" 2>/dev/null; then
  ssh-keyscan -t rsa,ed25519 github.com >> "$SSH_DIR/known_hosts" 2>/dev/null
fi
SSH_CONFIG="$SSH_DIR/config"
ORG=""
KEY_NAME=""
UPLOAD=false
GH_TOKEN=""
REWRITE_ONLY=false
LIST_ONLY=false
MARKER="# ── git-ssh-setup managed"

# ── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)          ORG="$2"; shift 2 ;;
    --key)          KEY_NAME="$2"; shift 2 ;;
    --upload)       UPLOAD=true; shift ;;
    --token)        GH_TOKEN="$2"; shift 2 ;;
    --rewrite-only) REWRITE_ONLY=true; shift ;;
    --list)         LIST_ONLY=true; shift ;;
    --help|-h)
      head -30 "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

# ── List configured orgs ───────────────────────────────────────────────────
if [[ "$LIST_ONLY" == true ]]; then
  header "Configured GitHub SSH keys"
  echo ""
  if [[ -f "$SSH_CONFIG" ]]; then
    grep -A3 "$MARKER" "$SSH_CONFIG" 2>/dev/null | \
      awk '/Host github-/{host=$2} /IdentityFile/{key=$2; printf "  %-25s → %s\n", host, key}' || true
  fi
  echo ""
  info "Global git rewrite:"
  git config --global --get-all url.git@github.com:.insteadof 2>/dev/null | \
    while read -r url; do echo "  $url → git@github.com:"; done || echo "  (not configured)"
  echo ""
  info "SSH keys in ~/.ssh/:"
  ls -1 "$SSH_DIR"/*-git-ssh-key 2>/dev/null | while read -r f; do
    echo "  $(basename "$f")  →  $(ssh-keygen -l -f "$f" 2>/dev/null | awk '{print $2}')"
  done || echo "  (none)"
  exit 0
fi

# ── Rewrite-only mode ──────────────────────────────────────────────────────
if [[ "$REWRITE_ONLY" == true ]]; then
  header "Enabling global HTTPS → SSH rewrite"
  git config --global url."git@github.com:".insteadOf "https://github.com/"
  ok "All git HTTPS URLs to github.com now route through SSH"
  info "Verify: git config --global --get url.git@github.com:.insteadof"
  exit 0
fi

# ── Interactive prompts if needed ───────────────────────────────────────────
if [[ -z "$ORG" ]]; then
  echo ""
  echo -e "${BOLD}GitHub SSH Key Setup${NC}"
  echo "Configure per-org SSH keys for GitHub."
  echo ""
  read -rp "GitHub org or username (e.g., example-org): " ORG
fi

if [[ -z "$ORG" ]]; then
  err "Org name is required."
  exit 1
fi

if [[ -z "$KEY_NAME" ]]; then
  # Derive key name from org
  local_prefix=$(echo "$ORG" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-12)
  KEY_NAME="${local_prefix}-git-ssh-key"
  read -rp "SSH key name [${KEY_NAME}]: " user_key
  KEY_NAME="${user_key:-$KEY_NAME}"
fi

KEY_PATH="$SSH_DIR/$KEY_NAME"
HOST_ALIAS="github-${ORG}"

# ── Ensure ~/.ssh ──────────────────────────────────────────────────────────
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# ── SSH key: reuse or generate ─────────────────────────────────────────────
header "SSH Key: $KEY_NAME"

if [[ -f "$KEY_PATH" ]]; then
  ok "Key already exists: $KEY_PATH"
  info "Fingerprint: $(ssh-keygen -l -f "$KEY_PATH" | awk '{print $2}')"
  chmod 600 "$KEY_PATH"
  [[ -f "${KEY_PATH}.pub" ]] && chmod 644 "${KEY_PATH}.pub"
else
  info "Generating new ed25519 key..."
  COMMENT="${USER:-$(whoami)}@$(hostname -s)-${ORG}"
  ssh-keygen -t ed25519 -C "$COMMENT" -f "$KEY_PATH" -N "" -q
  ok "Key generated: $KEY_PATH"
  echo ""
  echo -e "${BOLD}Public key (add to GitHub → Settings → SSH Keys):${NC}"
  echo ""
  cat "${KEY_PATH}.pub"
  echo ""
fi

# ── Add to SSH agent ──────────────────────────────────────────────────────
header "SSH Agent"
# Start agent if not running
if ! ssh-add -l &>/dev/null; then
  eval "$(ssh-agent -s)" >/dev/null 2>&1
fi

if ssh-add -l 2>/dev/null | grep -q "$KEY_NAME"; then
  ok "Key already loaded in agent"
else
  ssh-add "$KEY_PATH" 2>/dev/null
  ok "Key added to SSH agent"
fi

# On macOS, configure Keychain integration
if [[ "$(uname)" == "Darwin" ]]; then
  # Ensure Apple SSH config for keychain
  if ! grep -q "AddKeysToAgent yes" "$SSH_CONFIG" 2>/dev/null; then
    {
      echo ""
      echo "Host *"
      echo "  AddKeysToAgent yes"
      echo "  UseKeychain yes"
    } >> "$SSH_CONFIG"
    info "Enabled macOS Keychain integration for SSH"
  fi
fi

# ── SSH config: per-org Host entry ────────────────────────────────────────
header "SSH Config: $HOST_ALIAS"

touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

BLOCK_START="${MARKER}: ${ORG} ──"
BLOCK_END="${MARKER}: ${ORG} end ──"

# Remove existing block for this org
if grep -q "$BLOCK_START" "$SSH_CONFIG" 2>/dev/null; then
  info "Updating existing entry for $ORG..."
  python3 - "$SSH_CONFIG" "$BLOCK_START" "$BLOCK_END" << 'PYEOF'
import sys
path, start, end = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    lines = f.readlines()
in_block = False
out = []
for line in lines:
    if start in line:
        in_block = True
    if not in_block:
        out.append(line)
    if end in line:
        in_block = False
with open(path, 'w') as f:
    f.writelines(out)
PYEOF
fi

# Write new block
cat >> "$SSH_CONFIG" << SSHBLOCK

${BLOCK_START}
Host ${HOST_ALIAS}
  HostName github.com
  User git
  IdentityFile ${KEY_PATH}
  IdentitiesOnly yes
${BLOCK_END}
SSHBLOCK

ok "SSH config entry written: Host ${HOST_ALIAS}"

# ── Git global config ────────────────────────────────────────────────────
header "Git Config"

# 1. Global HTTPS → SSH rewrite (covers all orgs)
if ! git config --global --get url."git@github.com:".insteadOf &>/dev/null; then
  git config --global url."git@github.com:".insteadOf "https://github.com/"
  ok "Global rewrite: https://github.com/ → git@github.com: (SSH)"
else
  ok "Global rewrite already active"
fi

# 2. Per-org rewrite using the host alias (for key isolation)
git config --global url."git@${HOST_ALIAS}:${ORG}/".insteadOf "https://github.com/${ORG}/"
git config --global url."git@${HOST_ALIAS}:${ORG}/".insteadOf "git@github.com:${ORG}/"
ok "Org rewrite: github.com/${ORG}/* → uses key ${KEY_NAME}"

# ── Upload to GitHub (optional) ──────────────────────────────────────────
if [[ "$UPLOAD" == true ]]; then
  header "Upload to GitHub"
  if [[ -z "$GH_TOKEN" ]]; then
    read -rsp "GitHub PAT (with admin:public_key scope): " GH_TOKEN
    echo ""
  fi

  TITLE="$(hostname -s)-${KEY_NAME}-$(date +%Y%m%d)"
  PUB_KEY=$(cat "${KEY_PATH}.pub")

  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    https://api.github.com/user/keys \
    -d "{\"title\":\"${TITLE}\",\"key\":\"${PUB_KEY}\"}")

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  BODY=$(echo "$RESPONSE" | head -n -1)

  if [[ "$HTTP_CODE" == "201" ]]; then
    ok "Key uploaded to GitHub: ${TITLE}"
  elif echo "$BODY" | grep -q "key is already in use"; then
    ok "Key already exists on GitHub"
  else
    err "Upload failed (HTTP ${HTTP_CODE})"
    echo "$BODY" | head -5
  fi
fi

# ── Verify ───────────────────────────────────────────────────────────────
header "Verification"

info "Testing SSH connection to GitHub via ${HOST_ALIAS}..."
SSH_OUTPUT=$(ssh -T -o StrictHostKeyChecking=accept-new "git@${HOST_ALIAS}" 2>&1 || true)

if echo "$SSH_OUTPUT" | grep -qi "successfully authenticated"; then
  GITHUB_USER=$(echo "$SSH_OUTPUT" | grep -oP '(?<=Hi )\w+' || echo "?")
  ok "Authenticated as: ${GITHUB_USER}"
else
  warn "Could not verify (key may not be on GitHub yet)"
  echo "  $SSH_OUTPUT"
  echo ""
  echo -e "  ${BOLD}To fix: add this public key to GitHub → Settings → SSH Keys:${NC}"
  cat "${KEY_PATH}.pub"
fi

# ── Summary ──────────────────────────────────────────────────────────────
header "Summary"
echo ""
echo "  Org:        $ORG"
echo "  Key:        $KEY_PATH"
echo "  SSH alias:  $HOST_ALIAS"
echo "  Git URL:    git@${HOST_ALIAS}:${ORG}/<repo>.git"
echo ""
echo "  All GitHub clones/pushes for ${ORG} now use this key."
echo "  Repos with PAT in remote URLs will also use SSH (global rewrite)."
echo ""
info "To set up another org, run again:"
echo "  bash $(basename "$0") --org <other-org> --key <other-key-name>"
echo ""
info "To copy this key to another machine:"
echo "  scp ~/.ssh/${KEY_NAME}{,.pub} user@host:~/.ssh/"
echo "  # Then run this script on that machine — it will detect the existing key."
echo ""
