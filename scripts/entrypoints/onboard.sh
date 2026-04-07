#!/bin/bash
# scripts/entrypoints/onboard.sh — Universal device onboarding wizard
#
# Usage (via Makefile):
#   make onboard                                    # local (auto-detect)
#   make onboard IP=1.2.3.4                         # new device by IP
#   make onboard HOST=myserver                      # by SSH config alias
#   make onboard IP=1.2.3.4 SSH_KEY=~/.ssh/id_rsa  # with custom key
#   make onboard TYPE=android NAME=s25 IP=100.x.x.x
#
# Env vars:
#   TYPE        local|server|mac|windows|android|ios|wsl (auto-detected if omitted)
#   NAME        device name for config (auto: hostname)
#   IP          IP address or hostname to SSH into
#   HOST        SSH config alias or device name from defaults.yaml
#   SSH_KEY     path to SSH private key for initial access
#   REMOTE_USER SSH user (auto-set from type if omitted)
#   TERMIUS     set to 1 for Termius-only iOS mode
#   DRY_RUN     set to 1 for dry-run mode
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$INFRA_DIR"

# Bootstrap Python environment before any use of $PYTHON
make -C "$INFRA_DIR" --no-print-directory install-deps > /dev/null
PYTHON="${INFRA_DIR}/.venv/bin/python3"
[[ -x "$PYTHON" ]] || { echo "✗ venv setup failed — run 'make install-deps' manually"; exit 1; }

# Source state tracking library (must come after PYTHON is resolved)
source "$INFRA_DIR/scripts/lib/state_track.sh"

# Source env validation library
source "$INFRA_DIR/scripts/lib/env_check.sh"

# ── Config ──────────────────────────────────────────────────────────────────
TYPE="${TYPE:-}"
NAME="${NAME:-}"
IP="${IP:-}"
HOST_ARG="${HOST:-}"
SSH_KEY="${SSH_KEY:-}"
REMOTE_USER="${REMOTE_USER:-}"
TERMIUS="${TERMIUS:-0}"
DRY_RUN="${DRY_RUN:-0}"
TEST="${TEST:-0}"
SSH_TARGET=""           # canonical SSH target — alias when from ssh_config, user@ip otherwise
SSH_ALIAS=""           # original SSH config alias (empty if not alias-based)
RESOLVED_SRC=""        # how the host was resolved: config, ssh_config, raw

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
err()   { echo -e "${RED}✗${NC} $*"; }
step()  { echo -e "\n${CYAN}──${NC} $* ${CYAN}──${NC}"; }

