# Architecture — tenai Mesh

## Overview

tenai is a personal infrastructure mesh that connects all your devices (servers, Mac, Android, iOS, Windows) into a single private network via **Tailscale**.

> 📖 For the AI agent orchestration system, see [CONCEPT_agent_system.md](CONCEPT_agent_system.md).

```
┌──────────────────────────────────────────────────────────────────┐
│                    Tailscale Mesh (WireGuard)                     │
│                                                                  │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌───────────┐  │
│  │ Server A   │  │ Server B   │  │  Laptop    │  │  Mobile   │  │
│  │ (compute)  │  │ (compute)  │  │ (control)  │  │ (monitor) │  │
│  │ 100.x.x.x │  │ 100.y.y.y │  │ 100.z.z.z │  │ 100.w.w.w│  │
│  └─────┬──────┘  └─────┬─────┘  └─────┬──────┘  └─────┬─────┘  │
│        │               │              │               │          │
│    Mosh+tmux       Mosh+tmux      Mosh+tmux        SSH/Mosh    │
│    AI Agents       AI Agents      AI Agents                     │
│    VibeTunnel      VibeTunnel     VibeTunnel                    │
│    Webapp:7700     Webapp:7700                                  │
│    Exit Node       Exit Node                                    │
└──────────────────────────────────────────────────────────────────┘
```

## Layer Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| **Network** | Tailscale (WireGuard) | Encrypted mesh VPN, MagicDNS, exit nodes |
| **Shell Access** | Mosh → tmux | Resilient mobile shell + persistent sessions |
| **SSH** | Tailscale SSH + key-based | Direct access, SCP, file transfer |
| **Browser Terminal** | VibeTunnel (ghostty-web) | Browser-based terminal to tmux sessions |
| **Dev Tools** | Claude Code, Gemini CLI, Codex CLI | AI coding agents |
| **Orchestration** | Make + Hydra + Python | Config-driven setup & management |
| **Packages** | uv (Python), npm (Node.js) | Fast, reliable dependency management |
| **Web UI** | FastAPI webapp + VibeTunnel API | Job creation, VT terminal bridge |

## Config Flow

```
.env (secrets)  +  config/defaults.yaml (devices, repos)
        │                      │
        └──────┬───────────────┘
               ▼
          setup.py (Hydra)
               │
               ▼
      scripts/install/*.sh   →  Install tools
      scripts/configure/*.sh →  Write SSH config, aliases
```

## Device Types

Each device auto-detects its type via `scripts/detect.sh`:

- **server** (`linux`) — apt-based, enables IP forwarding, UFW, Tailscale SSH, exit node
- **mac** (`Darwin`) — brew-based, zsh, no mosh bind
- **android** (`termux`) — pkg-based, limited tool set
- **ios_ish** (`alpine`) — apk-based, local Linux sandbox on iOS
- **ios_termius** — SSH/Mosh client only, no local setup
- **windows** (`powershell`) — winget-based, OpenSSH server

## Key Design Decisions

1. **Marker-based config blocks** — aliases and SSH config use `START`/`END` markers for idempotent replace-on-rerun
2. **`command -v` guards** — all install scripts skip if tool is already present
3. **uv over pip** — faster installs, no `--break-system-packages` needed with `--system` flag
4. **Hydra config** — YAML-based with CLI overrides for any value
5. **`create_subprocess_exec` for SSH** — avoids `$HOME`/`$SHELL` expansion issues in Docker containers
6. **VT API bridge, not wrapping** — `vt` crashes in detached tmux; webapp calls VT REST API after tmux session creation
7. **SSH key distribution** — `make git-ssh HOST=x` copies local GitHub SSH key to remotes instead of generating per-device keys
