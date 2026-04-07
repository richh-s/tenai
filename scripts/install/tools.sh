#!/bin/bash
# scripts/install/tools.sh — install Week 1 & 2 tools
set -euo pipefail

source "$(dirname "$0")/../detect.sh"
source "$(dirname "$0")/../lib/state_track.sh"

# Wait for apt/dpkg lock to be released (up to 60s)
wait_for_apt() {
  local tries=0
  while fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 || \
        fuser /var/lib/apt/lists/lock &>/dev/null 2>&1; do
    if [ $tries -eq 0 ]; then
      echo "  ⏳ Waiting for apt lock..."
    fi
    sleep 5
    tries=$((tries + 1))
    if [ $tries -ge 12 ]; then
      echo "  ⚠ apt lock held for 60s+, proceeding anyway"
      break
    fi
  done
}

npm_install_g() {
  local pkg="$1"
  if [[ -w "$(npm root -g)" ]]; then
    npm install -g "$pkg"
  else
    sudo_prompt "npm install -g $pkg"
    sudo npm install -g "$pkg"
  fi
  tenai_track tool_installed --tool "npm_${pkg}" --pkg-mgr npm
}

install_pkg() {
  # Install a single package if not already present and not skipped.
  # Usage: install_pkg <skip_name> <command_to_check> <pkg_name> [pkg_name_mac] [pkg_name_termux]
  local skip_name="$1" check_cmd="$2" pkg_linux="$3"
  local pkg_mac="${4:-$pkg_linux}" pkg_termux="${5:-$pkg_linux}"

  if ! should_install "$skip_name"; then
    echo "  ⊘ ${skip_name} (skipped)"
    return
  fi
  if command -v "$check_cmd" &>/dev/null; then
    echo "  ✓ ${skip_name} (already installed)"
    return
  fi

  echo "  → Installing ${skip_name}..."
  local _pkg_mgr=""
  case "$OS_TYPE" in
    linux|wsl) wait_for_apt; sudo_prompt "apt-get install $pkg_linux"; sudo apt-get install -y -qq "$pkg_linux"; _pkg_mgr="apt" ;;
    mac)       brew install "$pkg_mac"; _pkg_mgr="brew" ;;
    termux)    pkg install -y "$pkg_termux"; _pkg_mgr="pkg" ;;
    ish)       apk add --no-cache "$pkg_linux"; _pkg_mgr="apk" ;;
  esac
  local _actual_pkg="$pkg_linux"
  [[ "$OS_TYPE" == "mac" ]] && _actual_pkg="$pkg_mac"
  [[ "$OS_TYPE" == "termux" ]] && _actual_pkg="$pkg_termux"
  tenai_track tool_installed --tool "$_actual_pkg" --pkg-mgr "$_pkg_mgr"
}

install_common_tools() {
  echo "── Installing common tools on ${OS_TYPE} ──"

  # Check if all common tools are already present — skip package update if so
  local _needs_install=false
  for t in git curl wget vim jq unzip expect htop; do
    command -v "$t" &>/dev/null || { _needs_install=true; break; }
  done

  if [[ "$_needs_install" == "false" ]]; then
    echo "✓ All common tools already installed"
    return
  fi

  # Update package index once (only when something needs installing)
  case "$OS_TYPE" in
    linux|wsl)
      sudo_prompt "apt-get update"
      sudo apt-get update -qq
      ;;
    mac)
      if ! command -v brew &>/dev/null; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      fi
      ;;
    termux)  pkg update -y ;;
    ish)     apk update ;;
  esac

  # Install each tool individually (idempotent + skippable)
  install_pkg git    git    git
  install_pkg curl   curl   curl
  install_pkg wget   wget   wget
  install_pkg vim    vim    vim
  install_pkg jq     jq     jq
  install_pkg unzip  unzip  unzip  unzip  unzip
  install_pkg expect expect expect expect expect
  install_pkg htop   htop   htop

  # Termux/iSH-specific extras (python and nodejs for tools like Claude CLI)
  if [[ "$OS_TYPE" == "termux" ]]; then
    install_pkg python  python3  python  python  python
    install_pkg nodejs  node     nodejs  node    nodejs
  fi
  if [[ "$OS_TYPE" == "ish" ]]; then
    install_pkg python  python3  python3
    install_pkg nodejs  node     nodejs-current
  fi

  echo "✓ Common tools done"
}