# ── Read SSH key config ─────────────────────────────────────────────────────
SSH_KEY_NAME=$("$PYTHON" -c "
import sys; sys.path.insert(0, '$INFRA_DIR')
from scripts.lib.load_config import load_config
c = load_config()
print(c.get('ssh', {}).get('key_name', 'tenai-ssh-key'))
" 2>/dev/null || echo "tenai-ssh-key")

SSH_KEY_DIST=$("$PYTHON" -c "
import sys; sys.path.insert(0, '$INFRA_DIR')
from scripts.lib.load_config import load_config
c = load_config()
print(c.get('ssh', {}).get('key_distribution', 'shared'))
" 2>/dev/null || echo "shared")

SSH_KEY_PATH="${SSH_KEY:-$HOME/.ssh/${SSH_KEY_NAME}}"

# ── Phase 0: Resolve HOST/IP ────────────────────────────────────────────────
# Priority: HOST > IP > local
resolve_target() {
  step "Resolving target device"

  # If HOST is provided, resolve through our chain (config → ssh config → raw)
  if [[ -n "$HOST_ARG" ]]; then
    local resolve_output
    resolve_output=$("$PYTHON" scripts/configure/resolve_host.py "$HOST_ARG" --allow-unknown 2>&1) || true

    if echo "$resolve_output" | grep -q "^RESOLVED_"; then
      eval "$resolve_output"
      IP="${RESOLVED_IP:-$IP}"
      NAME="${NAME:-$RESOLVED_NAME}"
      REMOTE_USER="${REMOTE_USER:-$RESOLVED_USER}"
      SSH_KEY="${RESOLVED_SSH_KEY:-$SSH_KEY}"
      RESOLVED_SRC="${RESOLVED_SOURCE:-raw}"
      # Only use config type if TYPE wasn't explicitly set
      if [[ -z "$TYPE" ]] && [[ "$RESOLVED_SOURCE" == "config" || "$RESOLVED_SOURCE" == "config+ssh" ]]; then
        TYPE="$RESOLVED_TYPE"
      fi
      SSH_PORT="${RESOLVED_SSH_PORT:-22}"

      # When source is ssh_config, the original alias is the working target.
      # Using the alias preserves IdentityFile, ProxyCommand, etc.
      if [[ "$RESOLVED_SRC" == "ssh_config" || "$RESOLVED_SRC" == "config+ssh" ]]; then
        SSH_ALIAS="$HOST_ARG"
        SSH_TARGET="$HOST_ARG"
        info "Resolved HOST='${HOST_ARG}' → using SSH alias directly (user=${REMOTE_USER}, source=${RESOLVED_SRC})"
      else
        SSH_TARGET="${REMOTE_USER}@${IP}"
        info "Resolved HOST='${HOST_ARG}' → IP=${IP}, user=${REMOTE_USER}, source=${RESOLVED_SRC}"
      fi
    else
      # resolve_host.py printed an error — try using HOST_ARG as raw IP/hostname
      warn "Could not resolve '${HOST_ARG}' — trying as raw SSH target"
      IP="${HOST_ARG}"
      RESOLVED_SRC="raw"
    fi
  fi

  # If still no IP and no HOST, this is a local onboard
  if [[ -z "$IP" ]] && [[ -z "$HOST_ARG" ]]; then
    info "No IP or HOST provided — running local onboard"
    return
  fi

  # Build SSH_TARGET for non-alias cases
  if [[ -z "$SSH_TARGET" ]] && [[ -n "$IP" ]]; then
    SSH_TARGET="${IP}"
    info "Target: ${IP}"
  fi
}

resolve_target

# ── Phase 0b: Detect local type ─────────────────────────────────────────────
detect_local_type() {
  # Sources detect.sh which prints a diagnostic to stderr (safe in $() capture).
  # Redirect stderr to /dev/null here as belt-and-suspenders.
  source "$INFRA_DIR/scripts/detect.sh" 2>/dev/null
  case "$OS_TYPE" in
    linux)  echo "server" ;;
    mac)    echo "mac" ;;
    termux) echo "android" ;;
    ish)    echo "ios_ish" ;;
    wsl)    echo "wsl" ;;
    *)      echo "server" ;;
  esac
}

# ── Marker-based idempotency ────────────────────────────────────────────────
MARKER_DIR="/tmp/.tenai-onboard-${NAME:-${IP:-local}}"
mkdir -p "$MARKER_DIR" 2>/dev/null || true

