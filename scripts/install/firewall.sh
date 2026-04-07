#!/bin/bash
# scripts/install/firewall.sh — Safe firewall port management for tenai-infra.
#
# Design principles:
#   1. NEVER touch SSH ports — if we're connected, SSH works. Not our problem.
#   2. NEVER enable/activate a firewall that isn't already active.
#   3. Only add rules for ports our codebase manages (mosh, tailscale, vibetunnel).
#   4. Detect cloud environments and skip host-level firewall (use Security Groups).
#   5. Support UFW, firewalld, and raw iptables backends.
#
# Usage:
#   bash scripts/install/firewall.sh           # auto-detect and configure
#   FIREWALL_SKIP=1 bash scripts/install/firewall.sh   # skip entirely
#
set -euo pipefail

source "$(dirname "$0")/../detect.sh"

# Only run on Linux
if [[ "$OS_TYPE" != "linux" ]]; then
  echo "✓ Firewall config: skipped (${OS_TYPE} — not applicable)"
  exit 0
fi

# Allow skipping via env or skip_tools
if [[ "${FIREWALL_SKIP:-0}" == "1" ]]; then
  echo "✓ Firewall config: skipped (FIREWALL_SKIP=1)"
  exit 0
fi

# ── Ports we manage ──────────────────────────────────────────────────────────
# These are the ONLY ports this script will add rules for.
# SSH (22/tcp) is explicitly NOT included — that's the user's responsibility.
MANAGED_UDP_PORTS="60000:61000"   # mosh
MANAGED_TCP_PORTS=""              # reserved for future use (e.g. vibetunnel 4020)
MANAGED_INTERFACES="tailscale0"  # allow all traffic on tailnet

# ── Cloud detection ──────────────────────────────────────────────────────────

detect_cloud() {
  # Returns: aws, gcp, azure, or empty string
  local cloud=""

  # AWS: check DMI board_asset_tag (contains instance ID like "i-...")
  if [[ -f /sys/devices/virtual/dmi/id/board_asset_tag ]]; then
    local tag
    tag=$(cat /sys/devices/virtual/dmi/id/board_asset_tag 2>/dev/null || echo "")
    if [[ "$tag" == i-* ]]; then
      cloud="aws"
    fi
  fi

  # AWS fallback: IMDS metadata endpoint (with 1s timeout)
  if [[ -z "$cloud" ]]; then
    if curl -s --connect-timeout 1 --max-time 1 \
       -H "X-aws-ec2-metadata-token-ttl-seconds: 1" \
       -X PUT http://169.254.169.254/latest/api/token &>/dev/null 2>&1; then
      cloud="aws"
    fi
  fi

  # GCP: check product_name
  if [[ -z "$cloud" ]] && [[ -f /sys/devices/virtual/dmi/id/product_name ]]; then
    local product
    product=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo "")
    if [[ "$product" == "Google Compute Engine" ]]; then
      cloud="gcp"
    fi
  fi

  # Azure: check chassis_asset_tag
  if [[ -z "$cloud" ]] && [[ -f /sys/devices/virtual/dmi/id/chassis_asset_tag ]]; then
    local chassis
    chassis=$(cat /sys/devices/virtual/dmi/id/chassis_asset_tag 2>/dev/null || echo "")
    if [[ "$chassis" == "7783-7084-3265-9085-8269-3286-77" ]]; then
      cloud="azure"
    fi
  fi

  echo "$cloud"
}

# ── Firewall backend detection ───────────────────────────────────────────────

detect_firewall() {
  # Returns: ufw, firewalld, iptables, or none
  # Only returns a backend if it's ACTIVE (we never activate dormant firewalls)

  # Check UFW first (most common on Ubuntu)
  if command -v ufw &>/dev/null; then
    if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
      echo "ufw"
      return
    fi
  fi

  # Check firewalld (common on RHEL/CentOS/Fedora)
  if command -v firewall-cmd &>/dev/null; then
    if sudo firewall-cmd --state 2>/dev/null | grep -q "running"; then
      echo "firewalld"
      return
    fi
  fi

  # Check iptables (raw fallback)
  if command -v iptables &>/dev/null; then
    # Only consider iptables "active" if there are non-default rules
    local rule_count
    rule_count=$(sudo iptables -L INPUT -n 2>/dev/null | grep -c -v '^Chain\|^target\|^$' || echo "0")
    if [[ "$rule_count" -gt 0 ]]; then
      echo "iptables"
      return
    fi
  fi

  echo "none"
}

# ── UFW backend ──────────────────────────────────────────────────────────────