install_gh() {
  echo "── Installing GitHub CLI ──"
  if ! should_install "gh"; then
    echo "  ⊘ gh (skipped)"
    return
  fi
  if command -v gh &>/dev/null; then
    echo "  ✓ gh already installed: $(gh --version | head -1)"
    return
  fi

  echo "  → Installing gh..."
  case "$OS_TYPE" in
    linux|wsl)
      # Official GitHub apt repository
      wait_for_apt
      sudo mkdir -p -m 755 /etc/apt/keyrings
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
      sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
      sudo_prompt "apt-get update"
      sudo apt-get update -qq
      sudo_prompt "apt-get install gh"
      sudo apt-get install -y -qq gh
      ;;
    mac)
      brew install gh
      ;;
    termux)
      pkg install -y gh
      ;;
  esac
  local _gh_mgr="apt"
  [[ "$OS_TYPE" == "mac" ]] && _gh_mgr="brew"
  [[ "$OS_TYPE" == "termux" ]] && _gh_mgr="pkg"
  tenai_track tool_installed --tool "gh" --pkg-mgr "$_gh_mgr"
  echo "✓ gh installed: $(gh --version 2>/dev/null | head -1 || echo 'installed')"
}

install_node() {
  echo "── Checking Node.js ──"
  local MIN_MAJOR=22  # VibeTunnel requires Node.js 22.12+

  if command -v node &>/dev/null; then
    local current_ver
    current_ver="$(node --version 2>/dev/null | sed 's/^v//')"
    local current_major="${current_ver%%.*}"
    if [[ "$current_major" -ge "$MIN_MAJOR" ]] 2>/dev/null; then
      echo "✓ Node: v${current_ver} (>= v${MIN_MAJOR}, up to date)"
      return
    fi
    echo "  Node v${current_ver} found but < v${MIN_MAJOR} — upgrading..."
  fi

  case "$OS_TYPE" in
    linux)
      sudo_prompt "install nodejs repository"
      curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
      sudo_prompt "apt-get install nodejs"
      sudo apt-get install -y nodejs
      ;;
    mac)
      brew install node
      ;;
    termux)
      pkg install -y nodejs
      ;;
  esac
  local _node_pkg="nodejs" _node_mgr="apt"
  [[ "$OS_TYPE" == "mac" ]] && _node_pkg="node" && _node_mgr="brew"
  [[ "$OS_TYPE" == "termux" ]] && _node_pkg="nodejs" && _node_mgr="pkg"
  tenai_track tool_installed --tool "$_node_pkg" --pkg-mgr "$_node_mgr"
  echo "✓ Node: $(node --version)"
}

install_claude_code() {
  echo "── Installing Claude Code ──"

  if command -v claude &>/dev/null; then
    echo "✓ Claude Code already installed: $(claude --version 2>/dev/null || echo 'version unknown')"
    return
  fi

  if ! command -v node &>/dev/null; then
    echo "Node.js required for Claude Code — installing first..."
    install_node
  fi

  npm_install_g @anthropic-ai/claude-code
  mkdir -p "$HOME/.claude"
  tenai_track dir_created --path "~/.claude"
  echo "✓ Claude Code installed: $(claude --version 2>/dev/null || echo 'installed')"
}

install_gemini_cli() {
  echo "── Installing Gemini CLI ──"

  if command -v gemini &>/dev/null; then
    echo "✓ Gemini CLI already installed"
    return
  fi

  if ! command -v node &>/dev/null; then
    echo "Node.js required for Gemini CLI — installing first..."
    install_node
  fi

  npm_install_g @google/gemini-cli
  mkdir -p "$HOME/.gemini"
  tenai_track dir_created --path "~/.gemini"
  echo "✓ Gemini CLI installed"
}

install_codex_cli() {
  echo "── Installing OpenAI Codex CLI ──"

  if command -v codex &>/dev/null; then
    echo "✓ Codex CLI already installed"
    return
  fi

  if ! command -v node &>/dev/null; then
    echo "Node.js required for Codex CLI — installing first..."
    install_node
  fi

  npm_install_g @openai/codex
  mkdir -p "$HOME/.codex"
  tenai_track dir_created --path "~/.codex"
  echo "✓ Codex CLI installed"
}

