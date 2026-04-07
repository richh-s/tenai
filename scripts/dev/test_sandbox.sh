#!/bin/bash
# scripts/dev/test_sandbox.sh — Automated cross-platform Sandbox testing for tenai-infra
#
# Usage: ./scripts/dev/test_sandbox.sh [multipass|tart] [--auto|--interactive] [--keep]
#        [--name=NAME] [--ubuntu-version=VERSION] [--update-packages]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$INFRA_DIR"

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

# Parameters
ENGINE="multipass"
MODE="interactive"
KEEP=0
NODE_NAME="tenai-test-node-tmp"
UBUNTU_VERSION=""
TART_CACHED_IMAGE="local/macos-tahoe-cached:latest"
TART_IMAGE="ghcr.io/cirruslabs/macos-tahoe-vanilla:latest"
UPDATE_PACKAGES=false

for arg in "$@"; do
  case $arg in
    multipass|tart) ENGINE="$arg" ;;
    --auto) MODE="auto" ;;
    --interactive) MODE="interactive" ;;
    --name=*) NODE_NAME="${arg#*=}" ;;
    --keep) KEEP=1 ;;
    --update-packages) UPDATE_PACKAGES=true ;;
    --ubuntu-version=*)
      UBUNTU_VERSION="${arg#*=}"
      ;;
    --tart-image=*)
      TART_IMAGE="${arg#*=}"
      ;;
    *) err "Unknown arg: $arg"; exit 1 ;;
  esac
done

if ! command -v "$ENGINE" >/dev/null 2>&1; then
  err "$ENGINE is not installed. Please install it first."
  if [ "$ENGINE" = "multipass" ]; then
    echo "  macOS: brew install multipass"
    echo "  Linux: snap install multipass"
    echo "  Windows: https://multipass.run/download/windows"
  elif [ "$ENGINE" = "tart" ]; then
    echo "  macOS: brew install cirruslabs/cli/tart"
  fi
  exit 1
fi

# Force Tart to run as arm64 consistently if on an Apple Silicon host.
# We bypass `uname -m` because if the user's shell is heavily translated via Rosetta 2,
# `uname -m` outputs `x86_64`, skipping this very fix. `sysctl -in hw.optional.arm64` 
# reliably outputs '1' on Apple Silicon even deep inside Rosetta chains.
if [ "$ENGINE" = "tart" ] && [ "$(sysctl -in hw.optional.arm64 2>/dev/null)" = "1" ]; then
  tart() {
    arch -arm64 command tart "$@"
  }
fi

# ── Smart Ubuntu version detection ──
# 1. If user explicitly set --ubuntu-version, use that.
# 2. If existing VM instances exist, detect the latest cached image version.
# 3. Otherwise fall back to "lts" (multipass default).
resolve_ubuntu_version() {
  if [ -n "$UBUNTU_VERSION" ]; then
    info "Using explicitly requested Ubuntu version: $UBUNTU_VERSION"
    return
  fi

  # Check for locally cached instances to infer available images
  local cached_versions
  cached_versions=$(multipass list --format csv 2>/dev/null | tail -n +2 | awk -F, '{print $5}' | sort -Vr | head -1)

  if [ -n "$cached_versions" ] && [ "$cached_versions" != "" ]; then
    local ver
    ver=$(multipass list --format csv 2>/dev/null | tail -n +2 | awk -F, '{print $5}' | grep -oE '[0-9]+\.[0-9]+' | sort -Vr | head -1)
    if [ -n "$ver" ]; then
      UBUNTU_VERSION="$ver"
      info "Auto-detected cached Ubuntu version: $UBUNTU_VERSION"
      return
    fi
  fi

  # Check vault directory for cached images (OS-specific paths)
  local img_dir=""
  if [ "$(uname -s)" = "Darwin" ]; then
    local driver
    driver=$(multipass get local.driver 2>/dev/null || echo "qemu")
    img_dir="/var/root/Library/Caches/multipassd/$driver/vault/images"
  else
    img_dir="/var/snap/multipass/common/data/multipassd/vault/images"
  fi

  local use_sudo=""
  if [ "$(uname -s)" = "Darwin" ]; then use_sudo="sudo"; fi

  if $use_sudo ls "$img_dir" >/dev/null 2>&1; then
    local latest_cached
    latest_cached=$($use_sudo ls -1 "$img_dir" 2>/dev/null | sort -Vr | head -1)
    if [ -n "$latest_cached" ]; then
      local codename="${latest_cached%%-*}"

      local mp_alias=""
      if multipass find "$codename" >/dev/null 2>&1; then
        mp_alias="$codename"
      elif multipass find "daily:$codename" >/dev/null 2>&1; then
        mp_alias="daily:$codename"
      else
        local num_ver
        num_ver=$(multipass find --format csv 2>/dev/null | grep -i "$codename" | head -1 | awk -F, '{print $1}')
        if [ -n "$num_ver" ]; then
          mp_alias="$num_ver"
        fi
      fi

      if [ -n "$mp_alias" ]; then
        UBUNTU_VERSION="$mp_alias"
        info "Auto-detected cached image from vault: $UBUNTU_VERSION (from $latest_cached)"
        return
      else
        warn "Cached image '$codename' not found in multipass remotes — falling back to default"
      fi
    fi
  fi

  UBUNTU_VERSION="lts"
  info "No cached images found — using default: $UBUNTU_VERSION (latest LTS)"
}