is_done()  { [[ -f "$MARKER_DIR/$1" ]]; }
mark_done(){ echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_DIR/$1"; }

# ══════════════════════════════════════════════════════════════════════════════
# LOCAL MODE — no IP or HOST provided, run on this device
# ══════════════════════════════════════════════════════════════════════════════
is_local_onboard() {
  [[ -z "$IP" ]] && [[ -z "$HOST_ARG" ]]
}

if is_local_onboard; then
  if [[ -z "$TYPE" ]]; then
    TYPE=$(detect_local_type)
    step "Auto-detected device type: ${TYPE}"
  fi

  # Map ios → ios_ish or ios_termius
  if [[ "$TYPE" == "ios" ]]; then
    TYPE=$([ "$TERMIUS" = "1" ] && echo "ios_termius" || echo "ios_ish")
  fi

  # Auto-set user if not provided
  if [[ -z "$REMOTE_USER" ]]; then
    case "$TYPE" in
      android|mac|windows|wsl) REMOTE_USER="$(whoami)" ;;
      ios_ish)                 REMOTE_USER="root" ;;
      server)                  REMOTE_USER="ubuntu" ;;
      ios_termius)             REMOTE_USER="" ;;
      *)                       REMOTE_USER="$(whoami)" ;;
    esac
  fi

  # Auto-set name if not provided
  if [[ -z "$NAME" ]]; then
    NAME=$(hostname -s 2>/dev/null || echo "device")
    warn "No NAME provided, using hostname: ${NAME}"
  fi

  # Update DEVICE_NAME and TENAI_MANIFEST_DIR for tracking
  export DEVICE_NAME="$NAME"
  export TENAI_MANIFEST_DIR="${HOME}/.tenai/state/${NAME}"

  step "Local onboarding (running on this device)"

  echo ""
  echo "═══ TenAI — Local Device Onboarding ════════════════════════════════"
  echo "    Device:  ${NAME}  (${TYPE})"
  echo "    User:    ${REMOTE_USER:-n/a}"
  echo "    Will:    register device, install tools, configure SSH/aliases/CLI"
  echo "════════════════════════════════════════════════════════════════"

  # Interactive confirmation (skip with CONFIRM=1 for CI/scripted mode)
  if [[ "${CONFIRM:-0}" != "1" ]] && [[ "${DRY_RUN}" != "1" ]]; then
    read -rp "  Proceed? [Y/n] " _confirm
    if [[ "${_confirm:-Y}" =~ ^[Nn] ]]; then
      echo "  Cancelled."
      exit 0
    fi
   echo ""
  fi

  # ── Env validation ─────────────────────────────────────────────────────────
  # Check required keys are present in the env file
  if [[ "$TEST" == "1" ]] && [[ -f ".env.test" ]]; then
    _env_file=".env.test"
  elif [[ "$TEST" == "1" ]]; then
    # TEST=1 but .env.test doesn't exist
    if [[ "${CONFIRM:-0}" == "1" ]]; then
      err ".env.test not found but TEST=1 — cannot proceed in non-interactive mode."
      echo "  Create .env.test before running: cp .env.example .env.test"
      exit 1
    else
      warn ".env.test not found but TEST=1 — falling back to .env"
      _env_file=".env"
    fi
  else
    _env_file=".env"
  fi

  if [[ -f "$_env_file" ]]; then
    step "Validating environment ($_env_file)"
    WARN_FN=warn
    export WARN_FN

    _missing=""
    _missing=$(check_required_env "$_env_file" TAILSCALE_AUTH_KEY TAILSCALE_TAILNET) || true

    if [[ -n "$_missing" ]]; then
      err "Required keys missing from $_env_file:"
      echo "$_missing" | while IFS= read -r _key; do
        [[ -n "$_key" ]] && echo -e "    ${RED}✗${NC} $_key"
      done

      if [[ "${CONFIRM:-0}" == "1" ]]; then
        err "Cannot proceed in non-interactive mode with missing required keys."
        echo "  Set the missing keys in $_env_file and re-run."
        exit 1
      else
        echo ""
        warn "Set these keys in $_env_file before continuing."
        warn "Or run 'make reset-device' for guided key setup."
        read -rp "  Continue anyway? [y/N] " _continue
        if [[ "${_continue:-}" != "y" && "${_continue:-}" != "Y" ]]; then
          exit 1
        fi
      fi
    else
      info "Required keys present in $_env_file"
    fi

    # Recommended keys — warnings only
    check_recommended_env "$_env_file" GITHUB_TOKEN ANTHROPIC_API_KEY GEMINI_API_KEY OPENAI_API_KEY
  else
    # Env file doesn't exist at all
    if [[ "${CONFIRM:-0}" == "1" ]]; then
      err "$_env_file not found — cannot proceed in non-interactive mode."
      echo "  Create it first: cp .env.example $_env_file"
      exit 1
    else
      warn "No $_env_file found. Run 'make reset-device' for guided setup."
    fi
  fi

  # Track ~/.tenai directory creation
  if [[ ! -d "${HOME}/.tenai" ]]; then
    mkdir -p "${HOME}/.tenai"
    tenai_track dir_created --path "~/.tenai"
  fi

  # Get Tailscale IP
  if command -v tailscale &>/dev/null; then
    IP=$(tailscale ip -4 2>/dev/null || echo "")
  fi

  if [[ -z "$IP" ]]; then
    warn "Tailscale IP not found. Installing/configuring Tailscale..."
    if [[ "$DRY_RUN" != "1" ]]; then
      bash scripts/install/tailscale.sh || warn "Tailscale install/config may need manual steps"
      IP=$(tailscale ip -4 2>/dev/null || echo "")
    fi
    if [[ -z "$IP" ]]; then
      warn "Still no Tailscale IP. Will register without IP (update later)."
      IP="pending"
    fi
  fi
  info "Tailscale IP: ${IP}"

  # Register in config
  step "Registering device"
  "$PYTHON" scripts/configure/register_device.py \
    --name "$NAME" --ip "$IP" --user "$REMOTE_USER" --type "$TYPE" \
    ${DRY_RUN:+--dry-run} --force-update

  # Track registration and finalize manifest device name
  tenai_track config_registered --device "$NAME"
  tenai_finalize_device_name "$NAME"

  # Run local setup
  step "Running local setup"
  if [[ "$DRY_RUN" != "1" ]]; then
    make _setup
  else
    echo "[DRY RUN] Would run: make _setup"
  fi

  # ── macOS: Ensure Remote Login (SSH) is enabled ───────────────────────────
  if [[ "$TYPE" == "mac" ]]; then
    step "Checking Remote Login (SSH) for macOS"
    if sudo systemsetup -getremotelogin 2>/dev/null | grep -qi "on"; then
      info "Remote Login is already enabled"
    else
      warn "Remote Login (SSH) is OFF — other devices cannot connect to this Mac"
      echo ""
      echo "  To enable, run:"
      echo "    sudo systemsetup -setremotelogin on"
      echo ""
      echo "  Or: System Settings → General → Sharing → Remote Login → ON"
      echo ""
      sudo_prompt "Enable macOS Remote Login (SSH daemon)"
      read -rp "  Enable Remote Login now? [Y/n] " answer
      if [[ "${answer:-Y}" =~ ^[Yy]?$ ]]; then
        sudo systemsetup -setremotelogin on && info "Remote Login enabled" || \
          warn "Failed — please enable manually in System Settings"
      else
        warn "Skipped. Other devices will NOT be able to SSH/Mosh to this Mac."
      fi
    fi

    # Guide user for things we can't automate
    echo ""
    echo "  ┌─────────────────────────────────────────────────┐"
    echo "  │  macOS Manual Steps (if not already done)       │"
    echo "  ├─────────────────────────────────────────────────┤"
    echo "  │  1. System Settings → General → Sharing         │"
    echo "  │     • Remote Login: ON                          │"
    echo "  │     • Allow access for: All users (or your user)│"
    echo "  │  2. If using a firewall:                        │"
    echo "  │     • Allow incoming for sshd and mosh-server   │"
    echo "  └─────────────────────────────────────────────────┘"
  fi

  # If EXIT_NODE=1, configure this device as exit node
  if [[ "${EXIT_NODE:-}" == "1" ]]; then
    step "Configuring as exit node"
    DRY_RUN="$DRY_RUN" bash "$INFRA_DIR/scripts/configure/set_exit_node.sh" "$NAME"
  fi

  step "Onboarding Complete"
  info "Device '${NAME}' registered at ${IP}"
  info "Aliases available after: source ~/.$(basename "$SHELL")rc"
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# TERMIUS-ONLY MODE (no SSH, just print host table)
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$TYPE" == "ios_termius" || "$TERMIUS" == "1" ]]; then
  step "Termius Setup (client-only)"

  if [[ -n "$IP" ]]; then
    "$PYTHON" scripts/configure/register_device.py \
      --name "${NAME:-termius}" --ip "$IP" --user "" --type ios_termius \
      ${DRY_RUN:+--dry-run}
  fi

  echo ""
  echo "═══ Add these hosts in Termius ═══"
  echo ""
  printf "  ${CYAN}%-12s %-18s %-5s %-10s${NC}\n" "Label" "Hostname" "Port" "Username"
  printf "  %-12s %-18s %-5s %-10s\n" "───────────" "──────────────────" "─────" "──────────"

  "$PYTHON" -c "
