#!/bin/bash
# scripts/entrypoints/reset_device.sh — Device reset wizard
#
# Backs up existing config, optionally runs full uninstall, resets devices list,
# manages organizations, creates/validates .env, and reports existing artifacts.
#
# Usage (via Makefile):
#   make reset-device                                  # interactive config reset
#   make reset-device FULL_RESET=1                     # full uninstall + reconfigure
#   make reset-device NONINTERACTIVE=1 TAILNET=name@   # automated/CI mode
#   make reset-device TAILNET=yourname@                # pre-set tailnet

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$INFRA_DIR"

# ── Flags ─────────────────────────────────────────────────────────────────────
NONINTERACTIVE="${NONINTERACTIVE:-0}"
FULL_RESET="${FULL_RESET:-0}"
CONFIRM="${CONFIRM:-0}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
err()   { echo -e "${RED}✗${NC} $*"; }
step()  { echo -e "\n${CYAN}──${NC} $* ${CYAN}──${NC}"; }

BACKUP_DIR="$INFRA_DIR/.backup"
CONFIG_FILE="$INFRA_DIR/config/defaults.yaml"
ENV_FILE="$INFRA_DIR/.env"
ENV_EXAMPLE="$INFRA_DIR/.env.example"
ALIASES_FILE="$HOME/.tenai_aliases"
DATE_SUFFIX="$(date +%Y-%m-%d)"

