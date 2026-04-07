---
description: Validate TASKS.md for ATC compliance (Self-Contained, Verifiable, Bounded, Parallelizable, Resume-safe)
---
# Validate TASKS.md

Run ATC validation on the current repo's TASKS.md:

// turbo
```bash
python3 scripts/conductor/parse_tasks.py . --validate
```

## ATC Criteria Checklist
1. **Self-Contained** — works in its own git worktree
2. **Verifiable** — has clear pass/fail criteria
3. **Bounded** — completable in < 2 hours
4. **Parallelizable** — no cross-task dependencies
5. **Resume-safe** — can be restarted without side effects

## Required fields per Active task
- `Branch:` line (unique per task)
- `Verify:` line with test instructions

Report violations and suggest fixes after validation.
