#!/bin/bash
# scripts/install/cli_setup.sh — Unified CLI configuration installer
#
# Manages: extensions, MCP servers, plugins, skills, settings, rules, hooks
#
# Usage:
#   ./scripts/install/cli_setup.sh                           # Install everything for all CLIs
#   CLI=gemini ./scripts/install/cli_setup.sh                # Only Gemini
#   CLI=claude TYPE=plugins ./scripts/install/cli_setup.sh   # Only Claude plugins
#   ACTION=list ./scripts/install/cli_setup.sh               # List all installed assets
#   ACTION=install CLI=gemini TYPE=extensions EXT=conductor   # Install a single item
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config/cli"

# Resolve Python: always prefer .venv (has pyyaml and other deps)
if [[ -x "$REPO_ROOT/.venv/bin/python3" ]]; then
  PYTHON="$REPO_ROOT/.venv/bin/python3"
elif [[ -n "${PYTHON:-}" ]] && [[ -x "${PYTHON}" ]]; then
  : # Keep existing PYTHON from env
else
  PYTHON="$(command -v python3 2>/dev/null || echo python3)"
fi

# Load .env for secrets (e.g. CONTEXT7_API_KEY used by Gemini context7 extension)
# Use grep to only export clean KEY=VALUE lines — avoids executing malformed entries
# (e.g. "SSH_KEY_PATH= ~/.ssh/key" where space after = would run the path as a command)
if [[ -f "$REPO_ROOT/.env" ]]; then
  while IFS= read -r _env_line; do
    # Extract KEY and VALUE from "KEY=VALUE  # optional comment"
    _env_key="${_env_line%%=*}"
    _env_val="${_env_line#*=}"
    [[ -z "$_env_key" ]] && continue
    # Strip inline comments (# ...) and trim whitespace
    _env_val="$(echo "$_env_val" | sed 's/[[:space:]]*#[[:space:]].*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    export "$_env_key=$_env_val" 2>/dev/null || true
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$REPO_ROOT/.env")
fi

# Source state tracker
source "$REPO_ROOT/scripts/lib/state_track.sh"

# ── Env vars ──
CLI="${CLI:-}"                 # gemini, claude, or empty for all
TYPE="${TYPE:-}"               # extensions, mcp, plugins, skills, settings, rules, hooks, or empty for all
ACTION="${ACTION:-setup}"      # setup (install all), list, install (single)
EXT="${EXT:-}"                 # specific extension/plugin name for ACTION=install


# ══════════════════════════════════════════════════════════════════════════════
# YAML PARSER (tries pyyaml, falls back to pure Python stdlib)
# ══════════════════════════════════════════════════════════════════════════════

# Parse a YAML list into key=value blocks separated by ---
yaml_list() {
  local file="$1" path="$2"
  _F="$file" _P="$path" $PYTHON << 'PYEOF'
import sys, re, os
filepath, dotpath = os.environ['_F'], os.environ['_P']

def try_yaml(fp, dp):
    import yaml
    with open(fp) as f:
        data = yaml.safe_load(f)
    items = data
    for key in dp.split('.'):
        if key:
            items = items.get(key, []) if isinstance(items, dict) else []
    if isinstance(items, list):
        for item in items:
            if isinstance(item, dict):
                for k, v in item.items():
                    if isinstance(v, list):
                        print(f'{k}={" ".join(str(x) for x in v)}')
                    else:
                        print(f'{k}={v}')
                print('---')

def try_regex(fp, dp):
    with open(fp) as f:
        content = f.read()
    section = dp.split('.')[-1] if dp else ''
    pattern = rf'^{section}:\s*\n((?:(?:[ \t]+.*|[ \t]*)\n)*)'
    m = re.search(pattern, content, re.MULTILINE)
    if not m:
        return
    block = m.group(1)
    current = {}
    for line in block.split('\n'):
        line = line.rstrip()
        if not line.strip() or line.strip().startswith('#'):
            continue
        item_match = re.match(r'^[ \t]+-\s+(\w+):\s*(.*)', line)
        if item_match:
            if current:
                for k, v in current.items():
                    print(f'{k}={v}')
                print('---')
            current = {item_match.group(1): item_match.group(2).strip('"').strip("'")}
        else:
            kv_match = re.match(r'^[ \t]+(\w+):\s*(.*)', line)
            if kv_match:
                key = kv_match.group(1)
                val = kv_match.group(2).strip('"').strip("'")
                list_match = re.match(r'^\[(.+)\]$', val)
                if list_match:
                    items = [x.strip().strip('"').strip("'") for x in list_match.group(1).split(',')]
                    val = ' '.join(items)
                current[key] = val
    if current:
        for k, v in current.items():
            print(f'{k}={v}')
        print('---')

try:
    try_yaml(filepath, dotpath)
except ImportError:
    try_regex(filepath, dotpath)
except Exception:
    try_regex(filepath, dotpath)
PYEOF
}

# Get a single scalar value from YAML
yaml_get() {
  local file="$1" path="$2"
  _F="$file" _P="$path" $PYTHON << 'PYEOF'
import sys, re, os
filepath, dotpath = os.environ['_F'], os.environ['_P']

def try_yaml(fp, dp):
    import yaml
    with open(fp) as f:
        data = yaml.safe_load(f)
    val = data
    for key in dp.split('.'):
        if key and isinstance(val, dict):
            val = val.get(key)
    if val is None:
        sys.exit(1)
    print(val)

def try_regex(fp, dp):
    with open(fp) as f:
        content = f.read()
    keys = dp.split('.')
    if len(keys) == 2:
        pattern = rf'^{keys[0]}:\s*\n(?:[ \t]+.*\n)*?[ \t]+{keys[1]}:\s*["\']?([^"\'#\n]+)'
    elif len(keys) == 1:
        pattern = rf'^{keys[0]}:\s*["\']?([^"\'#\n]+)'
    else:
        sys.exit(1)
    m = re.search(pattern, content, re.MULTILINE)
    if m:
        print(m.group(1).strip().strip('"').strip("'"))
    else:
        sys.exit(1)

try:
    try_yaml(filepath, dotpath)
except ImportError:
    try_regex(filepath, dotpath)
except Exception:
    try_regex(filepath, dotpath)
PYEOF
}

