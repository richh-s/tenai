#!/bin/bash
# scripts/entrypoints/tagged_release.sh — Create a clean tagged release
#
# Creates an isolated worktree, sanitizes config (removes real devices/orgs),
# commits, tags with semver, pushes the tag, and destroys the worktree.
# Main branch retains your real device configuration.
#
# Usage (via Makefile):
#   make tagged-release PATCH=1                          # v0.0.0 → v0.0.1
#   make tagged-release MINOR=1 AUTO_MESSAGE=1           # auto-use .release_notes/
#   make tagged-release MAJOR=1 MESSAGE="big rewrite"    # inline message
#   make tagged-release PATCH=1 MESSAGE_FILE=notes.md    # from file

# macOS /bin/bash is 3.2 — re-exec with bash 4+ (Homebrew) if available.
# This script uses ${var,,} (bash 4+ lowercase expansion).
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  if [[ -x "/opt/homebrew/bin/bash" ]]; then
    exec /opt/homebrew/bin/bash "$0" "$@"
  elif [[ -x "/usr/local/bin/bash" ]]; then
    exec /usr/local/bin/bash "$0" "$@"
  fi
  echo "This script requires bash 4+. Install: brew install bash" >&2
  exit 1
fi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$INFRA_DIR"

PYTHON="${INFRA_DIR}/.venv/bin/python3"
[[ -x "$PYTHON" ]] || PYTHON="$(command -v python3)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
err()   { echo -e "${RED}✗${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}──${NC} $* ${CYAN}──${NC}"; }

# ── Parse increment flags ─────────────────────────────────────────────────────
BUMP_MAJOR="${MAJOR:-0}"
BUMP_MINOR="${MINOR:-0}"
BUMP_PATCH="${PATCH:-0}"

RELEASE_MSG="${MESSAGE:-}"
AUTO_MESSAGE="${AUTO_MESSAGE:-0}"
MESSAGE_FILE="${MESSAGE_FILE:-}"

# Default to PATCH if nothing specified
if [[ "$BUMP_MAJOR" == "0" && "$BUMP_MINOR" == "0" && "$BUMP_PATCH" == "0" ]]; then
  BUMP_PATCH=1
fi

# ── Get last tag ──────────────────────────────────────────────────────────────
step "Getting current version"
LAST_TAG=$(git tag -l 'v*' 2>/dev/null | sort -V | tail -1 || echo "v0.0.0")
[ -z "$LAST_TAG" ] && LAST_TAG="v0.0.0"
info "Last tag: ${LAST_TAG}"

# Parse version numbers
VERSION="${LAST_TAG#v}"
IFS='.' read -r CUR_MAJOR CUR_MINOR CUR_PATCH <<< "$VERSION"
CUR_MAJOR="${CUR_MAJOR:-0}"
CUR_MINOR="${CUR_MINOR:-0}"
CUR_PATCH="${CUR_PATCH:-0}"

# Compute next version
if [[ "$BUMP_MAJOR" != "0" ]]; then
  NEXT_MAJOR=$((CUR_MAJOR + 1))
  NEXT_MINOR=0
  NEXT_PATCH=0
elif [[ "$BUMP_MINOR" != "0" ]]; then
  NEXT_MAJOR=$CUR_MAJOR
  NEXT_MINOR=$((CUR_MINOR + 1))
  NEXT_PATCH=0
else
  NEXT_MAJOR=$CUR_MAJOR
  NEXT_MINOR=$CUR_MINOR
  NEXT_PATCH=$((CUR_PATCH + 1))
fi

NEXT_VERSION="v${NEXT_MAJOR}.${NEXT_MINOR}.${NEXT_PATCH}"
info "Next version: ${BOLD}${NEXT_VERSION}${NC}"

# ── Resolve release notes file ─────────────────────────────────────────────
NOTES_FILE=""

if [ -n "$MESSAGE_FILE" ]; then
  # Explicit file path
  if [ ! -f "$MESSAGE_FILE" ]; then
    err "MESSAGE_FILE not found: $MESSAGE_FILE"
    exit 1
  fi
  NOTES_FILE="$MESSAGE_FILE"
  info "Using release notes from: ${NOTES_FILE}"
elif [[ "$AUTO_MESSAGE" == "1" ]]; then
  # Check .release_notes/ for pre-generated notes
  STORED_NOTES="$INFRA_DIR/.release_notes/${NEXT_VERSION}.md"
  if [ -f "$STORED_NOTES" ]; then
    NOTES_FILE="$STORED_NOTES"
    info "Using pre-generated notes: ${NOTES_FILE}"
  else
    # Auto-generate
    step "Generating release notes"
    bash "$INFRA_DIR/scripts/entrypoints/release_notes.sh" \
      FROM="$LAST_TAG" MESSAGE="$RELEASE_MSG" FORCE=1 2>&1 | sed 's/^/  /'
    STORED_NOTES="$INFRA_DIR/.release_notes/${NEXT_VERSION}.md"
    [ -f "$STORED_NOTES" ] && NOTES_FILE="$STORED_NOTES"
  fi