# ══════════════════════════════════════════════════════════════════════════════
# Banner
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  TenAI Infra — Device Reset Wizard${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""

if [[ "$FULL_RESET" == "1" ]]; then
  echo "  This wizard will fully reset your device:"
  echo "    ✓ Uninstall all tools tracked by the state manifest"
  echo "    ✓ Remove SSH config blocks, aliases, CLI skills"
  echo "    ✓ Back up defaults.yaml and .env to .backup/"
  echo "    ✓ Reset tailnet name and clear devices list"
  echo "    ✗ Will NOT touch config/local.yaml or .backup/"
else
  echo "  This wizard will reset your configuration:"
  echo "    ✓ Back up defaults.yaml and .env to .backup/"
  echo "    ✓ Reset tailnet name and clear devices list"
  echo "    ✓ Walk through API key configuration"
  echo "    ✗ Will NOT touch config/local.yaml, .backup/, or installed tools"
fi
echo ""

# ── Confirmation ──────────────────────────────────────────────────────────────
if [[ "$NONINTERACTIVE" != "1" ]] && [[ "$CONFIRM" != "1" ]]; then
  read -rp "  Continue? [y/N] " _confirm
  if [[ "${_confirm:-}" != "y" && "${_confirm:-}" != "Y" && "${_confirm:-}" != "yes" ]]; then
    echo "  Aborted."
    exit 0
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Phase 0: Bootstrap Python environment (must run before any Python use)
# ══════════════════════════════════════════════════════════════════════════════
step "Phase 0: Bootstrapping Python environment"
make -C "$INFRA_DIR" --no-print-directory install-deps
PYTHON="${INFRA_DIR}/.venv/bin/python3"
if [[ ! -x "$PYTHON" ]]; then
  err "Python venv setup failed — cannot continue"
  exit 1
fi
info "Python ready: $PYTHON"

# ══════════════════════════════════════════════════════════════════════════════
# Phase 0.5: Full Reset (optional — uninstall all tracked changes)
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$FULL_RESET" == "1" ]]; then
  step "Phase 0.5: Full device reset (uninstalling tracked changes)"
  DEVICE_NAME="${DEVICE_NAME:-$(hostname -s 2>/dev/null || echo local)}"
  STATE_DIR="${HOME}/.tenai/state"
  MANIFEST="${STATE_DIR}/${DEVICE_NAME}/manifest.json"

  if [[ -f "$MANIFEST" ]]; then
    info "State manifest found: $MANIFEST"
    # Delegate to the existing uninstall pipeline
    CONFIRM=1 TENAI_UNINSTALL_CONFIRMED=1 bash scripts/entrypoints/uninstall.sh
    info "Full uninstall complete — continuing with config reset"
  else
    warn "No state manifest found at $MANIFEST"
    warn "Skipping full uninstall (nothing tracked to reverse)"
    echo "  Run 'make state-audit' to reconstruct a best-effort manifest."
  fi
elif [[ "$NONINTERACTIVE" != "1" ]]; then
  # In interactive mode, offer the option if manifest exists
  DEVICE_NAME="${DEVICE_NAME:-$(hostname -s 2>/dev/null || echo local)}"
  STATE_DIR="${HOME}/.tenai/state"
  MANIFEST="${STATE_DIR}/${DEVICE_NAME}/manifest.json"

  if [[ -f "$MANIFEST" ]]; then
    echo ""
    echo "  A state manifest was found — you can choose the reset scope:"
    echo "    [1] Config-only reset (default — just reset tailnet/devices/.env)"
    echo "    [2] Full reset — uninstall all tracked tools + reconfigure"
    echo ""
    read -rp "  Choice [1]: " _reset_choice
    if [[ "${_reset_choice:-1}" == "2" ]]; then
      step "Full device reset (uninstalling tracked changes)"
      TENAI_UNINSTALL_CONFIRMED=1 bash scripts/entrypoints/uninstall.sh
      info "Full uninstall complete — continuing with config reset"
    fi
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Phase 1: Backup existing config
# ══════════════════════════════════════════════════════════════════════════════
step "Phase 1: Backing up existing config"

mkdir -p "$BACKUP_DIR"

# Backup defaults.yaml
backup_name=""
if [[ -f "$CONFIG_FILE" ]]; then
  backup_name="defaults.yaml.${DATE_SUFFIX}"
  # Avoid overwriting existing backup from same day
  if [[ -f "$BACKUP_DIR/$backup_name" ]]; then
    backup_name="defaults.yaml.${DATE_SUFFIX}.$(date +%H%M%S)"
  fi
  cp "$CONFIG_FILE" "$BACKUP_DIR/$backup_name"
  info "Backed up defaults.yaml → .backup/${backup_name}"
else
  warn "No defaults.yaml found to backup"
fi

# Backup .env if it exists
if [[ -f "$ENV_FILE" ]]; then
  env_backup="env.${DATE_SUFFIX}"
  if [[ -f "$BACKUP_DIR/$env_backup" ]]; then
    env_backup="env.${DATE_SUFFIX}.$(date +%H%M%S)"
  fi
  cp "$ENV_FILE" "$BACKUP_DIR/$env_backup"
  info "Backed up .env → .backup/${env_backup}"
fi

echo ""
echo -e "  ${YELLOW}To restore:${NC} cp .backup/${backup_name:-defaults.yaml.*} config/defaults.yaml"

# ══════════════════════════════════════════════════════════════════════════════
# Phase 2: Set tailnet name and reset devices in defaults.yaml
# ══════════════════════════════════════════════════════════════════════════════
step "Phase 2: Configure Tailscale tailnet"

# Resolve TAILNET from multiple sources
TAILNET="${TAILNET:-}"

# Try TAILSCALE_TAILNET from .env if TAILNET not set
if [[ -z "$TAILNET" ]] && [[ -f "$ENV_FILE" ]]; then
  TAILNET=$(grep "^TAILSCALE_TAILNET=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' || true)
fi

if [[ "$NONINTERACTIVE" != "1" ]]; then
  echo ""
  echo "  Your ${BOLD}tailnet name${NC} is your Tailscale network identifier."
  echo "  It's the email you used to sign up for Tailscale, followed by @"
  echo "  Example: yourname@gmail.com → ${CYAN}yourname@${NC}"
  echo "  Find it at: ${CYAN}https://login.tailscale.com/admin/settings/general${NC}"
  echo ""

  if [[ -z "$TAILNET" ]]; then
    # Try to read current value from config
    current_tailnet=$("$PYTHON" -c "
import yaml
c = yaml.safe_load(open('$CONFIG_FILE'))
print(c.get('tailscale', {}).get('tailnet', ''))
" 2>/dev/null || echo "")

    if [[ -n "$current_tailnet" ]]; then
      read -rp "  Tailnet name [${current_tailnet}]: " TAILNET
      TAILNET="${TAILNET:-$current_tailnet}"
    else
      read -rp "  Tailnet name (e.g. yourname@): " TAILNET
    fi
  else
    echo -e "  Using tailnet: ${CYAN}${TAILNET}${NC}"
  fi
fi

if [[ -z "$TAILNET" ]]; then
  err "Tailnet name is required (set TAILNET or TAILSCALE_TAILNET env var)"
  exit 1
fi

# Ensure trailing @
[[ "$TAILNET" == *"@" ]] || TAILNET="${TAILNET}@"

# Reset defaults.yaml: update tailnet, clear devices
"$PYTHON" - "$CONFIG_FILE" "$TAILNET" <<'PYEOF'
import sys
import yaml

config_path = sys.argv[1]
tailnet = sys.argv[2]

with open(config_path) as f:
    config = yaml.safe_load(f)

# Update tailnet
config.setdefault("tailscale", {})["tailnet"] = tailnet

# Clear devices
config["tailscale"]["devices"] = {}

with open(config_path, "w") as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

print(f"✓ Set tailnet to '{tailnet}', cleared devices list")
PYEOF

# ══════════════════════════════════════════════════════════════════════════════
# Phase 2b: Review organizations
# ══════════════════════════════════════════════════════════════════════════════
step "Phase 2b: Review organizations"

if [[ "$NONINTERACTIVE" == "1" ]]; then
  info "Non-interactive mode — keeping existing organizations"
else
  echo ""
  echo "  Organizations define your GitHub orgs for Git SSH key setup."
  echo "  Each org gets its own SSH key alias for multi-org access."
  echo ""

  # Get list of current orgs
  orgs_json=$("$PYTHON" -c "
import json, yaml
c = yaml.safe_load(open('$CONFIG_FILE'))
orgs = c.get('organizations', {})
print(json.dumps(orgs))
" 2>/dev/null || echo "{}")

  org_names=$("$PYTHON" -c "
import json
orgs = json.loads('$orgs_json')
for name in orgs:
    print(name)
" 2>/dev/null || true)

  if [[ -z "$org_names" ]]; then
    echo "  No organizations configured."
  else
    echo "  Current organizations:"
    echo ""

    # Walk through each org and ask keep/remove
    while IFS= read -r org_name; do
      [[ -z "$org_name" ]] && continue
      org_info=$("$PYTHON" -c "
import json
orgs = json.loads('$(echo "$orgs_json" | sed "s/'/\\\\\\\\'/g")')
org = orgs.get('$org_name', {})
alias = org.get('ssh_host_alias', '?')
url = org.get('github_url', '?')
print(f'{url} (SSH alias: {alias})')
" 2>/dev/null || echo "?")
      read -rp "    ${org_name}  →  ${org_info}  — Keep? [Y/n] " keep
      if [[ "$keep" == "n" || "$keep" == "N" || "$keep" == "no" || "$keep" == "No" ]]; then
        # Remove this org
        "$PYTHON" - "$CONFIG_FILE" "$org_name" <<'PYEOF'
import sys, yaml
config_path, org_name = sys.argv[1], sys.argv[2]
with open(config_path) as f:
    config = yaml.safe_load(f)
config.get("organizations", {}).pop(org_name, None)
with open(config_path, "w") as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
PYEOF
        info "Removed ${org_name}"
      else
        info "Kept ${org_name}"
      fi
    done <<< "$org_names"
  fi

  # Ask if they want to add a new org
  echo ""
  while true; do
    read -rp "  Add a new organization? [y/N] " add_org
    if [[ "$add_org" != "y" && "$add_org" != "Y" && "$add_org" != "yes" && "$add_org" != "Yes" ]]; then
      break
    fi

    read -rp "    Organization name (e.g. my-company): " new_org_name
    [[ -z "$new_org_name" ]] && { warn "Empty name, skipping"; continue; }
    read -rp "    GitHub URL [github.com]: " new_org_url
    new_org_url="${new_org_url:-github.com}"
    read -rp "    SSH host alias [github-${new_org_name}]: " new_org_alias
    new_org_alias="${new_org_alias:-github-${new_org_name}}"
    read -rp "    SSH key path [~/.ssh/tenai-git-ssh-key]: " new_org_key
    new_org_key="${new_org_key:-~/.ssh/tenai-git-ssh-key}"
    read -rp "    Default branch [main]: " new_org_branch
    new_org_branch="${new_org_branch:-main}"

    "$PYTHON" - "$CONFIG_FILE" "$new_org_name" "$new_org_url" "$new_org_alias" "$new_org_key" "$new_org_branch" <<'PYEOF'
import sys, yaml
config_path = sys.argv[1]
name, url, alias, key, branch = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
with open(config_path) as f:
    config = yaml.safe_load(f)
config.setdefault("organizations", {})[name] = {
    "github_url": url,
    "ssh_host_alias": alias,
    "ssh_key": key,
    "default_branch": branch,
}
with open(config_path, "w") as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
PYEOF
    info "Added organization: ${new_org_name}"
  done
fi

# ══════════════════════════════════════════════════════════════════════════════
# Phase 3: Create or update .env
# ══════════════════════════════════════════════════════════════════════════════
step "Phase 3: Configure .env"

if [[ ! -f "$ENV_EXAMPLE" ]]; then
  err "Missing .env.example — cannot create .env"
  exit 1
fi

SKIP_KEY_PROMPTS=false

if [[ "$NONINTERACTIVE" == "1" ]]; then
  # Non-interactive: keep existing .env, just ensure TAILSCALE_TAILNET is set
  if [[ ! -f "$ENV_FILE" ]]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    info "Created .env from .env.example"
  fi
  SKIP_KEY_PROMPTS=true
else
  # Print all required keys upfront
  echo ""
  echo -e "  ${BOLD}The following keys are needed for the onboarding pipeline:${NC}"
  echo ""
  echo -e "  ${CYAN}Required:${NC}"
  echo "    TAILSCALE_API_KEY    — Tailscale API key (admin → Settings → Keys)"
  echo "    TAILSCALE_AUTH_KEY   — Tailscale auth key (for device onboarding)"
  echo "    TAILSCALE_TAILNET    — Your tailnet name (will be set automatically)"
  echo ""
  echo -e "  ${CYAN}Recommended:${NC}"
  echo "    ANTHROPIC_API_KEY   — Anthropic (Claude Code)   console.anthropic.com/settings/keys"
  echo "    GEMINI_API_KEY      — Google (Gemini CLI)        aistudio.google.com/apikey"
  echo "    OPENAI_API_KEY      — OpenAI (Codex CLI)         platform.openai.com/api-keys"
  echo "    GITHUB_TOKEN        — GitHub Token               github.com/settings/tokens"
  echo ""
  echo -e "  ${CYAN}Optional:${NC}"
  echo "    WEBAPP_TOKEN        — Protect the web control panel"
  echo "    NTFY_TOPIC          — ntfy.sh topic for notifications"
  echo "    SSH_KEY_PATH        — Custom SSH key path"
  echo ""

  if [[ -f "$ENV_FILE" ]]; then
    echo -e "  ${YELLOW}Existing .env found — it will be kept as-is.${NC}"
    echo "  We will walk through the essential keys and update any you want to change."
    echo ""
    read -rp "  Continue with interactive key setup, or edit .env manually? [C]ontinue / [S]kip > " env_choice
    if [[ "$env_choice" == "s" || "$env_choice" == "S" || "$env_choice" == "skip" || "$env_choice" == "Skip" ]]; then
      echo ""
      echo -e "  You can edit .env manually: ${CYAN}nano .env${NC}"
      echo "  Then re-run: ${CYAN}make reset-device${NC}"
      echo ""
      SKIP_KEY_PROMPTS=true
    fi
  else
    # No .env exists — create from example
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    info "Created .env from .env.example"
  fi
fi

# Always set TAILSCALE_TAILNET in .env
if grep -q "^TAILSCALE_TAILNET=" "$ENV_FILE" 2>/dev/null; then
  sed -i.bak "s|^TAILSCALE_TAILNET=.*|TAILSCALE_TAILNET=${TAILNET}|" "$ENV_FILE"
  rm -f "${ENV_FILE}.bak"
else
  echo "TAILSCALE_TAILNET=${TAILNET}" >> "$ENV_FILE"
fi
info "Set TAILSCALE_TAILNET=${TAILNET} in .env"

if [[ "$SKIP_KEY_PROMPTS" != "true" ]]; then
  # Helper: prompt and set a value in .env
  set_env_var() {
    local key="$1"
    local prompt="$2"
    local required="${3:-false}"
    local current

    # Read current value safely so grep failures don't trigger set -e aborts
    current=$(grep "^${key}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' || true)

    if [[ -n "$current" && ${#current} -gt 12 ]]; then
      # Already set — show masked
      local masked="${current:0:8}...${current: -4}"
      read -rp "  ${prompt} [${masked}]: " value
      value="${value:-$current}"
    elif [[ -n "$current" ]]; then
      read -rp "  ${prompt} [${current}]: " value
      value="${value:-$current}"
    else
      read -rp "  ${prompt}: " value
    fi

    if [[ -n "$value" ]]; then
      if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
        rm -f "${ENV_FILE}.bak"
      else
        echo "${key}=${value}" >> "$ENV_FILE"
      fi
      info "${key} set"
    elif [[ "$required" == "true" ]]; then
      warn "${key} is required — set it later in .env"
    fi
  }

  echo ""
  echo -e "  ${CYAN}── Tailscale ──${NC}"
  echo "  Get keys at: https://login.tailscale.com/admin/settings/keys"
  set_env_var "TAILSCALE_API_KEY" "Tailscale API Key" "true"
  set_env_var "TAILSCALE_AUTH_KEY" "Tailscale Auth Key" "true"

  echo ""
  echo -e "  ${CYAN}── AI Provider Keys (set the ones you plan to use) ──${NC}"
  set_env_var "ANTHROPIC_API_KEY" "Anthropic API Key (Claude)" "false"
  set_env_var "GEMINI_API_KEY" "Gemini API Key" "false"
  set_env_var "OPENAI_API_KEY" "OpenAI API Key (Codex)" "false"

  echo ""
  echo -e "  ${CYAN}── GitHub ──${NC}"
  set_env_var "GITHUB_TOKEN" "GitHub Token (for repo sync)" "false"

  echo ""
  echo -e "  ${CYAN}── Webapp ──${NC}"
  set_env_var "WEBAPP_TOKEN" "Webapp auth token (web panel security)" "false"

  # ── Set device identity ────────────────────────────────────────────────────
  echo ""
  echo -e "  ${CYAN}── This Device ──${NC}"
  echo "  Name and type of THIS machine (the one you're running this on)."

  local_name=$(hostname -s 2>/dev/null || echo "mydevice")
  read -rp "  Device name [${local_name}]: " device_name
  device_name="${device_name:-$local_name}"
  sed -i.bak "s|^DEVICE_NAME=.*|DEVICE_NAME=${device_name}|" "$ENV_FILE"
  rm -f "${ENV_FILE}.bak"

  # Auto-detect type
  if [[ "$(uname)" == "Darwin" ]]; then
    device_type="mac"
  elif [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
    device_type="wsl"
  else
    device_type="server"
  fi
  read -rp "  Device type [${device_type}]: " input_type
  device_type="${input_type:-$device_type}"
  sed -i.bak "s|^DEVICE_TYPE=.*|DEVICE_TYPE=${device_type}|" "$ENV_FILE"
  rm -f "${ENV_FILE}.bak"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Phase 4: Report existing artifacts (informational)
# ══════════════════════════════════════════════════════════════════════════════
step "Phase 4: Checking existing artifacts"

echo ""
artifact_count=0

if [[ -f "$ALIASES_FILE" ]]; then
  echo -e "  ${DIM}Found:${NC} ~/.tenai_aliases (shell aliases for mesh devices)"
  ((artifact_count++)) || true
fi

if ls /tmp/.tenai-onboard-* 1>/dev/null 2>&1; then
  marker_count=$(ls -d /tmp/.tenai-onboard-* 2>/dev/null | wc -l | xargs)
  echo -e "  ${DIM}Found:${NC} ${marker_count} onboard state markers in /tmp/"
  ((artifact_count++)) || true
fi

SSH_CONFIG="$HOME/.ssh/config"
if [[ -f "$SSH_CONFIG" ]] && grep -q "INFRA SSH START" "$SSH_CONFIG"; then
  echo -e "  ${DIM}Found:${NC} SSH config block in ~/.ssh/config"
  ((artifact_count++)) || true
fi

for rc_file in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
  if [[ -f "$rc_file" ]]; then
    if grep -q "source ~/.tenai_aliases" "$rc_file" 2>/dev/null; then
      echo -e "  ${DIM}Found:${NC} tenai_aliases source line in $(basename "$rc_file")"
      ((artifact_count++)) || true
    fi
    if grep -q "INFRA ALIASES" "$rc_file" 2>/dev/null; then
      echo -e "  ${DIM}Found:${NC} alias block in $(basename "$rc_file")"
      ((artifact_count++)) || true
    fi
  fi
done

if [[ $artifact_count -eq 0 ]]; then
  info "No existing artifacts found (clean system)"
else
  echo ""
  echo -e "  ${DIM}These artifacts were created by previous runs.${NC}"
  echo -e "  ${DIM}They will be regenerated when you run 'make onboard'.${NC}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  ✓ Device reset complete!${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  What's next:"
echo ""
echo "    1. Review your .env file:   ${CYAN}cat .env${NC}"
echo "    2. Onboard this device:     ${CYAN}make onboard${NC}"
echo "    3. Onboard a remote device: ${CYAN}make onboard IP=x.x.x.x${NC}"
echo ""
echo "  Backups are in: ${CYAN}.backup/${NC}"
echo "  To restore:     ${CYAN}cp .backup/defaults.yaml.${DATE_SUFFIX} config/defaults.yaml${NC}"
echo ""
