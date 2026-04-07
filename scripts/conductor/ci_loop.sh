#!/bin/bash
# scripts/conductor/ci_loop.sh
# CI validation loop: local validate → push → watch CI → signal agent → resume
#
# Usage:
#   REPO_DIR=/path ACTION=validate bash ci_loop.sh     # run local suite
#   REPO_DIR=/path ACTION=watch   bash ci_loop.sh      # watch for CI signal
#   REPO_DIR=/path ACTION=notify  bash ci_loop.sh      # send test notification
#   bash ci_loop.sh daemon                              # start webhook listener daemon
#
# Deps: curl, jq, ntfy (via ntfy.sh), gh (GitHub CLI optional)

set -euo pipefail
source "$(dirname "$0")/../detect.sh"

REPO_DIR="${REPO_DIR:-$(pwd)}"
ACTION="${ACTION:-validate}"
REPO_NAME="$(basename "$REPO_DIR")"
NTFY_TOPIC="${NTFY_TOPIC:-tenai-ci-$(hostname)}"
BUDGET_CAP="${BUDGET_CAP_USD:-5.0}"
DB_FILE="${HOME}/.tenai/ci_runs.json"

mkdir -p "${HOME}/.tenai"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${BLUE}[ci]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }

# ── Local validation suite ────────────────────────────────────────────────────
run_local_validate() {
  log "Running local validation suite for: ${REPO_NAME}"
  cd "$REPO_DIR"

  local failed=0

  # 1. Git state check
  log "1/4 — Git state"
  if [[ -n "$(git status --porcelain)" ]]; then
    warn "Uncommitted changes present — continuing"
  else
    ok "Working tree clean"
  fi

  # 2. Lint
  log "2/4 — Lint"
  if [[ -f "Makefile" ]] && grep -q "^lint:" Makefile; then
    make lint && ok "Lint passed" || { err "Lint failed"; failed=1; }
  elif command -v ruff &>/dev/null && find . -name "*.py" | head -1 | grep -q .; then
    ruff check . && ok "Ruff lint passed" || { err "Ruff failed"; failed=1; }
  elif [[ -f "package.json" ]] && grep -q '"lint"' package.json; then
    npm run lint && ok "npm lint passed" || { err "npm lint failed"; failed=1; }
  else
    warn "No lint target found — skipping"
  fi

  # 3. Tests
  log "3/4 — Tests"
  if [[ -f "Makefile" ]] && grep -q "^test:" Makefile; then
    make test && ok "Tests passed" || { err "Tests failed"; failed=1; }
  elif [[ -f "pytest.ini" ]] || [[ -f "pyproject.toml" ]] || find . -name "test_*.py" | head -1 | grep -q .; then
    "$PYTHON" -m pytest -x -q && ok "pytest passed" || { err "pytest failed"; failed=1; }
  elif [[ -f "package.json" ]] && grep -q '"test"' package.json; then
    npm test && ok "npm test passed" || { err "npm test failed"; failed=1; }
  else
    warn "No test target found — skipping"
  fi

  # 4. Build check (if applicable)
  log "4/4 — Build"
  if [[ -f "Makefile" ]] && grep -q "^build:" Makefile; then
    make build && ok "Build passed" || { err "Build failed"; failed=1; }
  elif [[ -f "package.json" ]] && grep -q '"build"' package.json; then
    npm run build && ok "Build passed" || { err "Build failed"; failed=1; }
  else
    warn "No build target — skipping"
  fi

  if [[ $failed -eq 0 ]]; then
    ok "All local checks passed for ${REPO_NAME}"
    return 0
  else
    err "Local validation failed for ${REPO_NAME} — fix before pushing"
    return 1
  fi
}

# ── Notify via ntfy.sh ────────────────────────────────────────────────────────
send_notification() {
  local status="${1:-unknown}"
  local run_id="${2:-local-$(date +%s)}"
  local message="${3:-CI signal}"
  local repo="${4:-$REPO_NAME}"

  if [[ -z "$NTFY_TOPIC" ]]; then
    warn "NTFY_TOPIC not set — skipping notification (set in .env)"
    return
  fi

  local emoji="✅"
  local priority="3"
  [[ "$status" == "failure" ]] && emoji="❌" && priority="4"
  [[ "$status" == "cancelled" ]] && emoji="⏹️"

  curl -s -X POST "https://ntfy.sh/${NTFY_TOPIC}" \
    -H "Content-Type: application/json" \
    -H "Priority: ${priority}" \
    -d "{
      \"topic\": \"${NTFY_TOPIC}\",
      \"title\": \"${emoji} CI ${status}: ${repo}\",
      \"message\": \"${message}\",
      \"tags\": [\"${status}\", \"ci\", \"${repo}\"],
      \"extras\": {
        \"run_id\": \"${run_id}\",
        \"repo\": \"${repo}\",
        \"status\": \"${status}\"
      }
    }" > /dev/null

  ok "Notification sent to ntfy.sh/${NTFY_TOPIC}"
}

