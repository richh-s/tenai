#!/bin/bash
# scripts/install/proxy.sh — verify/install proxy prerequisites
# Routes specific CLI tools through a Tailscale exit node via:
#   SSH dynamic port forwarding (SOCKS5) + privoxy (HTTP→SOCKS5 bridge)
set -euo pipefail

source "$(dirname "$0")/../detect.sh"

# ── Check SSH ─────────────────────────────────────────────────────────────────
check_ssh() {
  echo "── Checking SSH ──"
  if command -v ssh &>/dev/null; then
    echo "  ✓ ssh available: $(ssh -V 2>&1 | head -1)"
  else
    echo "  ✗ ssh not found"
    case "$OS_TYPE" in
      termux)  echo "  → Run: pkg install openssh" ;;
      linux|wsl) echo "  → Run: sudo apt-get install -y openssh-client" ;;
      *) echo "  → SSH should be pre-installed on $OS_TYPE" ;;
    esac
    return 1
  fi
}

# ── Check/Install privoxy ────────────────────────────────────────────────────
check_privoxy() {
  echo "── Checking privoxy (HTTP→SOCKS5 bridge) ──"

  local privoxy_bin=""
  local privoxy_conf=""

  # Detect existing installation
  if [ -x "$(brew --prefix 2>/dev/null)/opt/privoxy/sbin/privoxy" ]; then
    privoxy_bin="$(brew --prefix)/opt/privoxy/sbin/privoxy"
    privoxy_conf="$(brew --prefix)/etc/privoxy/config"
  elif command -v privoxy &>/dev/null; then
    privoxy_bin="$(command -v privoxy)"
    privoxy_conf="/etc/privoxy/config"
  fi

  if [ -n "$privoxy_bin" ]; then
    echo "  ✓ privoxy found: $privoxy_bin"
  else
    echo "  ✗ privoxy not installed. Installing..."
    case "$OS_TYPE" in
      macos|mac)
        brew install privoxy
        privoxy_bin="$(brew --prefix)/opt/privoxy/sbin/privoxy"
        privoxy_conf="$(brew --prefix)/etc/privoxy/config"
        ;;
      linux|wsl)
        sudo apt-get install -y privoxy
        privoxy_bin="/usr/sbin/privoxy"
        privoxy_conf="/etc/privoxy/config"
        ;;
      termux)
        pkg install -y privoxy
        privoxy_bin="$(command -v privoxy)"
        privoxy_conf="$PREFIX/etc/privoxy/config"
        ;;
      *)
        echo "  ⚠ Cannot auto-install on $OS_TYPE. Install manually."
        echo "    macOS:   brew install privoxy"
        echo "    Linux:   apt install privoxy"
        echo "    Windows: choco install privoxy"
        return 1
        ;;
    esac
    echo "  ✓ privoxy installed"
  fi

  # Configure SOCKS5 forwarding if not already set
  if [ -f "$privoxy_conf" ]; then
    local socks_port="${PROXY_SOCKS_PORT:-1055}"
    if grep -q "^forward-socks5" "$privoxy_conf" 2>/dev/null; then
      echo "  ✓ forward-socks5 already configured"
    else
      echo "forward-socks5 / 127.0.0.1:${socks_port} ." >> "$privoxy_conf"
      echo "  ✓ Added forward-socks5 → 127.0.0.1:${socks_port}"
    fi
  else
    echo "  ⚠ Config not found: $privoxy_conf"
  fi
}

# ── Check/Install autossh ─────────────────────────────────────────────────────
check_autossh() {
  echo "── Checking autossh (auto-reconnecting SSH tunnel) ──"

  if command -v autossh &>/dev/null; then
    echo "  ✓ autossh found: $(command -v autossh)"
    return 0
  fi

  echo "  ✗ autossh not installed. Installing..."
  case "$OS_TYPE" in
    macos|mac)
      # brew wrapper in detect.sh handles Rosetta automatically
      brew install autossh
      ;;
    linux|wsl)
      # Wait for dpkg lock before installing (mirrors wait_for_apt from tools.sh)
      local _retries=0
      while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && [ $_retries -lt 30 ]; do
        echo "  ⏳ Waiting for dpkg lock..."; sleep 5; _retries=$((_retries + 1))
      done
      sudo apt-get install -y autossh
      ;;
    termux)
      pkg install -y autossh
      ;;
    *)
      echo "  ⚠ Cannot auto-install on $OS_TYPE. Install manually."
      echo "    macOS:   brew install autossh"
      echo "    Linux:   apt install autossh"
      return 1
      ;;
  esac
  echo "  ✓ autossh installed"
}

