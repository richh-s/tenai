"""
tests/test_agent_tools.py — Tests for Phase A + B agent orchestration tools.

Covers:
  - parse_tasks.py (task parsing, ATC validation, GitHub flags)
  - github_issues.py (issue ↔ task conversion)
  - monitor_agents.py (worktree info extraction)
  - CLI skills existence
  - config: defaults.yaml structure for symphony/gastown
"""

import sys
import tempfile
from pathlib import Path

import pytest
import yaml

ROOT_DIR = Path(__file__).parent.parent
SCRIPTS_DIR = ROOT_DIR / "scripts"
CONFIG_DIR = ROOT_DIR / "config"

# Make scripts/conductor importable
sys.path.insert(0, str(SCRIPTS_DIR / "conductor"))


# ══════════════════════════════════════════════════════════════════════════════
# PARSE_TASKS.PY
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.unit
class TestParseTasksMd:
    """Test parse_tasks.py: parsing, validation, and task movement."""

    def _get_parser(self):
        from parse_tasks import parse_tasks_md
        return parse_tasks_md

    def test_parse_basic_tasks(self):
        content = """\
## Active

### Task 1: Implement login
Branch: feat/login
Add login form with validation.
Verification: `make test` passes

### Task 2: Add API endpoints
Branch: feat/api
Create REST API for users.
Verification: `pytest tests/test_api.py` passes

## Done

### Task 3: Setup CI
Branch: feat/ci
Already complete.
Verification: CI runs green
"""
        tasks = self._get_parser()(content)
        assert len(tasks) == 3
        assert tasks[0]["title"] == "Implement login"
        assert tasks[0]["branch"] == "feat/login"
        assert tasks[0]["section"] == "Active"
        assert tasks[1]["number"] == 2
        assert tasks[2]["section"] == "Done"

    def test_parse_empty_content(self):
        tasks = self._get_parser()("")
        assert tasks == []

    def test_parse_no_branch(self):
        content = "## Active\n### Task 1: No branch task\nDescription only.\n"
        tasks = self._get_parser()(content)
        assert len(tasks) == 1
        assert tasks[0]["branch"] == ""

    def test_parse_sections(self):
        content = """\
## Active
### Task 1: T1
Branch: b1
Verification: v1

## In Progress
### Task 2: T2
Branch: b2
Verification: v2

## Done
### Task 3: T3
Branch: b3
Verification: v3
"""
        tasks = self._get_parser()(content)
        sections = [t["section"] for t in tasks]
        assert sections == ["Active", "In Progress", "Done"]


@pytest.mark.unit
class TestATCValidation:
    """Test ATC compliance validation."""

    def _get_validator(self):
        from parse_tasks import validate_tasks
        return validate_tasks

    def test_valid_tasks_pass(self):
        tasks = [
            {"number": 1, "title": "Good task", "branch": "feat/x", "description": "A good task", "verification": "test passes", "section": "Active"},
            {"number": 2, "title": "Another", "branch": "feat/y", "description": "Another good task", "verification": "lint passes", "section": "Active"},
        ]
        warnings = self._get_validator()(tasks)
        assert warnings == []

    def test_missing_branch_flagged(self):
        tasks = [{"number": 1, "title": "No branch", "branch": "", "description": "d", "verification": "v", "section": "Active"}]
        warnings = self._get_validator()(tasks)
        assert any("missing Branch" in w for w in warnings)

    def test_missing_verification_flagged(self):
        tasks = [{"number": 1, "title": "No verif", "branch": "b", "description": "d", "verification": "", "section": "Active"}]
        warnings = self._get_validator()(tasks)
        assert any("missing Verification" in w for w in warnings)

    def test_duplicate_branch_flagged(self):
        tasks = [
            {"number": 1, "title": "T1", "branch": "same", "description": "d", "verification": "v", "section": "Active"},
            {"number": 2, "title": "T2", "branch": "same", "description": "d", "verification": "v", "section": "Active"},
        ]
        warnings = self._get_validator()(tasks)
        assert any("duplicate branch" in w for w in warnings)

    def test_missing_description_flagged(self):
        tasks = [{"number": 1, "title": "T", "branch": "b", "description": "", "verification": "v", "section": "Active"}]
        warnings = self._get_validator()(tasks)
        assert any("missing description" in w for w in warnings)


