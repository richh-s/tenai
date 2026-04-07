#!/bin/bash
# scripts/configure/detect_remote.sh — Detect OS, shell, and capabilities on a remote device
#
# Usage:
#   eval $(bash scripts/configure/detect_remote.sh user@host [-p port] [-i key])
#
# Outputs shell-evaluable variables:
#   REMOTE_OS_TYPE       linux|mac|wsl|termux|ish|windows
#   REMOTE_PKG_MGR       apt|yum|dnf|brew|pkg|apk|""
#   REMOTE_SHELL         bash|zsh|ash|sh|dash|fish
#   REMOTE_SHELL_VERSION e.g. "5.1.16"
#   REMOTE_ARCH          x86_64|aarch64|arm64|armv7l
#   REMOTE_HAS_TAILSCALE 0|1
#   REMOTE_HAS_DOCKER    0|1
#   REMOTE_HAS_NODE      0|1
#   REMOTE_HAS_PYTHON    0|1
#   REMOTE_HAS_GIT       0|1
#   REMOTE_HOSTNAME      remote hostname
#   REMOTE_DEVICE_TYPE   server|mac|android|ios_ish|windows|wsl (mapped type for config)
#
# Also prints human-readable summary to stderr.
set -euo pipefail

# ── Parse arguments ──────────────────────────────────────────────────────────
SSH_TARGET=""
SSH_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) SSH_ARGS+=("-p" "$2"); shift 2 ;;
    -i) SSH_ARGS+=("-i" "$2"); shift 2 ;;
    -o) SSH_ARGS+=("-o" "$2"); shift 2 ;;
    *)  SSH_TARGET="$1"; shift ;;
  esac
done

if [[ -z "$SSH_TARGET" ]]; then
  echo "echo 'Usage: detect_remote.sh user@host [-p port] [-i key]'" >&2
  exit 1
fi

# ── Detection payload ───────────────────────────────────────────────────────
# This script runs ON THE REMOTE DEVICE via SSH. It must be POSIX-compatible
# (ash/sh) since some devices (iSH) may not have bash. Use basic constructs.
DETECT_SCRIPT='
detect_os() {
  if [ -n "${TERMUX_VERSION:-}" ] || [ -d "/data/data/com.termux" ]; then
    echo "termux"
  elif [ -f "/proc/ish/version" ]; then
    echo "ish"
  elif [ -f "/etc/alpine-release" ] && [ ! -d "/data/data/com.termux" ] && [ ! -f "/proc/ish/version" ]; then
    # Alpine Linux (could be iSH or regular Alpine)
    if grep -qi "ish" /proc/version 2>/dev/null; then
      echo "ish"
    else
      echo "linux"
    fi
  elif [ -n "${WSL_DISTRO_NAME:-}" ] || [ -f "/proc/sys/fs/binfmt_misc/WSLInterop" ]; then
    echo "wsl"
  elif [ "$(uname 2>/dev/null)" = "Darwin" ]; then
    echo "mac"
  elif [ "$(uname 2>/dev/null)" = "Linux" ]; then
    echo "linux"
  elif echo "$(uname -s 2>/dev/null)" | grep -qi "mingw\|msys\|cygwin"; then
    echo "windows"
  else
    echo "unknown"
  fi
}

detect_pkg_mgr() {
  if command -v apt >/dev/null 2>&1; then echo "apt"
  elif command -v pkg >/dev/null 2>&1 && [ -d "/data/data/com.termux" ]; then echo "pkg"
  elif command -v brew >/dev/null 2>&1; then echo "brew"
  elif command -v apk >/dev/null 2>&1; then echo "apk"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v yum >/dev/null 2>&1; then echo "yum"
  elif command -v pacman >/dev/null 2>&1; then echo "pacman"
  else echo ""
  fi
}

detect_shell() {
  # Get the actual running shell, not $SHELL which is the login shell
  local sh_name=""
  if [ -n "${BASH_VERSION:-}" ]; then
    sh_name="bash"
  elif [ -n "${ZSH_VERSION:-}" ]; then
    sh_name="zsh"
  else
    # Fallback: check $SHELL or /proc/self
    sh_name="$(basename "${SHELL:-sh}" 2>/dev/null || echo "sh")"
  fi
  echo "$sh_name"
}