import sys; sys.path.insert(0, '.')
from scripts.lib.load_config import load_config
c = load_config()
for name, dev in c.get('tailscale', {}).get('devices', {}).items():
    if dev.get('type') == 'ios_termius':
        continue
    ip = dev.get('ip', '?')
    port = dev.get('ssh_port', 22)
    user = dev.get('user', '?')
    print(f'  {name:<12s} {ip:<18s} {port:<5d} {user}')
" 2>/dev/null || echo "  (no devices in config)"

  echo ""
  info "Termius setup complete"
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# REMOTE MODE — onboard a device over SSH from this machine
# ══════════════════════════════════════════════════════════════════════════════

# Auto-set SSH port
SSH_PORT="${SSH_PORT:-22}"

# Build SSH command with optional key and port.
# When SSH_ALIAS is set, omit -i and -p — the alias in ~/.ssh/config handles those.
build_ssh_cmd() {
  local cmd="ssh"
  if [[ -n "$SSH_ALIAS" ]]; then
    # Let ~/.ssh/config handle identity, port, hostname, etc.
    echo "$cmd"
    return
  fi
  if [[ -n "$SSH_KEY" ]] && [[ -f "$SSH_KEY" ]]; then
    cmd="$cmd -i $SSH_KEY"
  elif [[ -n "$SSH_KEY_PATH" ]] && [[ -f "$SSH_KEY_PATH" ]]; then
    cmd="$cmd -i $SSH_KEY_PATH"
  fi
  cmd="$cmd -p ${SSH_PORT}"
  echo "$cmd"
}