# ── GitHub Actions CI workflow generator ─────────────────────────────────────
generate_ci_workflow() {
  local project_dir="${REPO_DIR}"
  local workflow_dir="${project_dir}/.github/workflows"
  mkdir -p "$workflow_dir"

  cat > "${workflow_dir}/ci.yml" << YAML
name: CI — Validation & Agent Signal

on:
  push:
    branches: ["**"]
  pull_request:
    branches: [main, master, develop]

env:
  NTFY_TOPIC: \${{ secrets.NTFY_TOPIC }}

jobs:
  validate:
    runs-on: ubuntu-latest
    timeout-minutes: 30

    steps:
      - uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip

      - name: Install dependencies
        run: |
          pip install --upgrade pip
          [ -f requirements.txt ] && pip install -r requirements.txt || true
          [ -f requirements-dev.txt ] && pip install -r requirements-dev.txt || true

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: npm
        continue-on-error: true  # skip if no package.json

      - name: Install Node dependencies
        run: npm ci --if-present
        continue-on-error: true

      - name: Lint
        run: |
          if make lint 2>/dev/null; then
            echo "✓ Lint via Makefile"
          elif command -v ruff; then
            ruff check .
          elif npm run lint --if-present 2>/dev/null; then
            echo "✓ npm lint"
          else
            echo "No lint configured — skipping"
          fi

      - name: Test
        id: test
        run: |
          if make test 2>/dev/null; then
            echo "✓ Tests via Makefile"
          elif python -m pytest -x -q --tb=short 2>/dev/null; then
            echo "✓ pytest"
          elif npm test --if-present 2>/dev/null; then
            echo "✓ npm test"
          else
            echo "No tests configured — skipping"
          fi

      # ── Agent Signal — always runs, signals success or failure ──────────────
      - name: Signal autonomous agent
        if: always()
        env:
          JOB_STATUS: \${{ job.status }}
          RUN_ID: \${{ github.run_id }}
          REPO: \${{ github.repository }}
          BRANCH: \${{ github.ref_name }}
          SHA: \${{ github.sha }}
          COMMIT_MSG: \${{ github.event.head_commit.message }}
        run: |
          if [ -z "\$NTFY_TOPIC" ]; then
            echo "NTFY_TOPIC not set — skipping agent signal"
            exit 0
          fi

          EMOJI="✅"
          PRIORITY=3
          [ "\$JOB_STATUS" = "failure" ] && EMOJI="❌" && PRIORITY=4

          curl -s -X POST "https://ntfy.sh/\${NTFY_TOPIC}" \\
            -H "Content-Type: application/json" \\
            -H "Priority: \${PRIORITY}" \\
            -d "{
              \\"topic\\": \\"\${NTFY_TOPIC}\\",
              \\"title\\": \\"\${EMOJI} CI \${JOB_STATUS}: \${REPO}\\",
              \\"message\\": \\"Branch: \${BRANCH}\\\\nCommit: \${SHA:0:8}\\\\n\${COMMIT_MSG}\\",
              \\"tags\\": [\\"ci\\", \\"\${JOB_STATUS}\\", \\"agent\\"],
              \\"extras\\": {
                \\"run_id\\": \\"\${RUN_ID}\\",
                \\"status\\": \\"\${JOB_STATUS}\\",
                \\"repo\\": \\"\${REPO}\\",
                \\"branch\\": \\"\${BRANCH}\\",
                \\"sha\\": \\"\${SHA}\\"
              }
            }"

          echo "✓ Agent signal sent (status=\${JOB_STATUS} run=\${RUN_ID})"
YAML

  ok "CI workflow written to ${workflow_dir}/ci.yml"
  echo "  Add secret NTFY_TOPIC to your GitHub repo settings."
}