step "Preparing .env.test payload"
if [ ! -f ".env.test" ]; then
  if [ "$MODE" = "auto" ]; then
    err ".env.test is missing. In auto mode, create it first:"
    err "  cp .env .env.test  # then set TAILSCALE_AUTH_KEY"
    exit 1
  fi
  warn "No .env.test found. Creating one automatically from .env..."
  > .env.test
  if [ -f ".env" ]; then
    grep -E "^(GITHUB_TOKEN|ANTHROPIC_API_KEY|GEMINI_API_KEY|OPENAI_API_KEY)=" .env >> .env.test || true
  fi

  echo "TAILSCALE_AUTH_KEY=" >> .env.test
  warn "Please open .env.test and add your TAILSCALE_AUTH_KEY (preferably Ephemeral/Reusable)."
  echo "Press Enter when you have saved the file..."
  read -r
fi

# Ensure TAILSCALE_AUTH_KEY is not completely empty
if ! grep -q "TAILSCALE_AUTH_KEY=tskey-auth" .env.test; then
  if [ "$MODE" = "auto" ]; then
    err "No valid TAILSCALE_AUTH_KEY in .env.test. Cannot proceed in auto mode."
    exit 1
  fi
  err "No valid TAILSCALE_AUTH_KEY found in .env.test! The test will fail tailscale join."
  read -rp "Proceed anyway? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then exit 1; fi
fi

teardown() {
  if [ "$KEEP" = 0 ]; then
    step "Tearing down Sandbox VM"
    if [ "$ENGINE" = "multipass" ]; then
      multipass delete --purge "$NODE_NAME" 2>/dev/null || true
    elif [ "$ENGINE" = "tart" ]; then
        tart stop "$NODE_NAME" 2>/dev/null || true
        tart delete "$NODE_NAME" 2>/dev/null || true
    fi
    info "Sandbox destroyed."
  else
    info "Sandbox retained (--keep). Use '$ENGINE delete $NODE_NAME' to manually purge."
  fi
}

trap teardown EXIT

step "Provisioning $ENGINE Sandbox: $NODE_NAME"