# Get a dict from YAML as JSON
yaml_dict() {
  local file="$1" path="$2"
  _F="$file" _P="$path" $PYTHON << 'PYEOF'
import sys, re, json, os
filepath, dotpath = os.environ['_F'], os.environ['_P']

def try_yaml(fp, dp):
    import yaml
    with open(fp) as f:
        data = yaml.safe_load(f)
    val = data
    for key in dp.split('.'):
        if key and isinstance(val, dict):
            val = val.get(key, {})
    if isinstance(val, dict) and val:
        print(json.dumps(val))

def try_regex(fp, dp):
    with open(fp) as f:
        content = f.read()
    section = dp.split('.')[-1] if dp else ''
    pattern = rf'^{section}:\s*\n((?:[ \t]+\w+:.*\n)*)'
    m = re.search(pattern, content, re.MULTILINE)
    if not m:
        return
    result = {}
    for line in m.group(1).split('\n'):
        kv = re.match(r'^[ \t]+(\w+):\s*(.*)', line)
        if kv:
            result[kv.group(1)] = kv.group(2).strip().strip('"').strip("'")
    if result:
        print(json.dumps(result))

try:
    try_yaml(filepath, dotpath)
except ImportError:
    try_regex(filepath, dotpath)
except Exception:
    try_regex(filepath, dotpath)
PYEOF
}


# ══════════════════════════════════════════════════════════════════════════════
# SHARED SKILL INSTALLER — auto-discovers from .agents/skills/
# ══════════════════════════════════════════════════════════════════════════════