SSH_CMD=$(build_ssh_cmd)

# Helper: update SSH_TARGET after user/IP changes (only for non-alias connections)
update_ssh_target() {
  if [[ -z "$SSH_ALIAS" ]]; then
    SSH_TARGET="${REMOTE_USER}@${IP}"
  fi
}

# ── Phase 1: Establish SSH ──────────────────────────────────────────────────
establish_ssh() {
  step "Establishing SSH to ${SSH_TARGET}"

  if is_done "ssh_established"; then
    # Verify still works
    if $SSH_CMD -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_TARGET" "echo ok" &>/dev/null; then
      info "SSH already established (from previous run)"
      return 0
    else
      warn "Previous SSH no longer works, retrying..."
    fi
  fi

  local connected=false

  # Strategy 1a: If we have an SSH alias, just use it directly
  if [[ -n "$SSH_ALIAS" ]]; then
    echo "  → Trying ssh ${SSH_ALIAS}..."
    if $SSH_CMD -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_ALIAS" "echo ok" &>/dev/null; then
      info "Connected via SSH alias '${SSH_ALIAS}'"
      connected=true
    else
      warn "SSH alias '${SSH_ALIAS}' failed — falling back to user@ip probing"
      # Clear alias mode and fall through to normal probing
      SSH_ALIAS=""
      SSH_CMD=$(build_ssh_cmd)
    fi
  fi

  # Strategy 1b: Try user candidates (only for non-alias connections)
  if ! $connected && [[ -z "$SSH_ALIAS" ]]; then
    local user_candidates=("" "${REMOTE_USER:-}" "ubuntu" "root" "$(whoami)")

    if [[ -z "$REMOTE_USER" ]]; then
      for u in "${user_candidates[@]}"; do
        local target_str
        if [[ -z "$u" ]]; then
          target_str="${IP}"
          echo "  → Trying ${target_str} (default ssh user)..."
        else
          target_str="${u}@${IP}"
          echo "  → Trying ${target_str}..."
        fi
        if $SSH_CMD -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$target_str" "echo ok" &>/dev/null; then
          REMOTE_USER="$u"
          SSH_TARGET="$target_str"
          if [[ -z "$u" ]]; then
            info "Connected (using default ssh user)"
          else
            info "Connected as ${u}"
          fi
          connected=true
          break
        fi
      done
    else
      SSH_TARGET="${REMOTE_USER}@${IP}"
      echo "  → Trying ${SSH_TARGET}..."
      if $SSH_CMD -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_TARGET" "echo ok" &>/dev/null; then
        info "Connected via key auth"
        connected=true
      fi
    fi
  fi

  # Strategy 2: Tailscale SSH if available
  if ! $connected && command -v tailscale &>/dev/null; then
    local ts_hostname
    ts_hostname=$("$PYTHON" -c "
import json, subprocess
r = subprocess.run(['tailscale', 'status', '--json'], capture_output=True, text=True)
d = json.loads(r.stdout)
for v in d.get('Peer', {}).values():
    ips = v.get('TailscaleIPs', [])
    if ips and ips[0] == '${IP}':
        print(v.get('HostName', ''))
        break
" 2>/dev/null || echo "")

    if [[ -n "$ts_hostname" ]]; then
      local ts_user="${REMOTE_USER:-root}"
      echo "  → Trying tailscale ssh ${ts_user}@${ts_hostname}..."
      if tailscale ssh "${ts_user}@${ts_hostname}" "echo ok" &>/dev/null 2>&1; then
        REMOTE_USER="$ts_user"
        SSH_TARGET="${ts_user}@${ts_hostname}"
        info "Connected via Tailscale SSH"
        connected=true
      fi
    fi
  fi

  # Strategy 3: Password SSH
  if ! $connected; then
    echo ""
    echo "  Could not connect with keys. Trying password auth..."
    echo "  Make sure the device is reachable and SSH is running."
    echo ""
    local u="${REMOTE_USER:-root}"
    read -rp "  SSH user [$u]: " input_user
    REMOTE_USER="${input_user:-$u}"
    SSH_TARGET="${REMOTE_USER}@${IP}"
    read -rp "  Press Enter then enter password for ${SSH_TARGET}... "

    if ssh -p "$SSH_PORT" -o ConnectTimeout=10 "$SSH_TARGET" "echo ok" 2>/dev/null; then
      info "Connected via password"
      connected=true

      # Copy SSH key for future connections
      if [[ -f "${SSH_KEY_PATH}.pub" ]]; then
        echo "  → Copying SSH key for passwordless auth..."
        ssh-copy-id -i "${SSH_KEY_PATH}.pub" -p "$SSH_PORT" "$SSH_TARGET" 2>/dev/null || true
      fi
    fi
  fi

  if ! $connected; then
    err "Could not establish SSH to ${SSH_TARGET}"
    echo ""
    echo "  Troubleshooting:"
    echo "    1. Verify the device is reachable: ping ${IP:-$HOST_ARG}"
    echo "    2. Check SSH is running on the device"
    echo "    3. Try manually: ssh ${SSH_TARGET} -p ${SSH_PORT}"
    echo "    4. Specify a key: make onboard IP=${IP:-$HOST_ARG} SSH_KEY=/path/to/key"
    exit 1
  fi

  # Rebuild SSH command now that we know the user
  SSH_CMD=$(build_ssh_cmd)
  mark_done "ssh_established"
}

# ── Phase 2: Remote System Detection ────────────────────────────────────────
detect_remote_system() {
  step "Detecting remote system"

  if is_done "system_detected" && [[ -n "$TYPE" ]]; then
    info "System already detected: TYPE=${TYPE}"
    return 0
  fi

  local detect_args=("$SSH_TARGET" "-p" "$SSH_PORT")
  if [[ -n "$SSH_KEY" ]] && [[ -f "$SSH_KEY" ]]; then
    detect_args+=("-i" "$SSH_KEY")
  elif [[ -n "$SSH_KEY_PATH" ]] && [[ -f "$SSH_KEY_PATH" ]]; then
    detect_args+=("-i" "$SSH_KEY_PATH")
  fi

  local detect_output
  detect_output=$(bash "$INFRA_DIR/scripts/configure/detect_remote.sh" "${detect_args[@]}" 2>/dev/null) || {
    warn "Remote detection failed — using defaults"
    TYPE="${TYPE:-server}"
    return 0
  }

  eval "$detect_output"

  # Auto-set TYPE from detection if not explicitly provided
  if [[ -z "$TYPE" ]]; then
    TYPE="${REMOTE_DEVICE_TYPE:-server}"
    info "Auto-detected type: ${TYPE}"
  fi

  # Auto-set NAME from remote hostname if not provided
  if [[ -z "$NAME" ]]; then
    NAME="${REMOTE_HOSTNAME:-device}"
    info "Auto-detected name: ${NAME}"
  fi

  # Set SSH port from type if detection reveals a mobile device
  case "$TYPE" in
    android) SSH_PORT=8022 ;;
  esac

  # Update SSH command
  SSH_CMD=$(build_ssh_cmd)
  mark_done "system_detected"
}

