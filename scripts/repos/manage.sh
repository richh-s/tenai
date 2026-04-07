#!/bin/bash
# scripts/repos/manage.sh
# Unified repo management: clone, pull, clean worktrees, clean artifacts
#
# Usage:
#   ACTION=clone  REPO_URL=git@github.com:org/repo.git bash manage.sh
#   ACTION=pull   REPO_DIR=/path/to/repo bash manage.sh
#   ACTION=pull-all bash manage.sh                      # pull all registered repos
#   ACTION=list   bash manage.sh                        # list all repos
#   ACTION=clean-worktrees REPO_DIR=/path bash manage.sh
#   ACTION=clean-artifacts REPO_DIR=/path bash manage.sh
#   ACTION=status bash manage.sh                        # git status all repos

set -euo pipefail
source "$(dirname "$0")/../detect.sh"

ACTION="${ACTION:-list}"
BASE_DIR="${BASE_DIR:-${HOME}/projects}"
REPO_URL="${REPO_URL:-}"
REPO_DIR="${REPO_DIR:-}"
BRANCH="${BRANCH:-main}"
DRY_RUN="${DRY_RUN:-false}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $*"; }
log()  { echo -e "${BLUE}[repo]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }

ensure_base_dir() {
  mkdir -p "$BASE_DIR"
}

# ── Clone ─────────────────────────────────────────────────────────────────────
do_clone() {
  if [[ -z "$REPO_URL" ]]; then
    err "REPO_URL required. Example: REPO_URL=git@github.com:org/repo.git"
    exit 1
  fi

  ensure_base_dir

  local repo_name
  repo_name=$(basename "$REPO_URL" .git)
  local dest="${BASE_DIR}/${repo_name}"

  if [[ -d "$dest" ]]; then
    warn "Repo already exists: ${dest}"
    log "To update: ACTION=pull REPO_DIR=${dest} bash manage.sh"
    return
  fi

  log "Cloning ${REPO_URL} → ${dest}"
  git clone --branch "$BRANCH" "$REPO_URL" "$dest"

  # Scaffold project files if missing
  if [[ ! -f "${dest}/CLAUDE.md" ]]; then
    PROJECT_DIR="$dest" PROJECT_NAME="$repo_name" \
      bash "$(dirname "$0")/../configure/claude_md.sh"
  fi
  if [[ ! -f "${dest}/GEMINI.md" ]]; then
    PROJECT_DIR="$dest" PROJECT_NAME="$repo_name" \
      bash "$(dirname "$0")/../configure/gemini_md.sh"
  fi

  # Create .trees directory for worktrees
  mkdir -p "${dest}/.trees"
  echo ".trees/" >> "${dest}/.gitignore" 2>/dev/null || true

  ok "Cloned and scaffolded: ${dest}"
  echo ""
  echo "Next steps:"
  echo "  conductor:  REPO_DIR=${dest} bash scripts/conductor/gemini_session.sh"
  echo "  worktrees:  REPO_DIR=${dest} bash scripts/repos/worktree.sh"
  echo "  validate:   REPO_DIR=${dest} ACTION=validate bash scripts/conductor/ci_loop.sh"
}

# ── Pull ─────────────────────────────────────────────────────────────────────
do_pull() {
  if [[ -z "$REPO_DIR" ]]; then
    err "REPO_DIR required"
    exit 1
  fi
  if [[ ! -d "$REPO_DIR" ]]; then
    err "Directory not found: ${REPO_DIR}"
    exit 1
  fi

  log "Pulling: ${REPO_DIR}"
  cd "$REPO_DIR"

  # Stash if dirty
  if [[ -n "$(git status --porcelain)" ]]; then
    warn "Working tree dirty — stashing before pull"
    git stash push -m "auto-stash before pull $(date +%s)"
    local stashed=true
  else
    local stashed=false
  fi

  git fetch --all --prune
  git pull --ff-only origin "$(git rev-parse --abbrev-ref HEAD)" 2>/dev/null || \
    git pull origin "$(git rev-parse --abbrev-ref HEAD)"

  # Update worktrees
  if git worktree list | grep -q "\.trees/"; then
    log "Updating worktrees..."
    git worktree list --porcelain | grep "^worktree " | awk '{print $2}' | tail -n +2 | while read -r wt; do
      if [[ -d "$wt" ]]; then
        log "  Fetching worktree: $(basename "$wt")"
        git -C "$wt" fetch --all --prune 2>/dev/null || true
      fi
    done
  fi

  if [[ "$stashed" == "true" ]]; then
    warn "Restoring stash..."
    git stash pop 2>/dev/null || warn "Stash pop had conflicts — check manually"
  fi

  ok "Pull complete: ${REPO_DIR}"
}

# ── Pull All (from registry) ──────────────────────────────────────────────────
do_pull_all() {
  log "Pulling all repos in ${BASE_DIR}"

  if [[ ! -d "$BASE_DIR" ]]; then
    warn "Base dir not found: ${BASE_DIR}"
    return
  fi

  local count=0 failed=0
  for dir in "${BASE_DIR}"/*/; do
    if [[ -d "${dir}/.git" ]]; then
      log "── ${dir} ──"
      REPO_DIR="$dir" do_pull && ((count++)) || ((failed++))
    fi
  done

  echo ""
  ok "Pull-all complete: ${count} succeeded, ${failed} failed"
}

# ── List ─────────────────────────────────────────────────────────────────────
do_list() {
  log "Repos in ${BASE_DIR}:"
  echo ""
  printf "%-30s %-20s %-10s %s\n" "NAME" "BRANCH" "STATUS" "LAST COMMIT"
  printf "%-30s %-20s %-10s %s\n" "────────────────────────────" "──────────────────" "──────────" "───────────────────"

  local count=0
  for dir in "${BASE_DIR}"/*/; do
    if [[ -d "${dir}/.git" ]]; then
      local name branch status last_commit dirty
      name=$(basename "$dir")
      branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
      dirty=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l)
      status=$([[ $dirty -gt 0 ]] && echo "dirty(${dirty})" || echo "clean")
      last_commit=$(git -C "$dir" log -1 --format="%ar" 2>/dev/null || echo "?")
      printf "%-30s %-20s %-10s %s\n" "$name" "$branch" "$status" "$last_commit"
      ((count++))
    fi
  done

  echo ""
  echo "Total: ${count} repos"
  echo ""
  echo "Worktrees:"
  for dir in "${BASE_DIR}"/*/; do
    if [[ -d "${dir}/.git" ]]; then
      local wt_count
      wt_count=$(git -C "$dir" worktree list 2>/dev/null | wc -l)
      if [[ $wt_count -gt 1 ]]; then
        echo "  $(basename "$dir"): $((wt_count - 1)) active worktrees"
      fi
    fi
  done
}

# ── Status ────────────────────────────────────────────────────────────────────
do_status() {
  for dir in "${BASE_DIR}"/*/; do
    if [[ -d "${dir}/.git" ]]; then
      echo "═══ $(basename "$dir") ═══"
      git -C "$dir" status --short
      git -C "$dir" worktree list 2>/dev/null
      echo ""
    fi
  done
}