install_muxtree() {
  echo "── Installing muxtree ──"

  if command -v muxtree &>/dev/null; then
    echo "✓ muxtree already installed"
    return
  fi

  # muxtree is a single bash script — clone from GitHub and copy to PATH
  local MUXTREE_REPO="https://github.com/b-d055/muxtree.git"
  local MUXTREE_TMP="/tmp/muxtree-install"
  local MUXTREE_BIN="/usr/local/bin/muxtree"

  rm -rf "$MUXTREE_TMP"
  if env GIT_CONFIG_GLOBAL=/dev/null git clone --depth 1 "$MUXTREE_REPO" "$MUXTREE_TMP" 2>/dev/null; then
    if [[ -f "$MUXTREE_TMP/muxtree" ]]; then
      # Use sudo on Linux, direct copy on Mac if writable
      if [[ -w "$(dirname "$MUXTREE_BIN")" ]]; then
        cp "$MUXTREE_TMP/muxtree" "$MUXTREE_BIN"
      else
        sudo_prompt "cp muxtree to $MUXTREE_BIN"
        sudo cp "$MUXTREE_TMP/muxtree" "$MUXTREE_BIN"
      fi
      chmod +x "$MUXTREE_BIN"
      tenai_track file_created --path "$MUXTREE_BIN"
      echo "✓ muxtree installed to $MUXTREE_BIN"

      # Install shell completions if available
      if [[ -d "$MUXTREE_TMP/completions" ]]; then
        mkdir -p "$HOME/.muxtree"
        cp -r "$MUXTREE_TMP/completions" "$HOME/.muxtree/"
        tenai_track dir_created --path "~/.muxtree"
        echo "  Shell completions copied to ~/.muxtree/completions/"
      fi
    else
      echo "⚠ muxtree script not found in cloned repo"
    fi
    rm -rf "$MUXTREE_TMP"
  else
    echo "⚠ muxtree clone failed — install manually: git clone $MUXTREE_REPO"
  fi
}

