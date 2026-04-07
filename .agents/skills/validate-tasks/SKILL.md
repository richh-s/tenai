---
name: validate-tasks
description: >
  Validate tasks for ATC compliance (Self-Contained, Verifiable, Bounded,
  Parallelizable, Resume-safe). Use this skill after creating or updating
  tasks to check they meet quality standards before dispatch.
  Triggers: "validate tasks", "check ATC compliance", "verify task quality",
  "validate TASKS.md".
---

# validate-tasks — ATC Compliance Validation

Validate tasks against the ATC quality criteria before dispatch.

## ATC Criteria

| Criterion | Requirement |
|:----------|:-----------|
| **Self-Contained** | Works in its own git worktree, no cross-worktree deps |
| **Verifiable** | Has clear pass/fail verification command |
| **Bounded** | Completable in < 2 hours |
| **Parallelizable** | No dependencies on other active tasks |
| **Resume-safe** | Can be restarted without side effects |

## Steps

### 1. Validate via API (preferred)

```bash
curl -s "http://localhost:7700/api/task-db/validate?repo=<org/repo>" \
  | python3 -m json.tool
```

**Expected response:** `{"ok": true, "warnings": [...], "task_count": N}`

### 2. Manual validation (fallback)

If the API is not available, read `TASKS.md` and check each Active task:

- [ ] Has `Branch:` line (unique per task)
- [ ] Has `Verification:` line with test command
- [ ] Has description (not empty)
- [ ] Branch name is unique across all tasks
- [ ] No two tasks modify the same files

### 3. Report

List violations and suggest fixes. For each warning:
- State which task and which criterion failed
- Suggest a concrete fix

## Output

Validation report with any ATC violations and recommended fixes.
