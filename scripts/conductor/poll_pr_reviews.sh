#!/bin/bash
# scripts/conductor/poll_pr_reviews.sh — Poll for PR reviews after push
#
# Usage:
#   bash scripts/conductor/poll_pr_reviews.sh [--pr <number>] [--timeout <seconds>]
#     [--interval <seconds>] [--exclude <login1,login2>] [--ntfy-topic <topic>]
#
# Polls a PR for new reviews using `gh api`. Forwards reviews to ntfy.sh
# and/or prints them to stdout. Useful for agent sessions after git push.
#
# Requires: gh (GitHub CLI, authenticated), jq, curl

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
PR_NUMBER=""
TIMEOUT=300     # 5 minutes
INTERVAL=30     # check every 30s
EXCLUDE_LOGINS=""
NTFY_TOPIC="${NTFY_TOPIC:-}"
VERBOSE=false

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)       PR_NUMBER="$2"; shift 2 ;;
    --timeout)  TIMEOUT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --exclude)  EXCLUDE_LOGINS="$2"; shift 2 ;;
    --ntfy-topic) NTFY_TOPIC="$2"; shift 2 ;;
    --verbose)  VERBOSE=true; shift ;;
    --help|-h)
      echo "Usage: poll_pr_reviews.sh [--pr <num>] [--timeout <sec>] [--interval <sec>]"
      echo "       [--exclude <login1,login2>] [--ntfy-topic <topic>]"
      echo ""
      echo "Polls a GitHub PR for reviews and forwards them to ntfy.sh."
      echo "Auto-detects PR number from current branch if not specified."
      echo ""
      echo "Options:"
      echo "  --pr         PR number (auto-detect from branch if omitted)"
      echo "  --timeout    Max seconds to wait (default: 300)"
      echo "  --interval   Seconds between polls (default: 30)"
      echo "  --exclude    Comma-separated logins to ignore"
      echo "  --ntfy-topic ntfy.sh topic (or set NTFY_TOPIC env var)"
      echo "  --verbose    Show debug output"
      exit 0
      ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ── Verify dependencies ───────────────────────────────────────────────────────
if ! command -v gh &>/dev/null; then
  echo "✗ gh CLI not found. Install: https://cli.github.com"
  exit 1
fi

if ! gh auth status &>/dev/null; then
  echo "✗ gh not authenticated. Run: gh auth login"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "✗ jq not found. Install: apt install jq  /  brew install jq"
  exit 1
fi

if ! command -v curl &>/dev/null; then
  echo "✗ curl not found. Install: apt install curl  /  brew install curl"
  exit 1
fi

# ── Resolve repo ──────────────────────────────────────────────────────────────
OWNER_REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
if [ -z "$OWNER_REPO" ]; then
  echo "✗ Not in a GitHub repo (or gh can't detect it)"
  exit 1
fi

# ── Resolve PR number ────────────────────────────────────────────────────────
if [ -z "$PR_NUMBER" ]; then
  BRANCH=$(git branch --show-current 2>/dev/null || echo "")
  if [ -z "$BRANCH" ]; then
    echo "✗ Cannot detect branch. Use --pr <number>"
    exit 1
  fi
  PR_NUMBER=$(gh pr list --head "$BRANCH" --json number -q '.[0].number' 2>/dev/null || echo "")
  if [ -z "$PR_NUMBER" ]; then
    echo "✗ No PR found for branch: $BRANCH"
    echo "  Create one: gh pr create --title '...' --body '...'"
    exit 1
  fi
  echo "── Auto-detected PR #${PR_NUMBER} for branch: ${BRANCH} ──"
fi

echo "── Polling PR #${PR_NUMBER} on ${OWNER_REPO} ──"
echo "   Timeout: ${TIMEOUT}s | Interval: ${INTERVAL}s | Exclude: ${EXCLUDE_LOGINS:-none}"
[ -n "$NTFY_TOPIC" ] && echo "   ntfy topic: ${NTFY_TOPIC}"
echo ""

# ── Track seen reviews to avoid duplicates ────────────────────────────────────
SEEN_FILE=$(mktemp /tmp/poll_reviews_seen.XXXXXX)
trap "rm -f $SEEN_FILE" EXIT

# ── Poll loop ─────────────────────────────────────────────────────────────────
ELAPSED=0
FOUND=0