@pytest.mark.unit
class TestMoveTask:
    """Test task movement between sections."""

    def _get_mover(self):
        from parse_tasks import move_task, parse_tasks_md
        return move_task, parse_tasks_md

    def test_move_active_to_done(self):
        content = """\
## Active

### Task 1: Test task
Branch: feat/x
A task.
Verification: passes

## In Progress

## Done
"""
        move_task, parse_tasks_md = self._get_mover()
        new_content = move_task(content, 1, "Done")
        tasks = parse_tasks_md(new_content)
        assert tasks[0]["section"] == "Done"

    def test_move_nonexistent_task_raises(self):
        move_task, _ = self._get_mover()
        with pytest.raises(ValueError, match="Task 99 not found"):
            move_task("## Active\n## Done\n", 99, "Done")


# ══════════════════════════════════════════════════════════════════════════════
# GITHUB_ISSUES.PY
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.unit
class TestGitHubIssuesAdapter:
    """Test GitHub Issues → TASKS.md conversion (no network calls)."""

    def _get_converter(self):
        from github_issues import issues_to_tasks
        return issues_to_tasks

    def test_convert_issues_to_tasks_format(self):
        issues = [
            {
                "number": 42,
                "title": "Implement auth",
                "body": "Branch: feat/auth\nAdd OAuth2 login flow.\nVerification: `make test` passes",
                "labels": [{"name": "agent-task"}, {"name": "status:active"}],
                "state": "OPEN",
                "assignees": [],
            },
            {
                "number": 43,
                "title": "Fix dashboard",
                "body": "The dashboard needs fixing.",
                "labels": [{"name": "agent-task"}, {"name": "status:done"}],
                "state": "CLOSED",
                "assignees": [],
            },
        ]
        result = self._get_converter()(issues)
        assert "# TASKS.md" in result
        assert "## Active" in result
        assert "## Done" in result
        assert "Task 42: Implement auth" in result
        assert "Task 43: Fix dashboard" in result

    def test_empty_issues_produces_skeleton(self):
        result = self._get_converter()([])
        assert "## Active" in result
        assert "## Done" in result

    def test_status_label_mapping(self):
        issues = [
            {"number": 1, "title": "T", "body": "", "labels": [{"name": "status:in-progress"}], "state": "OPEN", "assignees": []},
        ]
        result = self._get_converter()(issues)
        assert "## In Progress" in result
        assert "Task 1" in result


# ══════════════════════════════════════════════════════════════════════════════
# MONITOR_AGENTS.PY
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.unit
class TestMonitorAgents:
    """Test worktree info extraction and proof reading."""

    def _get_extractor(self):
        from monitor_agents import extract_worktree_info
        return extract_worktree_info

    def test_extract_worktree_info_standard(self):
        path = "/home/user/projects/myapp/.trees/feat-auth"
        info = self._get_extractor()(path)
        assert info["repo"] == "myapp"
        assert info["worktree_dir"] == path
        assert "safe_branch" in info

    def test_extract_worktree_info_non_worktree(self):
        path = "/home/user/projects/myapp"
        info = self._get_extractor()(path)
        assert info["worktree_dir"] == path
        assert info["repo"] == ""

    def test_read_proof_exists(self):
        from monitor_agents import read_proof

        with tempfile.TemporaryDirectory() as td:
            proof = Path(td) / "PROOF.md"
            proof.write_text("# Proof\nTests passed.")
            result = read_proof(td)
            assert "Tests passed" in result

    def test_read_proof_missing(self):
        from monitor_agents import read_proof

        with tempfile.TemporaryDirectory() as td:
            result = read_proof(td)
            assert result is None


