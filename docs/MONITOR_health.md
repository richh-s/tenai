# Monitor — System Health

## Quick Health Check

```bash
make check                   # local
make check HOST=<host-name>      # remote device
```

Verifies all tools are installed and shows versions:
- tailscale, mosh, tmux, claude, gemini, node, python3, git, jq, curl

## Full Status

```bash
make status                  # local — Tailscale peers, tmux, repos
make status HOST=<host-name>     # remote — Tailscale, tmux, disk, uptime, Docker
```

Remote status shows:
- **Tailscale** — peer list and connection status
- **tmux sessions** — active sessions on the device
- **Disk** — filesystem usage
- **Uptime** — device uptime and load
- **Docker** — running containers and ports

## Per-Device Checks

From any device with aliases configured:

```bash
# Tailscale status + public IP
ts_check

# Ping all devices
ping_<host-name>

# SSH test
ssh_<host-name> "echo ok"
```

## Tailscale Dashboard

- Admin panel: [login.tailscale.com/admin](https://login.tailscale.com/admin)
- View all devices, keys, ACLs, exit nodes

## CI Run History

```bash
make ci-history
```

## Webapp Status

If running in tmux:

```bash
tmux list-sessions | grep tenai-webapp
```

Access at `http://localhost:7700` or via Tailnet URL shown at startup.
