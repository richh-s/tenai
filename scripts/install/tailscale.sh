#!/bin/bash
# scripts/install/tailscale.sh — install and configure Tailscale
set -euo pipefail

source "$(dirname "$0")/../detect.sh"
source "$(dirname "$0")/../lib/state_track.sh"

install_tailscale() {
  echo "── Installing Tailscale on ${OS_TYPE} ──"

  case "$OS_TYPE" in
    linux)
      if command -v tailscale &>/dev/null; then
        local ts_ver
        ts_ver="$(tailscale version 2>&1 | head -1)" || true
        echo "✓ Tailscale already installed: $ts_ver"
        return
      fi
      curl -fsSL https://tailscale.com/install.sh | sh
      sudo_prompt "Starting Tailscale system daemon (tailscaled)"
      sudo systemctl enable --now tailscaled
      ;;

    mac)
      if command -v tailscale &>/dev/null; then
        local ts_ver
        ts_ver="$(tailscale version 2>&1 | head -1)" || true
        echo "✓ Tailscale already installed: $ts_ver"
        return
      fi
      # Install via pkg (not App Store — avoids sandboxing)
      echo "Download Tailscale .pkg from: https://pkgs.tailscale.com/stable/#macos"
      echo "Or install via brew:"
      brew install --cask tailscale
      ;;

    wsl)
      if command -v tailscale &>/dev/null; then
        local ts_ver
        ts_ver="$(tailscale version 2>&1 | head -1)" || true
        echo "✓ Tailscale already installed: $ts_ver"
        return
      fi
      curl -fsSL https://tailscale.com/install.sh | sh
      sudo_prompt "Starting Tailscale system daemon (tailscaled)"
      sudo systemctl enable --now tailscaled 2>/dev/null || true
      ;;

    termux)
      if command -v tailscale &>/dev/null; then
        echo "✓ Tailscale CLI already installed"
        return
      fi
      pkg install tailscale -y 2>/dev/null || {
        echo "pkg install failed, trying manual install..."
        ARCH=$(uname -m)
        case "$ARCH" in
          aarch64) ARCH_TAG="arm64" ;;
          armv7l)  ARCH_TAG="arm"   ;;
          x86_64)  ARCH_TAG="amd64" ;;
        esac
        curl -L "https://pkgs.tailscale.com/stable/tailscale_latest_${ARCH_TAG}.tgz" -o /tmp/tailscale.tgz
        tar -xzf /tmp/tailscale.tgz -C /tmp/
        mv /tmp/tailscale*/tailscale "$PREFIX/bin/"
        chmod +x "$PREFIX/bin/tailscale"
        rm -rf /tmp/tailscale*
      }
      ;;
  esac

  echo "✓ Tailscale installed"
}

configure_tailscale() {
  echo "── Configuring Tailscale ──"

  # Skip if already connected and running
  if command -v tailscale &>/dev/null; then
    local ts_state
    ts_state="$(tailscale status --json 2>/dev/null | $PYTHON -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || echo "")"
    if [[ "$ts_state" == "Running" ]]; then
      # Check if this is OUR tailnet or someone else's
      local current_user
      current_user="$(tailscale status --json 2>/dev/null | $PYTHON -c 'import json,sys; d=json.load(sys.stdin); print(d.get("Self",{}).get("UserID",0))' 2>/dev/null || echo "")"
      local current_tailnet
      current_tailnet="$(tailscale status --json 2>/dev/null | $PYTHON -c 'import json,sys; d=json.load(sys.stdin); print(d.get("CurrentTailnet",{}).get("Name",""))' 2>/dev/null || echo "")"

      echo "✓ Tailscale already connected (tailnet: ${current_tailnet:-unknown})"
      tailscale status 2>/dev/null | head -5
      echo ""
      echo "  ⓘ  Tailscale is already running on another user's tailnet."
      echo "     To take over, run: sudo tailscale up --force-reauth --authkey=<yours>"
      echo "     To share this node, ask the tailnet admin to share it with your account."
      echo "     Skipping Tailscale configuration to avoid disrupting existing access."
      return 0
    fi
  fi

  # Only modify system settings if Tailscale is NOT already running
  local auth_key="${TAILSCALE_AUTH_KEY:-}"
  local flags="${TAILSCALE_FLAGS:---accept-routes}"

  # Enable IP forwarding on Linux servers
  if [[ "$OS_TYPE" == "linux" ]]; then
    echo "── Enabling IP forwarding ──"
    sudo_prompt "Configuring IP forwarding for Tailscale (sysctl)"
    grep -qxF 'net.ipv4.ip_forward = 1' /etc/sysctl.d/99-tailscale.conf 2>/dev/null || \
      echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
    grep -qxF 'net.ipv6.conf.all.forwarding = 1' /etc/sysctl.d/99-tailscale.conf 2>/dev/null || \
      echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
    sudo sysctl -p /etc/sysctl.d/99-tailscale.conf

    # UDP GRO optimization
    if command -v ethtool &>/dev/null; then
      IFACE=$(ip route | awk '/default/ {print $5; exit}')
      sudo ethtool -K "$IFACE" rx-udp-gro-forwarding on 2>/dev/null || true
    fi

    flags="$flags --ssh --advertise-exit-node"
  fi

  if [[ -n "$auth_key" ]]; then
    sudo_prompt "Connecting Tailscale to the tenai tailnet"
    sudo tailscale up $flags --authkey="$auth_key"
  else
    echo "No TAILSCALE_AUTH_KEY set — run manually:"
    echo "  sudo tailscale up $flags"
  fi

  echo "── Tailscale status ──"
  tailscale status 2>/dev/null || echo "(tailscale not yet running)"
  return 0  # never fail the script over status checks
}

configure_firewall() {
  if [[ "$OS_TYPE" != "linux" ]]; then return; fi
  # Delegate to the dedicated firewall manager (safe, cloud-aware, never touches SSH)
  bash "$(dirname "$0")/firewall.sh" || true
}

install_tailscale
configure_tailscale
configure_firewall

