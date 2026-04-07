# Tailscale Proxy Routing — Route CLI Traffic via Exit Node

> 📖 Routes specific CLI tools (Claude, Gemini, Codex) through a Tailscale exit node
> using **SSH dynamic port forwarding** + a **privoxy HTTP bridge**.
> Your main system traffic stays on local ISP — only prefixed commands go through the proxy.

## Why?

Some CLI tools (AI agents, API clients) may need to appear to originate from a
specific geographic location or IP address. Instead of routing *all* traffic through
a VPN exit node (which slows everything down), this setup lets you selectively
proxy individual commands through a Tailscale exit node.

```
┌───────────────────────────────────────────────────────────────────────┐
│  Your Mac/Linux/Windows Device                                        │
│                                                                       │
│   claude ──── direct ──────────────────► Anthropic API (local ISP)    │
│                                                                       │
│   tenai_claude ──► HTTPS_PROXY=http://127.0.0.1:8118                  │
│                         │                                             │
│                    ┌────▼────────┐                                    │
│                    │  privoxy    │  HTTP CONNECT → SOCKS5 bridge      │
│                    │  :8118      │                                    │
│                    └────┬───────┘                                    │
│                         │                                             │
│                    ┌────▼────────┐                                    │
│                    │  SSH -D     │  SOCKS5 tunnel over Tailscale      │
│                    │  :1055      │                                    │
│                    └────┬───────┘                                    │
│                         │ WireGuard                                   │
└─────────────────────────┼────────────────────────────────────────────┘
                          │
                   ┌──────▼──────┐
                   │ Exit Node   │
                   │ (<host-name>)   │
                   └──────┬──────┘
                          │
                   ┌──────▼──────┐
                   │ Anthropic   │
                   │ API (exit   │
                   │ node's ISP) │
                   └─────────────┘
```

## How It Works

### Component Stack

| Component | Role | Port |
|-----------|------|------|
| **SSH -D** (dynamic forwarding) | SOCKS5 tunnel through the Tailscale exit node | 1055 |
| **privoxy** | HTTP CONNECT proxy that forwards to SOCKS5 | 8118 |
| **`HTTPS_PROXY` env var** | Tells the wrapped CLI (Node.js/Bun/curl) to use privoxy | — |
| **`tenai_*` aliases** | Shell functions wrapping commands with HTTPS_PROXY | — |

### Why Two Proxy Layers?

**Problem**: Node.js and Bun (which Claude Code runs on) do **not** support
SOCKS5 proxies via environment variables. They only respect `HTTP_PROXY` / `HTTPS_PROXY`
for HTTP CONNECT proxies.

**Solution**: privoxy acts as a protocol bridge — it accepts HTTP CONNECT requests
on port 8118 and forwards them through the SOCKS5 tunnel on port 1055.

### Data Flow

```
tenai_claude "help me"
    │
    ▼
HTTPS_PROXY=http://127.0.0.1:8118 claude "help me"
    │
    │  (Bun reads HTTPS_PROXY, sends HTTP CONNECT to privoxy)
    ▼
privoxy on 127.0.0.1:8118
    │
    │  (forwards via forward-socks5 → 127.0.0.1:1055)
    ▼
SSH SOCKS5 tunnel on 127.0.0.1:1055
    │
    │  (SSH dynamic port forwarding over Tailscale)
    ▼
<host-name> exit node → Internet
```

## Alternatives Evaluated

We evaluated several approaches before arriving at the current solution.
Each was rejected for specific technical reasons:

### 1. tailsocks + proxychains4 (❌ Rejected)

| Component | Issue |
|-----------|-------|
| **tailsocks** | Uses tsnet's userspace networking (`fakeRouter`). Exit node prefs are set but packets are dropped: `"packet was not handled"`. This is a [known tsnet limitation](https://github.com/tailscale/tailscale/issues/14195). |
| **proxychains4** | Works via `DYLD_INSERT_LIBRARIES` injection. macOS SIP silently blocks this for system binaries. Even non-system binaries are unreliable. |

### 2. ALL_PROXY=socks5h:// (❌ Rejected for Node.js/Bun)

| Component | Issue |
|-----------|-------|
| **curl, wget** | ✅ Correctly respects `ALL_PROXY` with SOCKS5. Confirmed: returns exit node IP. |
| **Node.js / Bun** | ❌ Ignores `ALL_PROXY` for SOCKS5 entirely. Tested: always returns local IP. Claude Code, Gemini CLI, and Codex are all Node.js-based. |

### 3. Tailscale system-wide exit node (⚠ Not selective)

```bash
tailscale set --exit-node=<host-name>   # ALL traffic goes through exit node
```

