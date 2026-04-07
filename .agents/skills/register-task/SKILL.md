---
name: register-task
description: >
  Register tasks into the central task database via API after generating
  or planning them. Use this skill after creating tasks from conductor
  planning, manual breakdown, or GitHub issue analysis.
  Triggers: "register task", "add task to database", "save tasks to DB",
  "track this task", "register in task-db".
---

# register-task — Register Tasks in the Database

Register tasks into the webapp task database so they can be tracked,
dispatched, and monitored from the control panel.

## Prerequisites

- Webapp API reachable at `http://localhost:7700`
- Task details available (title, branch, repo, description)

## Steps

### 1. Identify task details

For each task, gather: title, branch, repo, description, verification,
and context reference (conductor track, GitHub issue, or inline).

### 2. Register via API

```bash
curl -s -X POST "http://localhost:7700/api/task-db" \
  -H 'Content-Type: application/json' \
  -d '{
    "repo": "<org/repo>",
    "title": "<task title>",
    "branch": "<feat/branch-name>",
    "description": "<task description>",
    "verification": "<make test or specific command>",
    "context_ref": "<conductor/tracks/id | github:42 | inline>",
    "cli": "<claude|gemini|codex>",
    "model": "<model name>"
  }'
```

**Expected response:** `{"ok": true, "task_id": <id>}`

### 3. Verify registration

```bash
curl -s "http://localhost:7700/api/task-db?repo=<org/repo>" | python3 -m json.tool
```

### 4. Add subtasks (optional)

```bash
curl -s -X POST "http://localhost:7700/api/task-db/${TASK_ID}/subtasks" \
  -H 'Content-Type: application/json' \
  -d '{"title": "<subtask title>"}'
```

### 5. Render TASKS.md (optional)

```bash
curl -s "http://localhost:7700/api/task-db/render?repo=<org/repo>"
```

## Output

Tasks registered in the database, visible in the webapp control panel.