if [ "$ENGINE" = "multipass" ]; then
  # ── MULTIPASS FLOW ──
  #
  # Cloud-init provisions the VM: clones the repo, writes .env, and injects
  # the host SSH key. Direct SSH (ssh ubuntu@<IP>) works immediately after
  # launch — it bypasses the cloud-init completion check that blocks
  # `multipass shell` and `multipass exec`.

  resolve_ubuntu_version

  # Determine repo URL and branch
  _repo_url=$(git remote get-url origin 2>/dev/null | sed 's|git@github[^:]*:|https://github.com/|;s|\.git$||').git
  _branch=$(git branch --show-current 2>/dev/null || echo "main")

  # Extract GITHUB_TOKEN for private repo clone
  _github_token=""
  if [ -f ".env.test" ]; then
    _github_token=$(grep "^GITHUB_TOKEN=" .env.test | head -1 | cut -d= -f2-)
  fi
  if [ -z "$_github_token" ] && [ -f ".env" ]; then
    _github_token=$(grep "^GITHUB_TOKEN=" .env | head -1 | cut -d= -f2-)
  fi

  if [ -n "$_github_token" ]; then
    _clone_url=$(echo "$_repo_url" | sed "s|https://github.com/|https://${_github_token}@github.com/|")
    info "Will clone (authenticated) $_repo_url (branch: $_branch)"
  else
    _clone_url="$_repo_url"
    warn "No GITHUB_TOKEN found — clone will fail if repo is private"
    info "Will clone $_repo_url (branch: $_branch)"
  fi

  # Encode .env.test as base64 to avoid YAML escaping issues in cloud-init
  _env_b64=""
  if [ -f ".env.test" ]; then
    # Generate single-line base64 (no wrapping) to avoid breaking YAML heredoc
    _env_b64=$(base64 < .env.test | tr -d '\n')
  fi

  # Detect host SSH public key for direct VM access
  _ssh_pubkey=""
  for _keyfile in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
    if [ -f "$_keyfile" ]; then
      _ssh_pubkey=$(cat "$_keyfile")
      break
    fi
  done

  if [ -z "$_ssh_pubkey" ]; then
    if [ "$MODE" = "auto" ]; then
      err "No host SSH public key found. AUTO mode requires direct SSH access to stream logs."
      exit 1
    else
      warn "No host SSH public key found. Direct SSH access will not be available."
    fi
  fi

  # Build cloud-init user-data
  _cloud_init_file="/tmp/tenai-sandbox-cloud-init.yaml"

  cat > "$_cloud_init_file" <<CLOUDINIT
#cloud-config
package_update: $UPDATE_PACKAGES
packages:
  - git
  - make
  - curl
CLOUDINIT

  if [ -n "$_ssh_pubkey" ]; then
    cat >> "$_cloud_init_file" <<CLOUDINIT

ssh_authorized_keys:
  - $_ssh_pubkey
CLOUDINIT
  fi

  cat >> "$_cloud_init_file" <<CLOUDINIT

runcmd:
  - |
    set -e
    cd /home/ubuntu
    echo '>> Cloning tenai-infra...'
    git clone --branch "$_branch" "$_clone_url" tenai-infra
    cd /home/ubuntu/tenai-infra
    # Remove token from git remote to avoid leaking credentials
    git remote set-url origin "$_repo_url"
    # Write .env from base64-encoded .env.test
    echo '$_env_b64' | base64 -d > .env
    chmod 600 .env
    # Ensure ubuntu owns everything in home (runcmd runs as root)
    chown -R ubuntu:ubuntu /home/ubuntu
CLOUDINIT

  # In auto mode, append the full test pipeline
  if [ "$MODE" = "auto" ]; then
    cat >> "$_cloud_init_file" <<'CLOUDINIT_AUTO'
  - |
    set -e
    cd /home/ubuntu/tenai-infra
    LOG="/home/ubuntu/sandbox-log.txt"
    # Source .env for variables like TAILSCALE_TAILNET
    set -a; source .env 2>/dev/null || true; set +a
    # Use sandboxtest.yaml config if available
    if [ -f config/sandboxtest.yaml ]; then
      export TENAI_CONFIG=config/sandboxtest.yaml
    fi
    echo '>> Step 1: Resetting device config'
    make reset-device NONINTERACTIVE=1 CONFIRM=1 TAILNET="${TAILSCALE_TAILNET:-test@}" 2>&1 | tee "$LOG"
    echo '>> Step 2: Onboarding test node'
    make onboard CONFIRM=1 TEST=1 2>&1 | tee -a "$LOG" || true
    echo '>> Step 3: Verifying state'
    make check 2>&1 | tee -a "$LOG" || true
    echo '>> Step 4: Running unit tests'
    make test 2>&1 | tee -a "$LOG"
    echo '===== SANDBOX TEST COMPLETE =====' | tee -a "$LOG"
CLOUDINIT_AUTO
  fi

  cat >> "$_cloud_init_file" <<'CLOUDINIT_FINAL'

