#!/bin/bash
# scripts/configure/aliases.sh — generate ~/.tenai_aliases from config
# Uses generate_aliases.py to read config/defaults.yaml and create aliases
# for all devices dynamically.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../detect.sh"
source "$INFRA_DIR/scripts/lib/state_track.sh"

# Resolve Python — prefer .venv (has pyyaml and other deps)
PYTHON="$INFRA_DIR/.venv/bin/python3"
if [[ ! -x "$PYTHON" ]]; then
  PYTHON="$(command -v python3)"
fi

ALIASES_FILE="$HOME/.tenai_aliases"

# ── Generate aliases using Python ─────────────────────────────────────────────
generate() {
  echo "── Generating tenai aliases from config ──"

  # Ensure pyyaml is available
  "$PYTHON" -c "import yaml" 2>/dev/null || {
    echo "  Installing pyyaml..."
    if command -v uv &>/dev/null; then
      uv pip install -p "$INFRA_DIR/.venv" pyyaml 2>/dev/null || pip3 install pyyaml 2>/dev/null
    else
      pip3 install pyyaml 2>/dev/null
    fi
  }

  # Track file creation before writing (idempotent — no-op if already tracked)
  if [[ ! -f "$ALIASES_FILE" ]]; then
    tenai_track file_created --path "~/.tenai_aliases"
  fi
  "$PYTHON" "$SCRIPT_DIR/generate_aliases.py" --output "$ALIASES_FILE"
}

# ── Ensure source line in shell rc ────────────────────────────────────────────
ensure_source_line() {
  local rc="$SHELL_RC"
  local source_line="source $ALIASES_FILE"
  local old_marker="INFRA ALIASES START"
  local old_marker_end="INFRA ALIASES END"

  # Remove old inline alias block if it exists (migration from old approach)
  if grep -q "$old_marker" "$rc" 2>/dev/null; then
    echo "  Migrating: removing old inline alias block from $rc..."
    "$PYTHON" - "$rc" "$old_marker" "$old_marker_end" << 'PYEOF'
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
    echo "  ✓ Old alias block removed"
  fi

  # Also clean up old "source ~/.tailscale_aliases" if present (legacy)
  if grep -q "source.*\.tailscale_aliases" "$rc" 2>/dev/null; then
    sed -i.bak '/source.*\.tailscale_aliases/d' "$rc"
    rm -f "${rc}.bak"
    echo "  ✓ Removed old ~/.tailscale_aliases source line"
  fi

  # Add source line if not already present
  if ! grep -qF "$source_line" "$rc" 2>/dev/null; then
    # Add blank line before if file doesn't end with one
    if [[ -s "$rc" ]] && [[ "$(tail -c 1 "$rc")" != "" ]]; then
      echo "" >> "$rc"
    fi
    echo "# ── TENAI INFRA ALIASES START ──" >> "$rc"
    echo "$source_line" >> "$rc"
    echo "# ── TENAI INFRA ALIASES END ──" >> "$rc"
    tenai_track file_modified --path "~/${rc##*/}" \
      --marker-start "# ── TENAI INFRA ALIASES START ──" \
      --marker-end   "# ── TENAI INFRA ALIASES END ──"
    echo "✓ Added 'source $ALIASES_FILE' to $rc"
  else
    echo "✓ Source line already in $rc"
  fi
}

generate
ensure_source_line
echo "Run: source $SHELL_RC"
