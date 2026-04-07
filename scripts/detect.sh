#!/bin/bash
# scripts/detect.sh — detect OS, shell, package manager, architecture
# Source this file: source scripts/detect.sh
# After sourcing, variables are available:
#   OS_TYPE, PKG_MGR, SHELL_RC, IS_TERMUX, DEVICE_USER, SHELL_NAME, SHELL_VERSION
#   ARCH, RUNNING_UNDER_ROSETTA, NATIVE_BASH

# ── Rosetta / Architecture Hardening ──────────────────────────────────────────
# On macOS, `uname -m` reports the *process* architecture, not the hardware.
# If a script is launched by an x86_64 bash (e.g. old Intel Homebrew bash at
# /usr/local/bin/bash via #!/usr/bin/env bash), uname -m lies and says x86_64
# even on an Apple Silicon (arm64) machine. This breaks `brew install` because
# ARM Homebrew (/opt/homebrew) refuses to run under Rosetta 2.
#
# Note: #!/bin/bash always resolves to /bin/bash (native on macOS).
# It's #!/usr/bin/env bash that searches PATH and can pick up Intel Homebrew bash.
#
# Fix: use `sysctl -n hw.optional.arm64` on macOS — it always returns the real
# hardware. We also wrap `brew` and `npm` to force native ARM execution when
# Rosetta is detected, so every downstream script gets correct behavior.
# ──────────────────────────────────────────────────────────────────────────────