install_vibetunnel() {
  echo "── Installing VibeTunnel ──"

  # Check for vt command or VibeTunnel.app
  if command -v vt &>/dev/null; then
    echo "✓ VibeTunnel already installed (vt command found)"
    return
  fi
  if [[ -d "/Applications/VibeTunnel.app" ]]; then
    echo "✓ VibeTunnel.app found — creating symlinks..."
    mkdir -p "$HOME/.local/bin"
    ln -sf /Applications/VibeTunnel.app/Contents/Resources/vt "$HOME/.local/bin/vt"
    ln -sf /Applications/VibeTunnel.app/Contents/Resources/vibetunnel "$HOME/.local/bin/vibetunnel"
    tenai_track file_created --path "~/.local/bin/vt"
    tenai_track file_created --path "~/.local/bin/vibetunnel"
    echo "✓ vt and vibetunnel symlinks created at ~/.local/bin/"
    return
  fi
  if command -v vibetunnel &>/dev/null; then
    echo "✓ VibeTunnel already installed (vibetunnel command found)"
    return
  fi

  case "$OS_TYPE" in
    mac)
      # Prefer the native macOS cask (Apple Silicon only)
      if [[ "$ARCH" == "arm64" ]]; then
        echo "  Installing via Homebrew cask (Apple Silicon)..."
        if brew install --cask vibetunnel 2>/dev/null; then
          tenai_track tool_installed --tool "vibetunnel" --pkg-mgr "brew"
          echo "✓ VibeTunnel.app installed"
          return
        fi
      fi
      # Fallback: npm package (works on Intel Macs too)
      echo "  Installing via npm (requires build tools)..."
      npm_install_g node-addon-api 2>/dev/null || true
      if npm_install_g vibetunnel; then
        tenai_track tool_installed --tool "vibetunnel" --pkg-mgr npm
        echo "✓ VibeTunnel installed via npm"
      else
        echo "⚠ VibeTunnel install failed — try: xcode-select --install && npm install -g vibetunnel"
      fi
      ;;
    linux)
      # Linux: npm package (requires Node.js 22.12+ and build deps for native modules)
      echo "  Installing build dependencies..."
      wait_for_apt
      sudo_prompt "apt-get install build-essential libpam0g-dev"
      sudo apt-get install -y build-essential libpam0g-dev 2>/dev/null || true
      echo "  Installing via npm..."
      # Clean old install to avoid ENOTEMPTY errors during npm overwrite
      local vt_old="$(npm root -g)/vibetunnel"
      if [[ -d "$vt_old" ]]; then
        echo "  Removing old VibeTunnel install..."
        if [[ -w "$vt_old" ]]; then rm -rf "$vt_old"; else sudo_prompt "rm -rf $vt_old"; sudo rm -rf "$vt_old"; fi
      fi
      npm_install_g node-addon-api 2>/dev/null || true
      if npm_install_g vibetunnel; then
        # Fix: uuid is missing from vibetunnel's declared deps (silent crash on Linux)
        local vt_dir
        vt_dir="$(npm root -g)/vibetunnel"
        if [[ -d "$vt_dir" ]]; then
          (cd "$vt_dir" && npm install uuid 2>/dev/null) || true
        fi
        # Symlink to /usr/local/bin so vt is on PATH for SSH sessions
        local npm_bin
        npm_bin="$(dirname "$(npm root -g)")/../bin"
        if [[ -f "$npm_bin/vt" ]] && [[ ! -f /usr/local/bin/vt ]]; then
          sudo_prompt "symlinking vt to /usr/local/bin/"
          sudo ln -sf "$npm_bin/vt" /usr/local/bin/vt
          sudo ln -sf "$npm_bin/vibetunnel" /usr/local/bin/vibetunnel
          tenai_track file_created --path "/usr/local/bin/vt"
          tenai_track file_created --path "/usr/local/bin/vibetunnel"
          echo "  Symlinked vt to /usr/local/bin/"
        fi
        # Set up systemd user service (auto-starts VT server on boot)
        # Note: vibetunnel's bin wrapper is broken on npm installs — use node dist/cli.js directly
        local node_bin vt_port
        node_bin="$(which node)"
        vt_port="${VT_PORT:-4020}"
        if [[ -n "$node_bin" ]] && [[ -f "$vt_dir/dist/cli.js" ]]; then
          # Check if systemd user bus is available (absent in cloud VMs, SSH sessions)
          if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || timeout 5 systemctl --user status >/dev/null 2>&1; then
            mkdir -p "$HOME/.config/systemd/user"
            cat > "$HOME/.config/systemd/user/vibetunnel.service" << EOSVC
[Unit]
Description=VibeTunnel - Terminal sharing server with web interface
Documentation=https://github.com/amantus-ai/vibetunnel
After=network.target

[Service]
Type=simple
WorkingDirectory=${vt_dir}
ExecStart=${node_bin} ${vt_dir}/dist/cli.js --port ${vt_port} --no-auth --bind 0.0.0.0
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=vibetunnel
Environment=NODE_ENV=production
Environment=HOME=${HOME}

[Install]
WantedBy=default.target
EOSVC
            timeout 10 systemctl --user daemon-reload 2>/dev/null || true
            timeout 10 systemctl --user enable vibetunnel 2>/dev/null || true
            loginctl enable-linger "$(whoami)" 2>/dev/null || true
            timeout 10 systemctl --user restart vibetunnel 2>/dev/null || true
            tenai_track file_created --path "~/.config/systemd/user/vibetunnel.service"
            echo "  ✓ Systemd service installed and started (port ${vt_port})"
          else
            echo "  ⓘ Systemd user bus not available — skipping service setup"
            echo "  ⓘ Run manually: node $vt_dir/dist/cli.js --port ${vt_port}"
          fi
        fi
        tenai_track tool_installed --tool "vibetunnel" --pkg-mgr "npm"
        echo "✓ VibeTunnel installed via npm"
      else
        echo "⚠ VibeTunnel install failed — check: Node.js 22.12+, build-essential, libpam0g-dev"
      fi
      ;;
    termux)
      echo "⚠ VibeTunnel does not support Termux"
      ;;
  esac
}

