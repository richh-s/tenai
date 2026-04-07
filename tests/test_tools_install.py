# tests/test_tools_install.py
"""
Tests for scripts/install/tools.sh — installer hardening.

Covers:
  - SKIP_TOOLS whitespace stripping (spaces after commas)
  - INSTALL_ONLY whitespace stripping
  - Systemd user bus guard for vibetunnel (prevents hangs in cloud VMs)
  - should_install() function correctness
  - Tool registry completeness
"""
import re
from pathlib import Path

import pytest

ROOT_DIR = Path(__file__).parent.parent
TOOLS_SH = ROOT_DIR / "scripts" / "install" / "tools.sh"


@pytest.mark.unit
class TestShouldInstallFunction:
    """Verify the should_install() function handles edge cases."""

    def _get_should_install_body(self):
        content = TOOLS_SH.read_text()
        match = re.search(
            r"^should_install\(\)\s*\{(.*?)^\}",
            content,
            re.MULTILINE | re.DOTALL,
        )
        assert match is not None, "should_install() not found in tools.sh"
        return match.group(1)

    def test_should_install_exists(self):
        self._get_should_install_body()

    def test_skip_tools_whitespace_stripping(self):
        """SKIP_TOOLS with spaces after commas must be handled (e.g. 'vim, vibetunnel')."""
        body = self._get_should_install_body()
        # Must strip spaces from merged_skip before matching
        assert "// /" in body or "${merged_skip// /}" in body, (
            "should_install must strip whitespace from SKIP_TOOLS. "
            "Users naturally write 'SKIP_TOOLS=vim, vibetunnel' with spaces."
        )

    def test_install_only_whitespace_stripping(self):
        """INSTALL_ONLY with spaces must also be handled."""
        body = self._get_should_install_body()
        assert "${INSTALL_ONLY// /}" in body or "${only// /}" in body, (
            "should_install must strip whitespace from INSTALL_ONLY"
        )

    def test_skip_tools_merge_with_resolved(self):
        """SKIP_TOOLS (.env) must be merged with RESOLVED_SKIP_TOOLS (config)."""
        body = self._get_should_install_body()
        assert "RESOLVED_SKIP_TOOLS" in body, "Must merge with RESOLVED_SKIP_TOOLS"
        assert "merged_skip" in body, "Must use merged_skip variable"

    def test_case_insensitive_matching(self):
        """Tool matching should be case-insensitive."""
        body = self._get_should_install_body()
        assert "grep -qi" in body, "Tool matching should use grep -qi (case-insensitive)"


@pytest.mark.unit
class TestVibetunnelSystemdGuard:
    """Verify vibetunnel installer won't hang in cloud VMs."""

    def _get_vibetunnel_body(self):
        content = TOOLS_SH.read_text()
        match = re.search(
            r"^install_vibetunnel\(\)\s*\{(.*?)^\}",
            content,
            re.MULTILINE | re.DOTALL,
        )
        assert match is not None, "install_vibetunnel() not found"
        return match.group(1)

    def test_systemd_user_bus_check(self):
        """Must check for systemd user bus before running systemctl --user."""
        body = self._get_vibetunnel_body()
        assert "DBUS_SESSION_BUS_ADDRESS" in body, (
            "Must check DBUS_SESSION_BUS_ADDRESS before systemctl --user"
        )

    def test_systemctl_has_timeout(self):
        """All systemctl --user commands must have timeouts."""
        body = self._get_vibetunnel_body()
        # Find all systemctl --user lines
        systemctl_lines = [
            line.strip()
            for line in body.split("\n")
            if "systemctl --user" in line and not line.strip().startswith("#")
        ]
        for line in systemctl_lines:
            assert "timeout" in line, (
                f"systemctl --user without timeout will hang in cloud VMs: {line}"
            )

    def test_graceful_skip_without_user_bus(self):
        """Must gracefully skip systemd setup when user bus is unavailable."""
        body = self._get_vibetunnel_body()
        assert "skipping service setup" in body.lower() or "not available" in body.lower(), (
            "Must print a message when skipping systemd setup"
        )


@pytest.mark.unit
class TestToolRegistryConsistency:
    """Verify tool registry and call sites are consistent."""

    def test_all_install_functions_called(self):
        """Every install_* function defined must be called somewhere."""
        content = TOOLS_SH.read_text()
        # Find all install_* function definitions
        definitions = set(re.findall(r"^(install_\w+)\(\)", content, re.MULTILINE))
        # Functions that are called indirectly (via install_common_tools calling install_pkg)
        indirect = {"install_pkg"}
        # Find all install_* calls in the run section
        for func in definitions - indirect:
            # Must appear at least twice: definition + at least one call
            count = content.count(func)
            assert count >= 2, (
                f"{func} is defined but never called (appears {count} time(s))"
            )

    def test_should_install_guards_tools(self):
        """should_install must guard vibetunnel, muxtree, mosh, etc."""
        content = TOOLS_SH.read_text()
        guarded_tools = ["vibetunnel", "muxtree", "mosh", "claude_code", "gemini_cli"]
        for tool in guarded_tools:
            pattern = f'should_install {tool}'
            assert pattern in content, (
                f"Tool '{tool}' must be guarded by should_install"
            )


@pytest.mark.unit
class TestCloudInitEnvInjection:
    """Verify cloud-init .env injection in sandbox test script."""

    SANDBOX_SH = ROOT_DIR / "scripts" / "dev" / "test_sandbox.sh"

    def test_env_injection_uses_base64(self):
        """Sandbox must use base64 for .env injection to avoid YAML escaping issues."""
        if not self.SANDBOX_SH.exists():
            pytest.skip("test_sandbox.sh not present")
        content = self.SANDBOX_SH.read_text()
        assert "base64" in content, (
            ".env injection must use base64 encoding to avoid YAML/special char issues"
        )

    def test_env_injection_after_clone(self):
        """The .env must be written after the repo clone, not in write_files."""
        if not self.SANDBOX_SH.exists():
            pytest.skip("test_sandbox.sh not present")
        content = self.SANDBOX_SH.read_text()
        # Should be in runcmd, not in write_files
        assert "runcmd" in content, ".env injection should be in cloud-init runcmd"

    def test_home_dir_ownership_fix(self):
        """Cloud-init must fix home directory ownership after root operations."""
        if not self.SANDBOX_SH.exists():
            pytest.skip("test_sandbox.sh not present")
        content = self.SANDBOX_SH.read_text()
        assert "chown" in content, (
            "Must fix home dir ownership (chown) after cloud-init root operations"
        )

    def test_package_update_optional(self):
        """Package update must be optional / default false."""
        if not self.SANDBOX_SH.exists():
            pytest.skip("test_sandbox.sh not present")
        content = self.SANDBOX_SH.read_text()
        assert "update-packages" in content or "UPDATE_PACKAGES" in content, (
            "Package update should be controlled by a flag"
        )