while [ $ELAPSED -lt $TIMEOUT ]; do
  # Fetch reviews
  REVIEWS=$(gh api "repos/${OWNER_REPO}/pulls/${PR_NUMBER}/reviews" 2>/dev/null || echo "[]")

  # Process each review
  echo "$REVIEWS" | jq -c '.[]' 2>/dev/null | while IFS= read -r review; do
    REVIEW_ID=$(echo "$review" | jq -r '.id')
    USER=$(echo "$review" | jq -r '.user.login')
    STATE=$(echo "$review" | jq -r '.state')
    BODY=$(echo "$review" | jq -r '.body // ""')
    URL=$(echo "$review" | jq -r '.html_url')

    # Skip if already seen
    grep -q "^${REVIEW_ID}$" "$SEEN_FILE" 2>/dev/null && continue

    # Skip empty-body "COMMENTED" reviews (just inline comments without summary)
    [ "$STATE" = "COMMENTED" ] && [ -z "$BODY" ] && continue

    # Skip excluded logins
    if [ -n "$EXCLUDE_LOGINS" ]; then
      SKIP=false
      for excluded in $(echo "$EXCLUDE_LOGINS" | tr ',' ' '); do
        [ "$USER" = "$excluded" ] && SKIP=true && break
      done
      [ "$SKIP" = "true" ] && continue
    fi

    # Mark as seen
    echo "$REVIEW_ID" >> "$SEEN_FILE"
    FOUND=$((FOUND + 1))

    # Print review
    echo "── Review by ${USER} (${STATE}) ──"
    [ -n "$BODY" ] && echo "$BODY" | head -c 1000
    echo ""
    echo "   URL: ${URL}"
    echo ""

    # Forward to ntfy
    if [ -n "$NTFY_TOPIC" ]; then
      EMOJI="💬"
      case "$STATE" in
        APPROVED)          EMOJI="✅" ;;
        CHANGES_REQUESTED) EMOJI="🔴" ;;
      esac

      BODY_TRUNC=$(echo "$BODY" | head -c 500)
      # Build JSON payload with jq to safely handle quotes, backslashes, and newlines
      PAYLOAD=$(jq -n \
        --arg topic   "$NTFY_TOPIC" \
        --arg title   "${EMOJI} PR #${PR_NUMBER} review by ${USER}" \
        --arg message "State: ${STATE}\n\n${BODY_TRUNC}" \
        --arg click   "$URL" \
        --arg reviewer "$USER" \
        --arg pr_number "$PR_NUMBER" \
        --arg repo    "$OWNER_REPO" \
        '{
          topic:   $topic,
          title:   $title,
          message: $message,
          tags:    ["pr-review", $reviewer],
          click:   $click,
          extras:  { type: "pr-review", reviewer: $reviewer, pr_number: $pr_number, repo: $repo }
        }')
      curl -s -X POST "https://ntfy.sh/${NTFY_TOPIC}" \
        -H "Content-Type: application/json" \
        -H "Priority: 3" \
        -d "$PAYLOAD" >/dev/null 2>&1 && echo "   ✓ Sent to ntfy.sh/${NTFY_TOPIC}"
    fi
  done

  # Also check inline comments
  COMMENTS=$(gh api "repos/${OWNER_REPO}/pulls/${PR_NUMBER}/comments" 2>/dev/null || echo "[]")
  INLINE_COUNT=$(echo "$COMMENTS" | jq 'length' 2>/dev/null || echo "0")

  if [ "$INLINE_COUNT" -gt 0 ] && [ "$VERBOSE" = "true" ]; then
    echo "── Inline comments (${INLINE_COUNT}) ──"
    echo "$COMMENTS" | jq -r '.[] | "\(.user.login) on \(.path):\(.line // .original_line) — \(.body | .[0:200])"' 2>/dev/null
    echo ""
  fi

  TOTAL_REVIEWS=$(echo "$REVIEWS" | jq 'length' 2>/dev/null || echo "0")
  if [ "$TOTAL_REVIEWS" -gt 0 ] || [ "$INLINE_COUNT" -gt 0 ]; then
    echo "── Summary: ${TOTAL_REVIEWS} reviews, ${INLINE_COUNT} inline comments ──"
    break
  fi

  echo "  ⏳ No reviews yet... (${ELAPSED}s / ${TIMEOUT}s)"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $TIMEOUT ] && [ $FOUND -eq 0 ]; then
  echo "  ⏰ Timeout after ${TIMEOUT}s with no reviews"
fi
