# tests/test_exit_node.py
"""
Tests for the set-exit-node feature and proxy configuration.

Covers:
  - set_exit_node.sh script structure and safety
  - Makefile target wiring
  - onboard.sh EXIT_NODE integration
  - Config update logic (advertise_exit_node, proxy.exit_node, proxy.enabled)
"""
import re
from pathlib import Path

import pytest

ROOT_DIR = Path(__file__).parent.parent
MAKEFILE = ROOT_DIR / "Makefile"
SET_EXIT_NODE = ROOT_DIR / "scripts" / "configure" / "set_exit_node.sh"
ONBOARD = ROOT_DIR / "scripts" / "entrypoints" / "onboard.sh"


@pytest.mark.unit
class TestSetExitNodeScript:
    """Verify set_exit_node.sh structure and safety."""

    def test_script_exists(self):
        assert SET_EXIT_NODE.exists(), "scripts/configure/set_exit_node.sh missing"

    def test_script_has_shebang(self):
        content = SET_EXIT_NODE.read_text()
        assert content.startswith("#!/bin/bash"), "Must use #!/bin/bash shebang"

    def test_script_has_strict_mode(self):
        content = SET_EXIT_NODE.read_text()
        assert "set -euo pipefail" in content, "Must use strict mode"

    def test_script_requires_device_arg(self):
        """Script must validate that a device argument is provided."""
        content = SET_EXIT_NODE.read_text()
        assert 'if [[ -z "$DEVICE" ]]' in content, "Must check for empty device arg"

    def test_script_validates_device_in_config(self):
        """Script must validate the device exists in config."""
        content = SET_EXIT_NODE.read_text()
        assert "NOT_FOUND" in content, "Must check if device exists in config"

    def test_script_updates_local_yaml(self):
        """Script must update config/local.yaml."""
        content = SET_EXIT_NODE.read_text()
        assert "local.yaml" in content, "Must reference config/local.yaml"
        assert "advertise_exit_node" in content, "Must set advertise_exit_node"
        assert "exit_node" in content, "Must set proxy.exit_node"

    def test_script_clears_previous_exit_node(self):
        """When setting a new exit node, previous ones should be cleared."""
        content = SET_EXIT_NODE.read_text()
        assert "pop" in content or "clear" in content.lower() or "!= device" in content, (
            "Must clear advertise_exit_node from other devices"
        )

    def test_script_advertises_on_device(self):
        """Must run tailscale set --advertise-exit-node on the device."""
        content = SET_EXIT_NODE.read_text()
        assert "--advertise-exit-node" in content, "Must run tailscale --advertise-exit-node"

    def test_script_attempts_api_approval(self):
        """Should attempt Tailscale API approval if keys are available."""
        content = SET_EXIT_NODE.read_text()
        assert "api.tailscale.com" in content, "Must attempt API-based exit node approval"
        assert "TAILSCALE_API_KEY" in content, "Must check for API key"

    def test_script_falls_back_to_manual_approval(self):
        """Must provide manual approval instructions when API is unavailable."""
        content = SET_EXIT_NODE.read_text()
        assert "login.tailscale.com/admin" in content, "Must show admin console URL"

    def test_script_regenerates_aliases(self):
        """Must regenerate aliases after setting exit node."""
        content = SET_EXIT_NODE.read_text()
        assert "configure-aliases" in content, "Must regenerate aliases"

    def test_script_installs_proxy(self):
        """Must install proxy prerequisites."""
        content = SET_EXIT_NODE.read_text()
        assert "proxy" in content.lower(), "Must set up proxy"

    def test_script_enables_daemon(self):
        """Must auto-enable the proxy daemon."""
        content = SET_EXIT_NODE.read_text()
        assert "proxy-daemon" in content, "Must enable proxy daemon"

    def test_script_supports_dry_run(self):
        """Must support DRY_RUN mode."""
        content = SET_EXIT_NODE.read_text()
        assert "DRY_RUN" in content, "Must support DRY_RUN"
        assert content.count("DRY_RUN") >= 3, "DRY_RUN must gate multiple operations"


@pytest.mark.unit
class TestSetExitNodeMakefile:
    """Verify Makefile target wiring."""

    def test_target_exists(self):
        content = MAKEFILE.read_text()
        assert "set-exit-node:" in content, "Makefile missing set-exit-node target"

    def test_target_in_phony(self):
        content = MAKEFILE.read_text()
        phony_block = re.search(r"\.PHONY:(.+?)(?=\n\n|\Z)", content, re.DOTALL)
        assert phony_block is not None, ".PHONY block not found"
        assert "set-exit-node" in phony_block.group(), "set-exit-node not in .PHONY"

    def test_target_requires_host(self):
        """Target must fail if HOST is not provided."""
        content = MAKEFILE.read_text()
        # Find the set-exit-node recipe
        match = re.search(r"set-exit-node:.*?\n(\t.*?\n)+", content)
        assert match is not None, "Could not find set-exit-node recipe"
        recipe = match.group()
        assert "HOST" in recipe, "Target must reference HOST variable"

    def test_target_has_help_comment(self):
        """Target must have a ## help comment."""
        content = MAKEFILE.read_text()
        assert "## Set a device as the exit node" in content, (
            "set-exit-node must have a ## help comment"
        )


@pytest.mark.unit
class TestOnboardExitNodeIntegration:
    """Verify onboard.sh passes through EXIT_NODE."""

    def test_makefile_passes_exit_node(self):
        """Makefile onboard target must pass EXIT_NODE."""
        content = MAKEFILE.read_text()
        # Find onboard recipe
        match = re.search(r"onboard:.*?\n(\t.*?\n)+", content)
        assert match is not None, "Could not find onboard recipe"
        recipe = match.group()
        assert "EXIT_NODE" in recipe, (
            "Makefile onboard recipe must pass EXIT_NODE to onboard.sh"
        )

    def test_onboard_has_exit_node_hook_local(self):
        """onboard.sh local flow must check EXIT_NODE."""
        content = ONBOARD.read_text()
        # Check that EXIT_NODE check appears before the local 'exit 0'
        local_section = content[:content.find("# REMOTE MODE") if "# REMOTE MODE" in content else len(content)]
        assert "EXIT_NODE" in local_section, (
            "onboard.sh local flow must check EXIT_NODE"
        )

    def test_onboard_has_exit_node_hook_remote(self):
        """onboard.sh remote flow must check EXIT_NODE."""
        content = ONBOARD.read_text()
        remote_section = content[content.find("# ── Run the remote flow") if "# ── Run the remote flow" in content else 0:]
        assert "EXIT_NODE" in remote_section, (
            "onboard.sh remote flow must check EXIT_NODE"
        )

    def test_onboard_calls_set_exit_node_script(self):
        """onboard.sh must call set_exit_node.sh."""
        content = ONBOARD.read_text()
        assert "set_exit_node.sh" in content, (
            "onboard.sh must call set_exit_node.sh for EXIT_NODE"
        )
