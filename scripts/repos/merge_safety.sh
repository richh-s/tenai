#!/bin/bash
# merge_safety.sh — Worktree validation and merge safety
# 
# Actions:
#   validate-worktrees  — Run validation in each worktree
#   check-conflicts     — Check for file overlap between worktree branches
#   integration-test    — Merge all branches into test branch and validate
#   sequential-merge    — Merge branches one-by-one into main, validating between each
#
# Env:
#   REPO_DIR — path to the main repo
#   ACTION   — validate-worktrees | check-conflicts | integration-test | sequential-merge
#   TARGET   — target branch for integration/merge (default: main)
#   VALIDATE_CMD — validation command (default: auto-detect from ci config)
set -euo pipefail

# This script uses associative arrays (declare -A) which require bash 4+.
# macOS /bin/bash is 3.2 — re-exec with Homebrew bash if available.
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  if [[ -x "/opt/homebrew/bin/bash" ]]; then
    exec /opt/homebrew/bin/bash "$0" "$@"
  elif [[ -x "/usr/local/bin/bash" ]]; then
    exec /usr/local/bin/bash "$0" "$@"
  fi
  echo "This script requires bash 4+ (for associative arrays). Install: brew install bash" >&2
  exit 1
fi

REPO_DIR="${REPO_DIR:-$(pwd)}"
ACTION="${ACTION:-validate-worktrees}"
TARGET="${TARGET:-main}"
VALIDATE_CMD="${VALIDATE_CMD:-}"

REPO_NAME="$(basename "$REPO_DIR")"
TREES_DIR="${REPO_DIR}/.trees"

