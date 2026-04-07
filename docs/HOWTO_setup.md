# How To — Full Setup

## Prerequisites

- macOS, Linux (Ubuntu/Debian), Android (Termux), iOS (iSH), or Windows
- Internet connection
- A Tailscale account (free at [tailscale.com](https://tailscale.com))

## First-Time Setup

### 1. Clone the repo

```bash
git clone <repo-url> ~/tenai-infra
cd ~/tenai-infra
```

### 2. Configure environment

```bash
cp .env.example .env
```

Edit `.env` and set at minimum:

| Variable | Required | Description |
|----------|:--------:|-------------|
| `TAILSCALE_AUTH_KEY` | ✅ | Get from [Tailscale admin](https://login.tailscale.com/admin/settings/keys) |
| `DEVICE_NAME` | ✅ | Must match a key in `config/defaults.yaml` |
| `DEVICE_TYPE` | ✅ | `server`, `mac`, `android`, `ios_ish`, `ios_termius`, or `windows` |
| `GITHUB_TOKEN` | — | For syncing private repo lists in the webapp |
| `SSH_KEY_PATH` | — | Defaults to `~/.ssh/id_ed25519` |
| `BASE_DIR` | — | Defaults to `~/tenai-projects` |

### 3. Run full setup

```bash
make
```

This auto-detects your platform and runs:
1. **Install**: Tailscale, Mosh, tmux, uv, Claude Code, Gemini CLI, Codex CLI, muxtree, VibeTunnel
2. **Configure**: SSH config entries, shell aliases

### 4. Reload your shell

```bash
source ~/.zshrc    # macOS
source ~/.bashrc   # Linux / Termux
```

## Re-running Setup

All targets are **idempotent** — safe to re-run:

```bash
make                    # Full re-run (skips already-installed tools)
make configure-aliases  # Just regenerate aliases
make configure-ssh      # Just regenerate SSH config
make tools              # Just install dev tools
```

## Resetting / Uninstalling

### Config-only reset

Backs up your config and walks through `.env` and tailnet setup again. Does **not** uninstall tools or remove `config/local.yaml`.

```bash
make reset-device                                  # interactive wizard
make reset-device NONINTERACTIVE=1 TAILNET=name@   # automated (CI/testing)
```

### Full reset (uninstall + reconfigure)

Reads the state manifest (`~/.tenai/state/<device>/manifest.json`) and surgically reverses only what tenai installed — pre-existing tools are never touched.

```bash
make reset-device FULL_RESET=1              # interactive
make uninstall                               # standalone uninstall wizard
make uninstall DRY_RUN=1                     # preview what would be removed
```

### State tracking

```bash
make state         # display current manifest
make state-audit   # reconstruct manifest from filesystem (for pre-tracking setups)
```

## Adding a New Device

### Guided onboarding (recommended)

```bash
make onboard
```

This interactive wizard walks you through device setup: detecting type, creating config, bootstrapping, and SSH key distribution.

```bash
make onboard TYPE=server NAME=myserver IP=100.x.y.z   # Non-interactive
make onboard TYPE=local                                # Set up current machine
```

### Manual setup

1. Add the device to `config/defaults.yaml`:
   ```yaml
   tailscale:
     devices:
       myserver:
         ip: "100.x.y.z"
         user: ubuntu
         type: server
   ```

2. Bootstrap from any device with SSH access:
   ```bash
   make new-server HOST=myserver
   ```

   This syncs code, installs tools, distributes SSH keys, and sets up Git SSH for all orgs.

3. Install CLI extensions and skills:
   ```bash
   make cli-setup HOST=myserver
   ```

4. Sync aliases to all devices to pick up the new entry:
   ```bash
   make sync-all
   ```

## Syncing Code to Devices

```bash
make sync HOST=myserver           # rsync local → remote + rebuild webapp Docker
make sync HOST=myserver GIT_PULL=1  # git pull on remote instead of rsync
make sync-all                    # sync to all remote devices (auto-skips local)
```

`make sync` also propagates `.env` (with device-specific values) and rebuilds the Docker webapp container.

## Git SSH Key Management

```bash
make git-ssh                            # all orgs locally
make git-ssh HOST=myserver               # all orgs on remote (copies local key)
make git-ssh ORG=myorg HOST=myserver     # single org on remote
make git-ssh GENERATE_GIT_SSH_KEY=1 HOST=myserver  # generate new key on device
make git-ssh TOKEN=ghp_xxx              # upload key to GitHub
```

Without `HOST=`, runs locally. With `HOST=`, copies your local SSH key to the remote device first, then configures `Host github-<org>` aliases. This means all devices share the same GitHub-authorized key.

## Selective Install

```bash
make tailscale    # Just Tailscale
make mosh         # Just Mosh
make tmux         # Just tmux + config
make tools        # Just Claude/Gemini/Codex + muxtree + VibeTunnel
make gemini       # Just Gemini CLI
make check-tools  # Check which tools are installed
```

## Shared / Pre-configured Instances

When onboarding a device where **another user has already set up Tailscale** (e.g., a
shared AWS instance), tenai detects the existing tailnet and skips Tailscale
configuration automatically. A Tailscale device can only belong to **one tailnet at
a time** — reconfiguring it would remove the other user's access.

### Options for shared instances

| Approach | Command | Effect |
|----------|---------|--------|
| **Skip Tailscale** (recommended) | `make onboard HOST=x SKIP_TOOLS=tailscale` | Onboard without touching Tailscale |
| **Take over** | `sudo tailscale up --force-reauth --authkey=<yours>` | Moves device to your tailnet (breaks other user's access) |
| **Share the node** | Ask the tailnet admin to share the device | Both users can access via Tailscale |
| **Use public IP only** | Just update `~/.ssh/config` | Access via public IP, no tailnet needed |

### How detection works

1. **`tailscale.sh`** checks if `tailscale status` reports `BackendState: Running`.
   If so, it prints the current tailnet name and skips all configuration.
2. **`onboard.sh` Phase 3** checks if the remote device already has a Tailscale IP.
   If so, it records the IP and skips provisioning.

> **Tip**: For cloud instances with dynamic public IPs (AWS without Elastic IP),
> the IP changes on stop/start. Update your `~/.ssh/config` HostName when this
> happens, or assign an Elastic IP.

## SSH Host Resolution

When you run `make onboard HOST=ipm`, the system resolves the target through this
priority chain:

1. **`config/local.yaml`** → devices defined in your personal config
2. **`~/.ssh/config`** → SSH aliases with HostName, User, IdentityFile
3. **Raw IP/hostname** → used as-is

When the host resolves from `~/.ssh/config`, the original **alias is preserved** for
all SSH connections (e.g., `ssh ipm` instead of `ssh ubuntu@54.x.x.x`). This ensures
that IdentityFile, ProxyCommand, and other SSH config directives are respected.

## Firewall Safety

The onboarding process **never** enables a firewall that isn't already active, and
**never** touches SSH port configuration.

### What it does

- Detects the active firewall backend (UFW, firewalld, iptables)
- Adds rules **only** for ports managed by our codebase:
  - `60000:61000/udp` — mosh
  - `tailscale0` interface — Tailscale traffic
- On cloud instances (AWS/GCP/Azure), skips host-level firewall entirely
  (use Security Groups instead)

### What it does NOT do

- Enable/activate UFW or any firewall
- Add SSH port rules (22/tcp)
- Remove existing firewall rules
- Modify Security Groups


