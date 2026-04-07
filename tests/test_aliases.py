"""
tests/test_aliases.py — Tests for scripts/configure/generate_aliases.py.
"""
import sys
from pathlib import Path

import pytest

# Add the configure scripts directory to path
sys.path.insert(0, str(Path(__file__).parent.parent / "scripts" / "configure"))


@pytest.mark.unit
class TestSafeName:
    def test_hyphens_replaced(self):
        from generate_aliases import _safe_name
        assert _safe_name("dev-srv-1") == "dev_srv_1"

    def test_dots_replaced(self):
        from generate_aliases import _safe_name
        assert _safe_name("my.device") == "my_device"

    def test_already_safe(self):
        from generate_aliases import _safe_name
        assert _safe_name("server1") == "server1"

    def test_multiple_special_chars(self):
        from generate_aliases import _safe_name
        assert _safe_name("my-device.name") == "my_device_name"


@pytest.mark.unit
class TestCapabilities:
    def test_server_has_ssh(self):
        from generate_aliases import CAPABILITIES
        assert CAPABILITIES["server"]["ssh"] is True

    def test_ios_termius_no_ssh(self):
        from generate_aliases import CAPABILITIES
        assert CAPABILITIES["ios_termius"]["ssh"] is False

    def test_ios_termius_no_mosh(self):
        from generate_aliases import CAPABILITIES
        assert CAPABILITIES["ios_termius"]["mosh_tmux"] is False

    def test_windows_no_mosh(self):
        from generate_aliases import CAPABILITIES
        assert CAPABILITIES["windows"]["mosh_tmux"] is False

    def test_all_types_have_entries(self):
        from generate_aliases import CAPABILITIES
        expected_types = {"server", "mac", "android", "ios_ish", "ios_termius", "windows"}
        assert set(CAPABILITIES.keys()) == expected_types


@pytest.mark.unit
class TestGenerateAliases:
    def test_skips_self(self, sample_config):
        from generate_aliases import generate_aliases
        output = generate_aliases(sample_config, "server1")
        # Should not contain aliases for server1 (self)
        assert "ssh_server1" not in output
        # But should contain aliases for other devices
        assert "mac1" in output

    def test_generates_ssh_for_server(self, sample_config):
        from generate_aliases import generate_aliases
        output = generate_aliases(sample_config, "mac1")
        assert "ssh_server1" in output

    def test_no_ssh_for_termius(self, sample_config):
        from generate_aliases import generate_aliases
        output = generate_aliases(sample_config, "server1")
        assert "ssh_termius1" not in output

    def test_custom_ssh_port(self, sample_config):
        from generate_aliases import generate_aliases
        output = generate_aliases(sample_config, "server1")
        # android1 has ssh_port=8022
        assert "-p 8022" in output or "-P 8022" in output

    def test_exit_node_aliases(self, sample_config):
        from generate_aliases import generate_aliases
        output = generate_aliases(sample_config, "mac1")
        assert "ts_exit_on" in output

    def test_header_present(self, sample_config):
        from generate_aliases import generate_aliases
        output = generate_aliases(sample_config, "server1")
        assert "TENAI INFRA ALIASES" in output

    def test_tailscale_aliases(self, sample_config):
        from generate_aliases import generate_aliases
        output = generate_aliases(sample_config, "server1")
        assert "ts_status" in output
        assert "ts_ip" in output

    def test_send_alias_for_all_devices(self, sample_config):
        from generate_aliases import generate_aliases
        output = generate_aliases(sample_config, "server1")
        # All devices with tailscale_send capability should have send_ alias
        assert "send_mac1" in output


@pytest.mark.unit
class TestProxyAliases:
    def test_proxy_aliases_generated(self, sample_config):
        from generate_aliases import generate_aliases
        output = generate_aliases(sample_config, "server1")
        # Proxy management functions
        assert "tenai_proxy_start" in output
        assert "tenai_proxy_stop" in output
        assert "tenai_proxy_status" in output
        assert "tenai_proxy_test" in output
        # Proxied tool aliases
        assert "tenai_claude" in output
        assert "tenai_gemini" in output
        assert "tenai_codex" in output
        assert "tenai_python3" in output
        assert "tenai_ssh" in output

    def test_proxy_aliases_skipped_when_disabled(self, sample_config):
        from generate_aliases import generate_aliases
        sample_config["proxy"]["enabled"] = False
        output = generate_aliases(sample_config, "server1")
        assert "tenai_proxy_start" not in output
        assert "alias tenai_claude='claude'" in output

    def test_proxy_custom_tools(self, sample_config):
        from generate_aliases import generate_aliases
        sample_config["proxy"]["proxied_tools"] = ["myapp", "special-tool"]
        output = generate_aliases(sample_config, "server1")
        assert "tenai_myapp" in output
        assert "tenai_special_tool" in output
        # Original defaults no longer present
        assert "tenai_claude" not in output

    def test_proxy_exit_node_auto_detected(self, sample_config):
        from generate_aliases import generate_aliases
        # server1 has advertise_exit_node=True, exit_node is empty
        output = generate_aliases(sample_config, "mac1")
        # Should reference server1 as the default exit node
        assert "server1" in output

    def test_autossh_used_when_enabled(self, sample_config):
        from generate_aliases import generate_aliases
        sample_config["proxy"]["autossh"] = True
        output = generate_aliases(sample_config, "server1")
        assert "autossh" in output
        assert "AUTOSSH_GATETIME" in output
        assert "ServerAliveInterval" in output

    def test_ssh_fallback_when_autossh_disabled(self, sample_config):
        from generate_aliases import generate_aliases
        sample_config["proxy"]["autossh"] = False
        output = generate_aliases(sample_config, "server1")
        # Should use plain ssh, no autossh references in start function
        assert "tenai_proxy_start" in output
        # autossh should not appear in the start function
        assert "AUTOSSH_GATETIME" not in output

    def test_proxy_daemon_function_generated(self, sample_config):
        from generate_aliases import generate_aliases
        output = generate_aliases(sample_config, "server1")
        assert "tenai_proxy_daemon" in output
        assert "enable" in output
        assert "disable" in output
        assert "launchctl" in output
        assert "systemctl" in output

    def test_tenai_tmux_alias_generated(self, sample_config):
        from generate_aliases import generate_aliases
        output = generate_aliases(sample_config, "server1")
        assert "tenai_tmux()" in output
        assert '${1:-main}' in output
        assert "tmux has-session" in output
        assert "tmux new-session" in output
        assert "tmux attach" in output

    def test_tenai_ntfy_status_alias_generated(self, sample_config):
        from generate_aliases import generate_aliases
        output = generate_aliases(sample_config, "server1")
        assert "tenai_ntfy_status()" in output
        assert "agent_watcher" in output
        assert "Notification Listener Status" in output

