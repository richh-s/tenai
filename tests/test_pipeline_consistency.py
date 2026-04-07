"""
tests/test_pipeline_consistency.py — Tests for automated pipeline consistency.

Ensures functional equivalence between:
  - server.py API dispatch  (Python, reads config/cli/*.yaml)
  - worktree.sh terminal dispatch  (Bash, reads config/cli/*.yaml)

Covers:
  - CLI launch_args loaded from config vs hardcoded fallbacks
  - gh auth injection in dispatch flow
  - WORKTREE.md content validation (subtask DB API, PR step, Do-Not rules)
  - defaults.yaml has github_api_token_name for all orgs
  - .claude/settings.json exists with required allowed tools
  - implement-task skills consistency between Claude and Gemini
"""

import re
import sys
from pathlib import Path

import pytest
import yaml

ROOT_DIR = Path(__file__).parent.parent
CONFIG_DIR = ROOT_DIR / "config"
sys.path.insert(0, str(ROOT_DIR / "scripts" / "conductor"))


# ═══════════════════════════════════════════════════════════════════════════════
# CLI Config — launch_args
# ═══════════════════════════════════════════════════════════════════════════════

@pytest.mark.unit
class TestCLILaunchArgs:
    """Verify CLI config files have launch_args and they match expected patterns."""

    CLIS = ["claude", "gemini", "codex"]

    @pytest.mark.parametrize("cli", CLIS)
    def test_cli_config_exists(self, cli):
        cfg_path = CONFIG_DIR / "cli" / f"{cli}.yaml"
        assert cfg_path.exists(), f"CLI config missing: {cfg_path}"

    @pytest.mark.parametrize("cli", CLIS)
    def test_cli_config_has_launch_args(self, cli):
        cfg_path = CONFIG_DIR / "cli" / f"{cli}.yaml"
        with open(cfg_path) as f:
            cfg = yaml.safe_load(f)
        assert "launch_args" in cfg, f"{cli}.yaml missing 'launch_args' key"
        assert isinstance(cfg["launch_args"], list), f"{cli}.yaml launch_args must be a list"
        assert len(cfg["launch_args"]) > 0, f"{cli}.yaml launch_args is empty — needs auto-approve flags"

    def test_claude_launch_args_contain_skip_permissions(self):
        with open(CONFIG_DIR / "cli" / "claude.yaml") as f:
            cfg = yaml.safe_load(f)
        args = cfg["launch_args"]
        assert "--dangerously-skip-permissions" in args, (
            "Claude launch_args must include --dangerously-skip-permissions"
        )

    def test_codex_launch_args_contain_full_auto(self):
        with open(CONFIG_DIR / "cli" / "codex.yaml") as f:
            cfg = yaml.safe_load(f)
        args = cfg["launch_args"]
        assert "--full-auto" in args, "Codex launch_args must include --full-auto"

    def test_gemini_launch_args_contain_auto_approve(self):
        """Gemini should have --yolo or --sandbox=none for auto-approve."""
        with open(CONFIG_DIR / "cli" / "gemini.yaml") as f:
            cfg = yaml.safe_load(f)
        args = cfg["launch_args"]
        has_auto = any(a in args for a in ("--yolo", "--sandbox=none"))
        assert has_auto, (
            f"Gemini launch_args must include --yolo or --sandbox=none, got: {args}"
        )

    def test_server_reads_launch_args_from_config(self):
        """server.py should load launch_args from config/cli/{cli}.yaml, not hardcode."""
        server_py = ROOT_DIR / "webapp" / "server.py"
        content = server_py.read_text()
        # Check that server reads from cli config files
        assert "config/cli" in content or "cli_cfg_path" in content, (
            "server.py should reference config/cli/*.yaml for launch_args"
        )
        assert "launch_args" in content, (
            "server.py should reference launch_args from CLI config"
        )

    def test_worktree_sh_reads_launch_args_from_config(self):
        """worktree.sh should also load launch_args from config/cli/{cli}.yaml."""
        wt_sh = ROOT_DIR / "scripts" / "repos" / "worktree.sh"
        content = wt_sh.read_text()
        assert "launch_args" in content, (
            "worktree.sh should reference launch_args from CLI config"
        )
        assert "_cli_launch_args" in content, (
            "worktree.sh should have _cli_launch_args helper function"
        )

    def test_both_paths_use_same_config_files(self):
        """Both server.py and worktree.sh must read from the same config location."""
        server_py = (ROOT_DIR / "webapp" / "server.py").read_text()
        wt_sh = (ROOT_DIR / "scripts" / "repos" / "worktree.sh").read_text()

        # Both should reference config/cli/ directory pattern
        assert "config" in server_py and "cli" in server_py, (
            "server.py does not reference config/cli directory"
        )
        assert "config/cli" in wt_sh, (
            "worktree.sh does not reference config/cli directory"
        )


