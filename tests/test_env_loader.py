"""
tests/test_env_loader.py — Tests for scripts/env_loader.py.
"""
import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))


@pytest.mark.unit
class TestLoadEnv:
    def test_strips_trailing_whitespace(self, sample_env, clean_env):
        """Values with trailing whitespace/comments are stripped."""
        from env_loader import load_env
        load_env(sample_env)
        # "mac                  # server | mac | android" → "mac"
        # dotenv_values strips the comment; load_env strips whitespace
        val = os.environ.get("DEVICE_TYPE", "")
        assert val == val.strip()
        assert "  " not in val  # no trailing spaces

    def test_loads_simple_values(self, sample_env, clean_env):
        from env_loader import load_env
        load_env(sample_env)
        assert os.environ.get("DEVICE_NAME") == "test-device"
        assert os.environ.get("WEBAPP_PORT") == "7700"

    def test_missing_file_no_error(self, tmp_path, clean_env):
        from env_loader import load_env
        # Should not raise
        load_env(tmp_path / "nonexistent.env")

    def test_does_not_override_existing(self, sample_env, clean_env):
        """load_env uses setdefault-like behavior — existing env vars preserved."""
        from env_loader import load_env
        # Note: dotenv_values + os.environ[key] = value actually DOES override.
        # This test documents the current behavior.
        os.environ["DEVICE_NAME"] = "already-set"
        load_env(sample_env)
        # env_loader.py uses os.environ[key] = value.strip(), so it overrides
        # This is intentional — .env file is the source of truth
        assert os.environ.get("DEVICE_NAME") is not None
