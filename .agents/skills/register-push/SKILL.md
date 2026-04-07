---
name: register-push
description: >
  Register a git push or PR creation with the agent watcher daemon.
  Call this after pushing code so the watcher knows to poll for CI and
  PR review feedback. Triggers: "register push", "notify watcher",
  "register PR", "tell daemon about push".
---

# register-push — Register Push with Agent Watcher

After pushing code or creating a PR, register the event so the agent watcher
daemon polls GitHub for CI results and PR reviews on your behalf.

## Prerequisites

- `.session_start` file exists in the worktree (created by dispatch)
- `gh` CLI is authenticated
- Python3 available

## Steps

### 1. Build TSID from .session_start

```bash
DEVICE=$(grep '^device=' .session_start 2>/dev/null | cut -d= -f2 || hostname)
REPO_FULL=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
BRANCH=$(git branch --show-current)
SESSION=$(grep '^session=' .session_start 2>/dev/null | cut -d= -f2 || echo "")
WINDOW=$(grep '^window=' .session_start 2>/dev/null | cut -d= -f2 || echo "")
TSID="${DEVICE}:${REPO_FULL}:${BRANCH}:${SESSION}:${WINDOW}"
```

### 2. Detect PR number

```bash
PR_NUM=$(gh pr list --head "$BRANCH" --json number -q '.[0].number' 2>/dev/null || echo "0")
```

### 3. Determine push type

- If you just ran `gh pr create`: type = `pr`
- If you just ran `git push`: type = `commit`

### 4. Register with watcher DB

```bash
# Use TENAI_INFRA_DIR if set, otherwise try common locations
_INFRA="${TENAI_INFRA_DIR:-}"
[ -z "$_INFRA" ] && [ -d "$HOME/tenai-infra" ] && _INFRA="$HOME/tenai-infra"

python3 "${_INFRA}/scripts/conductor/watcher_db.py" register \
  --tsid "$TSID" \
  --repo "$REPO_FULL" \
  --branch "$BRANCH" \
  --pr "${PR_NUM:-0}" \
  --sha "$(git rev-parse HEAD)" \
  --type "${PUSH_TYPE:-commit}" \
  --message "$(git log -1 --format=%s)"
```

**Expected response:** `{"ok": true, "watch_id": <id>}`

## When to Use

Call this skill immediately after:
- `git push -u origin <branch>`
- `gh pr create ...`

The watcher daemon will then start polling GitHub for CI signals and PR reviews
for the configured duration (default: 1 hour).

## Do Not

- Call this without having pushed first
- Call this if `.session_start` doesn't exist (you're not in a dispatched worktree)
