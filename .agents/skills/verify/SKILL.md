---
name: verify
description: >
  Run a verification loop to validate code changes before committing.
  Use this skill after making code changes to ensure lint, tests, and
  type checks pass. Iterates until all checks are green.
  Triggers: "verify changes", "run verification", "check my code",
  "lint and test", "validate before commit".
---

# verify — Pre-Commit Verification Loop

Run lint, test, and type-check in a loop until all pass. Use after making
code changes and before committing.

## Steps

### 1. Lint

```bash
make lint 2>&1
```

If `make lint` is unavailable, try: `ruff check .` or `eslint .` or `cargo clippy`

### 2. Test

```bash
make test 2>&1
```

If `make test` is unavailable, try: `pytest` or `npm test` or `cargo test`

### 3. Type check (if applicable)

```bash
# Python
make typecheck 2>&1 || true
# TypeScript
npx tsc --noEmit 2>&1 || true
```

### 4. Fix failures

If any step fails:
1. Read the error output carefully
2. Fix the issue
3. **Go back to Step 1** and repeat

### 5. All green — commit

Once all checks pass, the code is ready to commit.

## Output

All lint, test, and type checks passing with zero errors.