Works, but routes ALL traffic (browsers, system updates, everything) through
the exit node. This slows down everything and is the exact thing we're trying to avoid.
On mobile (Termux), Tailscale supports **split tunneling** to select which apps
use the exit node — macOS does not support this natively.

### 4. gost (GO Simple Tunnel) (✅ Viable alternative)

```bash
gost -L http://127.0.0.1:8118 -F socks5://127.0.0.1:1055
```

| Aspect | Assessment |
|--------|-----------|
| **Pros** | Single Go binary, no dependencies, multi-protocol, modern, active development |
| **Cons** | Heavier binary (~20MB), more complex config for our simple use case |
| **Verdict** | Excellent tool, but overkill. We only need HTTP→SOCKS5 bridging. |

### 5. privoxy (✅ Selected)

| Aspect | Assessment |
|--------|-----------|
| **Pros** | Battle-tested (20+ years), tiny (<2MB), available everywhere (brew/apt/choco), one-line config, designed for exactly this use case |
| **Cons** | C binary (not a single binary, has config files), privacy-filtering features we don't use |
| **Verdict** | Best fit — lightweight, reliable, one-line SOCKS5 forwarding config, cross-platform |

### Decision Matrix

| Solution | Works with Node.js/Bun | Selective (per-command) | Cross-platform | Complexity | Status |
|----------|:---------------------:|:----------------------:|:--------------:|:----------:|:------:|
| tailsocks + proxychains4 | ❌ | ✅ | ❌ (SIP) | High | Rejected |
| ALL_PROXY=socks5h:// | ❌ | ✅ | ✅ | Low | Rejected |
| Tailscale system exit node | ✅ | ❌ | ✅ | Low | Not selective |
| gost | ✅ | ✅ | ✅ | Medium | Viable |
| **privoxy** | ✅ | ✅ | ✅ | Low | **Selected** |

## Setup

### 1. Install privoxy

```bash
# macOS
brew install privoxy

# Ubuntu/Debian
sudo apt-get install -y privoxy

# Windows (Chocolatey)
choco install privoxy

# Windows (Scoop)
scoop install privoxy
```

### 2. Configure privoxy for SOCKS5 forwarding

Add this line to privoxy's config file:

```bash
# macOS (Homebrew)
echo "forward-socks5 / 127.0.0.1:1055 ." >> $(brew --prefix)/etc/privoxy/config

# Linux
echo "forward-socks5 / 127.0.0.1:1055 ." >> /etc/privoxy/config

# Windows
# Add to C:\Program Files\Privoxy\config.txt:
# forward-socks5 / 127.0.0.1:1055 .
```

This tells privoxy: "forward ALL requests through SOCKS5 at 127.0.0.1:1055".
The trailing `.` means "no secondary HTTP proxy".

### 3. Configure Exit Node

In `config/defaults.yaml`:

```yaml
proxy:
  enabled: true
  socks_port: 1055       # SSH SOCKS5 tunnel port
  http_port: 8118        # privoxy HTTP bridge port (default)
  exit_node: "<host-name>"   # Tailscale exit node device name
  proxied_tools:
    - claude
    - gemini
    - codex
```

### 4. Ensure SSH Access to Exit Node

```bash
ssh ubuntu@<host-name> "echo connected"
```

SSH key setup: `make git-ssh HOST=<host-name>` or `make distribute-keys`.

### 5. Regenerate Aliases

```bash
make configure-aliases
source ~/.zshrc    # or source ~/.bashrc
```

## Usage

### Proxy Management

| Command | Description |
|---------|-------------|
| `tenai_proxy_start [node]` | Start SSH tunnel + privoxy bridge |
| `tenai_proxy_stop` | Stop both SSH tunnel and privoxy |
| `tenai_proxy_status` | Check if both services are running |
| `tenai_proxy_test` | Compare real IP vs proxied IP |

```bash
tenai_proxy_start             # uses default exit node from config
tenai_proxy_status            # check both :1055 and :8118
tenai_proxy_test              # shows real vs proxied IP
tenai_proxy_stop              # clean shutdown
```

### Proxied CLI Aliases

| Alias | What it does |
|-------|-------------|
| `tenai_claude ...` | `HTTPS_PROXY=http://127.0.0.1:8118 claude ...` |
| `tenai_gemini ...` | `HTTPS_PROXY=http://127.0.0.1:8118 gemini ...` |
| `tenai_codex ...` | `HTTPS_PROXY=http://127.0.0.1:8118 codex ...` |

```bash
claude "explain this code"          # direct (local ISP)
tenai_claude "explain this code"    # via exit node
```

### Makefile Targets

