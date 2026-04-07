# How To — Windows Desktop Setup

Set up a Windows machine as a device in the tenai mesh network.

## Prerequisites

- Windows 10/11 (or Windows Server 2019+)
- Internet connection
- A Tailscale account

## Quick Setup (Recommended)

Use the guided onboard wizard from any device:

```bash
make onboard TYPE=windows NAME=win_desktop IP=100.x.y.z
```

## Manual Setup

### 1. Install Tailscale

Download and install from [tailscale.com/download/windows](https://tailscale.com/download/windows), or via winget:

```powershell
winget install Tailscale.Tailscale
```

Sign in and connect to your tailnet.

### 2. Enable OpenSSH Server

Open **Settings → Apps → Optional Features → Add a feature** and install "OpenSSH Server".

Or via PowerShell (as Administrator):

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
```

### 3. Run the bootstrap script

```powershell
# Clone the repo
git clone <repo-url> ~/tenai-infra
cd ~/tenai-infra

# Run bootstrap (as Administrator for OpenSSH)
powershell -ExecutionPolicy Bypass -File scripts/install/bootstrap_windows.ps1
```

This installs: Git, Python, Node.js, curl, jq, Tailscale, OpenSSH Server, SSH key, Claude Code, Gemini CLI, Codex CLI.

### 4. Configure `.env`

```powershell
Copy-Item .env.example .env
# Edit .env: DEVICE_NAME=win_desktop  DEVICE_TYPE=windows
```

### 5. Add to mesh (from another device)

Add the device to `config/defaults.yaml`:

```yaml
tailscale:
  devices:
    win_desktop:
      ip: "100.x.y.z"     # from: tailscale ip -4
      user: your-username
      type: windows
      capabilities: []
      skip_tools: [muxtree, vibetunnel]
```

Then run `make onboard TYPE=windows NAME=win_desktop` or `make push-aliases` on all devices to generate aliases for the new device.

---

## Limitations

| Feature | Status |
|---------|--------|
| **SSH** | ✅ Built-in OpenSSH Server |
| **Mosh** | ❌ No native Windows build |
| **tmux** | ❌ Not available natively |
| **Makefile** | ⚠️ Requires WSL2 or Git Bash |
| **Tailscale** | ✅ Native Windows app |
| **AI CLIs** | ✅ Via npm (Node.js) |

### Mosh Workaround (WSL2)

If you need Mosh support, install WSL2:

```powershell
wsl --install
```

Then inside WSL:

```bash
sudo apt update && sudo apt install mosh tmux
```

## Dry Run

Test the bootstrap script without making changes:

```powershell
powershell -File scripts/install/bootstrap_windows.ps1 -DryRun
```
