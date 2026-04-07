"""
tests/test_uninstall.py — Sandboxed tests for uninstall wizard and audit.

All tests use tmp_path fixtures — nothing touches real ~/.ssh, ~/.tenai, or shell RCs.
"""
import json
from pathlib import Path

import pytest

from scripts.lib.state_tracker import StateTracker


@pytest.fixture
def sandbox(tmp_path: Path):
    """Create a sandboxed home + state dir that mirrors real layout."""
    home = tmp_path / "home"
    state_dir = tmp_path / "state"
    infra_dir = tmp_path / "infra"

    # Create home skeleton
    (home / ".ssh").mkdir(parents=True)
    (home / ".tenai").mkdir(parents=True)

    # Create state dir
    state_dir.mkdir(parents=True)

    # Create infra dir with minimal config
    (infra_dir / "config").mkdir(parents=True)
    (infra_dir / "config" / "defaults.yaml").write_text(
        "ssh:\n  key_name: test-ssh-key\ntools:\n  common:\n    - curl\n    - git\n"
    )

    return {"home": home, "state_dir": state_dir, "infra_dir": infra_dir}


# ── Uninstall plan generation ─────────────────────────────────────────────────


def test_uninstall_plan_empty(sandbox):
    """Empty manifest produces empty plan."""
    t = StateTracker(device="dev1", state_dir=sandbox["state_dir"])
    assert t.generate_uninstall_plan() == []


def test_uninstall_plan_skips_pre_existing(sandbox):
    """Pre-existing tools should NOT appear in the uninstall plan."""
    t = StateTracker(device="dev1", state_dir=sandbox["state_dir"])
    t.record_tool_installed("curl", "apt", pre_existing=True)
    t.record_tool_installed("gh", "apt", pre_existing=False)

    plan = t.generate_uninstall_plan()
    assert len(plan) == 1
    assert plan[0]["tool"] == "gh"


def test_uninstall_plan_reverse_order(sandbox):
    """Plan should be in reverse chronological order."""
    t = StateTracker(device="dev1", state_dir=sandbox["state_dir"])
    t.record_file_created("/first")
    t.record_file_created("/second")
    t.record_file_created("/third")

    plan = t.generate_uninstall_plan()
    assert [e["path"] for e in plan] == ["/third", "/second", "/first"]


def test_uninstall_plan_includes_all_reversible_types(sandbox):
    """All reversible types should appear in the plan."""
    t = StateTracker(device="dev1", state_dir=sandbox["state_dir"])
    t.record_file_created("/tmp/test_file")
    t.record_file_modified("/tmp/bashrc", "START", "END")
    t.record_ssh_key_created("/tmp/key")
    t.record_dir_created("/tmp/mydir")
    t.record_tool_installed("gh", "brew", pre_existing=False)
    t.record_config_registered("dev1")

    plan = t.generate_uninstall_plan()
    types = {e["type"] for e in plan}
    assert "file_created" in types
    assert "file_modified" in types
    assert "ssh_key_created" in types
    assert "dir_created" in types
    assert "tool_installed" in types
    assert "config_registered" in types


# ── Audit reconstruction ─────────────────────────────────────────────────────


def test_audit_finds_aliases_file(sandbox):
    """Audit should detect ~/.tenai_aliases if it exists."""
    home = sandbox["home"]
    (home / ".tenai_aliases").write_text("# aliases\n")

    t = StateTracker.audit(
        device="auditdev",
        state_dir=str(sandbox["state_dir"]),
        infra_dir=str(sandbox["infra_dir"]),
        home_dir=str(home),
    )

    entries = t.get_all()
    assert any(e["type"] == "file_created" and "tenai_aliases" in e["path"] for e in entries)