@pytest.mark.unit
class TestSessionHistory:
    """Test session_history.py: worktree session aggregation."""

    def test_get_worktree_sessions_empty(self):
        from session_history import get_worktree_sessions

        with tempfile.TemporaryDirectory() as td:
            sessions = get_worktree_sessions(td)
            assert sessions == []

    def test_get_worktree_sessions_with_trees(self):
        from session_history import get_worktree_sessions

        with tempfile.TemporaryDirectory() as td:
            trees = Path(td) / ".trees"
            trees.mkdir()
            wt = trees / "feat-login"
            wt.mkdir()
            # Write session start
            (wt / ".session_start").write_text(
                "2026-03-15T12:00:00Z\ncli=claude\ntask=Implement login\nsession=myapp-agents\nwindow=feat-login\n"
            )
            sessions = get_worktree_sessions(td)
            assert len(sessions) == 1
            assert sessions[0]["branch"] == "feat-login"
            assert sessions[0]["cli"] == "claude"
            assert sessions[0]["task"] == "Implement login"
            assert sessions[0]["started"] == "2026-03-15T12:00:00Z"

    def test_detects_proof(self):
        from session_history import get_worktree_sessions

        with tempfile.TemporaryDirectory() as td:
            trees = Path(td) / ".trees"
            trees.mkdir()
            wt = trees / "feat-api"
            wt.mkdir()
            (wt / "PROOF.md").write_text("# PROOF.md\n## Test Results\nAll tests passed.\n")
            sessions = get_worktree_sessions(td)
            assert sessions[0]["has_proof"] is True
            assert sessions[0]["proof_summary"] == "Test Results"

    def test_no_proof(self):
        from session_history import get_worktree_sessions

        with tempfile.TemporaryDirectory() as td:
            trees = Path(td) / ".trees"
            trees.mkdir()
            (trees / "feat-x").mkdir()
            sessions = get_worktree_sessions(td)
            assert sessions[0]["has_proof"] is False


@pytest.mark.unit
class TestOrchestrator:
    """Test orchestrator.py: task loading, webhook handling."""

    def test_load_dispatchable_empty(self):
        from orchestrator import load_dispatchable_tasks

        with tempfile.TemporaryDirectory() as td:
            tasks = load_dispatchable_tasks(td)
            assert tasks == []

    def test_load_dispatchable_from_tasks_md(self):
        from orchestrator import load_dispatchable_tasks

        with tempfile.TemporaryDirectory() as td:
            (Path(td) / "TASKS.md").write_text(
                "## Active\n### Task 1: Test\nBranch: feat/x\nDescription.\nVerification: passes\n## Done\n"
            )
            tasks = load_dispatchable_tasks(td)
            assert len(tasks) == 1
            assert tasks[0]["branch"] == "feat/x"

    def test_handle_webhook_dispatch(self):
        from orchestrator import _handle_webhook_payload

        # Should not crash even without real dispatch
        with tempfile.TemporaryDirectory() as td:
            _handle_webhook_payload(
                {"action": "dispatch", "branch": "feat/test", "repo": "", "task": "test"},
                td, "claude"
            )

    def test_handle_webhook_status(self, capsys):
        from orchestrator import _handle_webhook_payload

        with tempfile.TemporaryDirectory() as td:
            _handle_webhook_payload({"action": "status"}, td, "claude")
            out = capsys.readouterr().out
            assert "Status" in out

    def test_check_agents_empty(self):
        from orchestrator import check_agents

        with tempfile.TemporaryDirectory() as td:
            status = check_agents(td)
            assert status["total"] == 0
            assert status["all_done"] is False


