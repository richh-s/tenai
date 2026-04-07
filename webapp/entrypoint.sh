#!/bin/sh
# Entrypoint: fix SSH permissions before starting the webapp.
# The host's ~/.ssh is mounted read-only at /ssh-host.
# We copy keys/config to the runtime user's ~/.ssh with correct permissions,
# and fix any path references from the host user's home.

set -e

# Determine SSH target directory (works for both root and non-root users)
SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Copy SSH files with correct ownership and permissions
if [ -d /ssh-host ]; then
  for f in /ssh-host/*; do
    [ -f "$f" ] || continue
    cp "$f" "$SSH_DIR/"
  done
  # Fix permissions
  chmod 600 "$SSH_DIR"/* 2>/dev/null || true
  chmod 644 "$SSH_DIR"/*.pub 2>/dev/null || true
  chmod 644 "$SSH_DIR"/known_hosts 2>/dev/null || true
  chmod 600 "$SSH_DIR"/config 2>/dev/null || true

  # Fix IdentityFile paths — replace any /home/*/. to current HOME
  if [ -f "$SSH_DIR/config" ]; then
    sed -i "s|/home/[^/]*/\\.ssh/|$SSH_DIR/|g" "$SSH_DIR/config"
    sed -i "s|/root/\\.ssh/|$SSH_DIR/|g" "$SSH_DIR/config"
  fi
fi

# Ensure DB directory exists with correct ownership
DB_DIR="$HOME/.tenai"
mkdir -p "$DB_DIR" 2>/dev/null || true
# If running entrypoint as root, fix ownership so appuser can write
if [ "$(id -u)" = "0" ] && id appuser >/dev/null 2>&1; then
  chown -R appuser:appuser "$DB_DIR" 2>/dev/null || true
fi

# Ensure Tailscale socket is readable (if mounted from host)
if [ -S /var/run/tailscale/tailscaled.sock ]; then
  chmod 666 /var/run/tailscale/tailscaled.sock 2>/dev/null || true
fi

# Load .env if present — parse KEY=VALUE lines safely
if [ -f /app/.env ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip comments and empty lines
    case "$line" in
      \#*|"") continue ;;
    esac
    # Only export lines that look like KEY=VALUE
    case "$line" in
      *=*)
        key="${line%%=*}"
        # Skip if key has spaces or is not a valid var name
        case "$key" in
          *[!A-Za-z0-9_]*) continue ;;
        esac
        export "$line"
        ;;
    esac
  done < /app/.env
fi

exec "$@"
