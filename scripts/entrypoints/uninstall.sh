#!/usr/bin/env bash
# scripts/entrypoints/uninstall.sh — tenai uninstall wizard
#
# Reads ~/.tenai/state/<device>/manifest.json and surgically reverses
# only what tenai installed — pre-existing tools are always skipped.
#
# Usage:
#   make uninstall                    # local device, interactive
#   make uninstall HOST=myserver      # remote device (SSHes in)
#   make uninstall DRY_RUN=1          # preview without changing anything
#   make uninstall KEEP=mosh,tmux     # batch mode, keep listed tools
#   make uninstall INTERACTIVE=1      # confirm each item individually
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$INFRA_DIR"

PYTHON="${PYTHON:-$INFRA_DIR/.venv/bin/python3}"
[[ -x "$PYTHON" ]] || PYTHON="$(command -v python3)"

HOST="${1:-${HOST:-}}"
DRY_RUN="${DRY_RUN:-0}"
KEEP="${KEEP:-}"             # comma-separated tools to skip uninstalling
INTERACTIVE="${INTERACTIVE:-0}"
CONFIRM="${CONFIRM:-0}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}  ✓${NC}  $*"; }
warn()  { echo -e "${YELLOW}  ⚠${NC}  $*"; }
err()   { echo -e "${RED}  ✗${NC}  $*" >&2; }
step()  { echo -e "\n${CYAN}${BOLD}── $* ──${NC}"; }
skip()  { echo -e "  ${YELLOW}⊘${NC}  $* (skipped)"; }

# ── Remote mode ───────────────────────────────────────────────────────────────
if [[ -n "$HOST" ]]; then
  step "Remote uninstall: $HOST"
  eval "$("$PYTHON" scripts/configure/resolve_host.py "$HOST")" || {
    err "Cannot resolve host: $HOST"; exit 1
  }
  PORT="${RESOLVED_SSH_PORT:-22}"
  TARGET="${RESOLVED_USER}@${RESOLVED_IP}"
  REMOTE_INFRA_DIR=$("$PYTHON" -c "
import sys; sys.path.insert(0, '.')
from scripts.lib.load_config import load_config
c = load_config()
print(c.get('repos', {}).get('infra_dir', 'tenai'))
" 2>/dev/null || echo "tenai")

  ssh -p "$PORT" "$TARGET" \
    "DRY_RUN=${DRY_RUN} KEEP='${KEEP}' INTERACTIVE=${INTERACTIVE} CONFIRM=1 \
     bash ~/${REMOTE_INFRA_DIR}/scripts/entrypoints/uninstall.sh" < /dev/null
  exit $?
fi

# ── Local mode ────────────────────────────────────────────────────────────────
DEVICE_NAME="${DEVICE_NAME:-$(hostname -s 2>/dev/null || echo local)}"
STATE_BASE="${STATE_DIR:-${HOME}/.tenai/state}"
MANIFEST_DIR="${STATE_BASE}/${DEVICE_NAME}"
MANIFEST="${MANIFEST_DIR}/manifest.json"

echo ""
echo -e "${BOLD}  ═══ TenAI — Uninstall Wizard ════════════════════════════════${NC}"
echo -e "  ${BOLD}Device:${NC}   ${DEVICE_NAME}"
echo -e "  ${BOLD}Manifest:${NC} ${MANIFEST}"

if [[ ! -f "$MANIFEST" ]]; then
  warn "No manifest found at ${MANIFEST}"
  echo "  This device was either set up before state tracking was introduced,"
  echo "  or has already been uninstalled."
  echo ""
  echo "  Run:  make state-audit  to reconstruct a best-effort manifest."
  exit 0
fi

# Parse manifest with Python
PLAN=$("$PYTHON" scripts/lib/state_tracker.py plan --device "$DEVICE_NAME" --state-dir "$STATE_BASE" 2>/dev/null || echo "")
TOTAL=$("$PYTHON" - "$MANIFEST" << 'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
entries = m.get("entries", [])
rev = [e for e in entries if e.get("reversible")]
print(f"{len(entries)} total, {len(rev)} reversible")
PYEOF
)

echo -e "  ${BOLD}Entries:${NC}  ${TOTAL}"
echo -e "  ${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo ""

if [[ "$DRY_RUN" == "1" ]]; then
  echo -e "  ${YELLOW}[DRY RUN]${NC} — no changes will be made\n"
  "$PYTHON" scripts/lib/state_tracker.py plan --device "$DEVICE_NAME" --state-dir "$STATE_BASE"
  exit 0
fi

# Safety gate — prevents accidental destructive runs
# TENAI_UNINSTALL_CONFIRMED=1 bypasses this (for integration tests with tmp dirs)
if [[ "${TENAI_UNINSTALL_CONFIRMED:-}" != "1" ]]; then
  echo -e "  ${RED}⚠  This will permanently remove tenai-installed files from this device.${NC}"
  read -rp "  Type 'uninstall' to confirm: " safety_confirm
  if [[ "$safety_confirm" != "uninstall" ]]; then
    echo "  Cancelled."
    exit 0
  fi
fi

# Interactive confirmation (unless CONFIRM=1)
if [[ "${CONFIRM:-0}" != "1" ]]; then
  echo ""
  echo "  Options:"
  echo "    [1] Full uninstall  (batch — removes all reversible items)"
  echo "    [2] Interactive     (confirm each item)"
  echo "    [3] Dry run         (preview only)"
  echo "    [4] Exit"
  echo ""
  read -rp "  Choice [1]: " choice
  choice="${choice:-1}"
  case "$choice" in
    1) INTERACTIVE=0 ;;
    2) INTERACTIVE=1 ;;
    3) "$PYTHON" scripts/lib/state_tracker.py plan --device "$DEVICE_NAME" --state-dir "$STATE_BASE"; exit 0 ;;
    *) echo "  Cancelled."; exit 0 ;;
  esac
