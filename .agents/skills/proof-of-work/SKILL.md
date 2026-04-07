---
name: proof-of-work
description: >
  Generate a PROOF.md file documenting completed work in a worktree.
  Use this skill after finishing a task to create evidence of completion
  with test results, changed files, and a walkthrough.
  Triggers: "create proof", "generate PROOF.md", "document completed work",
  "proof of work", "create evidence".
---

# proof-of-work — Document Completed Work

Generate `PROOF.md` in the worktree root as evidence of task completion.

## Steps

### 1. Capture test results

```bash
make lint 2>&1 | tee /tmp/lint_output.txt
make test 2>&1 | tee /tmp/test_output.txt
```

### 2. Capture changed files

```bash
git diff --stat
```

### 3. Write PROOF.md

Create `PROOF.md` using this template:

```markdown
# PROOF.md

## Task
<task title from WORKTREE.md>

## Branch
<current branch name>

## Test Results
<paste lint + test output, truncated to key lines>

## Files Changed
<paste git diff --stat output>

## Walkthrough
<2-5 sentence summary of what was implemented and why>

## Verification
- [ ] `make lint` passes
- [ ] `make test` passes
- [ ] PR created
```

### 4. Commit, push, and create PR

```bash
git add -A
git commit -m "feat: <task summary> + PROOF.md"
git push -u origin <branch>
```

Create a PR with TSID metadata from `.session_start`:

```bash
DEVICE=$(grep '^device=' .session_start 2>/dev/null | cut -d= -f2 || hostname)
SESSION=$(grep '^session=' .session_start 2>/dev/null | cut -d= -f2 || echo "")
WINDOW=$(grep '^window=' .session_start 2>/dev/null | cut -d= -f2 || echo "")

gh pr create --base main \
  --title "feat: <task summary>" \
  --body "$(printf '%s\n\n<!-- tenai:device=%s,session=%s,window=%s -->' \
    '<description>' "$DEVICE" "$SESSION" "$WINDOW")" \
  2>/dev/null || true
```

## Output

A `PROOF.md` file committed and pushed, with a PR created containing TSID metadata.