| Target | Description |
|--------|-------------|
| `make proxy` | Verify proxy prerequisites (SSH access) |
| `make proxy-start [EXIT_NODE=x]` | Start SSH tunnel |
| `make proxy-stop` | Stop SSH tunnel |
| `make proxy-status` | Check tunnel status |

## Troubleshooting

### SSH tunnel fails to start

```
✗ SSH tunnel failed. Check: ssh ubuntu@<host-name>
```

**Fix**: Verify SSH access to exit node:
```bash
ssh -v ubuntu@<host-name> "echo ok"
```

### privoxy fails to start

**Check**: Is the config file valid?
```bash
# macOS
$(brew --prefix)/opt/privoxy/sbin/privoxy --config-test $(brew --prefix)/etc/privoxy/config

# Linux
privoxy --config-test /etc/privoxy/config
```

Common issue: missing `forward-socks5` line in the config.

### OAuth error: protocol mismatch

**Cause**: OAuth callbacks to `localhost` are being proxied.

**Fix**: The aliases include `NO_PROXY=localhost,127.0.0.1` to exclude local
OAuth callbacks. Regenerate aliases: `make configure-aliases`.

### Proxied IP same as real IP

**Cause 1**: Proxy not running. Start it: `tenai_proxy_start`

**Cause 2**: Application ignores `HTTPS_PROXY`. Test:
```bash
HTTPS_PROXY=http://127.0.0.1:8118 curl -s https://ipinfo.io/ip
```

### Slow proxied connections

The exit node's internet latency is additive. If <host-name> has a 15-20s round-trip
for HTTPS, proxied requests will be that much slower. This only affects `tenai_*`
commands — your direct traffic is unaffected.

### Port already in use

```bash
lsof -nP -i4TCP:1055   # who's on SOCKS port
lsof -nP -i4TCP:8118   # who's on HTTP bridge port

tenai_proxy_stop        # clean kill both
```

## Persistent Daemon (autossh)

The basic SSH tunnel (`ssh -D 1055 -fN`) dies when the network drops and does
not restart. **autossh** is a lightweight SSH session monitor that:

1. Detects when the SSH connection drops (via `ServerAliveInterval` keepalives)
2. Automatically restarts the SSH process
3. Handles transient network outages (Wi-Fi reconnect, sleep/wake, VPN changes)

### Why autossh vs Mosh?

Mosh **cannot do port forwarding** — it only forwards terminal I/O (stdin/stdout).
SSH `-D`, `-L`, `-R` flags are not supported by the Mosh protocol. autossh is
the standard tool for persistent SSH tunnels.

### How It Works

```
┌─── autossh (monitor) ────────────────────────────────────┐
│                                                           │
│  Spawns + monitors:  ssh -D 1055 -N ubuntu@<host-name>       │
│                                                           │
│  If SSH dies → wait 5s → restart                         │
│  ServerAliveInterval=30 → detect silent drops in ~90s    │
│                                                           │
└───────────────────────────────────────────────────────────┘
         ↓
┌─── OS daemon (launchd / systemd) ────────────────────────┐
│                                                           │
│  If autossh itself dies → restart                        │
│  On network up → start (macOS: NetworkState)             │
│  On boot/login → start (RunAtLoad / WantedBy)            │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

### `KeepAlive.NetworkState` (macOS launchd)

macOS launchd supports a `KeepAlive` dictionary with a `NetworkState` key.
When `NetworkState` is `true`, launchd treats the job as **dependent on network
availability**:

| Behavior | Description |
|----------|-------------|
| **Start when network appears** | If the system has **any** active network interface, launchd starts the job |
| **Stop when network disappears** | If **all** network interfaces go down (Wi-Fi off, Ethernet unplugged), launchd stops the job gracefully |
| **Restart on reconnect** | When network returns (Wi-Fi reconnects after sleep, VPN re-establishes), launchd restarts the job |

This is distinct from `KeepAlive=true` alone, which simply restarts the process
whenever it exits, regardless of network state. `NetworkState=true` adds
**network awareness** — it won't endlessly restart a process that can't connect.

**Other use cases for `KeepAlive.NetworkState`:**

- Any persistent tunnel or VPN connection daemon
- Background sync services (e.g., Tailscale, cloud file sync agents)
- Websocket/SSE listeners that need a network connection
- API polling services that should pause when offline

**Example plist pattern** (reusable for any network-dependent daemon):

```xml
<key>KeepAlive</key>
<dict>
    <key>NetworkState</key>
    <true/>
