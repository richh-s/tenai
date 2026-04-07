"""scripts/lib/load_config.py — Central config loader for tenai-infra.

Loads config/defaults.yaml and deep-merges config/local.yaml on top.
The overlay file can be overridden via TENAI_CONFIG env var.

Usage (Python):
    from scripts.lib.load_config import load_config
    config = load_config()

Usage (standalone):
    python3 scripts/lib/load_config.py                    # print merged config as YAML
    python3 scripts/lib/load_config.py --get tailscale.tailnet  # get a single value
    python3 scripts/lib/load_config.py --json             # print as JSON
"""

import json
import os
import sys
from pathlib import Path

import yaml

# Resolve repo root relative to this file: scripts/lib/load_config.py → ../../
REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULTS_PATH = REPO_ROOT / "config" / "defaults.yaml"


def deep_merge(base: dict, override: dict) -> dict:
    """Deep merge override into base. Override values win at leaf level.

    - Dicts are recursively merged (new keys added, existing keys overridden).
    - Non-dict values in override replace base values entirely.
    - Keys only in base are preserved.
    """
    result = dict(base)
    for key, value in override.items():
        if (
            key in result
            and isinstance(result[key], dict)
            and isinstance(value, dict)
        ):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def _resolve_local_path() -> Path:
    """Resolve the local overlay config path.

    Priority:
      1. TENAI_CONFIG env var (relative to repo root or absolute)
      2. config/local.yaml (default)
    """
    env_config = os.environ.get("TENAI_CONFIG", "").strip()
    if env_config:
        p = Path(env_config)
        if not p.is_absolute():
            p = REPO_ROOT / p
        return p
    return REPO_ROOT / "config" / "local.yaml"


def load_config() -> dict:
    """Load defaults.yaml, deep-merge local.yaml on top, return merged config."""
    if not DEFAULTS_PATH.exists():
        print(f"ERROR: Config not found: {DEFAULTS_PATH}", file=sys.stderr)
        sys.exit(1)

    with open(DEFAULTS_PATH) as f:
        config = yaml.safe_load(f) or {}

    local_path = _resolve_local_path()
    if local_path.exists():
        with open(local_path) as f:
            local = yaml.safe_load(f) or {}
        config = deep_merge(config, local)

    return config


def config_get(dotpath: str, default=None):
    """Get a single value from merged config using dot notation.

    Example: config_get("tailscale.tailnet") → "yourname@"
    """
    config = load_config()
    keys = dotpath.split(".")
    val = config
    for key in keys:
        if isinstance(val, dict):
            val = val.get(key)
        else:
            return default
        if val is None:
            return default
    return val


def get_config_path() -> str:
    """Return the path to the effective local config file (for scripts that write config)."""
    return str(_resolve_local_path())


def get_defaults_path() -> str:
    """Return the path to defaults.yaml."""
    return str(DEFAULTS_PATH)


def main():
    """CLI entrypoint for shell/Makefile integration."""
    import argparse

    parser = argparse.ArgumentParser(description="Load and query tenai config")
    parser.add_argument("--get", metavar="KEY", help="Get a value by dot-path (e.g. tailscale.tailnet)")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    parser.add_argument("--path", action="store_true", help="Print path to effective local config")
    parser.add_argument("--defaults-path", action="store_true", help="Print path to defaults.yaml")
    args = parser.parse_args()

    if args.path:
        print(get_config_path())
        return

    if args.defaults_path:
        print(get_defaults_path())
        return

    if args.get:
        val = config_get(args.get)
        if val is None:
            sys.exit(1)
        if isinstance(val, (dict, list)):
            print(json.dumps(val))
        else:
            print(val)
        return

    config = load_config()
    if args.json:
        print(json.dumps(config, indent=2))
    else:
        print(yaml.dump(config, default_flow_style=False))


if __name__ == "__main__":
    main()
