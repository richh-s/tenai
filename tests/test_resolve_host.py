"""
tests/test_resolve_host.py — Tests for scripts/configure/resolve_host.py.
"""
import sys
import textwrap
from pathlib import Path
from unittest.mock import patch

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent / "scripts" / "configure"))

SAMPLE_CONFIG = {
    "tailscale": {
        "devices": {
            "dev-srv1": {
                "ip": "100.125.137.1",
                "user": "ubuntu",
                "type": "server",
                "skip_tools": [],
            },
            "s24": {
                "ip": "100.109.109.127",
                "user": "testuser",
                "type": "android",
                "ssh_port": 8022,
                "skip_tools": ["vibetunnel"],
            },
            "dev-mac1": {
                "ip": "100.114.132.26",
                "user": "testuser",
                "type": "mac",
            },
        }
    }
}


@pytest.mark.unit
class TestResolve:
    @patch("resolve_host.load_config", return_value=SAMPLE_CONFIG)
    def test_resolve_by_name(self, mock_cfg):
        from resolve_host import resolve
        result = resolve("dev-srv1")
        assert result is not None
        assert result["name"] == "dev-srv1"
        assert result["ip"] == "100.125.137.1"
        assert result["user"] == "ubuntu"

    @patch("resolve_host.load_config", return_value=SAMPLE_CONFIG)
    def test_resolve_by_ip(self, mock_cfg):
        from resolve_host import resolve
        result = resolve("100.109.109.127")
        assert result is not None
        assert result["name"] == "s24"

    @patch("resolve_host.load_config", return_value=SAMPLE_CONFIG)
    def test_resolve_not_found(self, mock_cfg):
        from resolve_host import resolve
        result = resolve("nonexistent")
        assert result is None

    @patch("resolve_host.load_config", return_value=SAMPLE_CONFIG)
    def test_resolve_preserves_extra_fields(self, mock_cfg):
        from resolve_host import resolve
        result = resolve("s24")
        assert result["ssh_port"] == 8022
        assert result["type"] == "android"

    @patch("resolve_host.load_config", return_value=SAMPLE_CONFIG)
    def test_resolve_includes_source(self, mock_cfg):
        from resolve_host import resolve
        result = resolve("dev-srv1")
        assert result["_source"] == "config"


@pytest.mark.unit
class TestLoadDeviceProfileSkipTools:
    def test_existing_profile(self):
        """Load skip_tools from an actual device profile."""
        from resolve_host import load_device_profile_skip_tools
        # android.yaml exists in config/device/
        skip = load_device_profile_skip_tools("android")
        assert isinstance(skip, list)

    def test_nonexistent_profile(self):
        from resolve_host import load_device_profile_skip_tools
        skip = load_device_profile_skip_tools("nonexistent_type")
        assert skip == []


@pytest.mark.unit
class TestIsIpAddress:
    def test_valid_ipv4(self):
        from resolve_host import is_ip_address
        assert is_ip_address("100.125.137.1") is True
        assert is_ip_address("192.168.1.1") is True
        assert is_ip_address("0.0.0.0") is True

    def test_invalid(self):
        from resolve_host import is_ip_address
        assert is_ip_address("myserver") is False
        assert is_ip_address("100.125.137") is False
        assert is_ip_address("") is False
        assert is_ip_address("999.999.999.999") is False


@pytest.mark.unit
class TestParseSSHConfig:
    def test_basic_host_match(self):
        from resolve_host import _parse_ssh_config_file
        config_text = textwrap.dedent("""\
            Host myserver
                HostName 10.0.0.5
                User admin
                Port 2222
                IdentityFile ~/.ssh/mykey

            Host otherhost
                HostName 10.0.0.6
                User root
        """)
        import tempfile
        with tempfile.NamedTemporaryFile(mode="w", suffix=".config", delete=False) as f:
            f.write(config_text)
            f.flush()
            result = _parse_ssh_config_file(Path(f.name), "myserver")
        assert result is not None
        assert result["hostname"] == "10.0.0.5"
        assert result["user"] == "admin"
        assert result["port"] == "2222"
        assert "identity_file" in result

    def test_no_match(self):
        from resolve_host import _parse_ssh_config_file
        config_text = "Host other\n    HostName 10.0.0.1\n"
        import tempfile
        with tempfile.NamedTemporaryFile(mode="w", suffix=".config", delete=False) as f:
            f.write(config_text)
            f.flush()
            result = _parse_ssh_config_file(Path(f.name), "nonexistent")
        assert result is None

    def test_wildcard_match(self):
        from resolve_host import _host_matches
        assert _host_matches("prod-web-01", ["prod-*"]) is True
        assert _host_matches("staging-web", ["prod-*"]) is False
        assert _host_matches("anything", ["*"]) is True

    def test_negation_pattern(self):
        from resolve_host import _host_matches
        # Match all except "local"
        assert _host_matches("remote", ["*", "!local"]) is True
        assert _host_matches("local", ["*", "!local"]) is False

    def test_multiple_hosts_on_line(self):
        from resolve_host import _parse_ssh_config_file
        config_text = textwrap.dedent("""\
            Host server1 server2
                HostName 10.0.0.5
                User admin
        """)
        import tempfile
        with tempfile.NamedTemporaryFile(mode="w", suffix=".config", delete=False) as f:
            f.write(config_text)
            f.flush()
            result1 = _parse_ssh_config_file(Path(f.name), "server1")
            result2 = _parse_ssh_config_file(Path(f.name), "server2")
        assert result1 is not None
        assert result2 is not None
        assert result1["hostname"] == "10.0.0.5"
