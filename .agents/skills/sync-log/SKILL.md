---
name: sync-log
description: >
  Post structured log entries to the webapp for visibility in the control
  panel. Use this skill to report milestones, errors, status updates, or
  subtask completions during task execution.
  Triggers: "log progress", "post milestone", "sync log", "report status",
  "update job log".
---

# sync-log — Post Agent Progress Logs

Post structured log entries to the webapp database so progress is visible
in the control panel and to other team members.

## Prerequisites

- Webapp API reachable at `http://localhost:7700`
- JOB_ID available from WORKTREE.md or `$JOB_ID` env var

## Steps

### 1. Get your JOB_ID

```bash
JOB_ID=$(grep -oP 'JOB_ID: \K\d+' WORKTREE.md 2>/dev/null || echo $JOB_ID)
```

### 2. Post a log entry

```bash
curl -s -X POST "http://localhost:7700/api/jobs/${JOB_ID}/log" \
  -H 'Content-Type: application/json' \
  -d '{"line": "MILESTONE: <description of what was completed>"}'
```

**Expected response:** `{"ok": true}`

### 3. Log entry prefixes

Use these prefixes for structured parsing in the control panel:

| Prefix | Purpose | Example |
|:-------|:--------|:--------|
| `MILESTONE:` | Significant progress | `MILESTONE: Auth module complete` |
| `ERROR:` | Error encountered | `ERROR: Test suite failing on db.py` |
| `STATUS:` | Current activity | `STATUS: Running integration tests` |
| `SUBTASK_DONE:` | Subtask completed | `SUBTASK_DONE: 42` |

## Output

Log entry visible in webapp job detail panel.