# ── Clean Worktrees ───────────────────────────────────────────────────────────
do_clean_worktrees() {
  if [[ -z "$REPO_DIR" ]]; then
    err "REPO_DIR required"
    exit 1
  fi

  log "Cleaning worktrees for: ${REPO_DIR}"
  cd "$REPO_DIR"

  # List all worktrees except main
  local pruned=0
  git worktree list --porcelain | grep "^worktree " | awk '{print $2}' | tail -n +2 | while read -r wt; do
    if [[ -d "$wt" ]]; then
      local wt_branch
      wt_branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

      # Check if worktree has unmerged commits
      local ahead
      ahead=$(git -C "$wt" rev-list "origin/${wt_branch}..HEAD" 2>/dev/null | wc -l || echo "0")

      if [[ $ahead -gt 0 ]]; then
        warn "Skipping ${wt_branch}: has ${ahead} unmerged commits"
      else
        if [[ "$DRY_RUN" == "true" ]]; then
          log "[DRY RUN] Would remove: ${wt}"
        else
          log "Removing worktree: ${wt}"
          git worktree remove "$wt" --force 2>/dev/null || rm -rf "$wt"
          git worktree prune
          ((pruned++)) || true
        fi
      fi
    fi
  done

  git worktree prune
  ok "Worktree cleanup complete"
  echo "Remaining:"
  git worktree list
}

# ── Clean Artifacts ───────────────────────────────────────────────────────────
do_clean_artifacts() {
  if [[ -z "$REPO_DIR" ]]; then
    err "REPO_DIR required"
    exit 1
  fi

  log "Cleaning artifacts: ${REPO_DIR}"
  cd "$REPO_DIR"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Would clean:"
    git clean -ndx --exclude=".env" --exclude="*.pem" --exclude="*.key"
  else
    # Makefile clean if available
    if [[ -f "Makefile" ]] && grep -q "^clean:" Makefile; then
      make clean && ok "Makefile clean done"
    fi

    # Git clean — removes untracked files and build artifacts
    # Protects .env and key files
    git clean -fdx \
      --exclude=".env" \
      --exclude=".env.*" \
      --exclude="*.pem" \
      --exclude="*.key" \
      --exclude="*.secret"

    ok "Artifacts cleaned in ${REPO_DIR}"
  fi
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "$ACTION" in
  clone)            do_clone ;;
  pull)             do_pull ;;
  pull-all)         do_pull_all ;;
  list)             do_list ;;
  status)           do_status ;;
  clean-worktrees)  do_clean_worktrees ;;
  clean-artifacts)  do_clean_artifacts ;;
  *)
    echo "Usage: ACTION=<action> bash scripts/repos/manage.sh"
    echo "Actions: clone | pull | pull-all | list | status | clean-worktrees | clean-artifacts"
    exit 1
    ;;
esac
