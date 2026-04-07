#!/bin/bash
# scripts/install/mobile_bootstrap.sh — Bootstrap a mobile device (Termux or iSH)
#
# Can be run two ways:
#   1. Piped from onboard wizard: ssh user@ip "bash -s" < mobile_bootstrap.sh
#   2. Directly on the phone:     bash mobile_bootstrap.sh
#
# Idempotent — safe to re-run. Detects platform and installs minimum deps.
set -euo pipefail

# ── Detect platform ──────────────────────────────────────────────────────────
detect_platform() {
  if [[ -n "${PREFIX:-}" ]] && [[ "$PREFIX" == *"com.termux"* ]]; then
    echo "termux"
  elif [[ -f /proc/ish/version ]] || grep -q "ish" /proc/version 2>/dev/null; then
    echo "ish"
  elif [[ "$(uname -o 2>/dev/null)" == "Android" ]]; then
    echo "termux"
  else
    echo "unknown"
  fi
}

PLATFORM=$(detect_platform)
echo "── Mobile Bootstrap (${PLATFORM}) ──"

if [[ "$PLATFORM" == "unknown" ]]; then
  echo "✗ Cannot detect platform. Run this inside Termux (Android) or iSH (iOS)."
  exit 1
fi

# ── Helper: idempotent package install ────────────────────────────────────────
install_pkg() {
  local pkg="$1"
  local cmd="${2:-$1}"   # command to check (may differ from package name)
  if command -v "$cmd" &>/dev/null; then
    echo "  ✓ ${pkg} already installed"
  else
    echo "  → Installing ${pkg}..."
    case "$PLATFORM" in
      termux) pkg install -y "$pkg" 2>&1 ;;
      ish)    apk add "$pkg" 2>&1 ;;
    esac
  fi
}

# ── Helper: idempotent line in RC file ────────────────────────────────────────
ensure_rc_line() {
  local file="$1"
  local marker="$2"
  local line="$3"
  if grep -qF "$marker" "$file" 2>/dev/null; then
    echo "  ✓ Already in ${file}: ${marker}"
  else
    echo "" >> "$file"
    echo "# ${marker}" >> "$file"
    echo "$line" >> "$file"
    echo "  ✓ Added to ${file}: ${marker}"
  fi
}

# ── Phase 1: Update package manager ──────────────────────────────────────────
echo "── Updating packages ──"
case "$PLATFORM" in
  termux) pkg update -y 2>&1 | tail -1 ;;
  ish)    apk update 2>&1 | tail -1 ;;
esac

# ── Phase 2: Install essential packages ──────────────────────────────────────
echo "── Installing packages ──"
case "$PLATFORM" in
  termux)
    install_pkg openssh sshd
    install_pkg rsync
    install_pkg make
    install_pkg curl
    install_pkg git
    install_pkg mosh mosh-server
    ;;
  ish)
    install_pkg openssh sshd
    install_pkg rsync
    install_pkg make
    install_pkg curl
    install_pkg bash
    install_pkg git
    install_pkg mosh mosh-server
    install_pkg python3
    ;;
esac

# ── Phase 3: Generate SSH host keys (iSH only) ──────────────────────────────
if [[ "$PLATFORM" == "ish" ]]; then
  if [[ -f /etc/ssh/ssh_host_ed25519_key ]]; then
    echo "  ✓ SSH host keys exist"
  else
    echo "  → Generating SSH host keys..."
    ssh-keygen -A 2>/dev/null
    echo "  ✓ Host keys generated"
  fi
  # Ensure PermitRootLogin is enabled
  if grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config 2>/dev/null; then
    echo "  ✓ PermitRootLogin already enabled"
  else
    echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
    echo "  ✓ Enabled PermitRootLogin"
  fi
fi

# ── Phase 4: Start sshd ─────────────────────────────────────────────────────
echo "── Starting sshd ──"
if pgrep -x sshd >/dev/null 2>&1; then
  echo "  ✓ sshd already running"
else
  case "$PLATFORM" in
    termux) sshd 2>/dev/null && echo "  ✓ sshd started (port 8022)" ;;
    ish)    /usr/sbin/sshd 2>/dev/null && echo "  ✓ sshd started (port 22)" ;;
  esac
fi

# ── Phase 5: Auto-start sshd on new sessions ────────────────────────────────
echo "── Configuring sshd auto-start ──"
case "$PLATFORM" in
  termux)
    ensure_rc_line "$HOME/.bashrc" \
      "TENAI INFRA SSHD AUTO-START" \
      'pgrep -x sshd >/dev/null 2>&1 || sshd 2>/dev/null'
    ;;
  ish)
    ensure_rc_line "$HOME/.profile" \
      "TENAI INFRA SSHD AUTO-START" \
      'pgrep -x sshd >/dev/null 2>&1 || /usr/sbin/sshd 2>/dev/null'
    ;;
esac

# ── Phase 6: Termux storage access ──────────────────────────────────────────
if [[ "$PLATFORM" == "termux" ]]; then
  if [[ -d "$HOME/storage" ]]; then
    echo "  ✓ Termux storage already set up"
  else
    echo "  → Setting up Termux storage access..."
    termux-setup-storage 2>/dev/null || echo "  ⚠ Run 'termux-setup-storage' manually (needs UI)"
  fi
fi

# ── Report ───────────────────────────────────────────────────────────────────
echo ""
echo "── Bootstrap Complete ──"

# Determine IP and port
IP=""
PORT=""
USER_VAL=""

case "$PLATFORM" in
  termux)
    PORT="8022"
    USER_VAL="$(whoami)"
    ;;
  ish)
    PORT="22"
    USER_VAL="root"
    ;;
esac

# Try to get Tailscale IP
if command -v tailscale &>/dev/null; then
  IP=$(tailscale ip -4 2>/dev/null || echo "")
fi

if [[ -z "$IP" ]]; then
  # Fallback: get any non-loopback IP
  IP=$(hostname -I 2>/dev/null | awk '{print $1}' || ip addr show 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -1 || echo "unknown")
fi

echo "  Platform: ${PLATFORM}"
echo "  User:     ${USER_VAL}"
echo "  IP:       ${IP}"
echo "  Port:     ${PORT}"
echo ""
echo "ONBOARD_READY:${IP}:${PORT}:${USER_VAL}"
