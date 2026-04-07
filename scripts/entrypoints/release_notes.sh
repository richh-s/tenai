#!/bin/bash
# scripts/entrypoints/release_notes.sh — Generate release notes from git history
#
# Analyzes commits between the last tag and HEAD, categorizes by conventional
# commit prefixes, and saves to .release_notes/{next_version}.md
#
# Usage:
#   bash scripts/entrypoints/release_notes.sh              # default: next patch
#   bash scripts/entrypoints/release_notes.sh MINOR=1      # next minor version
#   bash scripts/entrypoints/release_notes.sh FROM=v0.0.1  # from specific tag
#   bash scripts/entrypoints/release_notes.sh MESSAGE="summary"
#   bash scripts/entrypoints/release_notes.sh FORCE=1      # regenerate existing
#
# Via Makefile:
#   make release-notes                  # next patch notes
#   make release-notes MINOR=1          # next minor notes
#   make release-notes FORCE=1          # regenerate
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$INFRA_DIR"

# ── Parse arguments ──────────────────────────────────────────────────────────
FROM=""
TO="HEAD"
MESSAGE=""
FORCE="0"
BUMP_MAJOR="${MAJOR:-0}"
BUMP_MINOR="${MINOR:-0}"
BUMP_PATCH="${PATCH:-0}"

for arg in "$@"; do
  case "$arg" in
    FROM=*)    FROM="${arg#FROM=}" ;;
    TO=*)      TO="${arg#TO=}" ;;
    MESSAGE=*) MESSAGE="${arg#MESSAGE=}" ;;
    FORCE=*)   FORCE="${arg#FORCE=}" ;;
    MAJOR=*)   BUMP_MAJOR="${arg#MAJOR=}" ;;
    MINOR=*)   BUMP_MINOR="${arg#MINOR=}" ;;
    PATCH=*)   BUMP_PATCH="${arg#PATCH=}" ;;
    *)         ;;
  esac
done

# Default to PATCH if nothing specified
if [[ "$BUMP_MAJOR" == "0" && "$BUMP_MINOR" == "0" && "$BUMP_PATCH" == "0" ]]; then
  BUMP_PATCH=1
fi

# Get last tag if FROM not specified — use git tag -l (not describe)
# because release tags live on isolated branches, not ancestors of HEAD
if [ -z "$FROM" ]; then
  FROM=$(git tag -l 'v*' 2>/dev/null | sort -V | tail -1 || echo "")
fi

# ── Compute next version ────────────────────────────────────────────────────
LAST_TAG="${FROM:-v0.0.0}"
VERSION="${LAST_TAG#v}"
IFS='.' read -r CUR_M CUR_m CUR_p <<< "$VERSION"
CUR_M="${CUR_M:-0}"; CUR_m="${CUR_m:-0}"; CUR_p="${CUR_p:-0}"

if [[ "$BUMP_MAJOR" != "0" ]]; then
  NEXT_VERSION="v$(( CUR_M + 1 )).0.0"
elif [[ "$BUMP_MINOR" != "0" ]]; then
  NEXT_VERSION="v${CUR_M}.$(( CUR_m + 1 )).0"
else
  NEXT_VERSION="v${CUR_M}.${CUR_m}.$(( CUR_p + 1 ))"
fi

# Build git log range — handle tags on isolated release branches
# Release tags fork off main → the tag itself isn't an ancestor of HEAD,
# but its parent commit IS. Use the parent for the range.
if [ -n "$FROM" ]; then
  TAG_PARENT=$(git rev-parse "${FROM}^1" 2>/dev/null || echo "")
  if [ -n "$TAG_PARENT" ] && git merge-base --is-ancestor "$TAG_PARENT" "${TO}" 2>/dev/null; then
    RANGE="${TAG_PARENT}..${TO}"
  elif git merge-base --is-ancestor "$FROM" "${TO}" 2>/dev/null; then
    RANGE="${FROM}..${TO}"
  else
    RANGE="${TO}"
  fi
  SINCE_LABEL="since ${FROM}"
else
  RANGE="$TO"
  SINCE_LABEL="(all commits)"
fi

# ── Check idempotency ────────────────────────────────────────────────────────
NOTES_DIR="$INFRA_DIR/.release_notes"
mkdir -p "$NOTES_DIR"
NOTES_FILE="$NOTES_DIR/${NEXT_VERSION}.md"