detect_shell_version() {
  if [ -n "${BASH_VERSION:-}" ]; then
    echo "$BASH_VERSION"
  elif [ -n "${ZSH_VERSION:-}" ]; then
    echo "$ZSH_VERSION"
  elif command -v bash >/dev/null 2>&1; then
    bash --version 2>/dev/null | head -1 | sed "s/.*version \([0-9.]*\).*/\1/"
  else
    echo "unknown"
  fi
}

detect_arch() {
  local arch
  arch="$(uname -m 2>/dev/null || echo "unknown")"
  echo "$arch"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1 && echo "1" || echo "0"
}

OS_TYPE=$(detect_os)
PKG_MGR=$(detect_pkg_mgr)
SHELL_NAME=$(detect_shell)
SHELL_VER=$(detect_shell_version)
ARCH=$(detect_arch)
HOSTNAME_VAL=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")

# Map OS type to device type for config
case "$OS_TYPE" in
  linux)   DEVICE_TYPE="server" ;;
  mac)     DEVICE_TYPE="mac" ;;
  wsl)     DEVICE_TYPE="wsl" ;;
  termux)  DEVICE_TYPE="android" ;;
  ish)     DEVICE_TYPE="ios_ish" ;;
  windows) DEVICE_TYPE="windows" ;;
  *)       DEVICE_TYPE="server" ;;
esac

echo "REMOTE_OS_TYPE=\"${OS_TYPE}\""
echo "REMOTE_PKG_MGR=\"${PKG_MGR}\""
echo "REMOTE_SHELL=\"${SHELL_NAME}\""
echo "REMOTE_SHELL_VERSION=\"${SHELL_VER}\""
echo "REMOTE_ARCH=\"${ARCH}\""
echo "REMOTE_HAS_TAILSCALE=\"$(has_cmd tailscale)\""
echo "REMOTE_HAS_DOCKER=\"$(has_cmd docker)\""
echo "REMOTE_HAS_NODE=\"$(has_cmd node)\""
echo "REMOTE_HAS_PYTHON=\"$(has_cmd python3)\""
echo "REMOTE_HAS_GIT=\"$(has_cmd git)\""
echo "REMOTE_HOSTNAME=\"${HOSTNAME_VAL}\""
echo "REMOTE_DEVICE_TYPE=\"${DEVICE_TYPE}\""
'

# ── Execute remotely ─────────────────────────────────────────────────────────
OUTPUT=$(ssh "${SSH_ARGS[@]}" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
  "$SSH_TARGET" "sh -c '$DETECT_SCRIPT'" 2>/dev/null)

if [[ $? -ne 0 ]] || [[ -z "$OUTPUT" ]]; then
  echo "echo 'ERROR: Failed to detect remote system at ${SSH_TARGET}'" >&2
  echo "echo 'Check SSH connectivity: ssh ${SSH_ARGS[*]} ${SSH_TARGET} \"echo ok\"'" >&2
  exit 1
fi

# Print shell-evaluable output to stdout
echo "$OUTPUT"

# Print human-readable summary to stderr
eval "$OUTPUT"
echo "── Remote Detection: ${SSH_TARGET} ──" >&2
echo "  OS:        ${REMOTE_OS_TYPE} → ${REMOTE_DEVICE_TYPE}" >&2
echo "  Shell:     ${REMOTE_SHELL} ${REMOTE_SHELL_VERSION}" >&2
echo "  Arch:      ${REMOTE_ARCH}" >&2
echo "  Pkg mgr:   ${REMOTE_PKG_MGR:-none}" >&2
echo "  Hostname:  ${REMOTE_HOSTNAME}" >&2
echo "  Tailscale: $([ "$REMOTE_HAS_TAILSCALE" = "1" ] && echo "installed" || echo "not installed")" >&2
echo "  Docker:    $([ "$REMOTE_HAS_DOCKER" = "1" ] && echo "installed" || echo "not installed")" >&2
echo "  Node:      $([ "$REMOTE_HAS_NODE" = "1" ] && echo "installed" || echo "not installed")" >&2
echo "  Python3:   $([ "$REMOTE_HAS_PYTHON" = "1" ] && echo "installed" || echo "not installed")" >&2
echo "  Git:       $([ "$REMOTE_HAS_GIT" = "1" ] && echo "installed" || echo "not installed")" >&2
