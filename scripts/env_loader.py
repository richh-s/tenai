"""
scripts/env_loader.py — Safe .env loader with whitespace stripping.

python-dotenv does NOT strip trailing whitespace from unquoted values,
which causes subtle bugs when .env lines have inline comments like:
    DEVICE_TYPE=mac                  # server | mac | android | ios_ish | windows
This results in DEVICE_TYPE="mac                  " instead of "mac".

Usage:
    from env_loader import load_env
    load_env()  # call once at startup, strips all loaded values
"""
import os
from pathlib import Path
from dotenv import dotenv_values


def load_env(env_path: Path = None):
    """Load .env file and strip whitespace from all values.

    Args:
        env_path: Path to .env file. If None, searches parent directories.
    """
    if env_path is None:
        # Walk up from caller to find .env
        env_path = Path(__file__).parent.parent / ".env"

    if not env_path.exists():
        return

    # Load raw values, strip, and inject into os.environ
    raw = dotenv_values(str(env_path))
    for key, value in raw.items():
        if value is not None:
            os.environ[key] = value.strip()