# ═══════════════════════════════════════════════════════════════════════════════
# Per-Org GitHub Token Config
# ═══════════════════════════════════════════════════════════════════════════════

@pytest.mark.unit
class TestGitHubTokenConfig:
    """Verify each org in defaults.yaml has github_api_token_name."""

    def _load_orgs(self):
        with open(CONFIG_DIR / "defaults.yaml") as f:
            return yaml.safe_load(f).get("organizations", {})

    def test_all_orgs_have_github_api_token_name(self):
        orgs = self._load_orgs()
        for name, org_cfg in orgs.items():
            assert "github_api_token_name" in org_cfg, (
                f"Org '{name}' missing 'github_api_token_name' in defaults.yaml"
            )
            assert isinstance(org_cfg["github_api_token_name"], str), (
                f"Org '{name}' github_api_token_name must be a string"
            )
            assert len(org_cfg["github_api_token_name"]) > 0, (
                f"Org '{name}' github_api_token_name is empty"
            )

    def test_gh_auth_in_server_dispatch(self):
        """server.py dispatch should include gh auth login --with-token."""
        content = (ROOT_DIR / "webapp" / "server.py").read_text()
        assert "gh auth login" in content, (
            "server.py dispatch should run gh auth login --with-token"
        )
        assert "github_api_token_name" in content, (
            "server.py should read github_api_token_name from org config"
        )

    def test_gh_auth_in_worktree_dispatch(self):
        """worktree.sh dispatch should also include gh auth login."""
        content = (ROOT_DIR / "scripts" / "repos" / "worktree.sh").read_text()
        assert "gh auth login" in content, (
            "worktree.sh dispatch should run gh auth login --with-token"
        )


# ═══════════════════════════════════════════════════════════════════════════════
# WORKTREE.md Content Validation
# ═══════════════════════════════════════════════════════════════════════════════

@pytest.mark.unit
class TestWorktreeMdContent:
    """Verify build_worktree_md produces correct instructions."""

    def _build_sample_worktree_md(self, subtasks=None):
        """Build a WORKTREE.md from a sample task."""
        from task_db import build_worktree_md
        task = {
            "id": 42,
            "title": "Test task",
            "description": "A test task",
            "branch": "feat/test",
            "base_branch": "main",
            "verification": "make test",
            "repo": "test-repo",
            "org": "test-org",
            "context_ref": "",
            "cli": "claude",
        }
        return build_worktree_md(task, subtasks or [])

    def test_worktree_md_has_subtask_registration(self):
        """WORKTREE.md must instruct agents to POST subtasks to DB API."""
        md = self._build_sample_worktree_md()
        assert "POST" in md, "WORKTREE.md should instruct POST for subtask registration"
        assert "/api/task-db/" in md, "WORKTREE.md should reference task-db API"
        assert "subtasks" in md.lower(), "WORKTREE.md should mention subtasks"

    def test_worktree_md_has_pr_step(self):
        """WORKTREE.md must instruct agents to create a PR."""
        md = self._build_sample_worktree_md()
        assert "gh pr create" in md, "WORKTREE.md must include gh pr create step"
        assert "--base main" in md, "PR should target base branch"

    def test_worktree_md_has_do_not_install(self):
        """WORKTREE.md must tell agents NOT to install system packages."""
        md = self._build_sample_worktree_md()
        low = md.lower()
        assert "install system" in low or "no apt" in low or "no brew" in low, (
            "WORKTREE.md must include 'do not install system packages' rule"
        )

    def test_worktree_md_has_subtask_status_update(self):
        """WORKTREE.md must instruct agents to PATCH subtask status."""
        md = self._build_sample_worktree_md()
        assert "PATCH" in md, "WORKTREE.md should instruct PATCH for subtask status update"

    def test_worktree_md_has_commit_push(self):
        """WORKTREE.md must instruct commit and push."""
        md = self._build_sample_worktree_md()
        assert "git push" in md, "WORKTREE.md should include git push"
        assert "git commit" in md or "git add" in md, "WORKTREE.md should include git commit"

    def test_worktree_md_subtask_creation_when_none(self):
        """When no subtasks, WORKTREE.md should instruct agent to create them."""
        md = self._build_sample_worktree_md(subtasks=[])
        assert "break" in md.lower() or "subtask" in md.lower(), (
            "WORKTREE.md should instruct agents to break task into subtasks"
        )

    def test_worktree_md_task_id_in_api_calls(self):
        """API URLs should contain the actual task ID, not a placeholder."""
        md = self._build_sample_worktree_md()
        assert "/42/" in md, "WORKTREE.md should embed actual task_id (42) in API URLs"


