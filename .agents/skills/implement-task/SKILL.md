---
name: implement-task
description: >
  Implement a dispatched task from a worktree. Use this skill when you are
  working inside a git worktree created by the task dispatch system, you see
  a WORKTREE.md file, and you need to implement the assigned task end-to-end.
  Triggers: "implement task", "start working", "complete the task",
  "implement WORKTREE.md", "do the task".
---

# implement-task — End-to-End Task Implementation

Implement the task assigned in your worktree, from reading context through
creating a PR. This skill assumes you are inside a dispatched git worktree.

## Prerequisites

- You are in a git worktree with `WORKTREE.md` present
- The webapp API is reachable at `http://localhost:7700`
- `gh` CLI is authenticated

## Steps

### 1. Read your assignment

```bash
cat WORKTREE.md
```

Extract: **TASK_ID**, **JOB_ID**, **branch name**, **Device**, and **Context** field.

### 2. Read the task list

```bash
cat TASKS.md
```

Find your task by branch name. Note the description and verification command.

### 3. Resolve context

| Context field value | Action |
|:-------------------|:-------|
| `conductor/tracks/<id>` | Read `conductor/tracks/<id>/spec.md` and `plan.md` |
| `github:<issue>` | Run `gh issue view <issue> --json body,comments,title` |
| `inline` or missing | Use the description in WORKTREE.md directly |

### 4. Break down into subtasks

If no subtasks are listed, create 3–7 concrete subtasks. Register each:

```bash
curl -s -X POST "http://localhost:7700/api/task-db/${TASK_ID}/subtasks" \
  -H 'Content-Type: application/json' \
  -d '{"title": "<subtask title>"}'
```

**Expected response:** `{"ok": true, "subtask_id": <id>}`

Add returned subtask IDs to WORKTREE.md as a checklist.

### 5. Implement

- Follow project rules from AGENTS.md / CLAUDE.md / GEMINI.md
- Write tests alongside implementation
- Run `make lint` after each file change

### 6. Track progress

After completing each subtask:

```bash
# Mark subtask done
curl -s -X PATCH "http://localhost:7700/api/task-db/subtasks/${SUBTASK_ID}" \
  -H 'Content-Type: application/json' -d '{"status": "done"}'

# Post milestone log
curl -s -X POST "http://localhost:7700/api/jobs/${JOB_ID}/log" \
  -H 'Content-Type: application/json' \
  -d '{"line": "MILESTONE: Completed <description>"}'
```

### 7. Verify

Run the verification command from the task's `Verification:` field.
Fallback: `make lint && make test`

### 8. Create proof of work

Create `PROOF.md` with: task summary, test results, files changed, walkthrough.

### 9. Commit, push, and create PR

```bash
git add -A
git commit -m "feat: <summary of changes>"
git push -u origin <branch>
```

Create a PR with machine-readable TSID metadata from `.session_start`:

```bash
# Read TSID from .session_start
DEVICE=$(grep '^device=' .session_start 2>/dev/null | cut -d= -f2 || hostname)
SESSION=$(grep '^session=' .session_start 2>/dev/null | cut -d= -f2 || echo "")
WINDOW=$(grep '^window=' .session_start 2>/dev/null | cut -d= -f2 || echo "")

# Create PR with TSID in body (invisible HTML comment)
gh pr create --base main \
  --title "feat: <summary>" \
  --body "$(printf '%s\n\n<!-- tenai:device=%s,session=%s,window=%s -->' \
    '<description of changes>' "$DEVICE" "$SESSION" "$WINDOW")" \
  2>/dev/null || true
```

### 10. Register push with agent watcher

After pushing, register with the watcher so it polls for CI and reviews:

```bash
REPO_FULL=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
BRANCH=$(git branch --show-current)
TSID="${DEVICE}:${REPO_FULL}:${BRANCH}:${SESSION}:${WINDOW}"
PR_NUM=$(gh pr list --head "$BRANCH" --json number -q '.[0].number' 2>/dev/null || echo "0")

# Use TENAI_INFRA_DIR if set, otherwise try common locations
_INFRA="${TENAI_INFRA_DIR:-}"
[ -z "$_INFRA" ] && [ -d "$HOME/tenai-infra" ] && _INFRA="$HOME/tenai-infra"
[ -z "$_INFRA" ] && _INFRA="$(cd "$(dirname "$(grep -l 'TENAI' ~/.tenai_aliases 2>/dev/null || echo /dev/null)")/../.." 2>/dev/null && pwd)"

python3 "${_INFRA}/scripts/conductor/watcher_db.py" register \
  --tsid "$TSID" --repo "$REPO_FULL" --branch "$BRANCH" \
  --pr "${PR_NUM:-0}" --sha "$(git rev-parse HEAD)" \
  --message "$(git log -1 --format=%s)" 2>/dev/null || true
```

> **Important**: The `<!-- tenai:... -->` comment enables automated systems to
> route CI signals and PR reviews back to the correct agent session. Always
> include it when creating PRs from a worktree.

### 11. Exit when complete

## Do Not

- Install system packages (`apt`, `brew`, `npm -g`, `pip install`)
- Modify files outside this worktree
- Commit `.env` files
- Debug infrastructure issues — report and move on