fi

# Show preview
if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
  step "Release notes preview"
  echo ""
  cat "$NOTES_FILE"
  echo ""
elif [ -n "$RELEASE_MSG" ]; then
  step "Release message"
  echo "  $RELEASE_MSG"
  echo ""
fi

# ── Confirm ───────────────────────────────────────────────────────────────────
read -rp "  Create release ${NEXT_VERSION}? [y/N] " confirm
if [[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]]; then
  echo "  Aborted."
  exit 0
fi

# ── Create temporary worktree ─────────────────────────────────────────────────
step "Creating release worktree"
RELEASE_DIR="/tmp/tenai-release-${NEXT_VERSION}"
RELEASE_BRANCH="release/${NEXT_VERSION}"

# Clean up any previous attempt
git worktree remove "$RELEASE_DIR" --force 2>/dev/null || true
git branch -D "$RELEASE_BRANCH" 2>/dev/null || true

git worktree add "$RELEASE_DIR" -b "$RELEASE_BRANCH" HEAD
info "Worktree created at ${RELEASE_DIR}"

# ── Sanitize config in worktree ───────────────────────────────────────────────
step "Sanitizing config for distribution"
cd "$RELEASE_DIR"

# Clear devices, reset tailnet, keep example entries
"$PYTHON" - "$RELEASE_DIR/config/defaults.yaml" <<'PYEOF'
import sys, yaml

config_path = sys.argv[1]
with open(config_path) as f:
    config = yaml.safe_load(f) or {}

# Reset tailnet to placeholder
config.setdefault("tailscale", {})["tailnet"] = "yourname@"

# Clear real devices, keep only commented examples
config["tailscale"]["devices"] = {}

# Reset organizations to single example
config["organizations"] = {
    "my-org": {
        "github_url": "github.com",
        "ssh_host_alias": "github-my-org",
        "ssh_key": "~/.ssh/tenai-git-ssh-key",
        "default_branch": "main",
    }
}

with open(config_path, "w") as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

print("✓ Config sanitized: cleared devices, reset tailnet, example org only")
PYEOF

# Remove .env (secrets) — keep .env.example
rm -f "$RELEASE_DIR/.env"

# Remove backup directory if present
rm -rf "$RELEASE_DIR/.backup"

# Remove any SQLite databases
rm -f "$RELEASE_DIR"/*.db "$RELEASE_DIR"/.tenai/*.db 2>/dev/null || true

info "Sanitization complete"

# ── Commit and tag ────────────────────────────────────────────────────────────
step "Committing and tagging"
cd "$RELEASE_DIR"
git add -A
git commit -m "release: ${NEXT_VERSION} — clean config for distribution

Sanitized for public release:
- Cleared all device entries from defaults.yaml
- Reset tailnet to placeholder
- Set example organization
- Removed .env secrets"

# Build tag message with release notes
TAG_MSG="Release ${NEXT_VERSION}"
if [ -n "$RELEASE_MSG" ]; then
  TAG_MSG="${TAG_MSG}\n\n${RELEASE_MSG}"
fi
if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
  TAG_MSG="${TAG_MSG}\n\n$(cat "$NOTES_FILE")"
fi

echo -e "$TAG_MSG" | git tag -a "$NEXT_VERSION" -F -
info "Tagged: ${NEXT_VERSION}"

# ── Push tag ──────────────────────────────────────────────────────────────────
step "Pushing tag to origin"
git push origin "$NEXT_VERSION"
info "Pushed tag ${NEXT_VERSION} to GitHub"

# ── Cleanup ───────────────────────────────────────────────────────────────────
step "Cleaning up"
cd "$INFRA_DIR"
git worktree remove "$RELEASE_DIR" --force
git branch -D "$RELEASE_BRANCH" 2>/dev/null || true
info "Removed temporary worktree and branch"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  ✓ Release ${NEXT_VERSION} published!${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  Tag:    ${NEXT_VERSION}"
echo "  GitHub: https://github.com/$(git remote get-url origin 2>/dev/null | sed 's|.*[:/]\([^/]*/[^/]*\)\.git$|\1|;s|.*[:/]\([^/]*/[^/]*\)$|\1|')/releases/tag/${NEXT_VERSION}"
echo ""
