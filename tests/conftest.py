"""
tests/conftest.py — Shared fixtures for tenai-infra test suite.
"""
import os
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

# ── Path setup — make webapp/ and scripts/ importable ────────────────────────
ROOT_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(ROOT_DIR / "webapp"))
sys.path.insert(0, str(ROOT_DIR / "scripts"))
sys.path.insert(0, str(ROOT_DIR / "scripts" / "configure"))


# ── Fixtures ─────────────────────────────────────────────────────────────────

@pytest.fixture(autouse=True, scope="session")
def _set_device_name():
    """Ensure DEVICE_NAME is always set during tests.

    _device_db_path() requires this — no local.db fallback.
    """
    prev = os.environ.get("DEVICE_NAME")
    os.environ["DEVICE_NAME"] = "testdev"
    yield
    if prev is not None:
        os.environ["DEVICE_NAME"] = prev
    else:
        os.environ.pop("DEVICE_NAME", None)


@pytest.fixture
def tmp_db(tmp_path):
    """Create a temporary SQLite database and patch db.DB_PATH to use it.

    Yields the Path to the temp DB file. The database is initialized with
    the full schema via init_db().
    """
    db_path = tmp_path / "test.db"
    with patch("db.DB_PATH", db_path):
        import db
        db.init_db()
        yield db_path


@pytest.fixture
def sample_config():
    """Return a representative config dict matching defaults.yaml structure."""
    return {
        "tailscale": {
            "tailnet": "test@",
            "devices": {
                "server1": {
                    "ip": "100.1.1.1",
                    "user": "ubuntu",
                    "type": "server",
                    "capabilities": ["conductor", "dispatch"],
                    "skip_tools": [],
                    "advertise_exit_node": True,
                },
                "mac1": {
                    "ip": "100.2.2.2",
                    "user": "testuser",
                    "type": "mac",
                    "capabilities": ["conductor"],
                    "skip_tools": [],
                },
                "android1": {
                    "ip": "100.3.3.3",
                    "user": "mobileuser",
                    "type": "android",
                    "ssh_port": 8022,
                    "capabilities": [],
                    "skip_tools": ["vibetunnel"],
                },
                "termius1": {
                    "ip": "100.4.4.4",
                    "user": "",
                    "type": "ios_termius",
                    "capabilities": [],
                    "skip_tools": ["all"],
                },
            },
        },
        "organizations": {
            "test-org": {
                "github_url": "github.com",
                "ssh_host_alias": "github-test-org",
                "ssh_key": "~/.ssh/test-key",
                "default_branch": "main",
            },
            "other-org": {
                "github_url": "github.com",
                "ssh_host_alias": "github-other-org",
                "ssh_key": "~/.ssh/other-key",
                "default_branch": "develop",
            },
        },
        "repos": {"base_dir": "~/projects"},
        "ci": {
            "ntfy_enabled": False,
            "ntfy_topic": "",
            "ntfy_topic_human": "",
            "local_validate": ["make lint", "make test"],
            "agent_watcher": {
                "enabled": True,
                "poll_interval": 30,
                "watch_duration": 3600,
                "max_review_cycles": 3,
            },
        },
        "webapp": {"port": 7700, "host": "0.0.0.0"},
        "proxy": {
            "enabled": True,
            "autossh": True,
            "socks_port": 1055,
            "http_port": 8118,
            "exit_node": "",
            "proxied_tools": ["claude", "gemini", "codex", "python3", "ssh"],
        },
    }


@pytest.fixture
def sample_env(tmp_path):
    """Create a temporary .env file with test values and patch os.environ."""
    env_file = tmp_path / ".env"
    env_file.write_text(
        "DEVICE_NAME=test-device\n"
        "DEVICE_TYPE=mac                  # server | mac | android\n"
        "WEBAPP_PORT=7700\n"
        "NTFY_TOPIC=test-topic\n"
        "# This is a comment\n"
        "SSH_KEY_PATH=~/.ssh/id_ed25519\n"
    )
    return env_file


@pytest.fixture
def clean_env():
    """Provide a clean environment dict, restoring os.environ after the test."""
    original = os.environ.copy()
    yield os.environ
    os.environ.clear()
    os.environ.update(original)