# ── Webhook listener daemon ───────────────────────────────────────────────────
start_daemon() {
  log "Starting CI webhook listener daemon"
  log "Topic: ntfy.sh/${NTFY_TOPIC}"
  log "Budget cap: \$${BUDGET_CAP}"

  if [[ -z "$NTFY_TOPIC" ]]; then
    err "NTFY_TOPIC not set. Add to .env"
    exit 1
  fi

  local spend=0

  echo "── Listening for CI signals on ntfy.sh/${NTFY_TOPIC} ──"
  echo "   Press Ctrl-C to stop"

  # Subscribe to ntfy.sh topic and process events
  curl -s "https://ntfy.sh/${NTFY_TOPIC}/json" | while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    local event_type msg status run_id repo branch
    event_type=$(echo "$line" | jq -r '.event // "message"' 2>/dev/null)
    [[ "$event_type" != "message" ]] && continue

    msg=$(echo "$line" | jq -r '.message // ""' 2>/dev/null)
    status=$(echo "$line" | jq -r '.extras.status // "unknown"' 2>/dev/null)
    run_id=$(echo "$line" | jq -r '.extras.run_id // ""' 2>/dev/null)
    repo=$(echo "$line" | jq -r '.extras.repo // ""' 2>/dev/null)
    branch=$(echo "$line" | jq -r '.extras.branch // ""' 2>/dev/null)

    log "CI signal received: status=${status} repo=${repo} branch=${branch} run=${run_id}"

    # Record in local DB
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local record="{\"timestamp\":\"${timestamp}\",\"status\":\"${status}\",\"run_id\":\"${run_id}\",\"repo\":\"${repo}\",\"branch\":\"${branch}\"}"
    echo "$record" >> "$DB_FILE"

    case "$status" in
      success)
        ok "CI passed — resuming agent for ${repo} on ${branch}"
        _resume_agent "$repo" "$branch" "$run_id" "success"
        ;;
      failure)
        warn "CI failed — waking agent to fix: ${repo} on ${branch}"
        _resume_agent "$repo" "$branch" "$run_id" "failure"
        ;;
      *)
        warn "Unknown status '${status}' — ignoring"
        ;;
    esac
  done
}

_resume_agent() {
  local repo="$1" branch="$2" run_id="$3" status="$4"

  # Find the tmux session for this repo/branch
  # Convention: session name = <repo-basename>-<branch-sanitized>
  local repo_name
  repo_name=$(basename "$repo")
  local branch_safe
  branch_safe=$(echo "$branch" | tr '/' '-' | tr '[:upper:]' '[:lower:]')

  # Try known session name patterns
  local possible_sessions=(
    "${repo_name}-${branch_safe}"
    "${repo_name}"
    "main"
  )

  local found_session=""
  for s in "${possible_sessions[@]}"; do
    if tmux has-session -t "$s" 2>/dev/null; then
      found_session="$s"
      break
    fi
  done

  if [[ -z "$found_session" ]]; then
    warn "No tmux session found for ${repo_name}. Known sessions:"
    tmux list-sessions 2>/dev/null || true
    return
  fi

  # Build resume prompt for the agent
  local prompt
  if [[ "$status" == "success" ]]; then
    prompt="CI PASSED (run ${run_id}). All tests green. You may merge the PR or proceed to the next task in TASKS.md."
  else
    prompt="CI FAILED (run ${run_id}). Review the failing logs, fix the issues, commit, and push. Check: gh run view ${run_id} --log-failed"
  fi

  # Inject resume signal into agent's tmux pane
  tmux send-keys -t "${found_session}" "" ""  # send escape to unstick
  tmux send-keys -t "${found_session}" "echo '=== CI SIGNAL: ${status} === Run: ${run_id}'" Enter
  tmux send-keys -t "${found_session}" "# ${prompt}" Enter

  ok "Resume signal sent to tmux session: ${found_session}"
}

# ── Show CI run history ───────────────────────────────────────────────────────
show_history() {
  if [[ -f "$DB_FILE" ]]; then
    echo "── CI Run History ──"
    cat "$DB_FILE" | jq -r '. | "\(.timestamp) [\(.status)] \(.repo) @ \(.branch) (run: \(.run_id))"' 2>/dev/null || cat "$DB_FILE"
  else
    echo "No CI run history yet."
  fi
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "$ACTION" in
  validate)      run_local_validate ;;
  notify)        send_notification "${STATUS:-success}" "${RUN_ID:-local}" "${MESSAGE:-manual signal}" ;;
  gen-workflow)  generate_ci_workflow ;;
  daemon)        start_daemon ;;
  history)       show_history ;;
  *)
    echo "Usage: ACTION=<action> bash ci_loop.sh"
    echo "Actions: validate | notify | gen-workflow | daemon | history"
    exit 1
    ;;
esac