# ── Phase 3: Tailscale Provisioning ─────────────────────────────────────────
provision_tailscale() {
  step "Provisioning Tailscale"

  if is_done "tailscale_provisioned"; then
    info "Tailscale already provisioned (from previous run)"
    return 0
  fi

  # Check if device already has Tailscale
  local has_ts
  has_ts=$($SSH_CMD -o ConnectTimeout=5 "$SSH_TARGET" "command -v tailscale >/dev/null 2>&1 && tailscale ip -4 2>/dev/null || echo ''" 2>/dev/null || echo "")

  if [[ -n "$has_ts" ]] && [[ "$has_ts" != "" ]]; then
    info "Tailscale already running on device (IP: ${has_ts})"
    # Update our IP to the Tailscale IP
    IP="$has_ts"
    mark_done "tailscale_provisioned"
    return 0
  fi

  # Generate a pre-auth key via API if we have the API key
  local ts_auth_key="${TAILSCALE_AUTH_KEY:-}"
  local ts_api_key="${TAILSCALE_API_KEY:-}"

  if [[ -n "$ts_api_key" ]] && [[ -z "$ts_auth_key" || "$ts_auth_key" == tskey-auth-* ]]; then
    echo "  → Generating pre-auth key via Tailscale API..."
    local generated_key
    generated_key=$("$PYTHON" scripts/configure/tailscale_provision.py create-authkey \
      --no-ephemeral --description "onboard-${NAME:-device}" 2>/dev/null) || true

    if [[ -n "$generated_key" ]] && [[ "$generated_key" == tskey-auth-* ]]; then
      ts_auth_key="$generated_key"
      info "Generated pre-auth key for device"
    else
      warn "Could not generate pre-auth key — will use existing TAILSCALE_AUTH_KEY"
    fi
  fi

  if [[ -z "$ts_auth_key" ]]; then
    warn "No Tailscale auth key available. Device must join manually."
    echo "  Set TAILSCALE_AUTH_KEY or TAILSCALE_API_KEY in .env"
    mark_done "tailscale_provisioned"
    return 0
  fi

  # Install and configure Tailscale on remote device
  echo "  → Installing Tailscale on remote device..."
  if [[ "$DRY_RUN" != "1" ]]; then
    # Install Tailscale
    $SSH_CMD "$SSH_TARGET" "
      if command -v tailscale >/dev/null 2>&1; then
        echo '✓ Tailscale already installed'
      else
        echo '→ Installing Tailscale...'
        curl -fsSL https://tailscale.com/install.sh | sh
      fi
    " 2>&1 || warn "Tailscale install may need manual steps"

    # Bring up Tailscale with auth key
    echo "  → Joining Tailscale network..."
    $SSH_CMD "$SSH_TARGET" "
      sudo tailscale up --authkey='${ts_auth_key}' --ssh --accept-routes 2>&1 || \
        echo 'WARN: tailscale up may need manual intervention'
    " 2>&1 || warn "Tailscale join may need manual steps"

    # Wait for device and get the Tailscale IP
    sleep 3
    local ts_ip
    ts_ip=$($SSH_CMD -o ConnectTimeout=5 "$SSH_TARGET" "tailscale ip -4 2>/dev/null" 2>/dev/null || echo "")

    if [[ -n "$ts_ip" ]]; then
      info "Device joined Tailscale network: ${ts_ip}"
      # Switch to using the Tailscale IP for subsequent operations
      local old_ip="$IP"
      IP="$ts_ip"
      # Switch to Tailscale IP — clear alias mode since we now have a direct IP
      SSH_ALIAS=""
      SSH_TARGET="${REMOTE_USER}@${IP}"
      SSH_CMD=$(build_ssh_cmd)
      info "Switched to Tailscale IP: ${old_ip} → ${IP}"
    else
      warn "Could not get Tailscale IP from device. Keeping original IP."
    fi
  else
    echo "  [DRY RUN] Would install tailscale and join network"
  fi

  mark_done "tailscale_provisioned"
}