final_message: "Tenai sandbox VM ready after $UPTIME seconds"
CLOUDINIT_FINAL

  # Enable bridged networking if configured
  _network_args=""
  _bridged_if=$(multipass get local.bridged-network 2>/dev/null || echo "")
  if [ -n "$_bridged_if" ] && [ "$_bridged_if" != "<empty>" ]; then
    _network_args="--network bridged"
    info "Bridged network enabled on $_bridged_if"
  fi

  if [ -n "$_ssh_pubkey" ]; then
    info "Host SSH key will be injected for direct access"
  else
    warn "No SSH public key found — only multipass shell will work (after cloud-init completes)"
  fi

  info "Launching fresh Ubuntu VM ($UBUNTU_VERSION) with cloud-init..."
  multipass launch "$UBUNTU_VERSION" --name "$NODE_NAME" --cloud-init "$_cloud_init_file" --memory 2G --disk 10G $_network_args

  # Get VM IP
  _vm_ip=$(multipass info "$NODE_NAME" 2>/dev/null | grep "IPv4" | awk '{print $2}') || _vm_ip="unknown"

  if [ "$MODE" = "interactive" ]; then
    step "Sandbox VM Ready"
    info "VM Name: $NODE_NAME"
    info "VM IP:   $_vm_ip"
    info "Image:   $UBUNTU_VERSION"
    echo ""
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│  Connect via SSH (works immediately):                      │"
    echo "│    ssh ubuntu@$_vm_ip                                      │"
    echo "│                                                            │"
    echo "│  Or via Multipass (waits for cloud-init to finish):        │"
    echo "│    multipass shell $NODE_NAME                              │"
    echo "│                                                            │"
    echo "│  Inside the VM, run:                                       │"
    echo "│    cd ~/tenai-infra && make onboard                        │"
    echo "│                                                            │"
    echo "│  Cloud-init is cloning the repo in the background.         │"
    echo "│  Wait ~1-2 min for the clone to finish before running.     │"
    echo "│                                                            │"
    echo "│  When done, destroy the VM:                                │"
    echo "│    multipass delete --purge $NODE_NAME                     │"
    echo "└─────────────────────────────────────────────────────────────┘"
    echo ""
    KEEP=1

  else
    # ── AUTO MODE ──
    # Stream logs from VM via SSH in real-time
    _log_date=$(date +%Y-%m-%d)
    _log_dir="sandbox-logs/${_log_date}_${NODE_NAME}"
    mkdir -p "$_log_dir"
    _log_file="$_log_dir/test-run.log"

    step "Automated Test Pipeline"
    info "Cloud-init is running the test suite inside the VM."
    info "SSH access: ssh ubuntu@$_vm_ip"
    info "Results: $_log_file"
    echo ""
    echo "  Waiting for test pipeline to produce output..."

    # Poll via SSH until the log file appears, then stream it
    _timeout=600  # 10 minutes max
    _elapsed=0
    _tail_pid=""

    while [ $_elapsed -lt $_timeout ]; do
      # Check if log file exists yet
      if [ -z "$_tail_pid" ]; then
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
           "ubuntu@$_vm_ip" "test -f /home/ubuntu/sandbox-log.txt" 2>/dev/null; then
          echo ""
          info "Streaming test output..."
          echo ""
          # Stream logs in background, tee to local file
          ssh -o StrictHostKeyChecking=no -o BatchMode=yes "ubuntu@$_vm_ip" \
            "tail -f /home/ubuntu/sandbox-log.txt" 2>/dev/null | tee "$_log_file" &
          _tail_pid=$!
        fi
      fi

      # Check for completion marker in local log
      if [ -f "$_log_file" ] && grep -q "SANDBOX TEST COMPLETE" "$_log_file" 2>/dev/null; then
        [ -n "$_tail_pid" ] && kill "$_tail_pid" 2>/dev/null || true
        wait "$_tail_pid" 2>/dev/null || true
        break
      fi

      sleep 10
      _elapsed=$((_elapsed + 10))
    done

    # Cleanup tail if still running
    if [ -n "$_tail_pid" ] && kill -0 "$_tail_pid" 2>/dev/null; then
      kill "$_tail_pid" 2>/dev/null || true
      wait "$_tail_pid" 2>/dev/null || true
    fi

    # If streaming never started, grab the full log
    if [ -z "$_tail_pid" ]; then
      ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
        "ubuntu@$_vm_ip" "cat /home/ubuntu/sandbox-log.txt" > "$_log_file" 2>/dev/null || true
    fi

    echo ""
    step "Test Results"
    if [ -f "$_log_file" ] && grep -q "SANDBOX TEST COMPLETE" "$_log_file" 2>/dev/null; then
      info "End-to-end Multipass test PASSED."
      info "Full log: $_log_file"
    elif [ -f "$_log_file" ] && [ -s "$_log_file" ]; then
      warn "Test pipeline may not have completed within timeout."
      warn "Partial log: $_log_file"
      warn "Check manually: ssh ubuntu@$_vm_ip"
    else
      warn "Could not retrieve log."
      warn "Check manually: ssh ubuntu@$_vm_ip"
      warn "  Then run: cat /home/ubuntu/sandbox-log.txt"
    fi

    # Save VM metadata
    multipass info "$NODE_NAME" > "$_log_dir/vm-info.txt" 2>/dev/null || true
  fi