# ── Setup OS daemon for persistent SOCKS5 tunnel ─────────────────────────────
setup_daemon() {
  local exit_node="${1:-}"
  local ssh_user="${2:-}"
  local socks_port="${3:-1055}"

  if [ -z "$exit_node" ]; then
    echo "  ⚠ No exit node — skipping daemon setup"
    return 0
  fi

  local ssh_target="$exit_node"
  [ -n "$ssh_user" ] && ssh_target="${ssh_user}@${exit_node}"

  # Resolve autossh path
  local autossh_bin
  autossh_bin="$(command -v autossh 2>/dev/null || echo "")"
  if [ -z "$autossh_bin" ]; then
    echo "  ⚠ autossh not found — skipping daemon setup"
    return 0
  fi

  case "$OS_TYPE" in
    macos|mac)
      _setup_launchd_daemon "$autossh_bin" "$ssh_target" "$socks_port"
      ;;
    linux|wsl)
      _setup_systemd_daemon "$autossh_bin" "$ssh_target" "$socks_port"
      ;;
    *)
      echo "  ⚠ Daemon setup not supported on $OS_TYPE"
      echo "    Add autossh to your system's startup mechanism manually."
      ;;
  esac
}

_setup_launchd_daemon() {
  local autossh_bin="$1" ssh_target="$2" socks_port="$3"
  local plist_dir="$HOME/Library/LaunchAgents"
  local plist_name="com.tenai.socks5"
  local plist_path="${plist_dir}/${plist_name}.plist"

  mkdir -p "$plist_dir"

  echo "── Setting up launchd daemon (macOS) ──"

  cat > "$plist_path" <<EOPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${plist_name}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${autossh_bin}</string>
        <string>-M</string><string>0</string>
        <string>-N</string>
        <string>-D</string><string>${socks_port}</string>
        <string>-o</string><string>ServerAliveInterval=30</string>
        <string>-o</string><string>ServerAliveCountMax=3</string>
        <string>-o</string><string>ConnectTimeout=10</string>
        <string>-o</string><string>ExitOnForwardFailure=yes</string>
        <string>-o</string><string>StrictHostKeyChecking=accept-new</string>
        <string>${ssh_target}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>NetworkState</key>
        <true/>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/tenai-socks5.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/tenai-socks5.log</string>
    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
EOPLIST

  echo "  ✓ Plist written to ${plist_path}"
  echo "  Enable with:  launchctl load ${plist_path}"
  echo "  Disable with: launchctl unload ${plist_path}"
  echo "  Or use:       tenai_proxy_daemon enable|disable"
}

_setup_systemd_daemon() {
  local autossh_bin="$1" ssh_target="$2" socks_port="$3"
  local service_dir="$HOME/.config/systemd/user"
  local service_name="tenai-socks5"
  local service_path="${service_dir}/${service_name}.service"

  mkdir -p "$service_dir"

  echo "── Setting up systemd user service (Linux) ──"

  cat > "$service_path" <<EOSVC
[Unit]
Description=Tenai SOCKS5 tunnel via autossh
Documentation=https://github.com/yabebalFantaye/tenai
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${autossh_bin} -M 0 -N -D ${socks_port} \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -o ConnectTimeout=10 -o ExitOnForwardFailure=yes \
  -o StrictHostKeyChecking=accept-new \
  ${ssh_target}
Restart=on-failure
RestartSec=5
Environment=AUTOSSH_GATETIME=0
Environment=HOME=${HOME}

[Install]
WantedBy=default.target
EOSVC

  systemctl --user daemon-reload 2>/dev/null || true
  echo "  ✓ Service written to ${service_path}"
  echo "  Enable with:  systemctl --user enable --now ${service_name}"
  echo "  Disable with: systemctl --user disable --now ${service_name}"
  echo "  Or use:       tenai_proxy_daemon enable|disable"
}