# ── Phase 4: Register device ───────────────────────────────────────────────
register_device() {
  step "Registering ${NAME} in config"

  local reg_args=(
    --name "$NAME"
    --ip "$IP"
    --user "$REMOTE_USER"
    --type "$TYPE"
    --ssh-port "$SSH_PORT"
    --force-update
  )

  if [[ "$DRY_RUN" == "1" ]]; then
    reg_args+=(--dry-run)
  fi

  "$PYTHON" scripts/configure/register_device.py "${reg_args[@]}"
  mark_done "registered"
}

# ── Phase 5: Bootstrap ──────────────────────────────────────────────────────
run_bootstrap() {
  step "Bootstrapping ${NAME}"

  if is_done "bootstrap_complete"; then
    if $SSH_CMD -o ConnectTimeout=5 "$SSH_TARGET" "command -v rsync" &>/dev/null; then
      info "Bootstrap already completed (from previous run)"
      return 0
    else
      warn "Previous bootstrap may be incomplete, re-running..."
    fi
  fi

  # Mobile devices get the mobile bootstrap first
  if [[ "$TYPE" == "android" || "$TYPE" == "ios_ish" ]]; then
    echo "  → Running mobile bootstrap..."
    if [[ "$DRY_RUN" != "1" ]]; then
      $SSH_CMD "$SSH_TARGET" "bash -s" < "$INFRA_DIR/scripts/install/mobile_bootstrap.sh" || true
    else
      echo "  [DRY RUN] Would pipe mobile_bootstrap.sh via SSH"
    fi
  fi

  # Full setup via new-server
  echo "  → Running full setup (new_server.sh ${NAME})..."
  if [[ "$DRY_RUN" != "1" ]]; then
    SSH_KEY="$SSH_KEY" bash "$INFRA_DIR/scripts/entrypoints/new_server.sh" "$NAME"
  else
    echo "  [DRY RUN] Would run: new_server.sh ${NAME}"
  fi

  mark_done "bootstrap_complete"
}

