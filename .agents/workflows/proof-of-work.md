---
description: Generate PROOF.md with test results, changed files, and walkthrough after completing a worktree task
---
# Generate Proof of Work

After finishing your task, create `PROOF.md` in the worktree root:

## Steps

1. **Run tests and capture output**
// turbo
```bash
make test 2>&1 | tail -30 > /tmp/test_output.txt || true
make lint 2>&1 | tail -10 >> /tmp/test_output.txt || true
```

2. **Get changed files**
// turbo
```bash
git diff --stat HEAD~1 > /tmp/diff_stat.txt 2>/dev/null || git diff --stat main > /tmp/diff_stat.txt
```

3. **Write `PROOF.md`** with:
   - Task description (from WORKTREE.md)
   - Test results (pass/fail + summary)
   - Files changed (git diff --stat)
   - Walkthrough (brief description)
   - Branch push output

4. **Commit and push**
```bash
git add -A
git commit -m "feat: [task description] + PROOF.md"
git push -u origin $(git rev-parse --abbrev-ref HEAD)
```