# ── Check exit node SSH access ────────────────────────────────────────────────
check_exit_node() {
  local exit_node="${1:-}"

  # Use central config loader (merges defaults.yaml + local.yaml)
  local _loader
  _loader="$(dirname "$0")/../lib/load_config.py"
  if [ -z "$exit_node" ] && [ -f "$_loader" ]; then
    exit_node=$($PYTHON -c "
import sys; sys.path.insert(0, '$(dirname "$0")/../..')
from scripts.lib.load_config import load_config
c = load_config()
en = c.get('proxy', {}).get('exit_node', '')
devs = c.get('tailscale', {}).get('devices', {})
if not en:
    en = next((n for n, d in devs.items() if d.get('advertise_exit_node')), '')
if not en:
    en = next((n for n, d in devs.items() if d.get('type') == 'server'), '')
print(en)
" 2>/dev/null) || true
  fi

  if [ -z "$exit_node" ]; then
    echo "  ⚠ No exit node configured (check config/local.yaml)"
    echo "  ℹ You can still use the proxy script if you have a local proxy."
    echo "  ℹ If you don't intend to use a proxy, set \`proxy.enabled: false\` in config/local.yaml."
    return 0
  fi

  echo "── Checking exit node: $exit_node ──"

  local ssh_user=""
  if [ -f "$_loader" ]; then
    ssh_user=$($PYTHON -c "
import sys; sys.path.insert(0, '$(dirname "$0")/../..')
from scripts.lib.load_config import load_config
c = load_config()
devs = c.get('tailscale', {}).get('devices', {})
d = devs.get('$exit_node', {})
print(d.get('user', ''))
" 2>/dev/null) || true
  fi

  local target="$exit_node"
  [ -n "$ssh_user" ] && target="${ssh_user}@${exit_node}"

  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$target" "echo ok" &>/dev/null; then
    echo "  ✓ SSH to $target: reachable"
  else
    echo "  ⚠ SSH to $target: not reachable (check Tailscale + SSH keys)"
  fi

  # Return exit_node and ssh_user for daemon setup
  PROXY_EXIT_NODE="$exit_node"
  PROXY_SSH_USER="$ssh_user"
}

# ── Main ──────────────────────────────────────────────────────────────────────
check_ssh
check_privoxy
check_autossh

# Resolve exit node and check SSH access
PROXY_EXIT_NODE=""
PROXY_SSH_USER=""
check_exit_node "$@"

# Read proxy config for daemon setup
socks_port="${PROXY_SOCKS_PORT:-1055}"
use_autossh="true"
_loader="$(dirname "$0")/../lib/load_config.py"
if [ -f "$_loader" ]; then
  socks_port=$($PYTHON -c "
import sys; sys.path.insert(0, '$(dirname "$0")/../..')
from scripts.lib.load_config import load_config
print(load_config().get('proxy', {}).get('socks_port', 1055))
" 2>/dev/null) || socks_port=1055
  use_autossh=$($PYTHON -c "
import sys; sys.path.insert(0, '$(dirname "$0")/../..')
from scripts.lib.load_config import load_config
print(str(load_config().get('proxy', {}).get('autossh', True)).lower())
" 2>/dev/null) || use_autossh="true"
fi

# Set up OS daemon if autossh is enabled
if [ "$use_autossh" = "true" ] && [ -n "$PROXY_EXIT_NODE" ]; then
  setup_daemon "$PROXY_EXIT_NODE" "$PROXY_SSH_USER" "$socks_port"
fi

echo ""
echo "✓ Proxy prerequisites verified for ${OS_TYPE}"
echo ""
echo "Usage:"
echo "  1. Start proxy:      tenai_proxy_start [exit-node]"
echo "  2. Test it:           tenai_proxy_test"
echo "  3. Use proxied:       tenai_claude ...  (routes through exit node)"
echo "  4. Enable daemon:     tenai_proxy_daemon enable"
echo "  5. Daemon status:     tenai_proxy_daemon status"
