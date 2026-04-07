# CLAUDE.md — Instructions for Claude Code

> This file is read automatically by Claude Code when working in this repo.

## Project Identity

**tenai-infra** — Infrastructure-as-code for the tenai mesh network.
Connects Linux servers, macOS workstation, Android phone, iOS devices, and Windows machines
into a single encrypted mesh with persistent sessions, AI coding agents, and automated repo management.

## Architecture

```
.env / config/defaults.yaml  →  setup.py (Hydra)  →  scripts/{install,configure}/*.sh
                                                       ↓
                                              Makefile orchestrates everything
                                                       ↓
                                              webapp/ Docker container on servers
```

- **scripts/install/** — Idempotent installers: tailscale, mosh, tmux, tools (claude/gemini/codex/muxtree/vibetunnel), mobile bootstrap
- **scripts/configure/** — SSH config, shell aliases, git-ssh-setup, key distribution, device registration (marker-based, idempotent)
- **scripts/conductor/** — Gemini CLI session manager + CI webhook daemon
- **scripts/entrypoints/** — Orchestration scripts (onboard, new-server, sync, git-ssh)
- **scripts/repos/** — Git worktree management + multi-agent dispatch
- **webapp/** — FastAPI control panel (runs in Docker, executes jobs via SSH to remote devices)
- **config/** — Hydra YAML configs (devices, orgs, repos, conductor settings)
- **docs/** — Categorized docs (CONCEPT_, DATA_FLOW_, DEBUG_, EXAMPLE_, HOWTO_, MONITOR_)

## Key Rules

1. **Idempotency is sacred.** Every script must be safe to re-run.
   - Use `command -v` guards for installs
   - Use marker-based `START`/`END` blocks for config files
   - Use `grep -qxF` dedup for append operations
2. **Shell compatibility.** Scripts must work on Linux (bash), macOS (zsh), Termux, iSH, and Windows.
   Use `scripts/detect.sh` for platform detection (`$OS_TYPE`: linux/mac/termux/ish/windows/wsl).
3. **Python uses `uv`**, not pip3. Use `uv venv .venv` + `uv pip install -p .venv <pkg>`. Never install system-wide.
4. **Tool selection.** `INSTALL_ONLY` / `SKIP_TOOLS` env vars control what gets installed.
   Every install function must be wrapped with `should_install <tool> && install_<tool> || true`.
5. **Config via Hydra.** Device configs live in `config/defaults.yaml`. Secrets in `.env`.
6. **Marker strings are stable.** Do NOT rename `TENAI INFRA ALIASES START/END` or
   `TENAI INFRA SSH START/END` — users have these in their live shell configs.
7. **No hardcoded IPs.** Use config/defaults.yaml entries resolved via `resolve_host.py`.
8. **SSH in webapp uses `create_subprocess_exec`** (not `create_subprocess_shell`) to prevent
   Docker's local shell from expanding `$HOME`, `$SHELL`, etc. These must expand on the remote device.
9. **Webapp runs in Docker.** Jobs execute via SSH to remote devices — not inside the container.
   Use `_resolve_home(user)` for paths, never rely on Docker's `$HOME`.

## Environment Setup

Before running any Python code, set up the development environment:

```bash
make install-deps   # creates .venv, installs all runtime + dev dependencies from pyproject.toml
```

This is **required** before `make lint`, `make test`, or running any Python script.
If the venv already exists, re-running is safe (idempotent).

## Using the Makefile

**Always check the `Makefile`** to discover available targets for setup, testing, linting,
deployment, and other operations. Run `make help` to see the full list of targets with
descriptions. Use the appropriate Makefile targets rather than running raw commands —
they handle venv activation, path setup, and cross-platform concerns automatically.

## Shell Functions (auto-generated per device, written to user's rc file)

| Function | What it does |
|----------|-------------|
| `<device> [session]` | Mosh into device → tmux session |
| `ssh_<device>` | Direct SSH to device |
| `send_<device> <file>` | Tailscale file send to device |
| `ts_check`, `ts_status` | Tailscale diagnostics |

## Verification — Run After Every Change

```bash
make lint        # ruff linter on scripts/ webapp/ tests/
make test        # pytest suite — unit + integration tests
```

**Targeted tests** — run the test file matching the module you changed:

| If you changed… | Run… |
|-----------------|------|
| `webapp/db.py` | `make test -- tests/test_db.py` |
| `webapp/server.py` | `make test -- tests/test_api.py` |
| `scripts/configure/generate_aliases.py` | `make test -- tests/test_aliases.py` |
| `scripts/configure/resolve_host.py` | `make test -- tests/test_resolve_host.py` |
| `scripts/env_loader.py` | `make test -- tests/test_env_loader.py` |
| `config/defaults.yaml` or `config/device/*.yaml` | `make test -- tests/test_config.py` |

```bash
make onboard     # guided device onboarding wizard
make check       # verify all tools are installed
make check HOST=x # verify tools on remote device
make check-tools # dynamic tool check
make status      # tailscale + tmux + repos overview
make status HOST=x # remote status (disk, uptime, Docker)
make validate    # run CI validation (for target repos, not tenai-infra itself)
```

## Harness Engineering

### Context Engineering
- Read ALL instruction files (`CLAUDE.md`, `WORKTREE.md`, `WORKFLOW.md`) before starting
- Check `config/defaults.yaml` for project-specific settings
- Read `docs/` for architecture context when modifying core components

### Architectural Constraints
- Run `make lint && make test` after EVERY code change
- Follow existing patterns — do not introduce new frameworks without approval
- All scripts must be idempotent and multi-platform

### Entropy Management
- After completing work, verify documentation is up to date
- Remove dead code and unused imports
- Ensure all new functions have corresponding tests
- Run `make lint` to catch style violations

## Proof of Work

When working in a worktree on a dispatched task:
1. Implement the task described in `WORKTREE.md`
2. Run all tests and capture output
3. Create `PROOF.md` with: test results, files changed, brief walkthrough
4. Commit everything including `PROOF.md`
5. Push branch: `git push -u origin <branch>`
6. Exit when complete

## Testing Rules

10. **After modifying Python code, always run `make lint && make test`** before committing.
    If you add a new function to `db.py`, `server.py`, or config scripts, add a corresponding test.
11. **Use the `/verify` workflow** — it maps changed files to their test files and runs them
    in the correct order (lint → test → check).

## Documentation Convention

Docs in `docs/` follow a prefix-based naming scheme:
- `CONCEPT_` — Architecture, design decisions
- `DATA_FLOW_` — Pipeline diagrams, flow charts
- `DEBUG_` — Troubleshooting guides
- `EXAMPLE_` — End-to-end walkthroughs
- `HOWTO_` — Task-specific how-to guides
- `MONITOR_` — Health checks, observability

## Skills

Skills are reusable agent instructions in `.agents/skills/<name>/SKILL.md`.
They are the single source of truth, symlinked to `.claude/skills/`, `.gemini/skills/`, `.codex/skills/`.

- **Add new skills** to `.agents/skills/<name>/SKILL.md` — see `docs/HOWTO_skills.md`
- **After creating a skill**, always validate it with the `validate-skill` skill
- **Sync locally**: `make skills-sync` (creates symlinks to CLI dirs)
- **Deploy to devices**: `make cli-skills HOST=<device>` or `make cli-skills HOST=all`
- Skills must be **self-sufficient** — only depend on `curl`, `git`, `gh`, `make` (no repo-internal scripts)

## Do NOT

- Remove or rename marker strings in aliases.sh or ssh.sh
- Use `pip3` — always use `uv`
- Hard-code device IPs, hostnames, or paths
- Add secrets to any tracked file (use `.env`)
- Break `set -euo pipefail` in scripts (use `|| true` for allowed failures)
- Use `create_subprocess_shell` in the webapp for SSH commands
- Wrap commands with `vt` inside detached tmux sessions (vt needs interactive TTY)