install_uv() {
  echo "── Installing uv package manager ──"

  if command -v uv &>/dev/null; then
    echo "✓ uv already installed: $(uv --version)"
    return
  fi

  curl -LsSf https://astral.sh/uv/install.sh | sh
  tenai_track tool_installed --tool "uv" --pkg-mgr "curl"

  # Ensure uv is on PATH for this session
  export PATH="$HOME/.local/bin:$PATH"
  echo "✓ uv installed: $(uv --version)"
}

install_python_env() {
  echo "── Setting up Python environment ──"

  if ! command -v python3 &>/dev/null; then
    case "$OS_TYPE" in
      linux)
        sudo_prompt "apt-get install python3 python3-venv"
        sudo apt-get install -y python3 python3-venv
        tenai_track tool_installed --tool "python3" --pkg-mgr "apt"
        tenai_track tool_installed --tool "python3-venv" --pkg-mgr "apt"
        ;;
      mac)
        brew install python3
        tenai_track tool_installed --tool "python3" --pkg-mgr "brew"
        ;;
      termux)
        pkg install -y python
        tenai_track tool_installed --tool "python" --pkg-mgr "pkg"
        ;;
    esac
  else
    echo "  ✓ Python already installed: $(python3 --version)"
  fi

  # Ensure uv is available
  install_uv

  # Install Hydra and dependencies into project venv
  local INFRA_DIR
  INFRA_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
  local VENV_DIR="$INFRA_DIR/.venv"
  if [[ ! -d "$VENV_DIR" ]]; then
    echo "  Creating project venv..."
    uv venv "$VENV_DIR"
  fi
  uv pip install -p "$VENV_DIR" hydra-core omegaconf python-dotenv

  echo "✓ Python environment ready"
}

install_mosh() {
  echo "── Installing mosh ──"
  local skip_name="mosh"
  if ! should_install "$skip_name"; then
    echo "  ⊘ Skipped (in SKIP_TOOLS)"
    return 0
  fi
  bash "$(dirname "$0")/mosh.sh"
}

install_symphony() {
  echo "── Installing Symphony Elixir ──"
  local skip_name="symphony"
  if ! should_install "$skip_name"; then
    echo "  ⊘ Skipped (in SKIP_TOOLS)"
    return 0
  fi
  local install_dir="${HOME}/symphony"
  if [[ -x "${install_dir}/bin/symphony" ]]; then
    echo "  ✓ Symphony already installed at ${install_dir}"
    return 0
  fi
  # Requires: git, mise (for Erlang/Elixir)
  if ! command -v git &>/dev/null; then
    echo "  ⚠ git not found — cannot install Symphony"
    return 1
  fi
  echo "  → Cloning openai/symphony..."
  env GIT_CONFIG_GLOBAL=/dev/null git clone --depth 1 https://github.com/openai/symphony.git "$install_dir" 2>/dev/null || {
    echo "  → Already cloned, pulling latest..."
    cd "$install_dir" && env GIT_CONFIG_GLOBAL=/dev/null git pull --ff-only 2>/dev/null || true
  }
  # Build if mise is available
  if command -v mise &>/dev/null; then
    echo "  → Building with mise + mix..."
    cd "${install_dir}/elixir" && \
      mise trust 2>/dev/null || true && \
      mise install 2>/dev/null || true && \
      mise exec -- mix setup 2>/dev/null && \
      mise exec -- mix build 2>/dev/null && \
      tenai_track dir_created --path "$install_dir" && \
      echo "  ✓ Symphony built successfully" || \
      echo "  ⚠ Build failed — mise + Elixir may need manual setup"
  else
    echo "  ⚠ mise not installed — run 'curl https://mise.run | sh' then re-run"
    echo "  Symphony cloned to ${install_dir} but not built"
  fi
}

