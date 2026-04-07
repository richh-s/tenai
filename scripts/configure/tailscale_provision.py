#!/usr/bin/env python3
"""scripts/configure/tailscale_provision.py — Tailscale API integration for device provisioning.

Uses TAILSCALE_API_KEY and TAILSCALE_TAILNET from .env to:
  - Generate pre-auth keys for new devices
  - List devices on the tailnet
  - Get a device's Tailscale IP after it joins

Usage:
    python3 scripts/configure/tailscale_provision.py create-authkey [--ephemeral] [--tags tag1,tag2]
    python3 scripts/configure/tailscale_provision.py list-devices
    python3 scripts/configure/tailscale_provision.py get-device-ip --hostname <name>
    python3 scripts/configure/tailscale_provision.py wait-for-device --hostname <name> [--timeout 120]
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def load_env():
    """Load .env file if present (simple key=value parsing)."""
    env_path = Path(__file__).resolve().parent.parent.parent / ".env"
    if env_path.exists():
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                if key and key not in os.environ:
                    os.environ[key] = value


def get_api_config() -> tuple[str, str]:
    """Get API key and tailnet from environment."""
    api_key = os.environ.get("TAILSCALE_API_KEY", "")
    tailnet = os.environ.get("TAILSCALE_TAILNET", "")

    if not api_key:
        print("ERROR: TAILSCALE_API_KEY not set in .env or environment", file=sys.stderr)
        sys.exit(1)
    if not tailnet:
        print("ERROR: TAILSCALE_TAILNET not set in .env or environment", file=sys.stderr)
        sys.exit(1)

    # Strip trailing @ from tailnet if present (Tailscale API doesn't want it)
    tailnet = tailnet.rstrip("@")

    return api_key, tailnet


def api_request(method: str, path: str, api_key: str, data: dict | None = None) -> dict:
    """Make a Tailscale API request."""
    url = f"https://api.tailscale.com/api/v2{path}"

    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Authorization", f"Bearer {api_key}")
    req.add_header("Content-Type", "application/json")

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        error_body = e.read().decode() if e.fp else ""
        print(f"ERROR: Tailscale API {method} {path} → {e.code}", file=sys.stderr)
        print(f"  {error_body}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"ERROR: Cannot reach Tailscale API: {e.reason}", file=sys.stderr)
        sys.exit(1)


def create_authkey(api_key: str, tailnet: str, ephemeral: bool = True,
                   reusable: bool = False, tags: list[str] | None = None,
                   description: str = "tenai-infra onboard") -> str:
    """Create a pre-authorization key for joining a device to the tailnet."""
    payload: dict = {
        "capabilities": {
            "devices": {
                "create": {
                    "reusable": reusable,
                    "ephemeral": ephemeral,
                    "preauthorized": True,
                    "tags": [f"tag:{t}" for t in (tags or [])],
                }
            }
        },
        "expirySeconds": 3600,  # 1 hour
        "description": description,
    }

    result = api_request("POST", f"/tailnet/{tailnet}/keys", api_key, payload)
    return result.get("key", "")


def list_devices(api_key: str, tailnet: str) -> list[dict]:
    """List all devices on the tailnet."""
    result = api_request("GET", f"/tailnet/{tailnet}/devices", api_key)
    return result.get("devices", [])


def find_device_by_hostname(api_key: str, tailnet: str, hostname: str) -> dict | None:
    """Find a device by hostname (case-insensitive)."""
    devices = list_devices(api_key, tailnet)
    hostname_lower = hostname.lower()
    for dev in devices:
        dev_name = dev.get("hostname", "").lower()
        dev_name_short = dev_name.split(".")[0]  # strip domain
        if dev_name_short == hostname_lower or dev_name == hostname_lower:
            return dev
    return None


def get_device_ip(device: dict) -> str:
    """Extract the IPv4 Tailscale IP from a device record."""
    addresses = device.get("addresses", [])
    for addr in addresses:
        if "." in addr:  # IPv4
            return addr
    return ""


def wait_for_device(api_key: str, tailnet: str, hostname: str,
                    timeout: int = 120) -> dict | None:
    """Wait for a device to appear on the tailnet after joining."""
    start = time.time()
    print(f"Waiting for '{hostname}' to join tailnet (timeout: {timeout}s)...", file=sys.stderr)

    while time.time() - start < timeout:
        dev = find_device_by_hostname(api_key, tailnet, hostname)
        if dev:
            ip = get_device_ip(dev)
            if ip:
                elapsed = int(time.time() - start)
                print(f"✓ Found '{hostname}' at {ip} (after {elapsed}s)", file=sys.stderr)
                return dev
        time.sleep(5)

    print(f"✗ Timed out waiting for '{hostname}' after {timeout}s", file=sys.stderr)
    return None


def main():
    load_env()

    parser = argparse.ArgumentParser(description="Tailscale API provisioning for device onboarding")
    subparsers = parser.add_subparsers(dest="action", required=True)

    # create-authkey
    p_authkey = subparsers.add_parser("create-authkey", help="Generate a pre-auth key")
    p_authkey.add_argument("--ephemeral", action="store_true", default=True,
                           help="Create ephemeral key (device removed on disconnect)")
    p_authkey.add_argument("--no-ephemeral", action="store_true",
                           help="Create persistent key")
    p_authkey.add_argument("--reusable", action="store_true",
                           help="Key can be reused for multiple devices")
    p_authkey.add_argument("--tags", default="",
                           help="Comma-separated tags (without 'tag:' prefix)")
    p_authkey.add_argument("--description", default="tenai-infra onboard",
                           help="Key description")

    # list-devices
    subparsers.add_parser("list-devices", help="List all devices on the tailnet")

    # get-device-ip
    p_ip = subparsers.add_parser("get-device-ip", help="Get a device's Tailscale IP")
    p_ip.add_argument("--hostname", required=True, help="Device hostname")

    # wait-for-device
    p_wait = subparsers.add_parser("wait-for-device", help="Wait for device to join tailnet")
    p_wait.add_argument("--hostname", required=True, help="Device hostname")
    p_wait.add_argument("--timeout", type=int, default=120, help="Timeout in seconds")

    args = parser.parse_args()
    api_key, tailnet = get_api_config()

    if args.action == "create-authkey":
        ephemeral = not args.no_ephemeral
        tags = [t.strip() for t in args.tags.split(",") if t.strip()] if args.tags else []
        key = create_authkey(api_key, tailnet, ephemeral=ephemeral,
                             reusable=args.reusable, tags=tags,
                             description=args.description)
        if key:
            # Output just the key for shell consumption
            print(key)
        else:
            print("ERROR: Failed to create auth key", file=sys.stderr)
            sys.exit(1)

    elif args.action == "list-devices":
        devices = list_devices(api_key, tailnet)
        print(f"{'Name':<20} {'IP':<18} {'OS':<10} {'Online':<8} {'Last Seen'}")
        print("-" * 76)
        for dev in devices:
            name = dev.get("hostname", "?").split(".")[0]
            ip = get_device_ip(dev) or "?"
            os_name = dev.get("os", "?")
            online = "●" if dev.get("online", False) else "○"
            last_seen = dev.get("lastSeen", "?")[:19] if dev.get("lastSeen") else "?"
            print(f"{name:<20} {ip:<18} {os_name:<10} {online:<8} {last_seen}")

    elif args.action == "get-device-ip":
        dev = find_device_by_hostname(api_key, tailnet, args.hostname)
        if dev:
            ip = get_device_ip(dev)
            if ip:
                print(ip)
            else:
                print("ERROR: Device found but no IPv4 address", file=sys.stderr)
                sys.exit(1)
        else:
            print(f"ERROR: Device '{args.hostname}' not found on tailnet", file=sys.stderr)
            sys.exit(1)

    elif args.action == "wait-for-device":
        dev = wait_for_device(api_key, tailnet, args.hostname, args.timeout)
        if dev:
            ip = get_device_ip(dev)
            print(ip)
        else:
            sys.exit(1)


if __name__ == "__main__":
    main()