_install_agents_skills() {
  local target_dir="$1"
  local agents_skills="$REPO_ROOT/.agents/skills"
  if [ ! -d "$agents_skills" ]; then
    echo "  ⚠ No .agents/skills/ directory found in $REPO_ROOT"
    return
  fi
  mkdir -p "$target_dir"
  for skill_dir in "$agents_skills"/*/; do
    [ ! -d "$skill_dir" ] && continue
    local name
    name=$(basename "$skill_dir")
    [ ! -f "$skill_dir/SKILL.md" ] && continue
    mkdir -p "$target_dir/$name"
    cp -r "$skill_dir"/* "$target_dir/$name/"
    
    # Track skill installation based on which CLI directory we are in
    local cli_name="unknown"
    if [[ "$target_dir" == *".gemini"* ]]; then cli_name="gemini"; fi
    if [[ "$target_dir" == *".claude"* ]]; then cli_name="claude"; fi
    if [[ "$target_dir" == *".codex"* ]]; then cli_name="codex"; fi
    tenai_track dir_created --path "$target_dir/$name"
    
    echo "  ✓ Skill: $name → $target_dir/$name/"
  done
}


# ══════════════════════════════════════════════════════════════════════════════
# GEMINI CLI
# ══════════════════════════════════════════════════════════════════════════════

gemini_extensions_list() {
  if command -v gemini &>/dev/null; then
    gemini extensions list 2>/dev/null || echo "  (none)"
  else
    echo "  ⊘ Gemini CLI not installed"
  fi
}

gemini_extensions_install_all() {
  if ! command -v gemini &>/dev/null; then
    echo "  ⊘ Gemini CLI not installed — skipping extensions"
    return
  fi
  local config="$CONFIG_DIR/gemini.yaml"
  [ ! -f "$config" ] && return

  # Cache installed extensions for idempotency — check both source URLs and names
  local _installed_urls _installed_names
  _installed_urls=$(gemini extensions list 2>/dev/null | grep "Source:" | sed 's/.*Source: //' | sed 's/ .*//' || true)
  _installed_names=$(ls ~/.gemini/extensions/ 2>/dev/null | grep -v '\.json$' || true)

  local name="" url=""
  while IFS= read -r line; do
    if [[ "$line" == "---" ]]; then
      if [[ -n "$url" && -n "$name" ]]; then
        # Check by source URL or by extension name (handles fork URL mismatches)
        if echo "$_installed_urls" | grep -qF "$url" || \
           echo "$_installed_names" | grep -qxF "$name"; then
          echo "  ✓ $name (already installed)"
        else
          echo "  → $name..."
          local install_out
          if command -v expect &>/dev/null; then
            install_out=$(expect -c "
              set timeout 60
              spawn gemini extensions install \"$url\"
              expect {
                \"Y/n\" { send \"y\r\"; exp_continue }
                \"API Key\" { send \"${CONTEXT7_API_KEY:-skip}\r\"; exp_continue }
                \"api_key\" { send \"${CONTEXT7_API_KEY:-skip}\r\"; exp_continue }
                eof {}
                timeout { close }
              }
            " 2>&1)
            if [[ $? -eq 0 ]]; then
              echo "  ✓ $name"
              tenai_track cli_extension_installed --cli gemini --name "$name" --url "$url"
            elif echo "$install_out" | grep -q "already installed"; then
              echo "  ✓ $name (already installed)"
            else
              echo "  ⚠ $name (install failed)"
            fi
          else
            # Fallback: timeout to prevent indefinite blocking on TTY prompts
            install_out=$(timeout 30 bash -c "printf '%s\n' 'y' '${CONTEXT7_API_KEY:-}' | gemini extensions install '$url'" 2>&1)
            if [[ $? -eq 0 ]]; then
              echo "  ✓ $name"
              tenai_track cli_extension_installed --cli gemini --name "$name" --url "$url"
            elif echo "$install_out" | grep -q "already installed"; then
              echo "  ✓ $name (already installed)"
            else
              echo "  ⚠ $name (install failed — try: gemini extensions install $url)"
            fi
          fi
        fi
      fi
      name="" url=""
    elif [[ "$line" == name=* ]]; then name="${line#name=}"
    elif [[ "$line" == url=* ]]; then url="${line#url=}"
    fi
  done < <(yaml_list "$config" "extensions"; echo "---")
}

gemini_extensions_install_one() {
  local ext_name="$1"
  if ! command -v gemini &>/dev/null; then echo "  ⊘ Gemini CLI not installed"; return 1; fi
  local config="$CONFIG_DIR/gemini.yaml" name="" url=""
  while IFS= read -r line; do
    if [[ "$line" == "---" ]]; then
      if [[ "$name" == "$ext_name" && -n "$url" ]]; then
        gemini extensions install "$url" --auto-update
        tenai_track cli_extension_installed --cli gemini --name "$name" --url "$url"
        echo "  ✓ $name installed"; return 0
      fi
      name="" url=""
    elif [[ "$line" == name=* ]]; then name="${line#name=}"
    elif [[ "$line" == url=* ]]; then url="${line#url=}"
    fi
  done < <(yaml_list "$config" "extensions"; echo "---")
  # Try as raw URL
  if [[ "$ext_name" == http* ]]; then
    gemini extensions install "$ext_name" --auto-update; return
  fi
  echo "  ✗ '$ext_name' not found in config"; return 1
}

gemini_skills_install() {
  local target_dir="$HOME/.gemini/skills"
  _install_agents_skills "$target_dir"
}

gemini_settings_install() {
  local config="$CONFIG_DIR/gemini.yaml"
  local new_settings
  new_settings="$(yaml_dict "$config" "settings")"
  [ -z "$new_settings" ] && return
  local target="$HOME/.gemini/settings.json"
  mkdir -p "$(dirname "$target")"
  if [ -f "$target" ]; then
    # Deep merge: add new keys from config, preserve existing values
    $PYTHON -c "
import json, sys
def deep_merge(base, override):
    result = dict(base)
    for k, v in override.items():
        if k in result and isinstance(result[k], dict) and isinstance(v, dict):
            result[k] = deep_merge(result[k], v)
        else:
            result[k] = v
    return result
existing = json.load(open('$target'))
new = json.loads('$new_settings')
merged = deep_merge(new, existing)
changed = merged != existing
with open('$target', 'w') as f:
    json.dump(merged, f, indent=2)
if changed:
    print('  ✓ Settings merged into $target (new keys added)')
else:
    print('  ✓ Settings: $target up to date')
" 2>/dev/null
  else
    echo "$new_settings" | $PYTHON -c "
import json, sys
data = json.load(sys.stdin)
with open('$target', 'w') as f:
    json.dump(data, f, indent=2)
print('  ✓ Settings written to $target')
" 2>/dev/null
  fi
}

gemini_rules_install() {
  local config="$CONFIG_DIR/gemini.yaml"
  local source
  source="$(yaml_get "$config" "rules.source")" || return
  local src="$REPO_ROOT/$source"
  local target="$HOME/.gemini/GEMINI.md"
  if [ ! -f "$src" ]; then
    echo "  ⚠ Rules source not found: $src"; return
  fi
  mkdir -p "$(dirname "$target")"
  if [ -f "$target" ]; then
    if ! diff -q "$src" "$target" > /dev/null 2>&1; then
      cp "$src" "$target"
      echo "  ✓ Rules: updated $target (source changed)"
    else
      echo "  ✓ Rules: $target up to date"
    fi
  else
    cp "$src" "$target"
    echo "  ✓ Rules: copied to $target"
  fi
}

gemini_hooks_install() {
  local config="$CONFIG_DIR/gemini.yaml"
  local source
  source="$(yaml_get "$config" "hooks.source")" || return
  local src="$REPO_ROOT/$source"
  local target="$HOME/.gemini/settings.json"
  if [ ! -f "$src" ]; then echo "  ⚠ Hooks source not found: $src"; return; fi
  mkdir -p "$(dirname "$target")"
  # Gemini reads hooks from settings.json — write hooks if key absent
  if [ -f "$target" ]; then
    $PYTHON -c "
import json, sys
with open('$target') as f:
    settings = json.load(f)
with open('$src') as f:
    hooks_data = json.load(f)
new_hooks = hooks_data.get('hooks', {})
existing_hooks = settings.get('hooks', {})
# Deep merge: source provides new events, existing user overrides win per-event
merged = dict(new_hooks)
for event, handlers in existing_hooks.items():
    merged[event] = handlers
changed = merged != existing_hooks
settings['hooks'] = merged
with open('$target', 'w') as f:
    json.dump(settings, f, indent=2)
if not existing_hooks:
    print('  ✓ Hooks: added to $target')
elif changed:
    print('  ✓ Hooks: updated $target (new hook events merged)')
else:
    print('  ✓ Hooks: $target up to date')
" || echo "  ⚠ Hooks: failed to process $target (check JSON validity)"
  else
    $PYTHON -c "
import json, sys
with open('$src') as f:
    hooks_data = json.load(f)
with open('$target', 'w') as f:
    json.dump(hooks_data, f, indent=2)
print('  ✓ Hooks: written to $target')
" || echo "  ⚠ Hooks: failed to write $target"
  fi
}


# ══════════════════════════════════════════════════════════════════════════════
# CLAUDE CODE
# ══════════════════════════════════════════════════════════════════════════════

claude_mcp_list() {
  if command -v claude &>/dev/null; then
    claude mcp list 2>/dev/null || echo "  (none)"
  else
    echo "  ⊘ Claude Code not installed"
  fi
}

claude_mcp_install_all() {
  if ! command -v claude &>/dev/null; then
    echo "  ⊘ Claude Code not installed — skipping MCP servers"
    return
  fi
  local config="$CONFIG_DIR/claude.yaml"
  [ ! -f "$config" ] && return

  # Cache installed MCP server names for idempotency
  local _installed
  _installed=$(claude mcp list 2>/dev/null | grep -E '^  [a-zA-Z]' | awk '{print $1}' || true)
  # Fallback: also check by name in the raw output
  local _installed_raw
  _installed_raw=$(claude mcp list 2>/dev/null || true)

  local name="" cmd="" args=""
  while IFS= read -r line; do
    if [[ "$line" == "---" ]]; then
      if [[ -n "$name" && -n "$cmd" ]]; then
        # Check if this MCP server is already installed
        if echo "$_installed_raw" | grep -qw "$name"; then
          echo "  ✓ MCP: $name (already installed)"
        else
          echo "  → MCP: $name..."
          # shellcheck disable=SC2086
          if claude mcp add "$name" -- $cmd $args 2>/dev/null; then
            tenai_track cli_extension_installed --cli claude --name "$name" --url "mcp"
            echo "  ✓ $name"
          else
            echo "  ⚠ $name (install failed)"
          fi
        fi
      fi
      name="" cmd="" args=""
    elif [[ "$line" == name=* ]]; then name="${line#name=}"
    elif [[ "$line" == command=* ]]; then cmd="${line#command=}"
    elif [[ "$line" == args=* ]]; then args="${line#args=}"
    fi
  done < <(yaml_list "$config" "mcp_servers"; echo "---")
}

claude_mcp_install_one() {
  local ext_name="$1"
  if ! command -v claude &>/dev/null; then echo "  ⊘ Claude Code not installed"; return 1; fi
  local config="$CONFIG_DIR/claude.yaml" name="" cmd="" args=""
  while IFS= read -r line; do
    if [[ "$line" == "---" ]]; then
      if [[ "$name" == "$ext_name" && -n "$cmd" ]]; then
        # shellcheck disable=SC2086
        claude mcp add "$name" -- $cmd $args
        tenai_track cli_extension_installed --cli claude --name "$name" --url "mcp"
        echo "  ✓ $name added"; return 0
      fi
      name="" cmd="" args=""
    elif [[ "$line" == name=* ]]; then name="${line#name=}"
    elif [[ "$line" == command=* ]]; then cmd="${line#command=}"
    elif [[ "$line" == args=* ]]; then args="${line#args=}"
    fi
  done < <(yaml_list "$config" "mcp_servers"; echo "---")
  echo "  ✗ MCP server '$ext_name' not found in config"; return 1
}

claude_plugins_list() {
  if ! command -v claude &>/dev/null; then echo "  ⊘ Claude Code not installed"; return; fi
  claude plugin list 2>/dev/null | grep -E '^\s+❯' | sed 's/.*❯ /  /' || echo "  (none)"
}

_claude_installed_plugins() {
  command -v claude &>/dev/null || { echo ""; return; }
  local raw
  raw=$(claude plugin list 2>/dev/null || echo "")
  # Extract name@marketplace patterns (e.g. "telegram@claude-plugins-official")
  echo "$raw" | grep -oE '[a-z0-9_-]+@[a-z0-9_-]+' | sed 's/@.*//' || true
  # Also extract bare names from ❯ or bullet lines
  echo "$raw" | grep -oE '(❯|•)\s*[a-z0-9_-]+' | sed 's/^[❯•[:space:]]*//' || true
}

_claude_plugin_marketplace_name() {
  # Extract the "name" field from a repo's .claude-plugin/marketplace.json.
  # Claude registers the marketplace under that name, not the CLI argument name,
  # so install must use: claude plugin install <plugin>@<marketplace-declared-name>
  local url="$1"
  local tmpdir
  tmpdir=$(mktemp -d)
  GIT_CONFIG_GLOBAL=/dev/null git clone --depth 1 --filter=blob:none --sparse "$url" "$tmpdir" 2>/dev/null \
    && git -C "$tmpdir" sparse-checkout set .claude-plugin 2>/dev/null || true
  local mktplace_name
  mktplace_name=$($PYTHON -c "import json,sys; print(json.load(open('$tmpdir/.claude-plugin/marketplace.json'))['name'])" 2>/dev/null || echo "")
  rm -rf "$tmpdir"
  echo "$mktplace_name"
}

claude_plugins_install_all() {
  if ! command -v claude &>/dev/null; then echo "  ⊘ Claude Code not installed — skipping plugins"; return; fi
  local config="$CONFIG_DIR/claude.yaml"
  [ ! -f "$config" ] && return
  local _installed
  _installed=$(_claude_installed_plugins)

  local name="" url="" marketplace="" marketplace_repo="" plugin_id=""
  while IFS= read -r line; do
    if [[ "$line" == "---" ]]; then
      if [[ -n "$name" ]]; then
        if echo "$_installed" | grep -qxF "$name"; then
          echo "  ✓ Plugin: $name (already installed)"
        elif [[ -n "$plugin_id" && -n "$marketplace_repo" ]]; then
          # ── Marketplace plugin: install via marketplace repo + plugin_id ──
          echo "  → Plugin: $name (marketplace)..."
          if claude plugin marketplace add "$marketplace_repo" --scope user 2>/dev/null || true; then
            if claude plugin install "$plugin_id" --scope user 2>/dev/null; then
              tenai_track cli_extension_installed --cli claude --name "$plugin_id" --url "$marketplace_repo"
              echo "  ✓ Plugin: $name"
            else
              echo "  ⚠ Plugin: $name (install failed)"
            fi
          else
            echo "  ⚠ Plugin: $name (marketplace add failed)"
          fi
        elif [[ -n "$url" ]]; then
          # ── Git-based plugin: clone URL, discover marketplace.json ──
          echo "  → Plugin: $name (git)..."
          local mktplace_name
          mktplace_name=$(_claude_plugin_marketplace_name "$url")
          if [[ -z "$mktplace_name" ]]; then
            echo "  ⚠ Plugin: $name (could not read marketplace name from repo)"
          elif claude plugin marketplace add "$url" --scope user 2>/dev/null; then
            if claude plugin install "${name}@${mktplace_name}" --scope user 2>/dev/null; then
              tenai_track cli_extension_installed --cli claude --name "$name" --url "$url"
              echo "  ✓ Plugin: $name"
            else
              echo "  ⚠ Plugin: $name (install failed)"
            fi
          else
            echo "  ⚠ Plugin: $name (marketplace add failed)"
          fi
        else
          echo "  ⚠ Plugin: $name (no url or plugin_id configured)"
        fi
      fi
      name="" url="" marketplace="" marketplace_repo="" plugin_id=""
    elif [[ "$line" == name=* ]]; then name="${line#name=}"
    elif [[ "$line" == url=* ]]; then url="${line#url=}"
    elif [[ "$line" == marketplace=* ]]; then marketplace="${line#marketplace=}"
    elif [[ "$line" == marketplace_repo=* ]]; then marketplace_repo="${line#marketplace_repo=}"
    elif [[ "$line" == plugin_id=* ]]; then plugin_id="${line#plugin_id=}"
    fi
  done < <(yaml_list "$config" "plugins"; echo "---")
}

claude_plugins_install_one() {
  if ! command -v claude &>/dev/null; then echo "  ⊘ Claude Code not installed — skipping plugin install"; return 1; fi
  local target_name="$1"
  local config="$CONFIG_DIR/claude.yaml"
  [ ! -f "$config" ] && { echo "  ⚠ No claude config found"; return 1; }
  local _installed
  _installed=$(_claude_installed_plugins)

  local name="" url="" marketplace="" marketplace_repo="" plugin_id=""
  while IFS= read -r line; do
    if [[ "$line" == "---" ]]; then
      if [[ "$name" == "$target_name" ]]; then
        if echo "$_installed" | grep -qxF "$name"; then
          echo "  ✓ Plugin: $name (already installed)"; return 0
        fi
        if [[ -n "$plugin_id" && -n "$marketplace_repo" ]]; then
          # Marketplace plugin
          claude plugin marketplace add "$marketplace_repo" --scope user 2>/dev/null || true
          if claude plugin install "$plugin_id" --scope user 2>/dev/null; then
            tenai_track cli_extension_installed --cli claude --name "$plugin_id" --url "$marketplace_repo"
            echo "  ✓ Plugin: $name"
          else
            echo "  ⚠ Plugin: $name (install failed)"; return 1
          fi
        elif [[ -n "$url" ]]; then
          # Git-based plugin
          local mktplace_name
          mktplace_name=$(_claude_plugin_marketplace_name "$url")
          [[ -z "$mktplace_name" ]] && { echo "  ⚠ Plugin: $name (could not read marketplace name)"; return 1; }
          claude plugin marketplace add "$url" --scope user 2>/dev/null || true
          if claude plugin install "${name}@${mktplace_name}" --scope user 2>/dev/null; then
            tenai_track cli_extension_installed --cli claude --name "$name" --url "$url"
            echo "  ✓ Plugin: $name"
          else
            echo "  ⚠ Plugin: $name (install failed)"; return 1
          fi
        else
          echo "  ⚠ Plugin: $name — no url or plugin_id configured"; return 1
        fi
        return 0
      fi
      name="" url="" marketplace="" marketplace_repo="" plugin_id=""
    elif [[ "$line" == name=* ]]; then name="${line#name=}"
    elif [[ "$line" == url=* ]]; then url="${line#url=}"
    elif [[ "$line" == marketplace=* ]]; then marketplace="${line#marketplace=}"
    elif [[ "$line" == marketplace_repo=* ]]; then marketplace_repo="${line#marketplace_repo=}"
    elif [[ "$line" == plugin_id=* ]]; then plugin_id="${line#plugin_id=}"
    fi
  done < <(yaml_list "$config" "plugins"; echo "---")
  echo "  ⚠ Plugin '$target_name' not found in config"
  return 1
}

claude_skills_install() {
  local target_dir="$HOME/.claude/skills"
  _install_agents_skills "$target_dir"
}

claude_settings_install() {
  local config="$CONFIG_DIR/claude.yaml"
  local new_settings
  new_settings="$(yaml_dict "$config" "settings")"
  [ -z "$new_settings" ] && return
  local target="$HOME/.claude/settings.json"
  mkdir -p "$(dirname "$target")"
  if [ -f "$target" ]; then
    # Deep merge: add new keys from config, preserve existing values
    $PYTHON -c "
import json
def deep_merge(base, override):
    result = dict(base)
    for k, v in override.items():
        if k in result and isinstance(result[k], dict) and isinstance(v, dict):
            result[k] = deep_merge(result[k], v)
        else:
            result[k] = v
    return result
existing = json.load(open('$target'))
new = json.loads('$new_settings')
merged = deep_merge(new, existing)
changed = merged != existing
with open('$target', 'w') as f:
    json.dump(merged, f, indent=2)
if changed:
    print('  ✓ Settings merged into $target (new keys added)')
else:
    print('  ✓ Settings: $target up to date')
" 2>/dev/null
  else
    echo "$new_settings" | $PYTHON -c "
import json, sys
data = json.load(sys.stdin)
with open('$target', 'w') as f:
    json.dump(data, f, indent=2)
print('  ✓ Settings written to $target')
" 2>/dev/null
  fi
}

claude_rules_install() {
  local config="$CONFIG_DIR/claude.yaml"
  local source
  source="$(yaml_get "$config" "rules.source")" || return
  local src="$REPO_ROOT/$source"
  local target="$HOME/.claude/CLAUDE.md"
  if [ ! -f "$src" ]; then echo "  ⚠ Rules source not found: $src"; return; fi
  mkdir -p "$(dirname "$target")"
  if [ -f "$target" ]; then
    if ! diff -q "$src" "$target" > /dev/null 2>&1; then
      cp "$src" "$target"
      echo "  ✓ Rules: updated $target (source changed)"
    else
      echo "  ✓ Rules: $target up to date"
    fi
  else
    cp "$src" "$target"
    echo "  ✓ Rules: copied to $target"
  fi
}

claude_hooks_install() {
  local config="$CONFIG_DIR/claude.yaml"
  local source
  source="$(yaml_get "$config" "hooks.source")" || return
  local src="$REPO_ROOT/$source"
  local settings_target="$HOME/.claude/settings.json"
  if [ ! -f "$src" ]; then echo "  ⚠ Hooks source not found: $src"; return; fi
  mkdir -p "$(dirname "$settings_target")"
  # Claude Code reads hooks from settings.json — write hooks if key absent
  if [ -f "$settings_target" ]; then
    $PYTHON -c "
import json, sys
with open('$settings_target') as f:
    settings = json.load(f)
with open('$src') as f:
    hooks_data = json.load(f)
new_hooks = hooks_data.get('hooks', {})
existing_hooks = settings.get('hooks', {})
# Deep merge: source provides new events, existing user overrides win per-event
merged = dict(new_hooks)
for event, handlers in existing_hooks.items():
    merged[event] = handlers
changed = merged != existing_hooks
settings['hooks'] = merged
with open('$settings_target', 'w') as f:
    json.dump(settings, f, indent=2)
if not existing_hooks:
    print('  ✓ Hooks: added to $settings_target')
elif changed:
    print('  ✓ Hooks: updated $settings_target (new hook events merged)')
else:
    print('  ✓ Hooks: $settings_target up to date')
" || echo "  ⚠ Hooks: failed to process $settings_target (check JSON validity)"
  else
    $PYTHON -c "
import json, sys
with open('$src') as f:
    hooks_data = json.load(f)
with open('$settings_target', 'w') as f:
    json.dump(hooks_data, f, indent=2)
print('  ✓ Hooks: written to $settings_target')
" || echo "  ⚠ Hooks: failed to write $settings_target"
  fi
}

claude_channel_setup() {
  # Automate Telegram channel plugin setup:
  #   1. Configure bot token from .env
  #   2. Write token to ~/.claude/channels/telegram/.env
  if ! command -v claude &>/dev/null; then
    echo "  ⊘ Claude Code not installed — skipping channel setup"
    return
  fi

  local bot_token="${TELEGRAM_BOT_TOKEN:-}"
  if [[ -z "$bot_token" ]]; then
    echo "  ⚠ TELEGRAM_BOT_TOKEN not set in .env — skipping Telegram channel setup"
    return
  fi

  # Write bot token to channel config directory
  local channel_dir="$HOME/.claude/channels/telegram"
  mkdir -p "$channel_dir"
  chmod 700 "$channel_dir"
  local env_file="$channel_dir/.env"
  if [[ -f "$env_file" ]]; then
    # Check if token already matches (exact line match, not substring)
    if grep -qxF "TELEGRAM_BOT_TOKEN=$bot_token" "$env_file" 2>/dev/null; then
      echo "  ✓ Telegram: bot token already configured"
    else
      # Update only the TELEGRAM_BOT_TOKEN line, preserving other content
      if grep -q '^TELEGRAM_BOT_TOKEN=' "$env_file" 2>/dev/null; then
        sed -i.bak 's|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN='"$bot_token"'|' "$env_file" && rm -f "${env_file}.bak"
      else
        echo "TELEGRAM_BOT_TOKEN=$bot_token" >> "$env_file"
      fi
      chmod 600 "$env_file"
      echo "  ✓ Telegram: bot token updated in $env_file"
    fi
  else
    echo "TELEGRAM_BOT_TOKEN=$bot_token" > "$env_file"
    chmod 600 "$env_file"
    echo "  ✓ Telegram: bot token written to $env_file"
  fi

  # Configure sender ID if available
  local sender_id="${TELEGRAM_SENDER_ID:-}"
  if [[ -n "$sender_id" ]]; then
    echo "  ℹ Telegram: sender ID available ($sender_id)"
    echo "    To pair: run '/telegram:access pair <code>' in Claude session"
    echo "    To lock:  run '/telegram:access policy allowlist' in Claude session"
  else
    echo "  ℹ Telegram: No TELEGRAM_SENDER_ID in .env"
    echo "    After first message to bot, pair with: /telegram:access pair <code>"
  fi

  echo "  ℹ Launch Claude with channels: claude --channels plugin:telegram@claude-plugins-official"
}

claude_subagents_install() {
  local config="$CONFIG_DIR/claude.yaml" name="" source=""
  while IFS= read -r line; do
    if [[ "$line" == "---" ]]; then
      if [[ -n "$name" && -n "$source" ]]; then
        local src="$REPO_ROOT/$source"
        local target="$HOME/.claude/agents/$name.md"
        if [ -f "$src" ]; then
          mkdir -p "$(dirname "$target")"
          cp "$src" "$target"
          echo "  ✓ Subagent: $name → $target"
        else
          echo "  ⚠ Subagent source not found: $src"
        fi
      fi
      name="" source=""
    elif [[ "$line" == name=* ]]; then name="${line#name=}"
    elif [[ "$line" == source=* ]]; then source="${line#source=}"
    fi
  done < <(yaml_list "$config" "subagents"; echo "---")
}


# ══════════════════════════════════════════════════════════════════════════════
# CODEX CLI
# ══════════════════════════════════════════════════════════════════════════════

codex_mcp_install_all() {
  local config="$CONFIG_DIR/codex.yaml"
  [ ! -f "$config" ] && return
  # Codex reads MCP config from .codex/mcp.json in the home directory
  local target="$HOME/.codex/mcp.json"

  # Cache existing MCP server names for idempotency
  local _existing_keys=""
  if [[ -f "$target" ]]; then
    _existing_keys=$($PYTHON -c "import json; print('\n'.join(json.load(open('$target')).keys()))" 2>/dev/null || echo "")
  fi

  local mcp_entries=""
  local new_count=0 skip_count=0
  local name="" cmd="" args=""
  while IFS= read -r line; do
    if [[ "$line" == "---" ]]; then
      if [[ -n "$name" && -n "$cmd" ]]; then
        local args_json="[]"
        if [[ -n "$args" ]]; then
          args_json=$($PYTHON -c "import json; print(json.dumps('$args'.split()))" 2>/dev/null || echo '[]')
        fi
        # Check if already in mcp.json
        if echo "$_existing_keys" | grep -qxF "$name"; then
          echo "  ✓ MCP: $name (already configured)"
          ((skip_count++)) || true
          # Preserve existing entry
          [[ -n "$mcp_entries" ]] && mcp_entries="$mcp_entries,"
          mcp_entries="${mcp_entries}\"$name\":{\"command\":\"$cmd\",\"args\":$args_json}"
        else
          echo "  → MCP: $name (adding)"
          ((new_count++)) || true
          [[ -n "$mcp_entries" ]] && mcp_entries="$mcp_entries,"
          mcp_entries="${mcp_entries}\"$name\":{\"command\":\"$cmd\",\"args\":$args_json}"
        fi
      fi
      name="" cmd="" args=""
    elif [[ "$line" == name=* ]]; then name="${line#name=}"
    elif [[ "$line" == command=* ]]; then cmd="${line#command=}"
    elif [[ "$line" == args=* ]]; then args="${line#args=}"
    fi
  done < <(yaml_list "$config" "mcp_servers"; echo "---")
  if [[ -n "$mcp_entries" ]]; then
    mkdir -p "$(dirname "$target")"
    echo "{$mcp_entries}" | $PYTHON -c "
import json, sys, os
yaml_data = json.load(sys.stdin)
# Preserve user-added MCP servers not defined in YAML config
existing = {}
if os.path.exists('$target'):
    try:
        with open('$target') as f:
            existing = json.load(f)
    except (json.JSONDecodeError, IOError):
        pass
user_added = {k: v for k, v in existing.items() if k not in yaml_data}
if user_added:
    for name in user_added:
        print(f'  ✓ MCP: {name} (user-added, preserved)')
merged = {**yaml_data, **user_added}
with open('$target', 'w') as f:
    json.dump(merged, f, indent=2)
print('  ✓ MCP config written to $target')
" 2>/dev/null
    if [[ $new_count -eq 0 ]]; then
      echo "  ✓ All MCP servers already configured ($skip_count skipped)"
    fi
  fi
}

codex_skills_install() {
  local target_dir="$HOME/.codex/skills"
  _install_agents_skills "$target_dir"
}

codex_rules_install() {
  local config="$CONFIG_DIR/codex.yaml"
  local source
  source="$(yaml_get "$config" "rules.source")" || return
  local src="$REPO_ROOT/$source"
  local target="$HOME/.codex/AGENTS.md"
  if [ ! -f "$src" ]; then echo "  ⚠ Rules source not found: $src"; return; fi
  mkdir -p "$(dirname "$target")"
  if [ -f "$target" ]; then
    if ! diff -q "$src" "$target" > /dev/null 2>&1; then
      cp "$src" "$target"
      echo "  ✓ Rules: updated $target (source changed)"
    else
      echo "  ✓ Rules: $target up to date"
    fi
  else
    cp "$src" "$target"
    echo "  ✓ Rules: copied to $target"
  fi
}

codex_hooks_install() {
  local config="$CONFIG_DIR/codex.yaml"
  local source
  source="$(yaml_get "$config" "hooks.source")" || return
  local src="$REPO_ROOT/$source"
  local target="$HOME/.codex/hooks.json"
  if [ ! -f "$src" ]; then echo "  ⚠ Hooks source not found: $src"; return; fi
  mkdir -p "$(dirname "$target")"
  if [ -f "$target" ]; then
    if ! diff -q "$src" "$target" > /dev/null 2>&1; then
      cp "$src" "$target"
      echo "  ✓ Hooks: updated $target (source changed)"
    else
      echo "  ✓ Hooks: $target up to date"
    fi
  else
    cp "$src" "$target"
    echo "  ✓ Hooks: copied to $target"
  fi
  # Auto-enable hooks feature flag in config.toml
  local config_toml="$HOME/.codex/config.toml"
  if [ -f "$config_toml" ]; then
    if ! grep -q 'codex_hooks' "$config_toml" 2>/dev/null; then
      # Append feature flag
      if grep -q '\[features\]' "$config_toml" 2>/dev/null; then
        sed -i.bak '/\[features\]/a\
codex_hooks = true' "$config_toml" 2>/dev/null && rm -f "${config_toml}.bak" || true
      else
        echo -e '\n[features]\ncodex_hooks = true' >> "$config_toml"
      fi
      echo "  ✓ Hooks: enabled codex_hooks feature flag in $config_toml"
    fi
  else
    mkdir -p "$(dirname "$config_toml")"
    echo -e '[features]\ncodex_hooks = true' > "$config_toml"
    echo "  ✓ Hooks: created $config_toml with codex_hooks feature flag"
  fi
}

codex_plugins_list() {
  if [ -d "$HOME/.codex/skills" ]; then
    ls "$HOME/.codex/skills/" 2>/dev/null | tr '\n' ' ' || echo "  (none)"
  else
    echo "  (none)"
  fi
}

codex_plugins_install_all() {
  # Codex has no plugin marketplace — plugins are git-cloned into ~/.codex/skills/<name>/
  # so Codex auto-discovers them alongside local skills.
  local config="$CONFIG_DIR/codex.yaml"
  [ ! -f "$config" ] && return
  local target_base="$HOME/.codex/skills"
  mkdir -p "$target_base"

  local name="" url=""
  while IFS= read -r line; do
    if [[ "$line" == "---" ]]; then
      if [[ -n "$name" && -n "$url" ]]; then
        local target_dir="$target_base/$name"
        if [ -d "$target_dir" ]; then
          echo "  ✓ Plugin: $name (already installed at $target_dir)"
        else
          echo "  → Plugin: $name..."
          git clone --depth 1 "$url" "$target_dir" 2>/dev/null && \
            echo "  ✓ Plugin: $name" || echo "  ⚠ Plugin: $name (clone failed — check URL)"
        fi
      fi
      name="" url=""
    elif [[ "$line" == name=* ]]; then name="${line#name=}"
    elif [[ "$line" == url=* ]]; then url="${line#url=}"
    fi
  done < <(yaml_list "$config" "plugins"; echo "---")
}


# ══════════════════════════════════════════════════════════════════════════════
# VERCEL SKILLS (cross-CLI: npx skills add <owner/repo>)
# ══════════════════════════════════════════════════════════════════════════════

vercel_skills_install() {
  local config="$1"
  if ! command -v npx &>/dev/null; then
    echo "  ⊘ npx not available — skipping Vercel Skills"
    return
  fi
  [ ! -f "$config" ] && return

  # Cache installed Vercel Skills for idempotency (check ~/.agents/skills/)
  local _installed_skills
  _installed_skills=$(ls ~/.agents/skills/ 2>/dev/null || echo "")

  local name="" package=""
  while IFS= read -r line; do
    if [[ "$line" == "---" ]]; then
      if [[ -n "$package" && -n "$name" ]]; then
        # Check if skill already exists in ~/.agents/skills/
        if echo "$_installed_skills" | grep -qxF "$name"; then
          echo "  ✓ $name (already installed)"
        else
          echo "  → $name..."
          # GIT_CONFIG_GLOBAL=/dev/null bypasses insteadOf rewrites (HTTPS→SSH)
          # that would fail for public repos when only org-specific SSH keys exist
          #
          # For monorepos (owner/repo/skill), split into repo + --skill flag
          # e.g. "anthropics/skills/webapp-testing" → add "anthropics/skills" --skill "webapp-testing"
          local repo_path="$package" skill_flag=""
          local slash_count
          slash_count=$(echo "$package" | tr -cd '/' | wc -c | tr -d ' ')
          if [[ "$slash_count" -ge 2 ]]; then
            # Extract skill name (last path segment) and repo (everything before it)
            local skill_name="${package##*/}"
            repo_path="${package%/*}"
            skill_flag="--skill $skill_name"
          fi
          GIT_CONFIG_GLOBAL=/dev/null npx -y skills add "$repo_path" $skill_flag --yes --global 2>/dev/null && \
            echo "  ✓ $name" || echo "  ⚠ $name (install failed)"
        fi
      fi
      name="" package=""
    elif [[ "$line" == name=* ]]; then name="${line#name=}"
    elif [[ "$line" == package=* ]]; then package="${line#package=}"
    fi
  done < <(yaml_list "$config" "vercel_skills"; echo "---")
}

vercel_skills_list() {
  if command -v npx &>/dev/null; then
    npx -y skills list 2>/dev/null || echo "  (none or skills CLI not available)"
  else
    echo "  ⊘ npx not available"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# DISPATCH
# ══════════════════════════════════════════════════════════════════════════════

do_list() {
  local cli="$1"
  case "$cli" in
    gemini)
      echo "── Gemini CLI ──"
      echo "Extensions:"; gemini_extensions_list
      echo "Vercel Skills:"; vercel_skills_list
      echo "Local Skills: $(ls ~/.gemini/skills/ 2>/dev/null | tr '\n' ' ' || echo '(none)')"
      echo "Settings: $([ -f ~/.gemini/settings.json ] && echo '~/.gemini/settings.json' || echo '(none)')"
      echo "Rules: $([ -f ~/.gemini/GEMINI.md ] && echo '~/.gemini/GEMINI.md' || echo '(none)')"
      _hooks=$($PYTHON -c 'import json; h=json.load(open("'"$HOME"'/.gemini/settings.json")).get("hooks",{}); print(", ".join(h.keys()) if h else "(none)")' 2>/dev/null || echo '(none)')
      echo "Hooks: $_hooks"
      ;;
    claude)
      echo "── Claude Code ──"
      echo "MCP Servers:"; claude_mcp_list
      echo "Plugins:"; claude_plugins_list
      echo "Vercel Skills:"; vercel_skills_list
      echo "Local Skills: $(ls ~/.claude/skills/ 2>/dev/null | tr '\n' ' ' || echo '(none)')"
      echo "Settings: $([ -f ~/.claude/settings.json ] && echo '~/.claude/settings.json' || echo '(none)')"
      echo "Rules: $([ -f ~/.claude/CLAUDE.md ] && echo '~/.claude/CLAUDE.md' || echo '(none)')"
      _hooks=$($PYTHON -c 'import json; h=json.load(open("'"$HOME"'/.claude/settings.json")).get("hooks",{}); print(", ".join(h.keys()) if h else "(none)")' 2>/dev/null || echo '(none)')
      echo "Hooks: $_hooks"
      echo "Channels: $([ -d ~/.claude/channels/telegram ] && echo 'telegram' || echo '(none)')"
      ;;
    codex)
      echo "── Codex CLI ──"
      echo "Plugins:"; codex_plugins_list
      echo "Local Skills: $(ls ~/.codex/skills/ 2>/dev/null | tr '\n' ' ' || echo '(none)')"
      echo "MCP Config: $([ -f ~/.codex/mcp.json ] && echo '~/.codex/mcp.json' || echo '(none)')"
      echo "Rules: $([ -f ~/.codex/AGENTS.md ] && echo '~/.codex/AGENTS.md' || echo '(none)')"
      echo "Hooks: $([ -f ~/.codex/hooks.json ] && echo '~/.codex/hooks.json' || echo '(none)')"
      echo "Vercel Skills:"; vercel_skills_list
      ;;
  esac
}

