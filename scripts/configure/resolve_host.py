#!/usr/bin/env python3
"""Resolve a HOST name to device config from defaults.yaml, ~/.ssh/config, or raw IP.

Resolution chain (first match wins):
  1. defaults.yaml — by name or IP
  2. ~/.ssh/config — parse Host entries for HostName, User, Port, IdentityFile
  3. Raw IP/hostname — passthrough with sensible defaults

Outputs shell-evaluable variables for use by Makefile targets:
  RESOLVED_NAME, RESOLVED_USER, RESOLVED_TYPE, RESOLVED_IP,
  RESOLVED_SSH_PORT, RESOLVED_SKIP_TOOLS, RESOLVED_SSH_KEY, RESOLVED_SOURCE

Usage:
    eval $(python3 scripts/configure/resolve_host.py mydevice)
    eval $(python3 scripts/configure/resolve_host.py 100.109.109.127)
    eval $(python3 scripts/configure/resolve_host.py my-ssh-alias)
"""

import os
import re
import sys
from pathlib import Path

import yaml


def load_config() -> dict:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))
    from scripts.lib.load_config import load_config as _load
    return _load()


def resolve(host_key: str) -> dict | None:
    """Resolve HOST to a device entry. Tries name match first, then IP match."""
    config = load_config()
    devices = config.get("tailscale", {}).get("devices", {})

    # Direct name match
    if host_key in devices:
        dev = devices[host_key]
        return {"name": host_key, "_source": "config", **dev}

    # IP match — scan all devices
    for name, dev in devices.items():
        if dev.get("ip") == host_key:
            return {"name": name, "_source": "config", **dev}

    return None


def parse_ssh_config(host_key: str) -> dict | None:
    """Parse ~/.ssh/config for a matching Host entry.

    Returns dict with: hostname, user, port, identity_file, or None if not found.
    Handles Host wildcards, Match blocks (skipped), and Include directives (top-level only).
    """
    ssh_config_path = Path.home() / ".ssh" / "config"
    if not ssh_config_path.exists():
        return None

    return _parse_ssh_config_file(ssh_config_path, host_key)


def _parse_ssh_config_file(config_path: Path, host_key: str) -> dict | None:
    """Parse a single SSH config file for a matching Host entry."""
    try:
        lines = config_path.read_text().splitlines()
    except OSError:
        return None

    # Process Include directives first (only at top level)
    for line in lines:
        stripped = line.strip()
        if stripped.lower().startswith("include "):
            include_pattern = stripped.split(None, 1)[1]
            # Expand ~ and globs
            include_path = Path(include_pattern.replace("~", str(Path.home())))
            if include_path.parent.exists():
                import glob
                for match_path in glob.glob(str(include_path)):
                    result = _parse_ssh_config_file(Path(match_path), host_key)
                    if result:
                        return result

    # Parse Host blocks and accumulate
    accumulated_config: dict[str, str] = {}
    found = False

    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        # Skip Match blocks entirely for now
        if stripped.lower().startswith("match "):
            found = False
            continue

        if stripped.lower().startswith("host "):
            patterns = stripped.split()[1:]  # everything after "Host"
            found = _host_matches(host_key, patterns)
            if found and "_matched_host" not in accumulated_config:
                accumulated_config["_matched_host"] = host_key
            continue

        # Parse key-value pairs within a block
        if found:
            match = re.match(r"^\s*(\w+)\s*=*?\s+(.+)$", line)
            if match:
                key = match.group(1).lower()
                value = match.group(2).strip()

                # Strip optional quotes around value
                if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
                    value = value[1:-1]

                # Expand ~ in paths
                if key in ("identityfile", "include"):
                    value = value.replace("~", str(Path.home()))

                # Accumulate if not already set (OpenSSH first-match-wins)
                if key == "hostname" and "hostname" not in accumulated_config:
                    accumulated_config["hostname"] = value
                elif key == "user" and "user" not in accumulated_config:
                    accumulated_config["user"] = value
                elif key == "port" and "port" not in accumulated_config:
                    accumulated_config["port"] = value
                elif key == "identityfile" and "identity_file" not in accumulated_config:
                    accumulated_config["identity_file"] = value

    if accumulated_config:
        return accumulated_config

    return None


def _host_matches(host_key: str, patterns: list[str]) -> bool:
    """Check if host_key matches any of the SSH config Host patterns.

    Supports simple wildcards (* and ?) and negation (!pattern).
    """
    import fnmatch

    matched = False
    for pattern in patterns:
        if pattern.startswith("!"):
            if fnmatch.fnmatch(host_key, pattern[1:]):
                return False
        elif fnmatch.fnmatch(host_key, pattern):
            matched = True
    return matched


def is_ip_address(s: str) -> bool:
    """Check if string looks like an IPv4 address."""
    parts = s.split(".")
    if len(parts) != 4:
        return False
    return all(p.isdigit() and 0 <= int(p) <= 255 for p in parts)


