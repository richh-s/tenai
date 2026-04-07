"""
tests/test_tailscale_provision.py — Tests for scripts/configure/tailscale_provision.py.
"""
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent / "scripts" / "configure"))


@pytest.mark.unit
class TestGetApiConfig:
    def test_missing_api_key(self):
        with patch.dict("os.environ", {}, clear=True):
            from tailscale_provision import get_api_config
            with pytest.raises(SystemExit):
                get_api_config()

    def test_missing_tailnet(self):
        with patch.dict("os.environ", {"TAILSCALE_API_KEY": "test-key"}, clear=True):
            from tailscale_provision import get_api_config
            with pytest.raises(SystemExit):
                get_api_config()

    def test_valid_config(self):
        with patch.dict("os.environ", {
            "TAILSCALE_API_KEY": "tskey-api-test",
            "TAILSCALE_TAILNET": "user@"
        }, clear=True):
            from tailscale_provision import get_api_config
            key, tailnet = get_api_config()
            assert key == "tskey-api-test"
            assert tailnet == "user"  # trailing @ stripped

    def test_tailnet_no_trailing_at(self):
        with patch.dict("os.environ", {
            "TAILSCALE_API_KEY": "tskey-api-test",
            "TAILSCALE_TAILNET": "myuser"
        }, clear=True):
            from tailscale_provision import get_api_config
            _, tailnet = get_api_config()
            assert tailnet == "myuser"


@pytest.mark.unit
class TestGetDeviceIp:
    def test_ipv4_found(self):
        from tailscale_provision import get_device_ip
        device = {"addresses": ["100.1.2.3", "fd7a:115c::1"]}
        assert get_device_ip(device) == "100.1.2.3"

    def test_no_ipv4(self):
        from tailscale_provision import get_device_ip
        device = {"addresses": ["fd7a:115c::1"]}
        assert get_device_ip(device) == ""

    def test_empty_addresses(self):
        from tailscale_provision import get_device_ip
        device = {"addresses": []}
        assert get_device_ip(device) == ""


@pytest.mark.unit
class TestFindDeviceByHostname:
    @patch("tailscale_provision.list_devices")
    def test_exact_match(self, mock_list):
        from tailscale_provision import find_device_by_hostname
        mock_list.return_value = [
            {"hostname": "dev-srv1.tail12345.ts.net", "addresses": ["100.1.2.3"]},
            {"hostname": "dev-srv2.tail12345.ts.net", "addresses": ["100.4.5.6"]},
        ]
        result = find_device_by_hostname("test-key", "test-tailnet", "dev-srv1")
        assert result is not None
        assert result["hostname"] == "dev-srv1.tail12345.ts.net"

    @patch("tailscale_provision.list_devices")
    def test_case_insensitive(self, mock_list):
        from tailscale_provision import find_device_by_hostname
        mock_list.return_value = [
            {"hostname": "MyServer.ts.net", "addresses": ["100.1.2.3"]},
        ]
        result = find_device_by_hostname("test-key", "test-tailnet", "myserver")
        assert result is not None

    @patch("tailscale_provision.list_devices")
    def test_not_found(self, mock_list):
        from tailscale_provision import find_device_by_hostname
        mock_list.return_value = [
            {"hostname": "other.ts.net", "addresses": ["100.1.2.3"]},
        ]
        result = find_device_by_hostname("test-key", "test-tailnet", "missing")
        assert result is None