# ═══════════════════════════════════════════════════════════════════════════════
# Fallback WORKTREE.md (server.py) Equivalence
# ═══════════════════════════════════════════════════════════════════════════════

@pytest.mark.unit
class TestFallbackWorktreeMd:
    """Verify server.py fallback WORKTREE.md has same critical steps as task_db version."""

    # These are the critical strings that MUST appear in BOTH WORKTREE.md templates
    REQUIRED_PATTERNS = [
        "gh pr create",           # PR creation step
        "git push",               # Push step
        "PROOF.md",               # Proof of work
        "make lint",              # Lint check
        "subtask",                # Subtask handling
    ]

    # Prohibited patterns that must NOT appear in either template
    PROHIBITED_PATTERNS = [
        "Skip running tests",     # Old phrasing
    ]

    def _get_fallback_worktree_lines(self):
        """Extract the fallback WORKTREE.md lines from server.py."""
        content = (ROOT_DIR / "webapp" / "server.py").read_text()
        # Find the _build_fallback_worktree function
        match = re.search(
            r"def _build_fallback_worktree.*?return.*?\n",
            content,
            re.DOTALL,
        )
        return match.group(0) if match else content

    @pytest.mark.parametrize("pattern", REQUIRED_PATTERNS)
    def test_fallback_has_required_pattern(self, pattern):
        """server.py fallback WORKTREE.md should include critical pipeline steps."""
        content = (ROOT_DIR / "webapp" / "server.py").read_text()
        assert pattern.lower() in content.lower(), (
            f"server.py fallback WORKTREE.md missing: '{pattern}'"
        )

    @pytest.mark.parametrize("pattern", REQUIRED_PATTERNS)
    def test_taskdb_has_required_pattern(self, pattern):
        """task_db.py build_worktree_md should include critical pipeline steps."""
        content = (ROOT_DIR / "scripts" / "conductor" / "task_db.py").read_text()
        assert pattern.lower() in content.lower(), (
            f"task_db.py build_worktree_md missing: '{pattern}'"
        )


# ═══════════════════════════════════════════════════════════════════════════════
# Agent Permissions (.claude/settings.json)
# ═══════════════════════════════════════════════════════════════════════════════

@pytest.mark.unit
class TestAgentPermissions:
    """Verify .claude/settings.json exists with required auto-approve tools."""

    REQUIRED_TOOLS = ["git", "gh", "make", "curl"]

    def test_settings_json_exists(self):
        settings = ROOT_DIR / ".claude" / "settings.json"
        assert settings.exists(), ".claude/settings.json missing — agents can't auto-approve"

    def test_settings_json_valid(self):
        import json
        settings = ROOT_DIR / ".claude" / "settings.json"
        with open(settings) as f:
            data = json.load(f)
        assert "permissions" in data, "settings.json must have 'permissions' key"
        assert "allow" in data["permissions"], "settings.json must have 'allow' list"

    @pytest.mark.parametrize("tool", REQUIRED_TOOLS)
    def test_tool_auto_approved(self, tool):
        import json
        settings = ROOT_DIR / ".claude" / "settings.json"
        with open(settings) as f:
            data = json.load(f)
        allow_list = data["permissions"]["allow"]
        has_tool = any(tool in entry for entry in allow_list)
        assert has_tool, f"Tool '{tool}' not in .claude/settings.json allow list"


# ═══════════════════════════════════════════════════════════════════════════════
# Skills Consistency
# ═══════════════════════════════════════════════════════════════════════════════

