"""
tests/test_config.py — Tests for YAML config loading and structure validation.

Tests defaults.yaml for structural correctness, and tests the merged config
(defaults + local) for device/org data when local.yaml exists.
"""
import sys
from pathlib import Path

import pytest
import yaml

ROOT_DIR = Path(__file__).parent.parent
CONFIG_DIR = ROOT_DIR / "config"

sys.path.insert(0, str(ROOT_DIR))
from scripts.lib.load_config import deep_merge, load_config  # noqa: E402


@pytest.mark.unit
class TestConfigLoading:
    def test_defaults_yaml_exists(self):
        assert (CONFIG_DIR / "defaults.yaml").exists()

    def test_defaults_yaml_parses(self):
        with open(CONFIG_DIR / "defaults.yaml") as f:
            cfg = yaml.safe_load(f)
        assert cfg is not None
        assert isinstance(cfg, dict)

    def test_has_required_top_level_keys(self):
        with open(CONFIG_DIR / "defaults.yaml") as f:
            cfg = yaml.safe_load(f)
        required = {"tailscale", "organizations", "repos", "ci", "webapp"}
        assert required.issubset(set(cfg.keys())), f"Missing keys: {required - set(cfg.keys())}"

    def test_merged_config_loads(self):
        """The central loader should always return a valid config."""
        cfg = load_config()
        assert isinstance(cfg, dict)
        assert "tailscale" in cfg
        assert "repos" in cfg


@pytest.mark.unit
class TestDeepMerge:
    def test_simple_override(self):
        base = {"a": 1, "b": 2}
        override = {"b": 3}
        assert deep_merge(base, override) == {"a": 1, "b": 3}

    def test_nested_merge(self):
        base = {"x": {"a": 1, "b": 2}}
        override = {"x": {"b": 3, "c": 4}}
        assert deep_merge(base, override) == {"x": {"a": 1, "b": 3, "c": 4}}

    def test_new_keys_added(self):
        base = {"a": 1}
        override = {"b": 2}
        assert deep_merge(base, override) == {"a": 1, "b": 2}

    def test_override_replaces_non_dict(self):
        base = {"x": {"a": 1}}
        override = {"x": "replaced"}
        assert deep_merge(base, override) == {"x": "replaced"}

    def test_empty_override(self):
        base = {"a": 1, "b": {"c": 3}}
        assert deep_merge(base, {}) == base

    def test_empty_base(self):
        override = {"a": 1}
        assert deep_merge({}, override) == override


@pytest.mark.unit
class TestDeviceConfig:
    def _load_config(self):
        return load_config()

    def test_devices_structure_when_present(self):
        """If local.yaml provides devices, they have required fields."""
        cfg = self._load_config()
        devices = cfg.get("tailscale", {}).get("devices", {})
        # Only validate if devices are configured (local.yaml present)
        if not devices:
            pytest.skip("No devices configured (no local.yaml)")
        for name, dev in devices.items():
            assert "ip" in dev, f"Device {name} missing 'ip'"
            assert "user" in dev, f"Device {name} missing 'user'"
            assert "type" in dev, f"Device {name} missing 'type'"

    def test_device_types_are_valid(self):
        valid_types = {"server", "mac", "android", "ios_ish", "ios_termius", "windows"}
        cfg = self._load_config()
        devices = cfg.get("tailscale", {}).get("devices", {})
        if not devices:
            pytest.skip("No devices configured (no local.yaml)")
        for name, dev in devices.items():
            assert dev["type"] in valid_types, f"Device {name} has invalid type: {dev['type']}"

    def test_device_ips_look_valid(self):
        cfg = self._load_config()
        devices = cfg.get("tailscale", {}).get("devices", {})
        if not devices:
            pytest.skip("No devices configured (no local.yaml)")
        for name, dev in devices.items():
            ip = dev["ip"]
            parts = ip.split(".")
            assert len(parts) == 4, f"Device {name} has invalid IP: {ip}"


@pytest.mark.unit
class TestDeviceProfiles:
    def test_profile_files_exist(self):
        """Each device type referenced in config has a profile file."""
        cfg = load_config()
        devices = cfg.get("tailscale", {}).get("devices", {})
        if not devices:
            pytest.skip("No devices configured (no local.yaml)")
        for name, dev in devices.items():
            dev_type = dev["type"]
            profile = CONFIG_DIR / "device" / f"{dev_type}.yaml"
            assert profile.exists(), f"Profile missing: {profile} (for device {name})"

    def test_profiles_parse_and_have_device_key(self):
        """All device profile YAML files parse and have a 'device' top-level key."""
        for profile in (CONFIG_DIR / "device").glob("*.yaml"):
            with open(profile) as f:
                data = yaml.safe_load(f)
            assert data is not None, f"{profile.name} is empty"
            assert "device" in data, f"{profile.name} missing 'device' key"


@pytest.mark.unit
class TestOrganizationConfig:
    def test_orgs_structure_when_present(self):
        """If local.yaml provides organizations, they have required fields."""
        cfg = load_config()
        orgs = cfg.get("organizations", {})
        if not orgs:
            pytest.skip("No organizations configured (no local.yaml)")
        for name, org in orgs.items():
            assert "github_url" in org, f"Org {name} missing 'github_url'"
            assert "ssh_host_alias" in org, f"Org {name} missing 'ssh_host_alias'"
            assert "ssh_key" in org, f"Org {name} missing 'ssh_key'"
