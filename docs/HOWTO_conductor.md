# How To — Gemini Conductor

## Overview

The Conductor is a tmux-based Gemini CLI session manager. It starts Gemini CLI in a dedicated tmux session per repo — locally or on remote devices — for task generation and AI-assisted planning.

## Start a Conductor Session

```bash
# Local:
make conductor REPO=<repo-name>

# Remote device:
make conductor REPO=<repo-name> HOST=<host-name> ORG=<org-name>
```

This:
1. Resolves the repo path (`$BASE_DIR/<org>/<repo-name>`)
2. Opens a tmux session named `<repo>-conductor`
3. Starts Gemini CLI with the configured model
4. Optionally splits into two panes if `split_pane: true` in config

## Send a Prompt

```bash
make conductor-send REPO=tenai PROMPT="generate tasks for auth module"
make conductor-send REPO=myapp PROMPT="analyze the API layer" HOST=<host-name>
```

## View Generated Tasks

```bash
make tasks REPO=tenai
make tasks REPO=tenai HOST=<host-name> ORG=<org-name>
```

Shows the contents of `TASKS.md` in the repo.

## Parse and Dispatch Tasks

```bash
make parse-tasks REPO=tenai           # Parse TASKS.md into structured output
make validate-tasks REPO=tenai        # Validate tasks pass ATC filter
make dispatch-tasks REPO=tenai        # Auto-dispatch to agent worktrees
```

All support `HOST=` for remote operation.

## Start All / List / Kill

```bash
make conductor-all                          # Start conductors for all repos
make conductor-list                         # List active conductor sessions
make conductor-list HOST=<host-name>            # List on remote device
```

## Tmux Session Management

If stale sessions block new conductors from picking up extensions:

```bash
make tmux-list HOST=<host-name>                 # See what's running
make tmux-clean HOST=<host-name>                # Kill stale sessions (keeps 'main')
make tmux-kill-all HOST=<host-name>             # Nuclear — kill everything
make tmux-clean HOST=all                    # Clean all devices
```

After cleaning, re-run `make conductor ...` to start a fresh session.

## Configuration

Settings in `config/defaults.yaml`:

```yaml
conductor:
  tmux_session_suffix: "-conductor"
  gemini_model: "gemini-3.1-pro-preview"  # gemini-3-flash-preview, gemini-2.5-pro, etc.
  claude_model: "sonnet"                  # sonnet (4.6), opus (4.6)
  codex_model: ""                         # empty = codex default
  split_pane: false                       # true = task monitor in right pane
  task_output_file: "TASKS.md"
  workflow:
    - spec
    - plan
    - implement
```

## Prerequisites

The **conductor** Gemini CLI extension must be installed:

```bash
make cli-extensions CLI=gemini HOST=<host-name>   # Install on remote
make cli-extensions CLI=gemini                # Install locally
```

Or manually: `gemini extensions install https://github.com/gemini-cli-extensions/conductor --auto-update`

## Tips

- **Attach to session**: `tmux attach -t tenai-conductor`
- **Kill a session**: `tmux kill-session -t tenai-conductor`
- **Extension not found?** Kill stale tmux sessions and re-run — extensions load at session start
- **Custom repo paths**: Pass the full path via `REPO=`:
  ```bash
  make conductor REPO=/path/to/my-repo
  ```