# ══════════════════════════════════════════════════════════════════════════════
# CLI SKILLS & CONFIG
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.unit
class TestCLISkillsExist:
    """Ensure all CLI skill files exist and are properly structured."""

    SKILL_PATHS = [
        (".agents/skills/validate-tasks/SKILL.md", "description:"),
        (".agents/skills/proof-of-work/SKILL.md", "description:"),
        (".claude/skills/validate-tasks/SKILL.md", "description:"),
        (".claude/skills/proof-of-work/SKILL.md", "description:"),
        (".gemini/skills/validate-tasks/SKILL.md", "description:"),
        (".gemini/skills/proof-of-work/SKILL.md", "description:"),
        (".codex/skills/validate-tasks/SKILL.md", "description:"),
        (".codex/skills/proof-of-work/SKILL.md", "description:"),
    ]

    @pytest.mark.parametrize("path,expected_content", SKILL_PATHS)
    def test_skill_file_exists(self, path, expected_content):
        full = ROOT_DIR / path
        assert full.exists(), f"Missing skill: {path}"

    @pytest.mark.parametrize("path,expected_content", SKILL_PATHS)
    def test_skill_has_description(self, path, expected_content):
        full = ROOT_DIR / path
        content = full.read_text()
        assert expected_content in content, f"Skill {path} missing '{expected_content}'"


@pytest.mark.unit
class TestInstructionFiles:
    """Ensure all instruction files contain harness engineering sections."""

    INSTRUCTION_FILES = ["CLAUDE.md", "GEMINI.md", "AGENTS.md"]

    @pytest.mark.parametrize("filename", INSTRUCTION_FILES)
    def test_has_harness_engineering(self, filename):
        f = ROOT_DIR / filename
        assert f.exists(), f"Missing: {filename}"
        content = f.read_text()
        assert "Harness Engineering" in content, f"{filename} missing Harness Engineering"

    @pytest.mark.parametrize("filename", INSTRUCTION_FILES)
    def test_has_proof_of_work(self, filename):
        f = ROOT_DIR / filename
        content = f.read_text()
        assert "Proof of Work" in content, f"{filename} missing Proof of Work"

    @pytest.mark.parametrize("filename", INSTRUCTION_FILES)
    def test_has_context_engineering(self, filename):
        f = ROOT_DIR / filename
        content = f.read_text()
        assert "Context Engineering" in content, f"{filename} missing Context Engineering"


@pytest.mark.unit
class TestConfigSymphonyGastown:
    """Test defaults.yaml has symphony and gastown config sections."""

    def _load(self):
        with open(CONFIG_DIR / "defaults.yaml") as f:
            return yaml.safe_load(f)

    def test_symphony_config_exists(self):
        cfg = self._load()
        assert "symphony" in cfg, "defaults.yaml missing symphony section"
        assert "enabled" in cfg["symphony"]
        assert "tracker" in cfg["symphony"]

    def test_gastown_config_exists(self):
        cfg = self._load()
        assert "gastown" in cfg, "defaults.yaml missing gastown section"
        assert "enabled" in cfg["gastown"]

    def test_conductor_config(self):
        cfg = self._load()
        cond = cfg.get("conductor", {})
        assert "task_output_file" in cond
        assert "workflow" in cond


@pytest.mark.unit
class TestCLIYamlConfigs:
    """Test CLI yaml configs reference built-in skills."""

    @pytest.mark.parametrize("cli", ["claude", "gemini", "codex"])
    def test_yaml_exists(self, cli):
        assert (CONFIG_DIR / "cli" / f"{cli}.yaml").exists()

    @pytest.mark.parametrize("cli", ["claude", "gemini", "codex"])
    def test_yaml_has_skills(self, cli):
        with open(CONFIG_DIR / "cli" / f"{cli}.yaml") as f:
            data = yaml.safe_load(f)
        assert "skills" in data, f"{cli}.yaml missing skills"
        # Should have at least validate-tasks and proof-of-work
        skill_names = [s.get("name", "") for s in data["skills"] if isinstance(s, dict)]
        assert "validate-tasks" in skill_names, f"{cli}.yaml missing validate-tasks skill"
        assert "proof-of-work" in skill_names, f"{cli}.yaml missing proof-of-work skill"