detect_environment() {
  # ── Architecture (Rosetta-safe) ──────────────────────────────────────────────
  if [[ "$(uname)" == "Darwin" ]]; then
    # On macOS, check hw.optional.arm64 (real hardware) and sysctl.proc_translated
    # (Rosetta indicator). hw.machine and uname -m both report the *process*
    # architecture, so they lie under Rosetta.
    local _is_arm64_hw _is_translated
    _is_arm64_hw="$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)"
    _is_translated="$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)"

    if [[ "$_is_arm64_hw" == "1" ]]; then
      export ARCH="arm64"
    else
      export ARCH="$(uname -m 2>/dev/null || echo 'x86_64')"
    fi
  else
    export ARCH="$(uname -m 2>/dev/null || echo 'unknown')"
  fi

  # ── Rosetta 2 detection ────────────────────────────────────────────────────
  export RUNNING_UNDER_ROSETTA=false
  if [[ "$(uname)" == "Darwin" ]]; then
    local _is_translated_check
    _is_translated_check="$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)"
    if [[ "$_is_translated_check" == "1" ]]; then
      export RUNNING_UNDER_ROSETTA=true
      echo "⚠ Rosetta 2 detected (process=x86_64, hardware=arm64). Wrapping brew/npm for native execution." >&2
    fi
  fi

  # ── Best native bash detection ─────────────────────────────────────────────
  # Detect the best native ARM bash for future bash 4+ scripts.
  # Priority: ARM Homebrew bash (/opt/homebrew/bin/bash) > system bash (/bin/bash)
  export NATIVE_BASH="/bin/bash"
  if [[ "$(uname)" == "Darwin" ]] && [[ "$ARCH" == "arm64" ]]; then
    if [[ -x "/opt/homebrew/bin/bash" ]]; then
      export NATIVE_BASH="/opt/homebrew/bin/bash"
    fi
  fi

  # ── Python resolution (always prefer .venv) ────────────────────────────────
  # All Python deps (pyyaml, etc.) live in .venv. System python3 may not have
  # them. Scripts must use $PYTHON instead of bare python3.
  local _infra_dir
  _infra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || _infra_dir="."
  if [[ -x "${_infra_dir}/.venv/bin/python3" ]]; then
    export PYTHON="${_infra_dir}/.venv/bin/python3"
  elif [[ -n "${PYTHON:-}" ]] && [[ -x "${PYTHON}" ]]; then
    : # Keep existing PYTHON from env (e.g. Makefile passes it)
  else
    export PYTHON="$(command -v python3 2>/dev/null || echo python3)"
  fi

  # ── Intel Homebrew detection (recommend upgrade) ───────────────────────────
  if [[ "$(uname)" == "Darwin" ]] && [[ "$ARCH" == "arm64" ]]; then
    if [[ -x "/usr/local/bin/brew" ]] && [[ -x "/opt/homebrew/bin/brew" ]]; then
      echo "⚠ Intel Homebrew (/usr/local/bin/brew) detected alongside ARM Homebrew (/opt/homebrew/)." >&2
      echo "  Consider removing Intel Homebrew to avoid Rosetta issues:" >&2
      echo "    /usr/local/bin/brew list    # check what's installed" >&2
      echo "    Reinstall needed formulae via /opt/homebrew/bin/brew" >&2
    elif [[ -x "/usr/local/bin/brew" ]] && [[ ! -x "/opt/homebrew/bin/brew" ]]; then
      echo "⚠ Intel Homebrew (/usr/local/bin/brew) detected on ARM Mac." >&2
      echo "  Recommend installing ARM Homebrew for native Apple Silicon performance:" >&2
      echo "    /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"" >&2
      echo "  Then add to your shell: eval \"\$(/opt/homebrew/bin/brew shellenv)\"" >&2
    fi
  fi

  # ── brew / npm wrappers (Rosetta workaround) ───────────────────────────────
  # When running under Rosetta, wrap brew and npm to force native ARM execution.
  # This ensures `brew install` and `npm install -g` produce arm64 binaries.
  if [[ "${RUNNING_UNDER_ROSETTA}" == "true" ]]; then
    if [[ -x "/opt/homebrew/bin/brew" ]]; then
      brew() { arch -arm64 /opt/homebrew/bin/brew "$@"; }
      export -f brew
    fi
    # Wrap npm to force arm64 — prevents x86_64 native modules
    if command -v npm &>/dev/null; then
      _original_npm="$(command -v npm)"
      npm() { arch -arm64 "$_original_npm" "$@"; }
      export -f npm
    fi
  fi

  # ── Shell info ────────────────────────────────────────────────────────────
  if [[ -n "${BASH_VERSION:-}" ]]; then
    export SHELL_NAME="bash"
    export SHELL_VERSION="$BASH_VERSION"
  elif [[ -n "${ZSH_VERSION:-}" ]]; then
    export SHELL_NAME="zsh"
    export SHELL_VERSION="$ZSH_VERSION"
  else
    export SHELL_NAME="$(basename "${SHELL:-sh}" 2>/dev/null || echo 'sh')"
    export SHELL_VERSION="unknown"
  fi

  # ── Login shell detection (for accurate diagnostics) ───────────────────────
  local _login_shell=""
  if [[ "$(uname)" == "Darwin" ]]; then
    _login_shell="$(dscl . -read /Users/"$(whoami)" UserShell 2>/dev/null | awk '{print $2}')" || _login_shell="$SHELL"
  else
    _login_shell="${SHELL:-/bin/sh}"
  fi

  # ── Termux (Android) ──────────────────────────────────────────────────────
  if [[ -n "${TERMUX_VERSION:-}" ]] || [[ -d "/data/data/com.termux" ]]; then
    export OS_TYPE="termux"
    export PKG_MGR="pkg"
    export SHELL_RC="$HOME/.bashrc"
    export IS_TERMUX=true
    export DEVICE_USER="$(whoami)"
    export MOSH_BIND_FLAG=""
    export PREFIX_DIR="$PREFIX"

  # ── macOS ──────────────────────────────────────────────────────────────────
  elif [[ "$(uname)" == "Darwin" ]]; then
    export OS_TYPE="mac"
    export PKG_MGR="brew"
    # Detect login shell (not $SHELL which may be bash under make/agents)
    local login_shell
    login_shell="$(dscl . -read /Users/"$(whoami)" UserShell 2>/dev/null | awk '{print $2}')" || login_shell="$SHELL"
    if [[ "$login_shell" == *"zsh"* ]] || [[ -f "$HOME/.zshrc" ]]; then
      export SHELL_RC="$HOME/.zshrc"
    else
      export SHELL_RC="$HOME/.bashrc"
    fi
    export IS_TERMUX=false
    export DEVICE_USER="$(whoami)"
    export MOSH_BIND_FLAG=""
    export PREFIX_DIR="/usr/local"

  # ── iSH (Alpine Linux on iOS) ────────────────────────────────────────────
  elif [[ -f "/proc/ish/version" ]] || { [[ -f "/etc/alpine-release" ]] && [[ ! -d "/data/data/com.termux" ]]; }; then
    export OS_TYPE="ish"
    export PKG_MGR="apk"
    export SHELL_RC="$HOME/.profile"
    export IS_TERMUX=false
    export DEVICE_USER="$(whoami)"
    export MOSH_BIND_FLAG=""
    export PREFIX_DIR="/usr"

  # ── Native Windows (Git Bash / MSYS / Cygwin) ─────────────────────────────
  elif [[ "$(uname -s)" == MINGW* ]] || [[ "$(uname -s)" == MSYS* ]] || [[ "$(uname -s)" == CYGWIN* ]]; then
    export OS_TYPE="windows_native"
    export PKG_MGR=""
    export SHELL_RC="$HOME/.bashrc"
    export IS_TERMUX=false
    export DEVICE_USER="$(whoami)"
    export MOSH_BIND_FLAG=""
    export PREFIX_DIR="/usr"
    echo "" >&2
    echo "⚠ Native Windows detected ($(uname -s))" >&2
    echo "  tenai-infra requires WSL2 (Windows Subsystem for Linux) on Windows." >&2
    echo "" >&2
    echo "  To set up WSL2:" >&2
    echo "    1. Open PowerShell as Administrator" >&2
    echo "    2. Run: wsl --install" >&2
    echo "    3. Restart your computer" >&2
    echo "    4. Open Ubuntu from Start menu" >&2
    echo "    5. Clone this repo inside WSL and run: make setup" >&2
    echo "" >&2
    echo "  For initial bootstrap (before WSL):" >&2
    echo "    powershell -File scripts/install/bootstrap_windows.ps1" >&2
    echo "" >&2

  # ── WSL2 (Windows Subsystem for Linux) ──────────────────────────────────
  elif [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ -f "/proc/sys/fs/binfmt_misc/WSLInterop" ]]; then
    export OS_TYPE="wsl"
    if command -v apt &>/dev/null; then
      export PKG_MGR="apt"
    elif command -v apk &>/dev/null; then
      export PKG_MGR="apk"
    fi
    export SHELL_RC="$HOME/.bashrc"
    export IS_TERMUX=false
    export DEVICE_USER="$(whoami)"
    export MOSH_BIND_FLAG=""
    export PREFIX_DIR="/usr"

  # ── Linux (server) ────────────────────────────────────────────────────────
  elif [[ "$(uname)" == "Linux" ]]; then
    export OS_TYPE="linux"
    if command -v apt &>/dev/null; then
      export PKG_MGR="apt"
    elif command -v yum &>/dev/null; then
      export PKG_MGR="yum"
    elif command -v dnf &>/dev/null; then
      export PKG_MGR="dnf"
    elif command -v pacman &>/dev/null; then
      export PKG_MGR="pacman"
    fi
    export SHELL_RC="$HOME/.bashrc"
    export IS_TERMUX=false
    export DEVICE_USER="$(whoami)"
    # get tailscale IP for mosh bind
    if command -v tailscale &>/dev/null; then
      export TAILSCALE_IP="$(tailscale ip -4 2>/dev/null)"
      export MOSH_BIND_FLAG="--bind-server=${TAILSCALE_IP}"
    else
      export MOSH_BIND_FLAG=""
    fi
    export PREFIX_DIR="/usr"
  else
    # Graceful fallback instead of hard exit
    export OS_TYPE="unknown"
    export PKG_MGR=""
    export SHELL_RC="$HOME/.bashrc"
    export IS_TERMUX=false
    export DEVICE_USER="$(whoami)"
    export MOSH_BIND_FLAG=""
    export PREFIX_DIR="/usr"
    echo "WARNING: Unknown OS: $(uname). Defaulting to generic settings." >&2
  fi

  # ── Diagnostic output ──────────────────────────────────────────────────────
  local _login_info=""
  if [[ "$(uname)" == "Darwin" ]] && [[ -n "$_login_shell" ]]; then
    _login_info=" login=$(basename "$_login_shell" 2>/dev/null)"
  fi
  local _rosetta_info=""
  if [[ "${RUNNING_UNDER_ROSETTA}" == "true" ]]; then
    _rosetta_info=" ROSETTA=yes"
  fi
  echo "✓ Detected: OS=${OS_TYPE} PKG=${PKG_MGR:-n/a} SHELL=${SHELL_NAME}/${SHELL_VERSION}${_login_info} ARCH=${ARCH}${_rosetta_info} RC=${SHELL_RC} USER=${DEVICE_USER}" >&2
}

# Auto-run if sourced — but only once per shell session.
# Subsequent sources (from subshells or other scripts) are no-ops:
# all exported variables are already in the environment, so callers
# still have OS_TYPE, PKG_MGR, PYTHON, etc. without re-printing the diagnostic.
if [[ -z "${_TENAI_DETECTED:-}" ]]; then
  detect_environment
  export _TENAI_DETECTED=1
fi
