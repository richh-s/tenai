#!/bin/bash
# scripts/repos/worktree.sh
# Provision, dispatch, and manage git worktrees for parallel Claude Code agents
#
# Usage:
#   REPO_DIR=/path BRANCH=feat/auth bash worktree.sh          # create worktree
#   REPO_DIR=/path ACTION=dispatch BRANCH=feat/auth bash ...   # create + launch Claude
#   REPO_DIR=/path ACTION=list bash ...                        # list worktrees
#   REPO_DIR=/path ACTION=clean-all bash ...                   # remove merged worktrees

set -euo pipefail
source "$(dirname "$0")/../detect.sh"

REPO_DIR="${REPO_DIR:-$(pwd)}"
ACTION="${ACTION:-create}"
BRANCH="${BRANCH:-}"
TASK="${TASK:-}"          # task description for Claude Code

# Auto-generate BRANCH from TASK title if BRANCH not provided
if [[ -z "$BRANCH" && -n "$TASK" ]]; then
  # Slugify: lowercase, replace non-alphanumeric with hyphens, trim, truncate
  BRANCH="task/$(echo "$TASK" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-50)"
fi

# Read model config from merged config (defaults + local)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_LOADER="${SCRIPT_DIR}/../lib/load_config.py"
if [[ -f "$_LOADER" ]] && [[ -n "${PYTHON:-}" ]] && [[ -x "$PYTHON" ]]; then
  _claude_model=$($PYTHON "$_LOADER" --get conductor.claude_model 2>/dev/null || echo "")
  _gemini_model=$($PYTHON "$_LOADER" --get conductor.gemini_model 2>/dev/null || echo "")
  _codex_model=$($PYTHON "$_LOADER" --get conductor.codex_model 2>/dev/null || echo "")
fi
CLAUDE_MODEL="${CLAUDE_MODEL:-${_claude_model:-sonnet}}"
GEMINI_MODEL="${GEMINI_MODEL:-${_gemini_model:-gemini-2.5-flash}}"
CODEX_MODEL="${CODEX_MODEL:-${_codex_model:-}}"
DRY_RUN="${DRY_RUN:-false}"

# Read launch_args from config/cli/{cli}.yaml
_cli_launch_args() {
  local cli="$1"
  local cfg="${SCRIPT_DIR}/../../config/cli/${cli}.yaml"
  if [[ -f "$cfg" ]] && [[ -n "${PYTHON:-}" ]] && [[ -x "$PYTHON" ]]; then
    $PYTHON -c "import yaml; args=yaml.safe_load(open('$cfg')).get('launch_args',[]); print(' '.join(args))" 2>/dev/null || echo ""
  fi
}

