#!/bin/bash
# scripts/configure/set_exit_node.sh — Configure a device as the Tailscale exit node
#
# Usage:
#   bash scripts/configure/set_exit_node.sh <device-name>
#
# What it does:
#   1. Validates the device exists in config
#   2. Updates config/local.yaml: advertise_exit_node, proxy.exit_node, proxy.enabled
#   3. Advertises exit node on the remote device (sudo tailscale set --advertise-exit-node)
#   4. Optionally approves exit node via Tailscale API (if TAILSCALE_API_KEY is set)
#   5. Regenerates aliases (so tenai_claude etc. get proxy wrappers)
#   6. Installs proxy prerequisites (autossh, privoxy) and enables daemon
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$INFRA_DIR"

PYTHON="${INFRA_DIR}/.venv/bin/python3"
[[ -x "$PYTHON" ]] || { echo "✗ venv not set up — run 'make install-deps' first"; exit 1; }

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

DEVICE="${1:-}"
DRY_RUN="${DRY_RUN:-0}"

if [[ -z "$DEVICE" ]]; then
  err "Usage: $0 <device-name>"
  err "  Example: $0 myserver"
  err "  Or via Makefile: make set-exit-node HOST=myserver"
  exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo "  TenAI — Set Exit Node: ${DEVICE}"
echo "═══════════════════════════════════════════════════"

# ── Step 1: Validate device exists ──────────────────────────────────────────
step "Validating device '${DEVICE}'"

_device_info=$("$PYTHON" - "$DEVICE" <<'PYEOF'
import sys; sys.path.insert(0, '.')
from scripts.lib.load_config import load_config
c = load_config()
device = sys.argv[1]
devs = c.get('tailscale', {}).get('devices', {})
d = devs.get(device, {})
if not d:
    print('NOT_FOUND')
else:
    print(f"{d.get('ip','')},{d.get('user','')},{d.get('type','')}")
PYEOF
) || _device_info="NOT_FOUND"

if [[ "$_device_info" == "NOT_FOUND" ]]; then
  err "Device '${DEVICE}' not found in config"
  echo "  Available devices:"
  "$PYTHON" -c "
import sys; sys.path.insert(0, '.')
from scripts.lib.load_config import load_config
c = load_config()
for name, dev in c.get('tailscale', {}).get('devices', {}).items():
    print(f'    {name}: {dev.get(\"ip\",\"?\")}, {dev.get(\"type\",\"?\")}')" 2>/dev/null || echo "    (none)"
  exit 1
fi

IFS=',' read -r _dev_ip _dev_user _dev_type <<< "$_device_info"
info "Found device: ${DEVICE} (ip=${_dev_ip}, user=${_dev_user}, type=${_dev_type})"

# ── Step 2: Update config/local.yaml ────────────────────────────────────────
step "Updating config/local.yaml"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "  [DRY RUN] Would set advertise_exit_node=true + proxy.exit_node=${DEVICE}"
else
  "$PYTHON" - "$DEVICE" <<'PYEOF'
import sys, yaml
from pathlib import Path

device = sys.argv[1]
local_yaml = Path("config/local.yaml")

if local_yaml.exists():
    with open(local_yaml) as f:
        config = yaml.safe_load(f) or {}
else:
    config = {}

# Set advertise_exit_node on the device
ts = config.setdefault("tailscale", {})
devs = ts.setdefault("devices", {})
dev = devs.setdefault(device, {})

# Clear advertise_exit_node from all other devices
for name, d in devs.items():
    if name != device and d.get("advertise_exit_node"):
        d.pop("advertise_exit_node")

dev["advertise_exit_node"] = True

# Set proxy config
proxy = config.setdefault("proxy", {})
proxy["exit_node"] = device
proxy["enabled"] = True

with open(local_yaml, "w") as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)

print(f"✓ Set {device}.advertise_exit_node=true")
print(f"✓ Set proxy.exit_node={device}, proxy.enabled=true")
PYEOF
fi

# ── Step 3: Advertise exit node on the remote device ────────────────────────
step "Advertising exit node on remote device"

_is_local=false
_local_hostname=$(hostname -s 2>/dev/null || echo "")
if [[ "$DEVICE" == "$_local_hostname" ]]; then
  _is_local=true
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "  [DRY RUN] Would run: sudo tailscale set --advertise-exit-node"
elif $_is_local; then
  info "Local device — running tailscale set locally"
  sudo tailscale set --advertise-exit-node 2>&1 || warn "tailscale set failed — may need manual approval"
else
  _ssh_target="${_dev_user:-ubuntu}@${_dev_ip:-$DEVICE}"
  echo "  → Running on ${_ssh_target}..."
  ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$_ssh_target" \
    "sudo tailscale set --advertise-exit-node" 2>&1 || \
    warn "Could not set advertise-exit-node remotely — may need manual SSH access"
fi

# ── Step 4: Approve exit node via API (if possible) ─────────────────────────
step "Approving exit node in Tailscale admin"

# Source .env for API keys
set -a; source .env 2>/dev/null || true; set +a

_ts_api_key="${TAILSCALE_API_KEY:-}"
_ts_tailnet="${TAILSCALE_TAILNET:-}"

