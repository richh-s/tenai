# How To — Web Control App

## Overview

The tenai webapp is a FastAPI-based browser control panel for managing the mesh network. It runs as a Docker container on server devices and is accessible over the Tailscale network.

## Deployment

The webapp deploys automatically when you sync code to a server:

```bash
make sync HOST=myserver   # syncs code + rebuilds Docker container
```

Access at: **`http://<device-ip>:7700`** (e.g., `http://100.x.y.z:7700`)

## Features

### Device Dashboard
- Shows all devices from `config/defaults.yaml`
- Live online/offline status via SSH ping
- Quick-connect buttons (Mosh/SSH/tmux)

### Organization Management
- Add/remove GitHub organizations from the sidebar
- Sync repos from GitHub (uses `GITHUB_TOKEN` for private repos)
- Per-org SSH host aliases configured automatically

### Repository Browser
- Searchable list of all repos across organizations
- Sorted by last GitHub activity (most recent first)
- Shows repo name with compact styling

### Job Launcher
Create remote jobs with these actions:

| Action | What it does |
|--------|-------------|
| 🖥 Interactive Shell | Auto-clones repo if needed, opens tmux + shell |
| 🤖 Start Conductor | Auto-clones repo, starts Gemini conductor session |
| 🚀 Dispatch Agent | Auto-clones repo, creates git worktree, runs AI agent |
| 📦 Clone Repo Only | Clones the repo to the device |
| ⬇ Pull Repo Only | Pulls latest on an existing repo |

### Job Details
- Click any job to see full command, logs, and status
- Connect command for attaching to tmux sessions
- VibeTunnel session tracking (`vt_session_id`, `vt_url`)

### VibeTunnel Integration

After creating a tmux-based job (shell, conductor, dispatch), the webapp automatically calls VibeTunnel's REST API to bridge the session:

1. **Auto-attach**: `POST /api/tmux/attach` on VibeTunnel creates a PTY bridge to the tmux session
2. **🖥 Terminal button**: Job rows show a green "Terminal" button that opens VibeTunnel's browser terminal in a new tab
3. **Status sync**: Background poller (every 30s) checks VT session status and marks jobs as `completed` when the terminal exits
4. **Graceful fallback**: If VibeTunnel isn't running, falls back to the mosh/tmux connect command

See [CONCEPT_webapp_vibetunnel.md](CONCEPT_webapp_vibetunnel.md) for the full architecture.

## Docker Architecture

The webapp runs inside Docker with:
- SSH keys volume-mounted for remote device access
- `.env` propagated with device-specific values
- Auto-rebuilt on every `make sync`

```
Docker Container (tenai-webapp)
├── FastAPI server (uvicorn, port 7700)
├── SQLite database (tenai.db)
├── SSH client → remote devices via Tailscale
└── Volume: host ~/.ssh → container SSH keys
```

## Configuration

| Variable | Default | Source |
|----------|---------|--------|
| `WEBAPP_PORT` | `7700` | `.env` or `config/defaults.yaml` |
| `WEBAPP_HOST` | `0.0.0.0` | `.env` or `config/defaults.yaml` |
| `VT_PORT` | `4020` | `.env` — VibeTunnel port on remote devices |
| `GITHUB_TOKEN` | *(empty)* | `.env` — required for private repo sync |
| `BASE_DIR` | `~/tenai-projects` | `.env` or `config/defaults.yaml` |

## Database Schema

SQLite database at `data/tenai.db`:

| Table | Purpose |
|-------|---------|
| `devices` | Cached device info |
| `organizations` | GitHub orgs with SSH aliases |
| `repos` | Synced repos with `pushed_at` for activity sorting |
| `jobs` | Job history with status, logs, VibeTunnel session info |

## Security

- The webapp is accessible on your Tailscale network only (100.x.x.x)
- `GITHUB_TOKEN` stored in `.env` (never committed)
- SSH keys mounted read-only from host
- Jobs execute via SSH to the target device (not inside Docker)
