#!/bin/bash
# scripts/install/mosh.sh — install mosh on any platform
set -euo pipefail

source "$(dirname "$0")/../detect.sh"

install_mosh() {
  echo "── Installing Mosh on ${OS_TYPE} ──"

  if command -v mosh &>/dev/null; then
    echo "✓ Mosh already installed: $(mosh --version 2>&1 | head -1)"
    return
  fi

  case "$OS_TYPE" in
    linux)
      sudo apt-get update -qq
      sudo apt-get install -y mosh
      # Generate locale if missing
      sudo locale-gen en_US.UTF-8 2>/dev/null || true
      sudo update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 2>/dev/null || true
      ;;
    mac)
      brew install mosh
      ;;
    termux)
      pkg install mosh -y
      ;;
    ish)
      apk add mosh
      ;;
  esac

  echo "✓ Mosh installed: $(mosh --version 2>&1 | head -1)"
}

verify_mosh_server() {
  if [[ "$OS_TYPE" == "linux" || "$OS_TYPE" == "mac" ]]; then
    if ! command -v mosh-server &>/dev/null; then
      echo "ERROR: mosh-server not found after install" >&2
      exit 1
    fi
    echo "✓ mosh-server: $(which mosh-server)"
  fi
}

install_mosh
verify_mosh_server