REPO_NAME="$(basename "$REPO_DIR")"
TREES_DIR="${REPO_DIR}/.trees"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $*"; }
log()  { echo -e "${BLUE}[wt]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }

ensure_trees_dir() {
  mkdir -p "$TREES_DIR"
  # Add to .gitignore
  if [[ -f "${REPO_DIR}/.gitignore" ]]; then
    grep -q "^\.trees/" "${REPO_DIR}/.gitignore" || echo ".trees/" >> "${REPO_DIR}/.gitignore"
  fi
}

sanitize_branch() {
  echo "$1" | sed 's/[^a-zA-Z0-9._-]/-/g' | tr '[:upper:]' '[:lower:]'
}

# ── Create worktree ────────────────────────────────────────────────────────────
do_create() {
  if [[ -z "$BRANCH" ]]; then
    err "BRANCH required. Example: BRANCH=feat/auth-module"
    exit 1
  fi

  ensure_trees_dir
  cd "$REPO_DIR"

  local safe_branch
  safe_branch=$(sanitize_branch "$BRANCH")
  local wt_dir="${TREES_DIR}/${safe_branch}"

  if [[ -d "$wt_dir" ]]; then
    warn "Worktree already exists: ${wt_dir}"
    return 0
  fi

  log "Creating worktree: ${wt_dir} (branch: ${BRANCH})"

  # Create branch if it doesn't exist
  if git rev-parse --verify "$BRANCH" &>/dev/null; then
    git worktree add "$wt_dir" "$BRANCH"
  else
    git worktree add -b "$BRANCH" "$wt_dir" "$(git rev-parse --abbrev-ref HEAD)"
    log "Created new branch: ${BRANCH}"
  fi

  # Copy env files (not tracked in git)
  # Guard: if .env is a directory (Docker artifact), remove it first
  [[ -d "${wt_dir}/.env" ]] && rm -rf "${wt_dir}/.env"
  for f in .env .env.local .env.development; do
    [[ -f "${REPO_DIR}/${f}" ]] && cp "${REPO_DIR}/${f}" "${wt_dir}/${f}" && log "  Copied ${f}"
  done

  # Fallback: pull from ~/.tenai_envs/ if no .env was copied or it's empty
  if [[ ! -s "${wt_dir}/.env" ]]; then
    local origin
    origin=$(cd "$REPO_DIR" && git remote get-url origin 2>/dev/null || echo "")
    if [[ -n "$origin" ]]; then
      local env_name
      env_name=$(echo "$origin" | sed 's|.*[:/]\([^/]*/[^/]*\)\.git$|\1|;s|.*[:/]\([^/]*/[^/]*\)$|\1|;s|/|--|')
      for envf in "$HOME/.tenai_envs/${env_name}.env" "$HOME/.tenai_envs/$(basename "$REPO_DIR").env"; do
        if [[ -f "$envf" ]]; then
          cat "$envf" > "${wt_dir}/.env"
          chmod 600 "${wt_dir}/.env"
          log "  Populated .env from $envf"
          break
        fi
      done
    fi
  fi

  # Copy CLAUDE.md, GEMINI.md, and AGENTS.md if present
  [[ -f "${REPO_DIR}/CLAUDE.md" ]] && cp "${REPO_DIR}/CLAUDE.md" "${wt_dir}/"
  [[ -f "${REPO_DIR}/GEMINI.md" ]] && cp "${REPO_DIR}/GEMINI.md" "${wt_dir}/"
  [[ -f "${REPO_DIR}/AGENTS.md" ]] && cp "${REPO_DIR}/AGENTS.md" "${wt_dir}/"

  # Copy CLI skill directories if present
  for d in .claude .gemini .codex; do
    [[ -d "${REPO_DIR}/${d}" ]] && cp -r "${REPO_DIR}/${d}" "${wt_dir}/" && log "  Copied ${d}/"
  done

  # Write worktree-specific context
  local _device="${DEVICE_NAME:-$(hostname)}"
  cat > "${wt_dir}/WORKTREE.md" << WTMD
# Worktree Context
- **Branch**: ${BRANCH}
- **Task**: ${TASK:-"See TASKS.md in parent repo"}
- **Parent**: ${REPO_DIR}
- **Device**: ${_device}
- **Created**: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Instructions for this worktree
1. Implement the task described above
2. Run tests: \`make test\` or \`pytest\`
3. Commit with descriptive message
4. Create \`PROOF.md\` with: test results, files changed, brief walkthrough
5. Push branch: \`git push -u origin ${BRANCH}\`
6. Create PR: \`gh pr create --base main --fill\` (include TSID from .session_start)
7. Exit when complete

## Do not
- Install system packages or tools (no apt, brew, npm -g, pip install). If a tool is missing, skip that step and note it in PROOF.md
- Modify files outside this worktree's scope
- Commit .env files
- Merge from other branches (let CI handle it)
- Spend time debugging infrastructure issues (SSH, auth, permissions) — report them and move on
WTMD

  ok "Worktree ready: ${wt_dir}"
  echo "  Branch: ${BRANCH}"
  echo "  To attach: tmux attach -t ${REPO_NAME}-$(sanitize_branch "$BRANCH")"
}

# ── Dispatch: create worktree + launch AI agent in tmux pane ──────────────────
do_dispatch() {
  local safe_branch
  safe_branch=$(sanitize_branch "$BRANCH")
  local session="${REPO_NAME}-agents"
  local window="${safe_branch}"

  # ── Idempotency check: skip if tmux window already running ──
  if tmux has-session -t "$session" 2>/dev/null; then
    if tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -q "^${window}$"; then
      # Check if there's a running process in that window
      local pane_pid
      pane_pid=$(tmux list-panes -t "${session}:${window}" -F '#{pane_pid}' 2>/dev/null | head -1)
      if [[ -n "$pane_pid" ]] && kill -0 "$pane_pid" 2>/dev/null; then
        warn "Session '${session}' window '${window}' already running (pid ${pane_pid}) — skipping dispatch"
        echo "  To attach: tmux attach -t ${session}:${window}"
        return 0
      fi
    fi
  fi

  # First create the worktree
  do_create

  local wt_dir="${TREES_DIR}/${safe_branch}"
  local cli="${AGENT_CLI:-claude}"

  log "Dispatching ${cli} agent to: ${wt_dir}"
  log "  tmux session: ${session}"
  log "  window:       ${window}"

  # Create or attach to agents session for this repo
  if ! tmux has-session -t "$session" 2>/dev/null; then
    tmux new-session -d -s "$session" -c "$wt_dir" -x "$(tput cols)" -y "$(tput lines)"
    tmux rename-window -t "${session}:0" "$window"
  else
    # Add new window for this branch
    tmux new-window -t "$session" -n "$window" -c "$wt_dir"
  fi

  # Build agent prompt based on task
  local task_desc
  if [[ -n "$TASK" ]]; then
    task_desc="${TASK}. When done: run tests, commit changes, push branch ${BRANCH}, then exit."
  else
    task_desc="Read WORKTREE.md for your task. Implement it, run tests, commit, push branch ${BRANCH}, then exit."
  fi

  # Build CLI invocation — launch interactively (NOT -p one-shot)
  local agent_cmd
  local agent_prompt="Read WORKTREE.md and implement the task. Track subtask progress by updating status. When done: run tests, commit, push branch, create PROOF.md, then exit."
  local cli_args
  cli_args=$(_cli_launch_args "$cli")
  case "$cli" in
    claude)
      agent_cmd="claude --model ${CLAUDE_MODEL} ${cli_args}"
      ;;
    gemini)
      agent_cmd="gemini --model ${GEMINI_MODEL} ${cli_args}"
      ;;
    codex)
      if [[ -n "$CODEX_MODEL" ]]; then
        agent_cmd="codex ${cli_args} -m ${CODEX_MODEL}"
      else
        agent_cmd="codex ${cli_args}"
      fi
      ;;
    *)
      warn "Unknown CLI '${cli}', falling back to claude"
      cli_args=$(_cli_launch_args claude)
      agent_cmd="claude --model ${CLAUDE_MODEL} ${cli_args}"
      ;;
  esac

  # Launch agent interactively, then send the task prompt
  tmux send-keys -t "${session}:${window}" "cd ${wt_dir}" Enter
  tmux send-keys -t "${session}:${window}" "echo '── ${cli} agent dispatched to ${BRANCH} ──'" Enter
  # Pre-trust worktree for Claude to skip "trust this folder?" prompt
  if [[ "$cli" == "claude" || "$cli" != "gemini" && "$cli" != "codex" ]]; then
    tmux send-keys -t "${session}:${window}" "claude config add trustedDirectories $(pwd)/${wt_dir} 2>/dev/null; true" Enter
  fi
  # Pre-auth gh CLI with GitHub token from .env
  if command -v gh &>/dev/null; then
    local gh_token=""
    if [[ -f "${REPO_DIR}/.env" ]]; then
      gh_token=$(grep "^GITHUB_TOKEN=" "${REPO_DIR}/.env" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
    fi
    if [[ -n "$gh_token" ]]; then
      tmux send-keys -t "${session}:${window}" "echo '${gh_token}' | gh auth login --with-token 2>/dev/null; true" Enter
      tmux send-keys -t "${session}:${window}" "export GH_TOKEN='${gh_token}'" Enter
    fi
  fi
  tmux send-keys -t "${session}:${window}" "$agent_cmd" Enter
  sleep 3
  tmux send-keys -t "${session}:${window}" "$agent_prompt" Enter

  # Register with Gastown (if available and enabled)
  if command -v gt &>/dev/null && [[ "${GASTOWN_ENABLED:-}" == "true" ]]; then
    gt hook create "${safe_branch}" --rig "${REPO_NAME}" 2>/dev/null || true
    gt convoy create "Task: ${TASK:-${BRANCH}}" "${safe_branch}" 2>/dev/null || true
    log "  Gastown: registered hook + convoy for ${safe_branch}"
  fi

  # Record session start for history (includes TSID components)
  local _device="${DEVICE_NAME:-$(hostname)}"
  local session_log="${wt_dir}/.session_start"
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$session_log"
  echo "device=${_device}" >> "$session_log"
  echo "cli=${cli}" >> "$session_log"
  echo "task=${TASK:-}" >> "$session_log"
  echo "repo=${REPO_NAME}" >> "$session_log"
  echo "branch=${BRANCH}" >> "$session_log"
  echo "session=${session}" >> "$session_log"
  echo "window=${window}" >> "$session_log"

  ok "Agent dispatched (${cli})"
  echo "  Monitor: tmux attach -t ${session}"
  echo "  Window:  ${window}"
}

# ── List worktrees ────────────────────────────────────────────────────────────
do_list() {
  cd "$REPO_DIR"
  echo "═══ Worktrees: ${REPO_NAME} ═══"
  git worktree list

  echo ""
  echo "Active agent sessions:"
  tmux list-sessions 2>/dev/null | grep "^${REPO_NAME}-" || echo "  (none)"
}

# ── Clean merged worktrees ────────────────────────────────────────────────────
do_clean_all() {
  cd "$REPO_DIR"
  log "Cleaning merged worktrees for ${REPO_NAME}"

  local main_branch
  main_branch=$(git rev-parse --abbrev-ref HEAD)

  local cleaned=0
  git worktree list --porcelain | grep "^worktree " | awk '{print $2}' | tail -n +2 | while read -r wt; do
    if [[ ! -d "$wt" ]]; then
      git worktree prune
      continue
    fi

    local wt_branch
    wt_branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")

    # Check if branch merged into main
    if git merge-base --is-ancestor "origin/${wt_branch}" "origin/${main_branch}" 2>/dev/null; then
      if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would remove merged worktree: ${wt_branch}"
      else
        log "Removing merged worktree: ${wt_branch}"
        git worktree remove "$wt" --force
        git branch -d "$wt_branch" 2>/dev/null || true
        ((cleaned++)) || true
      fi
    else
      log "Keeping active worktree: ${wt_branch}"
    fi
  done

  git worktree prune
  ok "Clean complete"
  git worktree list
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "$ACTION" in
  create)     do_create ;;
  dispatch)   do_dispatch ;;
  list)       do_list ;;
  clean-all)  do_clean_all ;;
  *)
    echo "Usage: ACTION=<action> BRANCH=<branch> bash scripts/repos/worktree.sh"
    echo "Actions: create | dispatch | list | clean-all"
    exit 1
    ;;
esac
