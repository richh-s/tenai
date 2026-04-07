# How To — CI Validation & Webhook Daemon

## tenai-infra's Own CI

This repo runs lint + tests on every push via GitHub Actions:

```bash
# Run locally (same as CI)
make lint        # ruff check on scripts/ webapp/ tests/
make test        # pytest suite — unit + integration

# Verbose output
.venv/bin/python3 -m pytest tests/ -v --tb=long
```

### GitHub Actions Workflow

The workflow at `.github/workflows/ci.yml` runs:
1. **Lint** — `ruff check` for style/syntax issues
2. **Test** — `pytest` for unit + integration tests
3. **Signal** — sends ntfy.sh notification with pass/fail status

### CI Signals (ntfy.sh)

On every CI run, a JSON payload is sent to `ntfy.sh/<NTFY_TOPIC>`:

```json
{
  "topic": "<topic>",
  "title": "✅ CI success: org/repo",
  "message": "Branch: main\nCommit: abc12345\nFix widget layout",
  "tags": ["ci", "success", "tenai-infra"],
  "extras": {
    "run_id": "12345678",
    "status": "success",
    "repo": "org/repo",
    "branch": "main",
    "sha": "abc12345..."
  }
}
```

**Setup**: Add `NTFY_TOPIC` as a GitHub repo secret (Settings → Secrets → Actions).

---

## Target Repo Validation

Run the lint + test suite for any managed repo:

```bash
# Current directory
make validate

# Specific repo
make validate REPO=brownfield-cartographer
```

This runs the commands defined in `config/defaults.yaml`:

```yaml
ci:
  local_validate:
    - "make lint"
    - "make test"
```

## Generate GitHub Actions Workflow for Target Repos

Auto-generate a CI workflow file for a managed repo:

```bash
make ci-workflow REPO=brownfield-cartographer
```

Creates `.github/workflows/ci.yml` in the repo with the configured validation steps and optional ntfy.sh notification.

## Webhook Listener Daemon

Start a daemon that watches an [ntfy.sh](https://ntfy.sh) topic for CI events and resumes agents on success:

```bash
make ci-daemon
```

### Setup

1. Set `NTFY_TOPIC` in `.env`:
   ```env
   NTFY_TOPIC=<your-ntfy-topic>
   ```

2. Start the daemon (runs in foreground, use tmux for persistence):
   ```bash
   tmux new-session -s ci-daemon "make ci-daemon"
   ```

### How the Daemon Works

1. Subscribes to `ntfy.sh/<NTFY_TOPIC>/json` (server-sent events)
2. Parses CI signal JSON from the `extras` field
3. On **success**: finds the tmux session for that repo/branch and injects a resume prompt
4. On **failure**: wakes the agent with error context so it can fix and re-push

## CI History

View recent CI run logs:

```bash
make ci-history
```

## Budget Control

Set a spending cap for overnight agent runs:

```yaml
# config/defaults.yaml
ci:
  budget_cap_usd: 5.0
```

Or via `.env`:

```env
BUDGET_CAP_USD=5.0
```
