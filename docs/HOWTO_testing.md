# How To — Testing

## Quick Start

```bash
# Run all tests
make test

# Run linter
make lint

# Run a specific test file
.venv/bin/python3 -m pytest tests/test_db.py -v

# Run a single test by name
.venv/bin/python3 -m pytest tests/test_db.py -k "test_upsert_and_get" -v

# Run only unit tests (no I/O)
.venv/bin/python3 -m pytest tests/ -m unit

# Run only integration tests (FastAPI TestClient)
.venv/bin/python3 -m pytest tests/ -m integration
```

## Test Architecture

```
tests/
├── conftest.py          # Shared fixtures (tmp_db, sample_config, sample_env)
├── test_db.py           # SQLite CRUD: organizations, repos, devices, jobs, logs
├── test_config.py       # YAML config validation: structure, types, profiles
├── test_aliases.py      # Alias generation: capabilities, ports, self-exclusion
├── test_resolve_host.py # Host resolution: by name, by IP, skip_tools merge
├── test_env_loader.py   # .env loading: whitespace stripping, defaults
└── test_api.py          # FastAPI endpoints: status, orgs, repos, devices, jobs
```

| Layer | Test File | Markers | What It Validates |
|-------|-----------|---------|-------------------|
| Database | `test_db.py` | `unit` | All CRUD ops, COALESCE logic, WAL mode |
| Config | `test_config.py` | `unit` | YAML structure, required fields, device profiles |
| Aliases | `test_aliases.py` | `unit` | `_safe_name`, capabilities matrix, alias output |
| Resolve | `test_resolve_host.py` | `unit` | Host lookup by name/IP, skip_tools merge |
| Env | `test_env_loader.py` | `unit` | Whitespace stripping, missing file handling |
| API | `test_api.py` | `integration` | FastAPI endpoints via TestClient |

## Key Fixtures (conftest.py)

| Fixture | Description |
|---------|-------------|
| `tmp_db` | Temporary SQLite DB, patches `db.DB_PATH`, auto-initializes schema |
| `sample_config` | Representative config dict matching `defaults.yaml` structure |
| `sample_env` | Temporary `.env` file with test values (includes whitespace edge cases) |
| `clean_env` | Saves/restores `os.environ` for test isolation |

## Adding a New Test

1. Create or edit a file in `tests/` matching `test_*.py`
2. Import what you need from `webapp/` or `scripts/` (path setup is in `conftest.py`)
3. Use `@pytest.mark.unit` or `@pytest.mark.integration` markers
4. Use fixtures from `conftest.py` for database/config isolation
5. Run `make test` to verify

## CI Pipeline

Tests run automatically on every push via GitHub Actions (`.github/workflows/ci.yml`):

1. **Lint** — `ruff check` on `scripts/`, `webapp/`, `tests/`
2. **Test** — `pytest` on all test files
3. **Signal** — sends ntfy.sh notification with pass/fail status

Set `NTFY_TOPIC` as a GitHub repo secret to receive CI signals.

## Sandbox / End-to-End Testing

Test the full onboarding pipeline in an isolated virtual machine before releasing changes.

### Engine Comparison

| | Multipass | Tart |
|---|---|---|
| **VM Type** | Ubuntu (Linux) | macOS (ARM64) |
| **Platform** | macOS, Linux, Windows | macOS (Apple Silicon only) |
| **Provisioning** | Cloud-init (automatic) | SSH + git clone |
| **Use case** | Linux server onboarding | macOS device onboarding |
| **Install** | `brew install multipass` | `brew install cirruslabs/cli/tart` |

### Quick Start

```bash
# Prerequisites
cp .env.example .env.test
$EDITOR .env.test   # set TAILSCALE_AUTH_KEY, TAILSCALE_TAILNET, GITHUB_TOKEN

# Multipass (Linux VM)
make test-sandbox                          # interactive — SSH in and test manually
make test-sandbox AUTO=1                   # automated — runs full pipeline

# Tart (macOS VM)
make test-sandbox ENGINE=tart              # interactive macOS sandbox
make test-sandbox ENGINE=tart AUTO=1       # automated macOS pipeline
```

### What the Auto Pipeline Does

The automated pipeline runs exactly what a real user would do following the README:

```
make reset-device NONINTERACTIVE=1 CONFIRM=1 TAILNET="test@"
make onboard CONFIRM=1 TEST=1
make check
make test
```

If this pipeline fails, a real user following the README would hit the same bug.

### Available Flags

| Flag | Default | Description |
|------|---------|-------------|
| `ENGINE` | `multipass` | VM engine: `multipass` or `tart` |
| `AUTO` | `0` | Run full pipeline automatically (no SSH) |
| `KEEP` | `0` | Keep VM after test (skip teardown) |
| `TART_IMAGE` | `ghcr.io/cirruslabs/macos-tahoe-vanilla:latest` | Tart OCI base image |
| `UBUNTU_VERSION` | auto-detected | Specific Ubuntu version for Multipass |
| `UPDATE_PACKAGES` | `0` | Run `apt update` before test |
| `NAME` | `tenai-test-node-tmp` | Custom VM name |

### Tart Image Caching

Tart downloads large macOS images (~27 GB) on first use. To avoid re-downloading:

1. **OCI cache**: Tart automatically caches downloaded images in `~/.tart/cache/OCIs/`
2. **VM reuse**: If a VM with the same name exists, the script reuses it instead of cloning fresh — this skips the 20+ minute Homebrew/Xcode setup
3. **Baking workflow**: Run with `KEEP=1`, let setup complete, then re-run without `KEEP` — the cached VM boots instantly

```bash
# First run: downloads image + installs Homebrew (slow)
make test-sandbox ENGINE=tart AUTO=1 KEEP=1

# Subsequent runs: reuses cached VM (fast)
make test-sandbox ENGINE=tart AUTO=1
```

### Accessing VMs

```bash
# Tart (macOS)
ssh admin@$(tart ip <vm-name>)     # SSH (password: admin)
tart run <vm-name>                  # GUI desktop window

# Multipass (Ubuntu)
ssh ubuntu@<ip>                     # SSH (key injected via cloud-init)
multipass shell <vm-name>           # Alternative shell access
```

### Logs

Test logs are persisted to `sandbox-logs/<date>_<vm-name>/` on the host.

### Troubleshooting

| Issue | Solution |
|-------|----------|
| Tart fails with architecture error | Shell is running under Rosetta. The script auto-detects Apple Silicon and forces `arch -arm64`. |
| SSH password prompt during rsync | Tart macOS VMs use password `admin`. The script uses `StrictHostKeyChecking=no`. |
| `make validate-pipeline` not found | This was a bug (fixed). The pipeline now runs `make reset-device` → `make onboard` → `make check` → `make test`. |
| Multipass VM stuck in "Starting" | Run `multipass delete --purge <name>` and retry. |
| Tart VM won't get an IP | Wait longer (up to 60s). Check `tart list` for status. |