add_rules_ufw() {
  local changed=false

  # Mosh UDP ports
  if [[ -n "$MANAGED_UDP_PORTS" ]]; then
    if ! sudo ufw status | grep -q "${MANAGED_UDP_PORTS}/udp"; then
      echo "  → Adding UFW rule: ${MANAGED_UDP_PORTS}/udp (mosh)"
      sudo ufw allow "${MANAGED_UDP_PORTS}/udp"
      changed=true
    else
      echo "  ✓ UFW rule exists: ${MANAGED_UDP_PORTS}/udp"
    fi
  fi

  # Tailscale interface
  for iface in $MANAGED_INTERFACES; do
    if ! sudo ufw status | grep -q "$iface"; then
      echo "  → Adding UFW rule: allow in on ${iface}"
      sudo ufw allow in on "$iface"
      changed=true
    else
      echo "  ✓ UFW rule exists: ${iface}"
    fi
  done

  # Managed TCP ports (if any)
  if [[ -n "$MANAGED_TCP_PORTS" ]]; then
    if ! sudo ufw status | grep -q "${MANAGED_TCP_PORTS}/tcp"; then
      echo "  → Adding UFW rule: ${MANAGED_TCP_PORTS}/tcp"
      sudo ufw allow "${MANAGED_TCP_PORTS}/tcp"
      changed=true
    else
      echo "  ✓ UFW rule exists: ${MANAGED_TCP_PORTS}/tcp"
    fi
  fi

  if $changed; then
    echo "  ✓ UFW rules updated (firewall NOT restarted — rules are live)"
  else
    echo "  ✓ All UFW rules already configured"
  fi
}

# ── firewalld backend ────────────────────────────────────────────────────────

add_rules_firewalld() {
  local changed=false

  # Mosh UDP ports
  if [[ -n "$MANAGED_UDP_PORTS" ]]; then
    local start_port end_port
    start_port="${MANAGED_UDP_PORTS%%:*}"
    end_port="${MANAGED_UDP_PORTS##*:}"
    if ! sudo firewall-cmd --list-ports 2>/dev/null | grep -q "${start_port}-${end_port}/udp"; then
      echo "  → Adding firewalld rule: ${start_port}-${end_port}/udp (mosh)"
      sudo firewall-cmd --permanent --add-port="${start_port}-${end_port}/udp"
      changed=true
    else
      echo "  ✓ firewalld rule exists: ${start_port}-${end_port}/udp"
    fi
  fi

  # Tailscale interface
  for iface in $MANAGED_INTERFACES; do
    if ! sudo firewall-cmd --list-interfaces 2>/dev/null | grep -q "$iface"; then
      echo "  → Adding firewalld interface: ${iface}"
      sudo firewall-cmd --permanent --add-interface="$iface" 2>/dev/null || true
      changed=true
    else
      echo "  ✓ firewalld interface exists: ${iface}"
    fi
  done

  if $changed; then
    echo "  → Reloading firewalld..."
    sudo firewall-cmd --reload
    echo "  ✓ firewalld rules updated"
  else
    echo "  ✓ All firewalld rules already configured"
  fi
}

# ── iptables backend ─────────────────────────────────────────────────────────

add_rules_iptables() {
  local changed=false

  # Mosh UDP ports
  if [[ -n "$MANAGED_UDP_PORTS" ]]; then
    local start_port end_port
    start_port="${MANAGED_UDP_PORTS%%:*}"
    end_port="${MANAGED_UDP_PORTS##*:}"
    if ! sudo iptables -L INPUT -n 2>/dev/null | grep -q "udp dpts:${start_port}:${end_port}"; then
      echo "  → Adding iptables rule: ${start_port}:${end_port}/udp (mosh)"
      sudo iptables -A INPUT -p udp --dport "${start_port}:${end_port}" -j ACCEPT
      changed=true
    else
      echo "  ✓ iptables rule exists: ${start_port}:${end_port}/udp"
    fi
  fi

  # Tailscale interface
  for iface in $MANAGED_INTERFACES; do
    if ! sudo iptables -L INPUT -n 2>/dev/null | grep -q "$iface"; then
      echo "  → Adding iptables rule: allow on ${iface}"
      sudo iptables -A INPUT -i "$iface" -j ACCEPT
      changed=true
    else
      echo "  ✓ iptables rule exists: ${iface}"
    fi
  done

  if $changed; then
    # Try to persist rules (best-effort)
    if command -v netfilter-persistent &>/dev/null; then
      sudo netfilter-persistent save 2>/dev/null || true
    elif command -v iptables-save &>/dev/null; then
      sudo iptables-save | sudo tee /etc/iptables/rules.v4 &>/dev/null 2>&1 || true
    fi
    echo "  ✓ iptables rules updated"
  else
    echo "  ✓ All iptables rules already configured"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

echo "── Configuring firewall ports ──"

# Step 1: Cloud detection
cloud=$(detect_cloud)
if [[ -n "$cloud" ]]; then
  echo "  ☁ Cloud environment detected: ${cloud}"
  echo "  ⊘ Skipping host-level firewall configuration."
  echo "    → Use ${cloud} Security Groups / firewall rules to open ports:"
  echo "      - UDP 60000-61000 (mosh)"
  echo "      - Allow Tailscale traffic (UDP 41641)"
  echo "  ✓ Firewall config: skipped (cloud instance)"
  exit 0
fi

# Step 2: Detect active firewall
backend=$(detect_firewall)
echo "  Firewall backend: ${backend}"

case "$backend" in
  ufw)
    add_rules_ufw
    ;;
  firewalld)
    add_rules_firewalld
    ;;
  iptables)
    add_rules_iptables
    ;;
  none)
    echo "  ⊘ No active firewall detected — no rules to add."
    echo "    If you enable a firewall later, re-run: bash scripts/install/firewall.sh"
    ;;
esac

echo "✓ Firewall configuration complete"
