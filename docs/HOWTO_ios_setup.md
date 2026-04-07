# How To — iOS Setup (iSH and Termius)

Two ways to use tenai-infra from an iPhone/iPad:

| App | Role | Best For |
|-----|------|----------|
| **iSH** | Local Alpine Linux shell | Running scripts, git, Python locally |
| **Termius** | SSH/Mosh client | Connecting to your mesh servers |

## Quick Setup (Recommended)

Use the guided onboard wizard from your Mac:

```bash
# For iSH:
make onboard TYPE=ios NAME=iphone

# For Termius (client-only):
make onboard TYPE=ios NAME=iphone TERMIUS=1
```

The wizard handles discovery, SSH key copy, tool installation, and config registration automatically.

---

## Option A: iSH (Local Linux Shell)

### 1. Install apps

- **iSH Shell** from the [App Store](https://apps.apple.com/app/ish-shell/id1436902243) (free)
- **Tailscale** from the App Store — sign in and connect

### 2. Install prerequisites (inside iSH)

```sh
apk update
apk add openssh git python3 py3-pip make curl bash mosh
```

### 3. Set up SSH server

```sh
ssh-keygen -A           # generate host keys
passwd                  # set root password
/usr/sbin/sshd          # start SSH server
```

### 4. Bootstrap from Mac

```bash
# Run from your Mac:
make onboard TYPE=ios NAME=iphone
```

Or manually:
```bash
make new-server HOST=iphone
```

### sshd auto-start

The bootstrap adds this to `~/.profile` so sshd starts on every iSH session:

```sh
# TENAI INFRA SSHD AUTO-START
pgrep -x sshd >/dev/null 2>&1 || /usr/sbin/sshd 2>/dev/null
```

> ⚠️ **Important**: iSH sessions (including sshd) stop when the app is backgrounded on iOS. Keep iSH in the foreground while SSH'd in.

---

## Option B: Termius (SSH/Mosh Client)

Termius is a **client-only** app — it connects to your servers but doesn't run tenai-infra locally.

### 1. Quick setup

```bash
# From Mac — prints all hosts to add in Termius:
make onboard TYPE=ios NAME=iphone TERMIUS=1
```

### 2. Install apps

- **Termius** from the [App Store](https://apps.apple.com/app/termius-terminal-ssh-client/id549039908)
- **Tailscale** from the App Store — sign in and connect

### 3. Add hosts

The onboard wizard prints a host table. Add each in Termius:

| Host | Address | User | Port | Auth |
|------|---------|------|------|------|
| <host-name> | 100.x.x.x | ubuntu | 22 | Key |
| my-mac | 100.y.y.y | user | 22 | Key |
| my-phone | 100.z.z.z | user | 8022 | Key |

For each host: enable **Use Mosh** in Advanced settings.

### 4. Verify connectivity

1. Open **Tailscale app** on iPhone → confirm "Connected"
2. In Termius → tap any host → should connect
3. Troubleshooting:
   - **"Connection refused"** → target device's sshd is down
   - **"Connection timed out"** → Tailscale not routing; toggle Tailscale off/on

### 5. Optional: SSH key

- Termius → Keychain → Generate Key → ED25519
- Copy public key → send to Mac
- Run `make distribute-keys` to push to all devices

---

## Background Activity Notes

| App | Background Behavior |
|-----|-------------------|
| **iSH** | Sessions die when backgrounded (~20-30s) |
| **Termius** | Limited background (~20-30s); use tmux on remote servers |
| **Tailscale** | Runs as VPN profile — always active |

**Tip**: Always use `tmux` on your remote servers. Both iSH and Termius sessions will eventually disconnect when iOS suspends the app, but tmux sessions persist on the server.