</dict>
<key>ThrottleInterval</key>
<integer>10</integer>
```

`ThrottleInterval` prevents rapid restart loops — launchd waits at least N
seconds between restart attempts.

On **Linux**, the equivalent is systemd's `After=network-online.target` +
`Wants=network-online.target` + `Restart=on-failure`.

### Daemon Management

| Command | Description |
|---------|-------------|
| `tenai_proxy_daemon enable` | Start daemon and enable auto-start |
| `tenai_proxy_daemon disable` | Stop daemon and disable auto-start |
| `tenai_proxy_daemon status` | Check if daemon is running |
| `make proxy-daemon ACTION=enable` | Same via Makefile |

```bash
# First-time setup (installs autossh + creates daemon config)
make proxy

# Enable the daemon
tenai_proxy_daemon enable

# Check daemon status
tenai_proxy_daemon status

# The tunnel will now auto-start on:
#   - Login/boot
#   - Network reconnection (Wi-Fi, VPN, etc.)
#   - After any connection drop
```

### Battery & Resource Impact

| Approach | Keepalive traffic | CPU wake-ups | Battery |
|----------|------------------|-------------|---------|
| **autossh** | SSH keepalive every 30s (~64 bytes) | ~2/min | **Low** ⚡ |
| **plain ssh + launchd** | Same keepalive | ~2/min | **Low** ⚡ |

autossh adds zero overhead when the connection is healthy — it's dormant until
SSH exits. The only recurring cost is the `ServerAliveInterval=30` SSH keepalive.

### Configuration

In `config/defaults.yaml`:

```yaml
proxy:
  enabled: true
  autossh: true                    # Use autossh (set false for plain ssh)
  socks_port: 1055
  http_port: 8118
  exit_node: "<host-name>"
```

### Files

| File | Purpose |
|------|---------|
| `~/Library/LaunchAgents/com.tenai.socks5.plist` | macOS launchd daemon config |
| `~/.config/systemd/user/tenai-socks5.service` | Linux systemd user service |
| `/tmp/tenai-socks5.log` | Daemon log output |

## Platform Support

| Platform | SSH -D | privoxy | HTTPS_PROXY | Notes |
|----------|:------:|:-------:|:-----------:|-------|
| **macOS** | ✅ built-in | ✅ `brew install` | ✅ | No SIP issues with this approach |
| **Linux** | ✅ built-in | ✅ `apt install` | ✅ | — |
| **Termux** | ✅ built-in | ✅ `pkg install` | ✅ | Can also use Tailscale split tunneling |
| **Windows (WSL2)** | ✅ built-in | ✅ `apt install` | ✅ | Same as Linux inside WSL |
| **Windows (native)** | ✅ OpenSSH | ✅ `choco install` | ✅ | Use PowerShell `$env:HTTPS_PROXY` |

## Configuration Reference

### `config/defaults.yaml` — `proxy` section

```yaml
proxy:
  enabled: true                     # Generate proxy aliases
  socks_port: 1055                  # SSH SOCKS5 tunnel port
  http_port: 8118                   # privoxy HTTP bridge port
  exit_node: "<host-name>"              # Tailscale exit node (empty = auto-detect)
  proxied_tools:                    # CLI tools to create tenai_* aliases for
    - claude
    - gemini
    - codex
```

### Adding Custom Tools

```yaml
  proxied_tools:
    - claude
    - gemini
    - codex
    - python3     # Route Python scripts through exit node
```

Each entry creates a `tenai_<tool>()` shell function.

## References

- [SSH Dynamic Port Forwarding](https://man.openbsd.org/ssh#D) — `ssh -D` creates a SOCKS5 proxy
- [Privoxy](https://www.privoxy.org/) — HTTP proxy with SOCKS5 forwarding
- [gost](https://gost.run/) — GO Simple Tunnel (evaluated alternative)
- [Tailscale Exit Nodes](https://tailscale.com/kb/1103/exit-nodes) — Route traffic through a device
- [Node.js HTTP_PROXY support](https://nodejs.org/api/cli.html) — Node.js respects HTTPS_PROXY for HTTP CONNECT

## Files

| File | Purpose |
|------|---------|
| [`scripts/install/proxy.sh`](../scripts/install/proxy.sh) | Verifies/installs SSH, privoxy, autossh; generates daemon configs |
| [`config/defaults.yaml`](../config/defaults.yaml) | `proxy` config section (ports, exit node, autossh flag) |
| [`scripts/configure/generate_aliases.py`](../scripts/configure/generate_aliases.py) | Alias generation (proxy start/stop/daemon/test) |
| `~/.tenai_aliases` | Generated shell aliases (sourced from shell rc) |
| `~/Library/LaunchAgents/com.tenai.socks5.plist` | macOS launchd daemon config (generated by `make proxy`) |
| `~/.config/systemd/user/tenai-socks5.service` | Linux systemd user service (generated by `make proxy`) |
| privoxy config | `/opt/homebrew/etc/privoxy/config` (macOS) or `/etc/privoxy/config` (Linux) |
