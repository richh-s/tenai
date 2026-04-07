---
description: verification loop for validating code changes before committing
---
# Verification Loop

Run this workflow after making any code changes to ensure correctness.

## Steps

1. **Lint** — check for style/syntax issues
// turbo
```bash
make lint
```

2. **Test** — run the full test suite
// turbo
```bash
make test
```

3. **Targeted test** — if you modified a specific module, run its tests
// turbo
```bash
# After changing webapp/db.py:
.venv/bin/python3 -m pytest tests/test_db.py -v

# After changing scripts/configure/generate_aliases.py:
.venv/bin/python3 -m pytest tests/test_aliases.py -v

# After changing scripts/configure/resolve_host.py:
.venv/bin/python3 -m pytest tests/test_resolve_host.py -v

# After changing webapp/server.py:
.venv/bin/python3 -m pytest tests/test_api.py -v

# After changing config/defaults.yaml or config/device/*.yaml:
.venv/bin/python3 -m pytest tests/test_config.py -v

# After changing scripts/env_loader.py:
.venv/bin/python3 -m pytest tests/test_env_loader.py -v
```

4. **Tool check** — verify tools are installed (optional, for infra changes)
// turbo
```bash
make check
```

5. **Fix any failures** — if lint or tests fail, fix the issues and re-run from step 1

6. **Commit and push** — CI will run automatically on GitHub Actions and signal via ntfy

## When to Run

- **Always**: after modifying Python files in `webapp/`, `scripts/`, or `tests/`
- **Always**: after modifying `config/defaults.yaml` or `config/device/*.yaml`
- **After shell script changes**: run `make check` to verify nothing broke
- **Before pushing**: run full `make lint && make test`

## What CI Checks

GitHub Actions (`.github/workflows/ci.yml`) runs:
1. `ruff check` — linting
2. `pytest` — full test suite
3. ntfy signal — sends pass/fail notification to configured topic

## Available Test Markers

- `@pytest.mark.unit` — pure logic tests, no I/O
- `@pytest.mark.integration` — tests with database or TestClient
