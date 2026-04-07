#!/usr/bin/env python3
"""scripts/configure/register_device.py — Add or update a device in config/local.yaml.

Usage:
    python3 register_device.py --name s24 --ip 100.x.x.x --user ubuntu --type android
    python3 register_device.py --name s24 --ip 100.x.x.x --type android --dry-run
    python3 register_device.py --name s24 --ip 100.x.x.x --type android --force-update
    python3 register_device.py --name mypc --ip 100.x.x.x --type wsl --capabilities conductor,claude
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))
import yaml  # noqa: E402 — needed for device templates and config save

from scripts.lib.load_config import REPO_ROOT  # noqa: E402
from scripts.lib.load_config import load_config as _load_merged  # noqa: E402

LOCAL_CONFIG_PATH = REPO_ROOT / "config" / "local.yaml"
DEVICE_CONFIG_DIR = REPO_ROOT / "config" / "device"

VALID_TYPES = ["server", "mac", "android", "ios_ish", "ios_termius", "windows", "wsl"]

# Default skip_tools per device type (fallback if no device config yaml exists)
DEFAULT_SKIP_TOOLS = {
    "server":      [],
    "mac":         [],
    "wsl":         [],
    "android":     ["vibetunnel", "muxtree", "codex_cli", "gemini_cli", "vim", "ufw", "htop", "python_env"],
    "ios_ish":     ["vibetunnel", "muxtree", "codex_cli", "tailscale", "ufw", "htop", "python_env", "git_ssh"],
    "ios_termius": ["all"],
    "windows":     ["muxtree", "vibetunnel"],
}

DEFAULT_SSH_PORTS = {
    "server": 22, "mac": 22, "android": 8022,
    "ios_ish": 22, "ios_termius": 22, "windows": 22, "wsl": 22,
}

# Default capabilities by type (used when none provided)
DEFAULT_CAPABILITIES = {
    "server":      ["conductor", "dispatch", "claude", "gemini"],
    "mac":         ["conductor", "claude", "gemini", "codex"],
    "wsl":         ["conductor", "claude", "gemini", "codex"],
    "android":     [],
    "ios_ish":     [],
    "ios_termius": [],
    "windows":     [],
}


def load_config():
    return _load_merged()


def _load_local_config():
    """Load only the local.yaml for writing."""
    if LOCAL_CONFIG_PATH.exists():
        with open(LOCAL_CONFIG_PATH) as f:
            return yaml.safe_load(f) or {}
    return {}


def save_config(config):
    LOCAL_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(LOCAL_CONFIG_PATH, "w") as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False, allow_unicode=True)


def load_device_template(device_type: str) -> dict:
    """Load skip_tools from config/device/<type>.yaml if available."""
    type_file = DEVICE_CONFIG_DIR / f"{device_type}.yaml"
    if type_file.exists():
        with open(type_file) as f:
            data = yaml.safe_load(f) or {}
        dev = data.get("device", {})
        return {
            "skip_tools": dev.get("skip_tools", DEFAULT_SKIP_TOOLS.get(device_type, [])),
            "ssh_port": DEFAULT_SSH_PORTS.get(device_type, 22),
        }
    return {
        "skip_tools": DEFAULT_SKIP_TOOLS.get(device_type, []),
        "ssh_port": DEFAULT_SSH_PORTS.get(device_type, 22),
    }


def build_device_entry(args, template: dict) -> dict:
    entry = {
        "ip": args.ip,
        "user": args.user,
        "type": args.type,
        "capabilities": args.capabilities if args.capabilities else DEFAULT_CAPABILITIES.get(args.type, []),
        "skip_tools": template["skip_tools"],
    }
    port = args.ssh_port or template["ssh_port"]
    if port != 22:
        entry["ssh_port"] = port
    return entry


def _handle_conflict_interactive(args, devices, new_entry, existing_ip):
    """Handle name conflict when interactive (not force-update, not dry-run)."""
    print("")
    print(f"⚠  Device '{args.name}' already in config with IP {existing_ip}")
    print(f"   Detected IP: {args.ip}")
    print("")
    choice = input("   [U]pdate IP  [R]ename  [S]kip? > ").strip().lower()
    if choice in ("u", "update"):
        print(f"✓ Updating '{args.name}' IP: {existing_ip} → {args.ip}")
        devices[args.name].update(new_entry)
        return "ok"
    if choice in ("r", "rename"):
        new_name = input("   New device name: ").strip()
        if not new_name:
            print("✗ Empty name, skipping")
            return "skip"
        if new_name in devices:
            print(f"✗ '{new_name}' also exists, skipping")
            return "skip"
        devices[new_name] = new_entry
        args.name = new_name
        print(f"✓ Registered as '{new_name}'")
        return "ok"
    print("   Skipped")
    return "skip"


def register_device(args):
    # Read merged config for resolving, but write to local.yaml
    config = load_config()
    devices = config.get("tailscale", {}).get("devices", {})
    template = load_device_template(args.type)
    new_entry = build_device_entry(args, template)

    if args.name in devices:
        existing = devices[args.name]
        existing_ip = existing.get("ip", "")

        if existing_ip == args.ip:
            print(f"✓ Device '{args.name}' already exists with same IP — updating config")
            existing.update(new_entry)
        elif args.force_update:
            print(f"✓ Updating '{args.name}' IP: {existing_ip} → {args.ip}")
            existing.update(new_entry)
        elif args.dry_run:
            print(f"⚠  CONFLICT: '{args.name}' exists with IP {existing_ip}, detected {args.ip}")
            print("   Would prompt: [U]pdate IP  [R]ename  [S]kip")
            return "conflict"
        else:
            result = _handle_conflict_interactive(args, devices, new_entry, existing_ip)
            if result == "skip":
                return "skip"
    else:
        print(f"✓ Registering new device: {args.name} ({args.type}, {args.ip})")
        devices[args.name] = new_entry

    if args.dry_run:
        print(f"[DRY RUN] Would write to {LOCAL_CONFIG_PATH}:")
        print(f"  {args.name}: {new_entry}")
        return "ok"

    # Write to local.yaml (not defaults.yaml)
    local = _load_local_config()
    local.setdefault("tailscale", {}).setdefault("devices", {})
    local["tailscale"]["devices"][args.name] = new_entry
    save_config(local)
    print(f"✓ Config saved to {LOCAL_CONFIG_PATH}")
    return "ok"


def _resolve_default_user(device_type: str) -> str:
    """Resolve default SSH user for a device type."""
    if device_type == "ios_ish":
        return "root"
    if device_type == "server":
        return "ubuntu"
    return ""


def main():
    parser = argparse.ArgumentParser(description="Register a device in config/local.yaml")
    parser.add_argument("--name", required=True, help="Device name")
    parser.add_argument("--ip", required=True, help="Tailscale IP")
    parser.add_argument("--user", default="", help="SSH user")
    parser.add_argument("--type", required=True,
                        choices=VALID_TYPES,
                        help="Device type")
    parser.add_argument("--ssh-port", type=int, default=0, help="SSH port (0=auto from type)")
    parser.add_argument("--capabilities", type=lambda x: [s.strip() for s in x.split(",") if s.strip()],
                        default=None, help="Comma-separated list of capabilities")
    parser.add_argument("--dry-run", action="store_true", help="Show what would happen")
    parser.add_argument("--force-update", action="store_true",
                        help="Force update on name conflict (non-interactive)")
    args = parser.parse_args()

    if not args.user:
        args.user = _resolve_default_user(args.type)

    result = register_device(args)
    sys.exit(0 if result in ("ok", "skip") else 1)


if __name__ == "__main__":
    main()