def load_device_profile_skip_tools(device_type: str) -> list:
    """Load default skip_tools from config/device/<type>.yaml."""
    profile = Path(__file__).resolve().parent.parent.parent / "config" / "device" / f"{device_type}.yaml"
    if profile.exists():
        with open(profile) as f:
            data = yaml.safe_load(f)
        return data.get("device", {}).get("skip_tools", [])
    return []


def main():
    if len(sys.argv) < 2:
        print("echo 'Usage: resolve_host.py <HOST>'")
        sys.exit(1)

    host_key = sys.argv[1]
    # Accept --allow-unknown flag to not error on missing hosts
    allow_unknown = "--allow-unknown" in sys.argv

    # ── Strategy 1: defaults.yaml (name or IP match) ─────────────────────
    dev = resolve(host_key)

    # ── Strategy 2: ~/.ssh/config fallback ────────────────────────────────
    ssh_config_info = None
    if dev is None:
        ssh_config_info = parse_ssh_config(host_key)
        if ssh_config_info:
            hostname_or_ip = ssh_config_info.get("hostname", host_key)
            # Check if the resolved hostname/IP is in defaults.yaml
            dev = resolve(hostname_or_ip)
            if dev:
                # Enrich with SSH config info (identity file, etc.)
                dev["_source"] = "config+ssh"
                if "identity_file" in ssh_config_info:
                    dev["_ssh_key"] = ssh_config_info["identity_file"]
            else:
                # Build a minimal device entry from SSH config
                dev = {
                    "name": host_key,
                    "ip": hostname_or_ip,
                    "user": ssh_config_info.get("user", ""),
                    "type": "server",  # default, will be overridden by remote detection
                    "ssh_port": int(ssh_config_info.get("port", 22)),
                    "skip_tools": [],
                    "_source": "ssh_config",
                }
                if "identity_file" in ssh_config_info:
                    dev["_ssh_key"] = ssh_config_info["identity_file"]

    # ── Strategy 3: Raw IP/hostname passthrough ───────────────────────────
    if dev is None:
        if is_ip_address(host_key) or allow_unknown:
            dev = {
                "name": host_key,
                "ip": host_key,
                "user": "",
                "type": "server",
                "ssh_port": 22,
                "skip_tools": [],
                "_source": "raw",
            }
        else:
            # Not found anywhere
            print(f"echo 'ERROR: HOST \"{host_key}\" not found in config/defaults.yaml or ~/.ssh/config'")
            print("echo '  Known devices in config: '")
            config = load_config()
            devices = config.get("tailscale", {}).get("devices", {})
            for name, d in devices.items():
                dev_type = d.get("type", "?")
                dev_ip = d.get("ip", "?")
                print(f"echo '    {name} ({dev_type}): {dev_ip}'")
            print("echo ''")
            print("echo '  Tip: You can also use an IP address, ~/.ssh/config alias, or --allow-unknown'")
            sys.exit(1)

    source = dev.pop("_source", "config")
    ssh_key = dev.pop("_ssh_key", os.environ.get("SSH_KEY", ""))

    # Merge skip_tools: device-specific overrides > device profile defaults
    dev_type = dev.get("type", "server")
    if source == "config" or source == "config+ssh":
        profile_skip = load_device_profile_skip_tools(dev_type)
        dev_skip = dev.get("skip_tools", [])
        all_skip = list(dict.fromkeys(profile_skip + dev_skip))
    else:
        all_skip = []

    # Merge env SKIP_TOOLS (from .env) — additive, not replace
    env_skip = os.environ.get("SKIP_TOOLS", "")
    if env_skip:
        env_list = [s.strip() for s in env_skip.split(",") if s.strip()]
        all_skip = list(dict.fromkeys(all_skip + env_list))

    # Also resolve SSH user from device profile as fallback
    profile_path = Path(__file__).resolve().parent.parent.parent / "config" / "device" / f"{dev_type}.yaml"
    profile_user = None
    if profile_path.exists():
        with open(profile_path) as f:
            data = yaml.safe_load(f)
        profile_user = data.get("device", {}).get("user")

    user = dev.get("user") or profile_user or "ubuntu"
    ssh_port = dev.get("ssh_port", 22)

    print(f'RESOLVED_NAME="{dev["name"]}"')
    print(f'RESOLVED_USER="{user}"')
    print(f'RESOLVED_TYPE="{dev_type}"')
    print(f'RESOLVED_IP="{dev.get("ip", "")}"')
    print(f'RESOLVED_SSH_PORT="{ssh_port}"')
    print(f'RESOLVED_SKIP_TOOLS="{",".join(all_skip)}"')
    print(f'RESOLVED_SSH_KEY="{ssh_key}"')
    print(f'RESOLVED_SOURCE="{source}"')


if __name__ == "__main__":
    main()