if [[ -n "$_ts_api_key" ]] && [[ -n "$_ts_tailnet" ]]; then
  echo "  → Attempting API-based approval..."
  _approval_result=$("$PYTHON" - "$DEVICE" "$_ts_api_key" "$_ts_tailnet" <<'PYEOF'
import sys, json, urllib.request, urllib.error

device_name = sys.argv[1]
api_key = sys.argv[2]
tailnet = sys.argv[3].rstrip("@")

# List devices to find this one
url = f"https://api.tailscale.com/api/v2/tailnet/{tailnet}/devices"
req = urllib.request.Request(url)
req.add_header("Authorization", f"Bearer {api_key}")
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read())
except urllib.error.HTTPError as e:
    print(f"API_ERROR: {e.code}")
    sys.exit(0)

# Find the device
target = None
for dev in data.get("devices", []):
    hostname = dev.get("hostname", "").lower()
    name = dev.get("name", "").lower()
    if hostname == device_name.lower() or device_name.lower() in name:
        target = dev
        break

if not target:
    print("DEVICE_NOT_FOUND")
    sys.exit(0)

device_id = target["id"]

# Approve exit node route (enable exit node via API)
# The routes endpoint shows advertised routes — we need to approve them
routes_url = f"https://api.tailscale.com/api/v2/device/{device_id}/routes"
req = urllib.request.Request(routes_url)
req.add_header("Authorization", f"Bearer {api_key}")
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        routes_data = json.loads(resp.read())
except urllib.error.HTTPError:
    print("ROUTES_ERROR")
    sys.exit(0)

# Find exit node routes (0.0.0.0/0 and ::/0) and enable them
exit_routes = []
for route in routes_data.get("advertisedRoutes", []):
    if route in ("0.0.0.0/0", "::/0"):
        exit_routes.append(route)

if not exit_routes:
    print("NOT_ADVERTISED_YET")
    sys.exit(0)

# Enable the routes
all_routes = routes_data.get("advertisedRoutes", [])
payload = json.dumps({"routes": all_routes}).encode()
req = urllib.request.Request(routes_url, data=payload, method="POST")
req.add_header("Authorization", f"Bearer {api_key}")
req.add_header("Content-Type", "application/json")
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        print("APPROVED")
except urllib.error.HTTPError as e:
    print(f"APPROVE_ERROR: {e.code}")
PYEOF
  ) || _approval_result="SCRIPT_ERROR"

  case "$_approval_result" in
    APPROVED)
      info "Exit node approved via Tailscale API"
      ;;
    NOT_ADVERTISED_YET)
      warn "Device hasn't advertised exit node yet — approve manually after it connects"
      echo "  → https://login.tailscale.com/admin/machines"
      ;;
    DEVICE_NOT_FOUND)
      warn "Device '${DEVICE}' not found in Tailscale admin — approve manually"
      echo "  → https://login.tailscale.com/admin/machines"
      ;;
    API_ERROR*)
      warn "Tailscale API error (${_approval_result}) — approve manually"
      echo "  → https://login.tailscale.com/admin/machines"
      ;;
    *)
      warn "Could not auto-approve — approve manually in Tailscale admin console"
      echo "  → https://login.tailscale.com/admin/machines"
      echo "  → Click on '${DEVICE}' → Edit route settings → Enable 'Use as exit node'"
      ;;
  esac
else
  warn "No TAILSCALE_API_KEY or TAILSCALE_TAILNET set — cannot auto-approve"
  echo ""
  echo "  To approve the exit node manually:"
  echo "    1. Go to: https://login.tailscale.com/admin/machines"
  echo "    2. Find '${DEVICE}' and click the ⋯ menu"
  echo "    3. Edit route settings → Enable 'Use as exit node'"
  echo ""
fi

# ── Step 5: Regenerate aliases ──────────────────────────────────────────────
step "Regenerating aliases (proxy wrappers)"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "  [DRY RUN] Would run: make configure-aliases"
else
  make --no-print-directory configure-aliases 2>&1 || warn "Alias regeneration failed (non-fatal)"
  info "Aliases regenerated — tenai_claude, tenai_gemini, tenai_codex now route through ${DEVICE}"
fi

# ── Step 6: Install proxy prerequisites + enable daemon ─────────────────────
step "Setting up proxy (autossh + privoxy + daemon)"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "  [DRY RUN] Would run: make proxy"
else
  make --no-print-directory proxy 2>&1 || warn "Proxy setup had warnings (check output above)"

  # Auto-enable the proxy daemon
  echo "  → Enabling persistent proxy daemon..."
  make --no-print-directory proxy-daemon ACTION=enable 2>&1 || warn "Daemon enable failed — run manually: tenai_proxy_daemon enable"
fi

# ── Done ────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo "  ✓ ${DEVICE} configured as exit node"
echo "═══════════════════════════════════════════════════"
echo ""
echo "  Verify proxy:    tenai_proxy_status"
echo "  Test routing:    tenai_proxy_test"
echo "  Proxied tools:   tenai_claude, tenai_gemini, tenai_codex"
echo "  Daemon control:  tenai_proxy_daemon enable|disable|status"
echo ""
echo "  To change exit node later:"
echo "    make set-exit-node HOST=<other-device>"
echo ""