fi

# Build keep-set from --keep flag
declare -A KEEP_SET
IFS=',' read -ra keep_list <<< "${KEEP:-}"
for t in "${keep_list[@]}"; do
  KEEP_SET["${t// /}"]="1"
done

# Load plan entries from Python
mapfile -t PLAN_LINES < <("$PYTHON" - "$MANIFEST" << 'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
entries = [e for e in m.get("entries", []) if e.get("reversible")]
for e in reversed(entries):
    print(json.dumps(e))
PYEOF
)

echo ""
step "Reversing install steps"

removed=0; skipped=0

for line in "${PLAN_LINES[@]}"; do
  etype=$(echo "$line" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin).get('type',''))")
  path=$(echo  "$line" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin).get('path',''))")
  tool=$(echo  "$line" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin).get('tool',''))")
  pre=$(echo   "$line" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin).get('pre_existing','false'))")
  ms=$(echo    "$line" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin).get('marker_start',''))")
  me=$(echo    "$line" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin).get('marker_end',''))")
  cli=$(echo   "$line" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin).get('cli',''))")
  name=$(echo  "$line" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin).get('name',''))")
  url=$(echo   "$line" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin).get('url',''))")
  sl=$(echo    "$line" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin).get('symlink_path',''))")
  cfgfile=$(echo "$line" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin).get('config_file',''))")
  device=$(echo  "$line" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin).get('device',''))")

  # Expand ~ in paths
  path_exp="${path/#\~/$HOME}"

  # Interactive per-item confirmation
  if [[ "$INTERACTIVE" == "1" ]]; then
    read -rp "  Remove ${etype}: ${path:-$tool$name}? [Y/n] " ans
    [[ "${ans:-Y}" =~ ^[Nn] ]] && { skip "${etype}: ${path:-$tool$name}"; ((skipped++)) || true; continue; }
  fi

  case "$etype" in
    file_created)
      if [[ -f "$path_exp" ]]; then
        rm -f "$path_exp" && info "Removed file: $path" || warn "Could not remove: $path"
        ((removed++)) || true
      else
        skip "file_created: $path (already gone)"
        ((skipped++)) || true
      fi
      ;;

    file_modified|ssh_config_block)
      if [[ -f "$path_exp" ]] && [[ -n "$ms" ]]; then
        "$PYTHON" - "$path_exp" "$ms" "$me" << 'PYEOF'
import sys, re
path, start, end = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    content = f.read()
# Remove the marked block including surrounding blank lines
pattern = r'\n?' + re.escape(start) + r'.*?' + re.escape(end) + r'\n?'
new = re.sub(pattern, '', content, flags=re.DOTALL)
with open(path, 'w') as f:
    f.write(new)