install_gastown() {
  echo "── Installing Gastown ──"
  local skip_name="gastown"
  if ! should_install "$skip_name"; then
    echo "  ⊘ Skipped (in SKIP_TOOLS)"
    return 0
  fi
  if command -v gt &>/dev/null; then
    echo "  ✓ Gastown already installed"
    return 0
  fi
  local install_dir="${HOME}/gastown"
  if ! command -v git &>/dev/null; then
    echo "  ⚠ git not found — cannot install Gastown"
    return 1
  fi
  echo "  → Cloning steveyegge/gastown..."
  env GIT_CONFIG_GLOBAL=/dev/null git clone --depth 1 https://github.com/steveyegge/gastown.git "$install_dir" 2>/dev/null || {
    echo "  → Already cloned, pulling latest..."
    cd "$install_dir" && env GIT_CONFIG_GLOBAL=/dev/null git pull --ff-only 2>/dev/null || true
  }
  if [[ -x "${install_dir}/install.sh" ]]; then
    echo "  → Running install script..."
    cd "$install_dir" && bash install.sh 2>/dev/null && \
      tenai_track dir_created --path "$install_dir" && \
      echo "  ✓ Gastown installed" || \
      echo "  ⚠ Install script failed — check ${install_dir}/install.sh"
  else
    echo "  ⚠ No install.sh found in ${install_dir}"
  fi
}

# ── Tool selection (env-based include/exclude) ────────────────────────────────
# INSTALL_ONLY="claude_code,gemini_cli"  → only install these
# SKIP_TOOLS="vibetunnel,muxtree"         → skip these
# RESOLVED_SKIP_TOOLS from config         → merged with SKIP_TOOLS (additive)
# Default: install all tools
should_install() {
  local tool="$1"
  # If INSTALL_ONLY is set, only install tools in the list
  if [[ -n "${INSTALL_ONLY:-}" ]]; then
    # Strip spaces so "foo, bar" becomes "foo,bar"
    local only="${INSTALL_ONLY// /}"
    echo ",${only}," | grep -qi ",${tool}," && return 0 || return 1
  fi
  # Merge SKIP_TOOLS (.env) + RESOLVED_SKIP_TOOLS (config) — additive
  local merged_skip="${SKIP_TOOLS:-}"
  if [[ -n "${RESOLVED_SKIP_TOOLS:-}" ]]; then
    if [[ -n "$merged_skip" ]]; then
      merged_skip="${merged_skip},${RESOLVED_SKIP_TOOLS}"
    else
      merged_skip="${RESOLVED_SKIP_TOOLS}"
    fi
  fi
  if [[ -n "$merged_skip" ]]; then
    # Strip spaces so "vim, vibetunnel" becomes "vim,vibetunnel"
    merged_skip="${merged_skip// /}"
    echo ",${merged_skip}," | grep -qi ",${tool}," && return 1 || return 0
  fi
  return 0
}

# ── Run based on device type ──────────────────────────────────────────────────
should_install common_tools   && install_common_tools   || true
should_install gh             && install_gh             || true
should_install node           && install_node           || true
should_install python_env     && install_python_env     || true
should_install mosh           && install_mosh           || true

case "$OS_TYPE" in
  linux)
    should_install claude_code  && install_claude_code  || true
    should_install gemini_cli   && install_gemini_cli   || true
    should_install codex_cli    && install_codex_cli    || true
    should_install muxtree      && install_muxtree      || true
    should_install vibetunnel   && install_vibetunnel   || true
    should_install symphony     && install_symphony     || true
    should_install gastown      && install_gastown      || true
    ;;
  mac)
    should_install claude_code  && install_claude_code  || true
    should_install gemini_cli   && install_gemini_cli   || true
    should_install codex_cli    && install_codex_cli    || true
    should_install muxtree      && install_muxtree      || true
    should_install vibetunnel   && install_vibetunnel   || true
    should_install symphony     && install_symphony     || true
    should_install gastown      && install_gastown      || true
    ;;
  termux)
    should_install claude_code  && install_claude_code  || true
    should_install gemini_cli   && install_gemini_cli   || true
    should_install codex_cli    && install_codex_cli    || true
    ;;
  ish)
    should_install claude_code  && install_claude_code  || true
    should_install gemini_cli   && install_gemini_cli   || true
    ;;
  wsl)
    should_install claude_code  && install_claude_code  || true
    should_install gemini_cli   && install_gemini_cli   || true
    should_install codex_cli    && install_codex_cli    || true
    should_install muxtree      && install_muxtree      || true
    should_install vibetunnel   && install_vibetunnel   || true
    should_install symphony     && install_symphony     || true
    should_install gastown      && install_gastown      || true
    ;;
esac

echo "✓ All tools installed for ${OS_TYPE}"