elif [ "$ENGINE" = "tart" ]; then
  # ── TART FLOW ──
  if tart list | grep -q "^local[[:space:]]*$NODE_NAME"; then
    info "Existing Sandbox VM '$NODE_NAME' detected."
    info "Reusing existing VM to bypass Xcode/Homebrew setup."
  else
    info "Cloning pristine macOS VM ($TART_IMAGE)..."
    tart clone "$TART_IMAGE" "$NODE_NAME"
  fi

  info "Booting macOS VM... (This takes a moment)"
  tart run --no-graphics "$NODE_NAME" &
  TART_PID=$!

  # Wait for IP
  sleep 10
  VM_IP=""
  for i in {1..30}; do
    VM_IP=$(tart ip "$NODE_NAME" 2>/dev/null || echo "")
    if [ -n "$VM_IP" ]; then break; fi
    sleep 2
  done

  if [ -z "$VM_IP" ]; then
    err "Failed to get IP for Tart VM."
    exit 1
  fi
  info "Tart VM booted at $VM_IP. Password is 'admin'."

  ssh-keyscan -H "$VM_IP" >> ~/.ssh/known_hosts 2>/dev/null || true

  # Determine repo URL and branch for git clone (mirror multipass approach)
  _repo_url=$(git remote get-url origin 2>/dev/null | sed 's|git@github[^:]*:|https://github.com/|;s|\.git$||').git
  _branch=$(git branch --show-current 2>/dev/null || echo "main")

  _github_token=""
  if [ -f ".env.test" ]; then
    _github_token=$(grep "^GITHUB_TOKEN=" .env.test | head -1 | cut -d= -f2-)
  fi
  if [ -z "$_github_token" ] && [ -f ".env" ]; then
    _github_token=$(grep "^GITHUB_TOKEN=" .env | head -1 | cut -d= -f2-)
  fi

  if [ -n "$_github_token" ]; then
    _clone_url=$(echo "$_repo_url" | sed "s|https://github.com/|https://${_github_token}@github.com/|")
    info "Will clone (authenticated) $_repo_url (branch: $_branch)"
  else
    _clone_url="$_repo_url"
    warn "No GITHUB_TOKEN found — clone will fail if repo is private"
    info "Will clone $_repo_url (branch: $_branch)"
  fi

  info "Cloning repo and injecting .env inside macOS VM..."
  ssh -o StrictHostKeyChecking=no "admin@$VM_IP" "
    set -e
    echo '>> Verifying homebrew'
    if ! command -v brew >/dev/null; then
      echo 'Installing Homebrew natively on Tart VM...'
      NONINTERACTIVE=1 /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
      echo 'eval \"\$(/opt/homebrew/bin/brew shellenv)\"' >> ~/.zprofile
      eval \"\$(/opt/homebrew/bin/brew shellenv)\"
    fi
    echo '>> Installing git'
    command -v git >/dev/null || brew install git

    echo '>> Cloning tenai-infra...'
    rm -rf ~/tenai-infra
    git clone --branch '$_branch' '$_clone_url' ~/tenai-infra
    cd ~/tenai-infra
    git remote set-url origin '$_repo_url'
    echo '>> Clone ready'
  "

  # Inject .env.test → .env via SCP (secrets stay out of git)
  info "Injecting .env.test as .env..."
  scp -o StrictHostKeyChecking=no .env.test "admin@$VM_IP:~/tenai-infra/.env"

  if [ "$MODE" = "interactive" ]; then
    info "Entering Interactive Sandbox."
    echo ""
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│  Connect via SSH (works immediately):                      │"
    echo "│    ssh admin@$VM_IP                                        │"
    echo "│                                                            │"
    echo "│  Inside the VM, run:                                       │"
    echo "│    cd ~/tenai-infra                                        │"
    echo "│    make reset-device                                       │"
    echo "│    make onboard                                            │"
    echo "│                                                            │"
    echo "│  To view the graphical desktop (UI):                       │"
    echo "│    you need to launch it without the --no-graphics flag.   │"
    echo "│    Since it is already running in the background,          │"
    echo "│    you first stop it, then launch it with the UI:          │"
    echo "│    tart stop $NODE_NAME                                    │"
    echo "│    tart run $NODE_NAME                                     │"
    echo "│                                                            │"
    echo "│  When done, destroy the VM:                                │"
    echo "│    tart delete $NODE_NAME                                  │"
    echo "└─────────────────────────────────────────────────────────────┘"
    echo ""
    KEEP=1
    ssh -o StrictHostKeyChecking=no "admin@$VM_IP"
  else
    # ── AUTO MODE ──
    info "Running Automated Test Pipeline..."
    _log_date=$(date +%Y-%m-%d)
    _log_dir="sandbox-logs/${_log_date}_${NODE_NAME}"
    mkdir -p "$_log_dir"
    _log_file="$_log_dir/test-tart-${TART_IMAGE//\//-}-$(date +%s).log"

    info "Test output will stream here and save to: $_log_file"

    # Run the real user flow inside the VM (mirrors README quick-start)
    ssh -o StrictHostKeyChecking=no "admin@$VM_IP" "
      set -e
      export PATH=\"/opt/homebrew/bin:\$PATH\"
      cd ~/tenai-infra
      LOG=~/sandbox-log.txt

      # Source .env for variables like TAILSCALE_TAILNET
      set -a; source .env 2>/dev/null || true; set +a

      # Use sandboxtest.yaml config if available
      if [ -f config/sandboxtest.yaml ]; then
        export TENAI_CONFIG=config/sandboxtest.yaml
      fi

      echo '>> Step 1: Resetting device config'
      make reset-device NONINTERACTIVE=1 CONFIRM=1 TAILNET=\"\${TAILSCALE_TAILNET:-test@}\" 2>&1 | tee \"\$LOG\"

      echo '>> Step 2: Onboarding test node'
      make onboard CONFIRM=1 TEST=1 2>&1 | tee -a \"\$LOG\" || true

      echo '>> Step 3: Verifying state'
      make check 2>&1 | tee -a \"\$LOG\" || true

      echo '>> Step 4: Running unit tests'
      make test 2>&1 | tee -a \"\$LOG\"

      echo '===== SANDBOX TEST COMPLETE =====' | tee -a \"\$LOG\"
    " &
    _tart_ssh_pid=$!

    # Wait briefly for log to be created by the background process
    sleep 5

    # Stream the log back to the host console (mirrors multipass approach)
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes "admin@$VM_IP" \
      "tail -f ~/sandbox-log.txt" 2>/dev/null | tee "$_log_file" &
    _tail_pid=$!

    # Wait for the main test to finish
    wait "$_tart_ssh_pid" 2>/dev/null || true

    # Fetch final log cleanly
    info "Fetching final log..."
    scp -o StrictHostKeyChecking=no -o BatchMode=yes "admin@$VM_IP:~/sandbox-log.txt" "$_log_file" 2>/dev/null || true

    [ -n "$_tail_pid" ] && kill "$_tail_pid" 2>/dev/null || true
    wait "$_tail_pid" 2>/dev/null || true

    if grep -q "SANDBOX TEST COMPLETE" "$_log_file" 2>/dev/null; then
      info "End-to-end Tart test PASSED."
    else
      warn "Test pipeline may have failed. Check log: $_log_file"
    fi
  fi

  # Kill VM
  kill $TART_PID 2>/dev/null || true
fi

