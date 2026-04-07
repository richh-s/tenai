#!/usr/bin/env python3
"""List all device names from config/defaults.yaml, one per line.

Usage:
    python list_devices.py                  # all devices
    python list_devices.py --exclude-local  # skip the device we're running on
"""
import os
import socket
import subprocess
import sys


sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
from scripts.lib.load_config import load_config

cfg = load_config()

exclude_local = "--exclude-local" in sys.argv

# Detect local device identity
local_name = os.environ.get("DEVICE_NAME", "")
local_hostname = socket.gethostname().lower()

# Get local IPs (including Tailscale)
local_ips: set[str] = set()
if exclude_local:
    try:
        # Get all local IPs
        result = subprocess.run(
            ["hostname", "-I"] if sys.platform == "linux" else ["ifconfig"],
            capture_output=True, text=True, timeout=5,
        )
        if sys.platform == "linux":
            local_ips.update(result.stdout.split())
        else:
            # macOS: parse ifconfig for inet lines
            for line in result.stdout.splitlines():
                line = line.strip()
                if line.startswith("inet ") and "127.0.0.1" not in line:
                    local_ips.add(line.split()[1])
    except Exception:
        pass
    # Also try Tailscale IP directly
    try:
        result = subprocess.run(
            ["tailscale", "ip", "-4"], capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            local_ips.add(result.stdout.strip())
    except Exception:
        pass

devices = cfg.get("tailscale", {}).get("devices", {})
for name in sorted(devices.keys()):
    if exclude_local:
        # Skip if device name matches DEVICE_NAME env or hostname
        if name == local_name or name in local_hostname or local_hostname in name:
            continue
        # Skip if device IP matches a local IP
        dev_ip = devices[name].get("ip", "")
        if dev_ip and dev_ip in local_ips:
            continue
    print(name)