do_setup() {
  local cli="$1" type="$2"
  case "$cli" in
    gemini)
      echo "═══ Gemini CLI Setup ═══"
      if [[ -z "$type" || "$type" == "extensions" ]]; then     echo "Extensions:";    gemini_extensions_install_all; fi
      if [[ -z "$type" || "$type" == "vercel-skills" ]]; then echo "Vercel Skills:"; vercel_skills_install "$CONFIG_DIR/gemini.yaml"; fi
      if [[ -z "$type" || "$type" == "skills" ]]; then         echo "Local Skills:";  gemini_skills_install; fi
      if [[ -z "$type" || "$type" == "settings" ]]; then       echo "Settings:";      gemini_settings_install; fi
      if [[ -z "$type" || "$type" == "rules" ]]; then          echo "Rules:";         gemini_rules_install; fi
      if [[ -z "$type" || "$type" == "hooks" ]]; then          echo "Hooks:";         gemini_hooks_install; fi
      echo "✓ Gemini setup done"
      ;;
    claude)
      echo "═══ Claude Code Setup ═══"
      if [[ -z "$type" || "$type" == "mcp" ]]; then            echo "MCP Servers:";  claude_mcp_install_all; fi
      if [[ -z "$type" || "$type" == "plugins" ]]; then        echo "Plugins:";      claude_plugins_install_all; fi
      if [[ -z "$type" || "$type" == "vercel-skills" ]]; then echo "Vercel Skills:"; vercel_skills_install "$CONFIG_DIR/claude.yaml"; fi
      if [[ -z "$type" || "$type" == "skills" ]]; then         echo "Local Skills:";  claude_skills_install; fi
      if [[ -z "$type" || "$type" == "settings" ]]; then       echo "Settings:";      claude_settings_install; fi
      if [[ -z "$type" || "$type" == "rules" ]]; then          echo "Rules:";         claude_rules_install; fi
      if [[ -z "$type" || "$type" == "hooks" ]]; then          echo "Hooks:";         claude_hooks_install; fi
      if [[ -z "$type" || "$type" == "channels" ]]; then       echo "Channels:";      claude_channel_setup; fi
      if [[ -z "$type" || "$type" == "subagents" ]]; then      echo "Subagents:";     claude_subagents_install; fi
      echo "✓ Claude setup done"
      ;;
    codex)
      echo "═══ Codex CLI Setup ═══"
      if [[ -z "$type" || "$type" == "mcp" ]]; then            echo "MCP Config:";   codex_mcp_install_all; fi
      if [[ -z "$type" || "$type" == "plugins" ]]; then        echo "Plugins:";      codex_plugins_install_all; fi
      if [[ -z "$type" || "$type" == "vercel-skills" ]]; then echo "Vercel Skills:"; vercel_skills_install "$CONFIG_DIR/codex.yaml"; fi
      if [[ -z "$type" || "$type" == "skills" ]]; then         echo "Local Skills:";  codex_skills_install; fi
      if [[ -z "$type" || "$type" == "rules" ]]; then          echo "Rules:";         codex_rules_install; fi
      if [[ -z "$type" || "$type" == "hooks" ]]; then          echo "Hooks:";         codex_hooks_install; fi
      echo "✓ Codex setup done"
      ;;
  esac
}