if [ -f "$NOTES_FILE" ] && [ "$FORCE" != "1" ]; then
  echo "✓ Release notes already exist: ${NOTES_FILE}"
  echo "  Use FORCE=1 to regenerate."
  echo ""
  echo "  Edit:    \$EDITOR ${NOTES_FILE}"
  echo "  Release: make tagged-release $([ "$BUMP_MAJOR" != "0" ] && echo "MAJOR=1" || ([ "$BUMP_MINOR" != "0" ] && echo "MINOR=1" || echo "PATCH=1")) AUTO_MESSAGE=1"
  exit 0
fi

# ── Collect commits ──────────────────────────────────────────────────────────
COMMITS=$(git log "$RANGE" --pretty=format:"%h|%s" --no-merges 2>/dev/null || echo "")

if [ -z "$COMMITS" ]; then
  echo "No commits found ${SINCE_LABEL}."
  exit 0
fi

# ── Categorize by conventional commit prefix ─────────────────────────────────
FEATURES=""
FIXES=""
IMPROVEMENTS=""
DOCS=""
OTHER=""

while IFS='|' read -r hash subject; do
  [ -z "$hash" ] && continue
  case "$subject" in
    feat:*|feat\(*) FEATURES="${FEATURES}\n- ${subject#feat: } (\`${hash}\`)" ;;
    fix:*|fix\(*)   FIXES="${FIXES}\n- ${subject#fix: } (\`${hash}\`)" ;;
    refactor:*|perf:*|chore:*|style:*|ci:*)
                    IMPROVEMENTS="${IMPROVEMENTS}\n- ${subject} (\`${hash}\`)" ;;
    docs:*|doc:*)   DOCS="${DOCS}\n- ${subject#docs: } (\`${hash}\`)" ;;
    revert:*)       FIXES="${FIXES}\n- ${subject} (\`${hash}\`)" ;;
    *)              OTHER="${OTHER}\n- ${subject} (\`${hash}\`)" ;;
  esac
done <<< "$COMMITS"

# ── Compute stats ────────────────────────────────────────────────────────────
COMMIT_COUNT=$(echo "$COMMITS" | wc -l | xargs)
FILES_CHANGED=$(git diff --stat "$RANGE" 2>/dev/null | tail -1 || echo "")
AUTHORS=$(git log "$RANGE" --pretty=format:"%an" --no-merges 2>/dev/null | sort -u | paste -sd ", " -)

# ── Write release notes ──────────────────────────────────────────────────────
{
  echo "# Release Notes — ${NEXT_VERSION}"
  echo ""
  echo "**${COMMIT_COUNT} commits** ${SINCE_LABEL} ($(date +%Y-%m-%d))"
  [ -n "$FILES_CHANGED" ] && echo "  ${FILES_CHANGED}"
  [ -n "$AUTHORS" ] && echo "  Contributors: ${AUTHORS}"
  echo ""

  if [ -n "$MESSAGE" ]; then
    echo "## Summary"
    echo ""
    echo "$MESSAGE"
    echo ""
  fi

  if [ -n "$FEATURES" ]; then
    echo "## ✨ New Features"
    echo -e "$FEATURES"
    echo ""
  fi

  if [ -n "$FIXES" ]; then
    echo "## 🐛 Bug Fixes"
    echo -e "$FIXES"
    echo ""
  fi

  if [ -n "$IMPROVEMENTS" ]; then
    echo "## 🔧 Improvements"
    echo -e "$IMPROVEMENTS"
    echo ""
  fi

  if [ -n "$DOCS" ]; then
    echo "## 📖 Documentation"
    echo -e "$DOCS"
    echo ""
  fi

  if [ -n "$OTHER" ]; then
    echo "## 📦 Other"
    echo -e "$OTHER"
    echo ""
  fi
} > "$NOTES_FILE"

# Determine bump label for usage hint
BUMP_LABEL="PATCH=1"
[[ "$BUMP_MAJOR" != "0" ]] && BUMP_LABEL="MAJOR=1"
[[ "$BUMP_MINOR" != "0" ]] && BUMP_LABEL="MINOR=1"

echo "✓ Release notes saved to: ${NOTES_FILE}"
echo ""
echo "  Review:  cat ${NOTES_FILE}"
echo "  Edit:    \$EDITOR ${NOTES_FILE}"
echo "  Release: make tagged-release ${BUMP_LABEL} AUTO_MESSAGE=1"
