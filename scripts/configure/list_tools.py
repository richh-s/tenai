#!/usr/bin/env python3
"""List available tools and their install status.

Two modes:
  --mode=available  Static: shows all tools the codebase can install, marks skipped for HOST
  --mode=installed  Dynamic: checks which tools are actually present (local or remote via SSH)

Usage:
    python3 scripts/configure/list_tools.py --mode=available [--host mydevice]
    python3 scripts/configure/list_tools.py --mode=installed [--host mydevice]
"""

import argparse
import subprocess
import sys
from pathlib import Path

import yaml


# ── Canonical tool registry ───────────────────────────────────────────────────
# Maps install-name → (display name, command to check, description)
TOOL_REGISTRY = {
    "common_tools": ("Common Tools", "jq",        "git, curl, wget, vim, jq, etc."),
    "node":         ("Node.js",      "node",       "JavaScript runtime (v22+)"),
    "python_env":   ("Python + uv",  "python3",    "Python 3, uv, project venv"),
    "claude_code":  ("Claude Code",  "claude",     "Anthropic AI coding agent CLI"),
    "gemini_cli":   ("Gemini CLI",   "gemini",     "Google AI coding agent CLI"),
    "codex_cli":    ("Codex CLI",    "codex",      "OpenAI AI coding agent CLI"),
    "muxtree":      ("muxtree",      "muxtree",    "Tmux session tree manager"),
    "vibtunnel":    ("VibeTunnel",   "vt",         "Browser-based terminal sharing"),
    "tailscale":    ("Tailscale",    "tailscale",  "Mesh VPN network"),
    "mosh":         ("Mosh",         "mosh",       "Mobile shell (UDP-based SSH)"),
    "tmux":         ("tmux",         "tmux",       "Terminal multiplexer"),
    "ufw":          ("UFW",          "ufw",        "Firewall manager (Linux)"),
    "htop":         ("htop",         "htop",       "Interactive process viewer"),
}


def load_config() -> dict:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))
    from scripts.lib.load_config import load_config as _load
    return _load()


def resolve_skip_tools(host: str | None) -> tuple:
    """Return (device_name, device_type, skip_tools_set) for a host."""
    if not host:
        return ("local", "local", set())

    config = load_config()
    devices = config.get("tailscale", {}).get("devices", {})

    dev = devices.get(host)
    if not dev:
        # Try IP match
        for name, d in devices.items():
            if d.get("ip") == host:
                dev = d
                host = name
                break

    if not dev:
        print(f"WARNING: HOST '{host}' not found in config", file=sys.stderr)
        return (host, "unknown", set())

    dev_type = dev.get("type", "server")
    skip = set(dev.get("skip_tools", []))

    # Merge with device profile defaults
    profile = Path(__file__).resolve().parent.parent.parent / "config" / "device" / f"{dev_type}.yaml"
    if profile.exists():
        with open(profile) as f:
            data = yaml.safe_load(f)
        profile_skip = data.get("device", {}).get("skip_tools", [])
        skip.update(profile_skip)

    # Merge env SKIP_TOOLS (from .env) — additive, not replace
    import os
    env_skip = os.environ.get("SKIP_TOOLS", "")
    if env_skip:
        skip.update(s.strip() for s in env_skip.split(",") if s.strip())

    return (host, dev_type, skip)


def check_command_exists(cmd: str, host: str | None = None, user: str | None = None, ip: str | None = None, port: int = 22) -> tuple:
    """Check if a command exists. Returns (exists: bool, version: str)."""
    if host and user and ip:
        # Remote check via SSH
        port_flag = f"-p {port}" if port and port != 22 else ""
        check = f"ssh -o ConnectTimeout=5 -o BatchMode=yes {port_flag} {user}@{ip} 'command -v {cmd} && {cmd} --version 2>/dev/null || echo n/a' 2>/dev/null"
    else:
        check = f"command -v {cmd} && ({cmd} --version 2>/dev/null || echo '') || echo ''"

    try:
        result = subprocess.run(check, shell=True, capture_output=True, text=True, timeout=10)
        output = result.stdout.strip()
        if not output or result.returncode != 0:
            return (False, "")
        lines = output.splitlines()
        path = lines[0] if lines else ""
        version = lines[1] if len(lines) > 1 else ""
        if path and ("/" in path or path == cmd):
            return (True, version.strip()[:40])
        return (False, "")
    except (subprocess.TimeoutExpired, OSError):
        return (False, "timeout")


def resolve_remote_info(host: str) -> tuple:
    """Get user, IP, and port for remote host."""
    config = load_config()
    devices = config.get("tailscale", {}).get("devices", {})
    dev = devices.get(host, {})
    user = dev.get("user", "ubuntu")
    ip = dev.get("ip", host)
    port = dev.get("ssh_port", 22)
    return (user, ip, port)


def mode_available(host: str | None):
    """Show all tools that the codebase can install, with skip status."""
    name, dev_type, skip_tools = resolve_skip_tools(host)

    header = "── Available tools"
    if host:
        header += f" for {name} ({dev_type})"
    header += " ──"
    print(header)
    print(f"{'Tool':<20} {'Status':<12} {'Description'}")
    print("─" * 60)

    for tool_id, (display, _cmd, desc) in TOOL_REGISTRY.items():
        if tool_id in skip_tools:
            status = "✗ skip"
        else:
            status = "✓ install"
        print(f"  {display:<18} {status:<12} {desc}")

    total = len(TOOL_REGISTRY)
    skipped = len([t for t in TOOL_REGISTRY if t in skip_tools])
    print(f"\n  {total} tools total, {total - skipped} to install, {skipped} skipped")


def mode_installed(host: str | None):
    """Dynamically check which tools are installed."""
    user, ip, port = None, None, 22
    label = "local"

    if host:
        user, ip, port = resolve_remote_info(host)
        label = f"{host} ({user}@{ip}:{port})"
        print(f"── Checking installed tools on {label} ──")
        # Preflight SSH check
        try:
            result = subprocess.run(
                f"ssh -o ConnectTimeout=5 -o BatchMode=yes -p {port} {user}@{ip} echo ok",
                shell=True, capture_output=True, timeout=8
            )
            if result.returncode != 0:
                print(f"\n✗ Cannot SSH into {label}")
                print("  Ensure the device is online and SSH is configured.")
                sys.exit(1)
        except subprocess.TimeoutExpired:
            print(f"\n✗ SSH timeout connecting to {label}")
            sys.exit(1)
    else:
        print(f"── Checking installed tools ({label}) ──")

    print(f"{'Tool':<20} {'Status':<12} {'Version'}")
    print("─" * 60)

    installed_count = 0
    for tool_id, (display, cmd, _desc) in TOOL_REGISTRY.items():
        exists, version = check_command_exists(cmd, host, user, ip, port)
        if exists:
            status = "✓ found"
            installed_count += 1
            ver_str = version if version and version != "n/a" else ""
        else:
            status = "✗ missing"
            ver_str = ""
        print(f"  {display:<18} {status:<12} {ver_str}")

    print(f"\n  {installed_count}/{len(TOOL_REGISTRY)} tools installed")


def main():
    parser = argparse.ArgumentParser(description="List or check tenai-infra tools")
    parser.add_argument("--mode", choices=["available", "installed"], required=True)
    parser.add_argument("--host", default=None, help="Device name from config (optional)")
    args = parser.parse_args()

    if args.mode == "available":
        mode_available(args.host)
    else:
        mode_installed(args.host)


if __name__ == "__main__":
    main()
