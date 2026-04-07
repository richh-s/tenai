# Debug — Common Issues & Troubleshooting

## Mosh Connection Failures

**Symptom**: `mosh: Connection refused` or timeout

**Diagnose**:
```bash
# Check mosh-server is installed on target
ssh <user>@<ip> "which mosh-server"

# Check UDP ports are open on target (server only)
ssh <user>@<ip> "sudo ufw status | grep 60000"

# Check Tailscale connectivity
tailscale ping <target-hostname>
```

**Fixes**:
- Ensure `mosh-server` is installed on the target: `make mosh` on the target
- Open UDP ports: `sudo ufw allow 60000:61000/udp`
- On servers, mosh binds to the Tailscale IP — verify with `tailscale ip -4`

---

## Tailscale Won't Connect

**Symptom**: `tailscale status` shows "Stopped" or only self

**Diagnose**:
```bash
make status
tailscale status
sudo systemctl status tailscaled  # Linux only
```

**Fixes**:
- Restart daemon: `sudo systemctl restart tailscaled`
- Re-authenticate: `sudo tailscale up --authkey=tskey-...`
- Check [Tailscale admin](https://login.tailscale.com/admin/machines) for expired keys

---

## Aliases Not Found After Setup

**Symptom**: `command not found: myserver`

**Diagnose**:
```bash
# Check if alias block exists
grep "TENAI INFRA ALIASES START" ~/.zshrc
# or
grep "TENAI INFRA ALIASES START" ~/.bashrc
```

**Fixes**:
- Source your shell config: `source ~/.zshrc` (or `~/.bashrc`)
- If block is missing, re-run: `make configure-aliases`
- Check which shell you're using: `echo $SHELL`

---

## Git Clone Fails on Remote Device (Permission Denied)

**Symptom**: `git@github-<org-name>: Permission denied (publickey)`

**Diagnose**:
```bash
# Check if the SSH host alias exists on the device
ssh ubuntu@100.x.x.x "grep 'Host github-' ~/.ssh/config"

# Check if the SSH key exists
ssh ubuntu@100.x.x.x "ls -la ~/.ssh/tenai-git-ssh-key"

# Test GitHub connectivity
ssh ubuntu@100.x.x.x "ssh -T git@github-<org-name> 2>&1"
```

**Fixes**:
```bash
# Set up Git SSH on the remote device (copies your local key + configures aliases):
make git-ssh HOST=myserver

# Or for a specific org:
make git-ssh ORG=myorg HOST=myserver
```

This copies your local `~/.ssh/tenai-git-ssh-key` to the remote device and sets up `Host github-*` aliases in `~/.ssh/config`.

---

## Job Creation Fails with `mkdir /root: Permission denied`

**Symptom**: Webapp job fails with `ERROR: mkdir: cannot create directory '/root': Permission denied`

**Cause**: The webapp runs in Docker where `$HOME=/root`. When using `create_subprocess_shell`, shell variables like `$HOME` are expanded locally (inside Docker) instead of on the remote device.

**Fix**: The webapp now uses `create_subprocess_exec` instead of `create_subprocess_shell` for SSH commands. This passes commands as literal strings — `$HOME` and `$SHELL` expand on the remote device.

If you see this after an update, redeploy:
```bash
make sync HOST=myserver
```

---

## Webapp Shows All Devices Offline

**Symptom**: The webapp dashboard shows all devices as "offline" even though they're up.

**Diagnose**:
```bash
# Check Docker logs
ssh ubuntu@100.x.x.x "docker logs tenai-infra-webapp-1 --tail 20"

# Test SSH from Docker container
ssh ubuntu@100.x.x.x "docker exec tenai-infra-webapp-1 ssh -o ConnectTimeout=5 ubuntu@100.x.x.x 'echo ok'"
```

**Fixes**:
- Check that SSH keys are mounted in Docker (the `docker-compose.yaml` volume should mount `~/.ssh`)
- Rebuild the container: `make sync HOST=<device>`
- Verify SSH works from inside the container

---

## VibeTunnel Session Crashes in tmux

**Symptom**: `vt bash -l` inside a detached tmux session exits immediately

**Cause**: `vt` is a TTY forwarder — it requires an interactive terminal. Detached tmux sessions have no TTY attached.

**Expected behavior**: VibeTunnel's daemon monitors tmux sessions directly and makes them accessible in the browser without needing `vt` wrapping inside the session.

**Fix**: Do NOT wrap commands with `vt` inside tmux. Just create regular tmux sessions — VibeTunnel discovers them automatically.

---

## apt Lock During Tool Installation

**Symptom**: `Unable to acquire the dpkg frontend lock` or installation hangs

**Cause**: Another apt process (e.g., unattended-upgrades) holds the lock.

**Fix**: The installer now includes `wait_for_apt()` which waits up to 60s for the lock to be released. If it persists:
```bash
# Check what holds the lock
sudo lsof /var/lib/dpkg/lock-frontend

# Kill the process if it's safe
sudo kill <pid>

# Or wait and retry
make tools HOST=myserver
```

---

## sync-all Syncs to Local Device

**Symptom**: `make sync-all` prompts for password trying to sync to itself

**Fix**: `sync-all` now uses `--exclude-local` which detects the local device via Tailscale IP matching. If detection fails, set `DEVICE_NAME` in `.env`:
```bash
echo "DEVICE_NAME=mymac" >> .env
```

---

## uv Not Found

**Symptom**: `command not found: uv`

**Fix**:
```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
# Or re-run: make
```

---

## SSH Connection Refused

**Symptom**: `ssh: connect to host 100.x.x.x port 22: Connection refused`

**Diagnose**:
```bash
grep "TENAI INFRA SSH" ~/.ssh/config
```

**Fixes**:
- Re-generate SSH config: `make configure-ssh`
- Distribute keys: `make distribute-keys`
- macOS: Enable remote login: `sudo systemsetup -setremotelogin on`
- **Android (Termux)**: Run `sshd` in Termux (port 8022, not 22)
- **iOS (iSH)**: Run `/usr/sbin/sshd` in iSH — note sshd crashes when iSH is backgrounded
- Use `make onboard` for guided setup that handles SSH key distribution automatically

---

## SSH Timeout After Onboarding (Firewall Lockout)

**Symptom**: `ssh: connect to host x.x.x.x port 22: Operation timed out` after a
previous onboarding attempt.

**Cause**: Older versions of the onboarding scripts ran `sudo ufw --force enable`,
which activates a deny-all firewall. If the SSH allow rule didn't match your
connection pattern, you'd be locked out.

**This has been fixed** — the current `scripts/install/firewall.sh` never enables a
firewall that isn't already active, and never touches SSH port rules.

**Recovery** (if already locked out):
```bash
# AWS: Use EC2 Instance Connect or SSM Session Manager from the AWS Console
# Then on the instance:
sudo ufw disable
# Or more conservatively:
sudo ufw allow 22/tcp
```

**Prevention**:
- On cloud instances, use Security Groups instead of host-level firewalls
- The current `firewall.sh` auto-detects cloud environments and skips

---

## SSH Alias Fails But Direct IP Works

**Symptom**: `ssh myalias` hangs/times out but `ssh user@<actual-ip>` works

**Cause**: The IP in `~/.ssh/config` is stale. Common on AWS instances without Elastic
IPs — the public IP changes on every stop/start.

**Fix**:
```bash
# Check the current public IP from inside the instance:
curl -s http://169.254.169.254/latest/meta-data/public-ipv4

# Update ~/.ssh/config with the new IP
# Then retry: ssh myalias
```

**Prevention**: Assign an Elastic IP to the AWS instance, or use Tailscale IPs (stable).

---

## Tailscale Already Configured By Another User

**Symptom**: `make onboard` skips Tailscale with "already connected" but the tailnet
isn't yours.

**Cause**: A Tailscale device can only belong to one tailnet. If another user set it
up first, our scripts detect this and skip to avoid disrupting their access.

**Options**:

| Approach | Command |
|----------|---------|
| Skip Tailscale entirely | `make onboard HOST=x SKIP_TOOLS=tailscale` |
| Take over (disconnects other user) | On device: `sudo tailscale up --force-reauth --authkey=<yours>` |
| Share the node | Ask the tailnet admin to share |
| Use public IP only | Update `~/.ssh/config`, don't touch Tailscale |

---

## Checking Overall Health

```bash
make check               # Verify all tools installed locally
make check HOST=myserver # Verify tools on remote device
make check-tools         # Dynamic tool check
make status              # Tailscale + tmux + repos overview
make status HOST=myserver # Remote status (disk, uptime, Docker)
```

