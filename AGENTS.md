# AGENTS.md — Instructions for OpenAI Codex CLI

> This file is read automatically by Codex CLI when working in this repo.

## Project

**tenai-infra** — Infrastructure-as-code for the tenai mesh network.
Manages: Tailscale VPN, Mosh, tmux, AI agent CLIs (Claude/Gemini/Codex),
git worktrees for parallel agent work, and a FastAPI web control panel.

## Structure

| Directory | Purpose |
|-----------|---------|
| `scripts/install/` | Idempotent tool installers (tailscale, mosh, tmux, tools) |
| `scripts/configure/` | SSH config, shell aliases, git-ssh-setup, key distribution |
| `scripts/conductor/` | Gemini session manager, task parser, CI daemon |
| `scripts/entrypoints/` | Orchestration scripts (onboard, new-server, sync, git-ssh) |
| `scripts/repos/` | Git worktree management, merge safety, multi-agent dispatch |
| `webapp/` | FastAPI control panel (runs in Docker on servers) |
| `config/` | Hydra YAML configs (devices, orgs, repos, CLI settings) |
| `docs/` | Categorized docs (CONCEPT_, DATA_FLOW_, DEBUG_, EXAMPLE_, HOWTO_) |

## Rules

- **Idempotent**: all scripts safe to re-run (`command -v` guards, marker blocks)
- **Cross-platform**: Linux, macOS, Termux, iSH, Windows — use `scripts/detect.sh` (`$OS_TYPE`)
- **Bash shebangs**: Use `#!/bin/bash` for all shell scripts (NOT `#!/usr/bin/env bash`).
  On Apple Silicon Macs, `#!/usr/bin/env bash` can pick up an x86_64 Intel bash from PATH,
  which forces Rosetta 2 translation and breaks ARM Homebrew. `/bin/bash` is always native
  on macOS, Linux, and WSL. **Exception**: Termux (Android) has bash at `$PREFIX/bin/bash`;
  scripts invoked there should be run via `bash script.sh` rather than direct execution.
  If you need bash 4+ features (associative arrays, `${var,,}`, etc.), use
  `#!/opt/homebrew/bin/bash` on macOS or guard with a version check:
  ```bash
  #!/bin/bash
  if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "This script requires bash 4+. Install: brew install bash" >&2; exit 1
  fi
  ```
- **Python in scripts**: Always use `$PYTHON` (exported by `detect.sh`), never bare `python3`.
  All Python deps (pyyaml, etc.) live in `.venv`; system python3 may not have them.
  `detect.sh` resolves `$PYTHON` → `.venv/bin/python3` → system python3 (in that order).
- **Python**: use `uv venv .venv` + `uv pip install -p .venv <pkg>`, never install system-wide
- **Config**: `config/defaults.yaml` for generic tracked defaults, `config/local.yaml` for
  personal overrides (devices, orgs, proxy — gitignored), `.env` for secrets.
  Scripts use `scripts/lib/load_config.py` to merge defaults + local overlay.
  Set `TENAI_CONFIG` in `.env` to use a custom overlay path.
- **Do not rename** marker strings: `TENAI INFRA ALIASES START/END`, `TENAI INFRA SSH START/END`
- **Tool selection**: `INSTALL_ONLY` / `SKIP_TOOLS` env vars control installation
- **SSH commands**: Use `create_subprocess_exec` (not `shell`) to avoid Docker `$HOME`/`$SHELL` expansion
- **Webapp**: Runs in Docker; jobs execute via SSH to remote devices, not inside the container

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

## Conductor Role

When used as a Conductor, your job is to:
1. **Analyze** the codebase and understand the current state
2. **Generate tasks** in `TASKS.md` using the ATC filter:
   - **Self-Contained** — works in its own worktree
   - **Verifiable** — has clear pass/fail criteria
   - **Bounded** — completable in < 2 hours
   - **Parallelizable** — no cross-task dependencies
   - **Resume-safe** — can be restarted without side effects
3. **Prioritize** tasks by impact and dependency order
4. **Validate** tasks by running `python3 scripts/conductor/parse_tasks.py . --validate`

## Harness Engineering

### Context Engineering
- Read ALL instruction files (`AGENTS.md`, `WORKTREE.md`, `WORKFLOW.md`) before starting
- Check the merged config (`config/defaults.yaml` + `config/local.yaml`) for project settings
- Personal data (devices, orgs, proxy) belongs in `config/local.yaml`, not `defaults.yaml`

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

## Verification

After modifying Python code, **always run**:

```bash
make lint        # ruff linter on scripts/ webapp/ tests/
make test        # pytest suite — unit + integration
```

Targeted tests — run the file matching your change:
- `webapp/db.py` → `make test -- tests/test_db.py`
- `webapp/server.py` → `make test -- tests/test_api.py`
- `scripts/configure/generate_aliases.py` → `make test -- tests/test_aliases.py`
- `scripts/configure/resolve_host.py` → `make test -- tests/test_resolve_host.py`
- `config/*.yaml` → `make test -- tests/test_config.py`

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

## Key Commands

```bash
make              # full setup (idempotent)
make check        # verify tools installed
make status       # mesh + repos overview
make conductor    # start Gemini conductor session
make dispatch     # dispatch agent to worktree
make validate     # CI validation
make parse-tasks  # parse TASKS.md into structured view
make validate-tasks # check ATC compliance
make dispatch-tasks # auto-dispatch all Active tasks
make check-conflicts # check file overlap between branches
make validate-worktrees # run tests in each worktree
make merge-sequential # merge one-by-one with validation
```