# ── Phase 6: Push aliases ──────────────────────────────────────────────────
push_aliases_to_device() {
  step "Pushing aliases to ${NAME}"

  if [[ "$DRY_RUN" != "1" ]]; then
    bash scripts/configure/push_aliases.sh "$NAME" || warn "Alias push failed (non-fatal)"
    bash scripts/configure/aliases.sh || true
  else
    echo "  [DRY RUN] Would push aliases and regenerate local aliases"
  fi
}

# ── Phase 7: Verify ────────────────────────────────────────────────────────
verify_onboard() {
  step "Verifying ${NAME}"

  if [[ "$DRY_RUN" != "1" ]]; then
    make check HOST="$NAME" 2>&1 || warn "Some tools missing (check output above)"
  else
    echo "  [DRY RUN] Would run: make check HOST=${NAME}"
  fi

  echo ""
  echo "═══════════════════════════════════════════════════"
  echo "  ✓ ${NAME} onboarded successfully!"
  echo "═══════════════════════════════════════════════════"
  echo ""
  echo "  Connect:  ssh_${NAME}  or  ${NAME} (mosh+tmux)"
  echo "  Check:    make check HOST=${NAME}"
  echo "  Status:   make status HOST=${NAME}"
  echo "  Sync:     make sync HOST=${NAME}"
  echo ""
}

# ── Print banner ────────────────────────────────────────────────────────────
print_banner() {
  echo ""
  echo "═══════════════════════════════════════════════════"
  echo "  TenAI Infra — Device Onboarding (Remote)"
  echo "═══════════════════════════════════════════════════"
  echo "  Target:  ${SSH_TARGET:-${IP}}"
  echo "  Name:    ${NAME:-auto-detect}"
  echo "  Type:    ${TYPE:-auto-detect}"
  echo "  User:    ${REMOTE_USER:-auto-detect}"
  echo "  Key:     ${SSH_KEY:-${SSH_KEY_PATH:-auto}}"
  echo "═══════════════════════════════════════════════════"
}

# ── Run the remote flow ─────────────────────────────────────────────────────
print_banner
establish_ssh        # Phase 1: Get SSH access
detect_remote_system # Phase 2: Determine OS/type/name
provision_tailscale  # Phase 3: Install tailscale + join network
register_device      # Phase 4: Add to config/local.yaml
run_bootstrap        # Phase 5: Sync code + install tools
push_aliases_to_device # Phase 6: SSH aliases on remote
verify_onboard       # Phase 7: Verify everything works

# Phase 8 (optional): Configure as exit node
if [[ "${EXIT_NODE:-}" == "1" ]]; then
  step "Configuring ${NAME} as exit node"
  DRY_RUN="$DRY_RUN" bash "$INFRA_DIR/scripts/configure/set_exit_node.sh" "$NAME"
fi