do_install_one() {
  local cli="$1" type="$2" ext="$3"
  case "$cli" in
    gemini)
      case "$type" in
        extensions) gemini_extensions_install_one "$ext" ;;
        *) echo "Gemini supports: extensions"; return 1 ;;
      esac
      ;;
    claude)
      case "$type" in
        mcp)     claude_mcp_install_one "$ext" ;;
        plugins) claude_plugins_install_one "$ext" ;;
        *) echo "Claude supports: mcp, plugins"; return 1 ;;
      esac
      ;;
    *) echo "Unknown CLI: $cli"; return 1 ;;
  esac
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

main() {
  case "$ACTION" in
    list)
      if [[ -z "$CLI" || "$CLI" == "gemini" ]]; then do_list gemini; echo; fi
      if [[ -z "$CLI" || "$CLI" == "claude" ]]; then do_list claude; echo; fi
      if [[ -z "$CLI" || "$CLI" == "codex" ]]; then  do_list codex; fi
      ;;
    install)
      if [[ -z "$CLI" || -z "$TYPE" || -z "$EXT" ]]; then
        echo "Usage: CLI=x TYPE=y EXT=z ACTION=install $0"
        echo "  CLI:  gemini, claude"
        echo "  TYPE: extensions, mcp, plugins"
        echo "  EXT:  extension/plugin name"
        exit 1
      fi
      do_install_one "$CLI" "$TYPE" "$EXT"
      ;;
    setup|"")
      if [[ -z "$CLI" || "$CLI" == "gemini" ]]; then do_setup gemini "$TYPE"; echo; fi
      if [[ -z "$CLI" || "$CLI" == "claude" ]]; then do_setup claude "$TYPE"; echo; fi
      if [[ -z "$CLI" || "$CLI" == "codex" ]];  then do_setup codex "$TYPE"; echo; fi
      ;;
    *)
      echo "Unknown ACTION: $ACTION (use: setup, list, install)"
      exit 1
      ;;
  esac
}

main "$@"