log()  { echo "  → $*"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*"; }
err()  { echo "  ✗ $*"; }

# Auto-detect validation command
detect_validate_cmd() {
  if [[ -n "$VALIDATE_CMD" ]]; then
    echo "$VALIDATE_CMD"
    return
  fi
  # Check for common patterns
  if [[ -f "$1/Makefile" ]] && grep -q '^test:' "$1/Makefile" 2>/dev/null; then
    echo "make lint 2>/dev/null; make test"
  elif [[ -f "$1/package.json" ]]; then
    echo "npm test"
  elif [[ -f "$1/pytest.ini" ]] || [[ -f "$1/setup.py" ]] || [[ -f "$1/pyproject.toml" ]]; then
    echo "python -m pytest -x -q --tb=short"
  else
    echo "echo 'No validation command found — skipping'"
  fi
}

# ── Validate all worktrees ───────────────────────────────────────────────────
do_validate_worktrees() {
  if [[ ! -d "$TREES_DIR" ]]; then
    echo "No .trees/ directory in ${REPO_DIR}"
    exit 0
  fi

  echo "── Validating worktrees in ${REPO_NAME} ──"
  local pass=0 fail=0 total=0

  for wt in "$TREES_DIR"/*/; do
    [[ -d "$wt/.git" ]] || [[ -f "$wt/.git" ]] || continue
    total=$((total + 1))
    local branch
    branch=$(cd "$wt" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    local vcmd
    vcmd=$(detect_validate_cmd "$wt")

    printf "\n━━━ %s (%s) ━━━\n" "$(basename "$wt")" "$branch"
    if (cd "$wt" && eval "$vcmd"); then
      ok "Validation passed"
      pass=$((pass + 1))
    else
      err "Validation FAILED"
      fail=$((fail + 1))
    fi
  done

  echo ""
  echo "── Summary: ${pass}/${total} passed, ${fail} failed ──"
  [[ $fail -eq 0 ]] && exit 0 || exit 1
}

# ── Check for file overlap between branches ──────────────────────────────────
do_check_conflicts() {
  if [[ ! -d "$TREES_DIR" ]]; then
    echo "No .trees/ directory in ${REPO_DIR}"
    exit 0
  fi

  echo "── Checking file overlap between worktree branches ──"
  cd "$REPO_DIR"

  # Collect changed files per branch
  declare -A branch_files
  local branches=()
  
  for wt in "$TREES_DIR"/*/; do
    [[ -d "$wt/.git" ]] || [[ -f "$wt/.git" ]] || continue
    local branch
    branch=$(cd "$wt" && git rev-parse --abbrev-ref HEAD 2>/dev/null || continue)
    branches+=("$branch")
    # Files changed vs the target branch
    local files
    files=$(cd "$wt" && git diff --name-only "$TARGET"..."$branch" 2>/dev/null || echo "")
    branch_files[$branch]="$files"
    log "$branch: $(echo "$files" | wc -l | tr -d ' ') files changed"
  done

  # Compare each pair for conflicts
  local conflicts=0
  for ((i=0; i<${#branches[@]}; i++)); do
    for ((j=i+1; j<${#branches[@]}; j++)); do
      local b1="${branches[$i]}" b2="${branches[$j]}"
      local overlap
      overlap=$(comm -12 \
        <(echo "${branch_files[$b1]}" | sort) \
        <(echo "${branch_files[$b2]}" | sort) | grep -v '^$' || true)
      if [[ -n "$overlap" ]]; then
        conflicts=$((conflicts + 1))
        warn "OVERLAP: $b1 ↔ $b2"
        echo "$overlap" | while read -r f; do
          echo "    $f"
        done
      fi
    done
  done

  if [[ $conflicts -eq 0 ]]; then
    ok "No file overlaps — safe to merge in parallel"
  else
    warn "${conflicts} potential conflict(s) found — consider sequential merge"
  fi
}

# ── Integration test: merge all → test branch → validate ─────────────────────
do_integration_test() {
  if [[ ! -d "$TREES_DIR" ]]; then
    echo "No .trees/ directory in ${REPO_DIR}"
    exit 0
  fi

  echo "── Integration test for ${REPO_NAME} ──"
  cd "$REPO_DIR"
  
  local test_branch="integration-test-$(date +%s)"
  log "Creating test branch: $test_branch (from $TARGET)"
  git checkout -b "$test_branch" "$TARGET" 2>/dev/null

  local merged=0 failed=0
  for wt in "$TREES_DIR"/*/; do
    [[ -d "$wt/.git" ]] || [[ -f "$wt/.git" ]] || continue
    local branch
    branch=$(cd "$wt" && git rev-parse --abbrev-ref HEAD 2>/dev/null || continue)
    
    log "Merging $branch..."
    if git merge --no-ff --no-edit "$branch" 2>/dev/null; then
      ok "Merged $branch"
      merged=$((merged + 1))
    else
      err "CONFLICT merging $branch — aborting merge"
      git merge --abort 2>/dev/null || true
      failed=$((failed + 1))
    fi
  done

  if [[ $failed -gt 0 ]]; then
    warn "${failed} branch(es) had merge conflicts"
    git checkout "$TARGET" 2>/dev/null
    git branch -D "$test_branch" 2>/dev/null || true
    exit 1
  fi

  # Run validation on merged result
  local vcmd
  vcmd=$(detect_validate_cmd "$REPO_DIR")
  echo ""
  echo "── Running validation on merged result ──"
  if eval "$vcmd"; then
    ok "Integration test PASSED ($merged branches merged)"
  else
    err "Integration test FAILED — validation errors after merge"
    git checkout "$TARGET" 2>/dev/null
    git branch -D "$test_branch" 2>/dev/null || true
    exit 1
  fi

  # Cleanup test branch
  git checkout "$TARGET" 2>/dev/null
  git branch -D "$test_branch" 2>/dev/null || true
  ok "Test branch cleaned up"
}

# ── Sequential merge: merge one-by-one with validation ───────────────────────
do_sequential_merge() {
  if [[ ! -d "$TREES_DIR" ]]; then
    echo "No .trees/ directory in ${REPO_DIR}"
    exit 0
  fi

  echo "── Sequential merge for ${REPO_NAME} into $TARGET ──"
  cd "$REPO_DIR"
  git checkout "$TARGET" 2>/dev/null

  local merged=0 skipped=0
  for wt in "$TREES_DIR"/*/; do
    [[ -d "$wt/.git" ]] || [[ -f "$wt/.git" ]] || continue
    local branch
    branch=$(cd "$wt" && git rev-parse --abbrev-ref HEAD 2>/dev/null || continue)
    
    printf "\n━━━ Merging %s ━━━\n" "$branch"
    
    # Try merge
    if ! git merge --no-ff --no-edit "$branch" 2>/dev/null; then
      err "CONFLICT — aborting. Fix $branch first."
      git merge --abort 2>/dev/null || true
      skipped=$((skipped + 1))
      continue
    fi

    # Validate after merge
    local vcmd
    vcmd=$(detect_validate_cmd "$REPO_DIR")
    if eval "$vcmd"; then
      ok "$branch merged and validated"
      merged=$((merged + 1))
    else
      warn "$branch merged but validation FAILED — reverting"
      git reset --hard HEAD~1 2>/dev/null
      skipped=$((skipped + 1))
    fi
  done

  echo ""
  echo "── Summary: ${merged} merged, ${skipped} skipped ──"
  [[ $skipped -eq 0 ]] && exit 0 || exit 1
}

# ── Main dispatch ────────────────────────────────────────────────────────────
case "$ACTION" in
  validate-worktrees) do_validate_worktrees ;;
  check-conflicts)    do_check_conflicts ;;
  integration-test)   do_integration_test ;;
  sequential-merge)   do_sequential_merge ;;
  *) echo "Usage: ACTION=<validate-worktrees|check-conflicts|integration-test|sequential-merge> $(basename "$0")"; exit 1 ;;
esac