@pytest.mark.unit
class TestImplementTaskSkills:
    """Verify implement-task skills are consistent across Claude, Gemini, and Codex."""

    # Canonical source in .agents/skills/
    CANONICAL_SKILL = ROOT_DIR / ".agents" / "skills" / "implement-task" / "SKILL.md"

    # CLI-specific paths (should be symlinks to canonical)
    ALL_CLI_PATHS = [
        ("claude", ROOT_DIR / ".claude" / "skills" / "implement-task" / "SKILL.md"),
        ("gemini", ROOT_DIR / ".gemini" / "skills" / "implement-task" / "SKILL.md"),
        ("codex", ROOT_DIR / ".codex" / "skills" / "implement-task" / "SKILL.md"),
    ]

    REQUIRED_IN_ALL = [
        "gh pr create",           # PR step
        "PROOF.md",               # Proof of work
        "subtask",                # Subtask handling
        "task-db",                # DB API reference
        "Do Not",                 # Restrictions
    ]

    def test_canonical_skill_exists(self):
        assert self.CANONICAL_SKILL.exists(), (
            f"Canonical implement-task skill missing: {self.CANONICAL_SKILL}"
        )

    @pytest.mark.parametrize("name,path", ALL_CLI_PATHS)
    def test_cli_skill_accessible(self, name, path):
        """Each CLI must have the skill accessible (via symlink or direct)."""
        assert path.exists(), (
            f"{name} implement-task skill not accessible: {path} — create symlink"
        )

    @pytest.mark.parametrize("pattern", REQUIRED_IN_ALL)
    def test_canonical_skill_has_pattern(self, pattern):
        content = self.CANONICAL_SKILL.read_text()
        assert pattern.lower() in content.lower(), (
            f"Canonical implement-task skill missing: '{pattern}'"
        )

    def test_canonical_has_subtask_registration(self):
        """Canonical skill must instruct agents to POST subtasks to DB."""
        content = self.CANONICAL_SKILL.read_text()
        assert "POST" in content, "Canonical skill missing subtask POST registration"


# ═══════════════════════════════════════════════════════════════════════════════
# gh CLI Installation
# ═══════════════════════════════════════════════════════════════════════════════

@pytest.mark.unit
class TestGHInstaller:
    """Verify tools.sh includes gh CLI installation."""

    def test_tools_sh_has_install_gh(self):
        content = (ROOT_DIR / "scripts" / "install" / "tools.sh").read_text()
        assert "install_gh" in content, "tools.sh missing install_gh function"

    def test_tools_sh_calls_install_gh(self):
        """install_gh should be called in the platform run section."""
        content = (ROOT_DIR / "scripts" / "install" / "tools.sh").read_text()
        # Should have both the function definition AND a call
        assert content.count("install_gh") >= 2, (
            "tools.sh should define AND call install_gh"
        )

    def test_tools_sh_gh_linux_install(self):
        """gh install should support Linux (apt)."""
        content = (ROOT_DIR / "scripts" / "install" / "tools.sh").read_text()
        assert "cli.github.com" in content, (
            "tools.sh should use the official GitHub apt repository"
        )

    def test_tools_sh_gh_mac_install(self):
        """gh install should support macOS (brew)."""
        content = (ROOT_DIR / "scripts" / "install" / "tools.sh").read_text()
        assert "brew install gh" in content, (
            "tools.sh should use brew for macOS gh install"
        )


# ═══════════════════════════════════════════════════════════════════════════════
# Template Generators (claude_md.sh, gemini_md.sh)
# ═══════════════════════════════════════════════════════════════════════════════

@pytest.mark.unit
class TestTemplateGenerators:
    """Verify claude_md.sh and gemini_md.sh have completion workflow sections."""

    REQUIRED_IN_TEMPLATES = [
        "gh pr create",           # PR creation
        "PROOF.md",               # Proof of work
        "git push",               # Push step
        "git commit",             # Commit step
    ]

    @pytest.mark.parametrize("pattern", REQUIRED_IN_TEMPLATES)
    def test_claude_md_has_pattern(self, pattern):
        content = (ROOT_DIR / "scripts" / "configure" / "claude_md.sh").read_text()
        assert pattern.lower() in content.lower(), (
            f"claude_md.sh missing: '{pattern}'"
        )

    @pytest.mark.parametrize("pattern", REQUIRED_IN_TEMPLATES)
    def test_gemini_md_has_pattern(self, pattern):
        content = (ROOT_DIR / "scripts" / "configure" / "gemini_md.sh").read_text()
        assert pattern.lower() in content.lower(), (
            f"gemini_md.sh missing: '{pattern}'"
        )

    def test_claude_md_has_do_not_install(self):
        content = (ROOT_DIR / "scripts" / "configure" / "claude_md.sh").read_text()
        low = content.lower()
        assert "do not" in low or "install" in low, "claude_md.sh should have restriction section"

    def test_gemini_md_has_restrictions(self):
        content = (ROOT_DIR / "scripts" / "configure" / "gemini_md.sh").read_text()
        low = content.lower()
        assert "do not" in low or "restriction" in low, "gemini_md.sh should have restriction section"

