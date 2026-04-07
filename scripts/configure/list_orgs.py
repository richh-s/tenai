#!/usr/bin/env python3
"""List organizations from config/defaults.yaml with their SSH key names.

Usage:
    python list_orgs.py                    # ORG KEY_NAME per line
    python list_orgs.py --org yabebalFantaye  # single org
"""
import os
import sys


sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
from scripts.lib.load_config import load_config

cfg = load_config()

filter_org = None
for i, arg in enumerate(sys.argv[1:], 1):
    if arg == "--org" and i < len(sys.argv) - 1:
        filter_org = sys.argv[i + 1]

orgs = cfg.get("organizations", {})
for name, info in sorted(orgs.items()):
    if filter_org and name != filter_org:
        continue
    # Extract key basename from ssh_key path (e.g., "~/.ssh/tenai-git-ssh-key" -> "tenai-git-ssh-key")
    ssh_key = info.get("ssh_key", "")
    key_name = os.path.basename(ssh_key) if ssh_key else ""
    print(f"{name} {key_name}")
