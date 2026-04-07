import json
from pathlib import Path

import pytest

from scripts.lib.state_tracker import StateTracker


@pytest.fixture
def temp_state_dir(tmp_path: Path):
    d = tmp_path / ".tenai" / "state"
    d.mkdir(parents=True)
    return d

def test_tracker_initialization(temp_state_dir):
    t = StateTracker(device="test-dev", state_dir=temp_state_dir)
    assert t.device == "test-dev"
    assert t.manifest_dir == temp_state_dir / "test-dev"
    assert (t.manifest_dir / "manifest.json") == temp_state_dir / "test-dev" / "manifest.json"

def test_record_file_created(temp_state_dir):
    t = StateTracker(device="test-dev", state_dir=temp_state_dir)
    t.record_file_created("/path/to/somefile")

    with open(t.manifest_dir / "manifest.json") as f:
        data = json.load(f)

    assert data["device"] == "test-dev"
    assert len(data["entries"]) == 1
    action = data["entries"][0]
    assert action["type"] == "file_created"
    assert action["path"] == "/path/to/somefile"

def test_record_file_modified(temp_state_dir):
    t = StateTracker(device="test-dev", state_dir=temp_state_dir)
    t.record_file_modified("/path/to/bashrc", "START", "END")

    with open(t.manifest_dir / "manifest.json") as f:
        data = json.load(f)

    action = data["entries"][0]
    assert action["type"] == "file_modified"
    assert action["path"] == "/path/to/bashrc"
    assert action["marker_start"] == "START"
    assert action["marker_end"] == "END"

def test_idempotent_append(temp_state_dir):
    t = StateTracker(device="test-dev", state_dir=temp_state_dir)
    t.record_tool_installed("gh", "apt", pre_existing=False)
    t.record_tool_installed("gh", "apt", pre_existing=False)
    t.record_tool_installed("node", "apt", pre_existing=False)

    with open(t.manifest_dir / "manifest.json") as f:
        data = json.load(f)

    # 'gh' should only be recorded once
    assert len(data["entries"]) == 2
    assert data["entries"][0]["tool"] == "gh"
    assert data["entries"][1]["tool"] == "node"

def test_pre_existing_tool(temp_state_dir):
    t = StateTracker(device="test-dev", state_dir=temp_state_dir)
    t.record_tool_installed("curl", "apt", pre_existing=True)

    with open(t.manifest_dir / "manifest.json") as f:
        data = json.load(f)

    action = data["entries"][0]
    assert action["tool"] == "curl"
    assert action["pre_existing"] is True

def test_provisional_rename(temp_state_dir):
    # Create abstract provisional state
    t = StateTracker(device="provisional", state_dir=temp_state_dir)
    t.record_file_created("/path/to/provisional.txt")

    # Assert provisional state exists
    assert (temp_state_dir / "provisional" / "manifest.json").exists()

    # Rename to final device
    StateTracker.rename_provisional(from_name="provisional", to_name="final-dev", state_dir=str(temp_state_dir))

    t_final = StateTracker(device="final-dev", state_dir=temp_state_dir)
    assert t_final.device == "final-dev"
    assert not (temp_state_dir / "provisional" / "manifest.json").exists()
    assert (temp_state_dir / "final-dev" / "manifest.json").exists()

    # Validate final device state
    with open(temp_state_dir / "final-dev" / "manifest.json") as f:
        data = json.load(f)
    assert data["device"] == "final-dev"
    assert data["entries"][0]["type"] == "file_created"

def test_audit_reconstruction(temp_state_dir):
    # Audit mode allows rebuilding missing manifest
    # For now, just test basic audit instantiates correctly
    t = StateTracker(device="audit-dev", state_dir=temp_state_dir)
    t.record_tool_installed("mosh", "brew", pre_existing=True)
    t.record_ssh_key_created("/home/user/.ssh/test_key")

    with open(t.manifest_dir / "manifest.json") as f:
        data = json.load(f)

    assert len(data["entries"]) == 2