PYEOF
        info "Removed block from: $path"
        ((removed++)) || true
      else
        skip "${etype}: $path (marker or file not found)"
        ((skipped++)) || true
      fi
      ;;

    tool_installed)
      # Never remove pre-existing tools
      if [[ "$pre" == "True" ]] || [[ "$pre" == "true" ]]; then
        skip "tool: $tool (was pre-existing)"
        ((skipped++)) || true
        continue
      fi
      # Honor --keep list
      if [[ -n "${KEEP_SET[$tool]:-}" ]]; then
        skip "tool: $tool (in --keep list)"
        ((skipped++)) || true
        continue
      fi
      pkg_mgr=$(echo "$line" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin).get('pkg_mgr',''))")
      local _tool_ok=false
      case "$pkg_mgr" in
        brew) brew uninstall --ignore-dependencies "$tool" 2>/dev/null && { info "brew uninstall $tool"; _tool_ok=true; } || warn "Could not uninstall $tool" ;;
        apt|apt-get) sudo apt-get remove -y "$tool" 2>/dev/null && { info "apt remove $tool"; _tool_ok=true; } || warn "Could not remove $tool" ;;
        pkg|apk) { command -v pkg &>/dev/null && pkg uninstall "$tool" 2>/dev/null || apk del "$tool" 2>/dev/null; } && { info "Removed $tool"; _tool_ok=true; } || warn "Could not remove $tool" ;;
        npm) npm uninstall -g "$tool" 2>/dev/null && { info "npm uninstall $tool"; _tool_ok=true; } || warn "Could not uninstall npm pkg $tool" ;;
        *) warn "Unknown pkg_mgr '${pkg_mgr}' for $tool — skipping" ;;
      esac
      [[ "$_tool_ok" == "true" ]] && ((removed++)) || ((skipped++)) || true
      ;;

    dir_created)
      if [[ -d "$path_exp" ]]; then
        rmdir "$path_exp" 2>/dev/null && { info "Removed dir: $path"; ((removed++)) || true; } || \
          warn "Dir not empty, skipping: $path"
      fi
      ;;

    ssh_key_created)
      if [[ -f "$path_exp" ]] || [[ -f "${path_exp}.pub" ]]; then
        rm -f "$path_exp" "${path_exp}.pub" && { info "Removed SSH key: $path"; ((removed++)) || true; } || warn "Could not remove SSH key: $path"
      else
        skip "ssh_key_created: $path (already gone)"
        ((skipped++)) || true
      fi
      ;;

    config_registered)
      if [[ -n "$device" ]]; then
        "$PYTHON" scripts/configure/register_device.py \
          --name "$device" --ip "" --user "" --type server --remove 2>/dev/null && \
          { info "Removed device '$device' from $cfgfile"; ((removed++)) || true; } || \
          { warn "Could not remove '$device' from $cfgfile (may need manual edit)"; ((skipped++)) || true; }
      fi
      ;;

    cli_extension_installed)
      local _ext_ok=false
      case "$cli" in
        gemini) command -v gemini &>/dev/null && gemini extensions remove "$name" 2>/dev/null && \
                  { info "Removed gemini extension: $name"; _ext_ok=true; } || warn "Could not remove gemini extension: $name" ;;
        claude)
          if [[ "$url" == "mcp" ]]; then
            command -v claude &>/dev/null && claude mcp remove "$name" 2>/dev/null && \
              { info "Removed claude MCP: $name"; _ext_ok=true; } || warn "Could not remove claude MCP: $name"
          else
            command -v claude &>/dev/null && claude plugin uninstall "$name" 2>/dev/null && \
              { info "Removed claude plugin: $name"; _ext_ok=true; } || warn "Could not remove claude plugin: $name"
          fi
          ;;
        *) warn "Unknown CLI '$cli' — cannot remove extension $name" ;;
      esac
      [[ "$_ext_ok" == "true" ]] && ((removed++)) || ((skipped++)) || true
      ;;

    cli_skill_installed)
      if [[ -n "$sl" ]] && [[ -L "$sl" ]]; then
        rm -f "$sl" && { info "Removed skill symlink: $sl"; ((removed++)) || true; } || warn "Could not remove: $sl"
      elif [[ -n "$sl" ]] && [[ -d "$sl" ]]; then
        rm -rf "$sl" && { info "Removed skill dir: $sl"; ((removed++)) || true; } || warn "Could not remove: $sl"
      fi
      ;;

    *)
      warn "Unknown entry type '$etype' — skipping"
      ;;
  esac
done

echo ""
echo -e "${BOLD}  ────────────────────────────────────────────────────────────${NC}"
echo -e "${GREEN}  ✓ Uninstall complete${NC}  — removed: ${removed}, skipped: ${skipped}"
echo ""

# Final cleanup: backup manifest then remove state dir
if [[ "$removed" -gt 0 ]]; then
  cp "$MANIFEST" "${MANIFEST_DIR}/manifest.json.final" 2>/dev/null || true
  rm -rf "$MANIFEST_DIR"
  echo -e "  State manifest removed: ${MANIFEST_DIR}"
fi

echo "  Run:  source ~/.zshrc  (or ~/.bashrc) to reload shell"
echo ""