def test_audit_finds_ssh_key(sandbox):
    """Audit should detect SSH key from config key_name."""
    home = sandbox["home"]
    # audit() calls load_config() which reads real config/local.yaml.
    # The key_name there is "tenai-git-ssh-key", so we create that file.
    # If load_config() fails, fallback is "tenai-ssh-key" from defaults.
    for name in ["tenai-git-ssh-key", "tenai-ssh-key", "test-ssh-key"]:
        (home / ".ssh" / name).write_text("fake-key\n")

    t = StateTracker.audit(
        device="auditdev",
        state_dir=str(sandbox["state_dir"]),
        infra_dir=str(sandbox["infra_dir"]),
        home_dir=str(home),
    )

    entries = t.get_all()
    assert any(e["type"] == "ssh_key_created" for e in entries)


def test_audit_finds_tenai_dir(sandbox):
    """Audit should detect ~/.tenai directory."""
    home = sandbox["home"]

    t = StateTracker.audit(
        device="auditdev",
        state_dir=str(sandbox["state_dir"]),
        infra_dir=str(sandbox["infra_dir"]),
        home_dir=str(home),
    )

    entries = t.get_all()
    assert any(e["type"] == "dir_created" and ".tenai" in e["path"] for e in entries)


def test_audit_finds_shell_rc_markers(sandbox):
    """Audit should detect TENAI INFRA marker blocks in shell RCs."""
    home = sandbox["home"]
    (home / ".zshrc").write_text(
        "# some stuff\n"
        "# ── TENAI INFRA ALIASES START ──\n"
        "source ~/.tenai_aliases\n"
        "# ── TENAI INFRA ALIASES END ──\n"
    )

    t = StateTracker.audit(
        device="auditdev",
        state_dir=str(sandbox["state_dir"]),
        infra_dir=str(sandbox["infra_dir"]),
        home_dir=str(home),
    )

    entries = t.get_all()
    assert any(e["type"] == "file_modified" and ".zshrc" in e["path"] for e in entries)


def test_audit_ignores_missing_files(sandbox):
    """Audit should not crash when home dir has minimal content."""
    home = sandbox["home"]
    # home has .ssh and .tenai but no aliases, no shell rc, no ssh key

    t = StateTracker.audit(
        device="auditdev",
        state_dir=str(sandbox["state_dir"]),
        infra_dir=str(sandbox["infra_dir"]),
        home_dir=str(home),
    )

    # Only .tenai dir should be detected
    entries = t.get_all()
    types = {e["type"] for e in entries}
    assert "dir_created" in types
    assert "file_created" not in types
    assert "ssh_key_created" not in types


def test_audit_uses_home_dir_not_real_home(sandbox):
    """Audit with home_dir should never read from Path.home()."""
    home = sandbox["home"]

    StateTracker.audit(
        device="isolated",
        state_dir=str(sandbox["state_dir"]),
        infra_dir=str(sandbox["infra_dir"]),
        home_dir=str(home),
    )

    # Verify manifest was written to sandbox, not real home
    manifest = sandbox["state_dir"] / "isolated" / "manifest.json"
    assert manifest.exists()

    with open(manifest) as f:
        data = json.load(f)
    assert data["device"] == "isolated"


# ── Manifest safety ──────────────────────────────────────────────────────────


def test_manifest_written_to_state_dir_only(sandbox):
    """Manifest must be created inside state_dir, never in home or elsewhere."""
    t = StateTracker(device="safedev", state_dir=sandbox["state_dir"])
    t.record_file_created("/some/file")

    manifest = sandbox["state_dir"] / "safedev" / "manifest.json"
    assert manifest.exists()

    # Verify nothing was written to the sandbox home dir
    assert not (sandbox["home"] / ".tenai" / "state").exists()


def test_state_dir_override_isolates_tests(sandbox):
    """Passing state_dir ensures no writes to default ~/.tenai/state."""
    t = StateTracker(device="testdev", state_dir=str(sandbox["state_dir"]))
    t.record_tool_installed("node", "brew", pre_existing=False)

    # Manifest exists in our sandbox
    assert (sandbox["state_dir"] / "testdev" / "manifest.json").exists()

    with open(sandbox["state_dir"] / "testdev" / "manifest.json") as f:
        data = json.load(f)
    assert data["entries"][0]["tool"] == "node"
