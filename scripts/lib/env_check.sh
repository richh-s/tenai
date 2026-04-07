#!/bin/bash
# scripts/lib/env_check.sh — Shared env validation functions
#
# Checks .env or .env.test for required and recommended keys.
# Used by onboard.sh for pre-flight env validation.
#
# Usage:
#   source scripts/lib/env_check.sh
#   check_required_env ".env" TAILSCALE_AUTH_KEY TAILSCALE_TAILNET
#   check_recommended_env ".env" GITHUB_TOKEN ANTHROPIC_API_KEY

# Check required env vars — returns newline-separated list of missing keys
# Exit code: 0 if all present, 1 if any missing
check_required_env() {
  local env_file="$1"
  shift
  local missing=""

  if [[ ! -f "$env_file" ]]; then
    # All keys are "missing" if the file doesn't exist
    for key in "$@"; do
      missing="${missing}${key}\n"
    done
    echo -e "$missing"
    return 1
  fi

  for key in "$@"; do
    local value
    value=$(grep "^${key}=" "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' || true)
    if [[ -z "$value" ]]; then
      missing="${missing}${key}\n"
    fi
  done

  if [[ -n "$missing" ]]; then
    echo -e "$missing"
    return 1
  fi
  return 0
}

# Check recommended env vars — prints warnings for missing keys
# Always returns 0 (warnings only, never fatal)
check_recommended_env() {
  local env_file="$1"
  shift
  local warn_fn="${WARN_FN:-echo}"

  if [[ ! -f "$env_file" ]]; then
    for key in "$@"; do
      $warn_fn "  Recommended key not set: $key"
    done
    return 0
  fi

  for key in "$@"; do
    local value
    value=$(grep "^${key}=" "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' || true)
    if [[ -z "$value" ]]; then
      case "$key" in
        GITHUB_TOKEN)
          $warn_fn "  $key not set — required if repo is private"
          ;;
        *)
          $warn_fn "  $key not set (optional)"
          ;;
      esac
    fi
  done
  return 0
}

# Get a value from an env file
get_env_value() {
  local env_file="$1"
  local key="$2"
  grep "^${key}=" "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' || true
}
