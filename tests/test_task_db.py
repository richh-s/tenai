"""
tests/test_task_db.py — Tests for task database CRUD and context resolution.

Covers:
  - Schema creation (tasks table exists)
  - CRUD: add, list, update, delete
  - Import from TASKS.md (with Context/Created-by fields)
  - Render TASKS.md from database
  - Context resolution (conductor tracks, inline, github stub)
  - Enhanced parse_tasks.py Context/Created-by parsing
"""

import os
import sys
import tempfile
from pathlib import Path

import pytest

ROOT_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(ROOT_DIR / "scripts" / "conductor"))
sys.path.insert(0, str(ROOT_DIR / "webapp"))


@pytest.mark.unit
class TestTaskSchema:
    """Test that the tasks table schema is created correctly."""

    def test_tasks_table_created(self):
        import db as webapp_db
        with tempfile.TemporaryDirectory() as td:
            test_db = Path(td) / "test.db"
            device_db_dir = Path(td) / "devices"
            original_path = webapp_db.DB_PATH
            original_dir = webapp_db.DB_DIR
            original_dev_dir = webapp_db.DEVICE_DB_DIR
            webapp_db.DB_PATH = test_db
            webapp_db.DB_DIR = Path(td)
            webapp_db.DEVICE_DB_DIR = device_db_dir
            try:
                webapp_db.init_webapp_db()
                webapp_db.init_device_db("")
                with webapp_db.get_device_db("") as conn:
                    tables = [r[0] for r in conn.execute(
                        "SELECT name FROM sqlite_master WHERE type='table'"
                    ).fetchall()]
                    assert "tasks" in tables
            finally:
                webapp_db.DB_PATH = original_path
                webapp_db.DB_DIR = original_dir
                webapp_db.DEVICE_DB_DIR = original_dev_dir

    def test_tasks_table_columns(self):
        import db as webapp_db
        with tempfile.TemporaryDirectory() as td:
            test_db = Path(td) / "test.db"
            device_db_dir = Path(td) / "devices"
            original_path = webapp_db.DB_PATH
            original_dir = webapp_db.DB_DIR
            original_dev_dir = webapp_db.DEVICE_DB_DIR
            webapp_db.DB_PATH = test_db
            webapp_db.DB_DIR = Path(td)
            webapp_db.DEVICE_DB_DIR = device_db_dir
            try:
                webapp_db.init_webapp_db()
                webapp_db.init_device_db("")
                with webapp_db.get_device_db("") as conn:
                    cols = {r[1] for r in conn.execute("PRAGMA table_info(tasks)").fetchall()}
                    expected = {
                        "id", "number", "title", "repo", "org", "branch", "slug",
                        "description", "instruction", "verification", "context_type", "context_ref",
                        "status", "section", "priority",
                        "created_by", "created_by_user", "created_by_cli", "created_by_model",
                        "github_issue", "github_repo", "github_url",
                        "conductor_track", "plan_document", "spec_document",
                        "dispatch_device", "dispatch_cli", "worktree_path",
                        "created_at", "updated_at",
                    }
                    assert expected.issubset(cols), f"Missing: {expected - cols}"
            finally:
                webapp_db.DB_PATH = original_path
                webapp_db.DB_DIR = original_dir
                webapp_db.DEVICE_DB_DIR = original_dev_dir


@pytest.mark.unit
class TestTaskCRUD:
    """Test task_db.py CRUD operations."""

    @pytest.fixture(autouse=True)
    def _setup_test_db(self):
        import db as webapp_db
        self._td = tempfile.TemporaryDirectory()
        td = Path(self._td.name)
        test_db = td / "test.db"
        device_db_dir = td / "devices"
        self._originals = {
            "DB_PATH": webapp_db.DB_PATH,
            "DB_DIR": webapp_db.DB_DIR,
            "DEVICE_DB_DIR": webapp_db.DEVICE_DB_DIR,
        }
        webapp_db.DB_PATH = test_db
        webapp_db.DB_DIR = td
        webapp_db.DEVICE_DB_DIR = device_db_dir
        # Set DEVICE_NAME so _device_db_path doesn't raise on empty device
        self._orig_device_name = os.environ.get("DEVICE_NAME")
        os.environ["DEVICE_NAME"] = "testdev"
        # Reset task_db module state (may be stale from test_api.py)
        from task_db import set_device
        set_device("testdev")
        webapp_db.init_webapp_db()
        webapp_db.init_device_db("testdev")
        # Seed repos table so resolve_task_org works
        with webapp_db.get_device_db("testdev") as conn:
            conn.execute(
                "INSERT OR IGNORE INTO organizations (name, ssh_host_alias, ssh_key) "
                "VALUES ('testorg', 'github.com', 'none')"
            )
            conn.execute(
                "INSERT OR IGNORE INTO repos (name, org, default_branch) "
                "VALUES ('myapp', 'testorg', 'main')"
            )
        yield
        webapp_db.DB_PATH = self._originals["DB_PATH"]
        webapp_db.DB_DIR = self._originals["DB_DIR"]
        webapp_db.DEVICE_DB_DIR = self._originals["DEVICE_DB_DIR"]
        if self._orig_device_name is not None:
            os.environ["DEVICE_NAME"] = self._orig_device_name
        else:
            os.environ.pop("DEVICE_NAME", None)
        self._td.cleanup()

    def test_resolve_task_org(self):
        from task_db import resolve_task_org
        assert resolve_task_org("myapp") == "testorg"

    def test_resolve_task_org_not_found(self):
        from task_db import resolve_task_org
        with pytest.raises(ValueError, match="not found in repos table"):
            resolve_task_org("nonexistent")

    def test_add_task_auto_resolves_org(self):
        from task_db import add_task, get_task_by_branch
        add_task(repo="myapp", title="Auto org test", branch="feat/auto-org")
        task = get_task_by_branch("myapp", "feat/auto-org")
        assert task["org"] == "testorg"

    def test_add_task_explicit_org(self):
        from task_db import add_task, get_task_by_branch
        add_task(repo="myapp", title="Explicit org", branch="feat/explicit", org="customorg")
        task = get_task_by_branch("myapp", "feat/explicit")
        assert task["org"] == "customorg"

    def test_add_and_list(self):
        from task_db import add_task, list_tasks
        tid = add_task(repo="myapp", title="Fix bug", branch="fix/bug")
        assert tid > 0
        tasks = list_tasks("myapp")
        assert len(tasks) == 1
        assert tasks[0]["title"] == "Fix bug"
        assert tasks[0]["number"] == 1

    def test_auto_number_increment(self):
        from task_db import add_task, list_tasks
        add_task(repo="myapp", title="T1", branch="b1")
        add_task(repo="myapp", title="T2", branch="b2")
        tasks = list_tasks("myapp")
        assert tasks[0]["number"] == 1
        assert tasks[1]["number"] == 2

    def test_filter_by_status(self):
        from task_db import add_task, list_tasks, update_task
        tid = add_task(repo="myapp", title="T1", branch="b1")
        add_task(repo="myapp", title="T2", branch="b2")
        update_task(tid, status="done", section="Done")
        active = list_tasks("myapp", status="active")
        assert len(active) == 1
        assert active[0]["title"] == "T2"

    def test_get_by_branch(self):
        from task_db import add_task, get_task_by_branch
        add_task(repo="myapp", title="Auth", branch="feat/auth")
        task = get_task_by_branch("myapp", "feat/auth")
        assert task is not None
        assert task["title"] == "Auth"

    def test_get_by_branch_not_found(self):
        from task_db import get_task_by_branch
        task = get_task_by_branch("myapp", "nonexistent")
        assert task is None

    def test_update_by_branch(self):
        from task_db import add_task, get_task_by_branch, update_task_by_branch
        add_task(repo="myapp", title="T", branch="b")
        update_task_by_branch("myapp", "b", status="done")
        task = get_task_by_branch("myapp", "b")
        assert task["status"] == "done"

    def test_delete(self):
        from task_db import add_task, delete_task, list_tasks
        tid = add_task(repo="myapp", title="To delete", branch="del")
        delete_task(tid)
        assert list_tasks("myapp") == []

    def test_lineage_fields(self):
        from task_db import add_task, get_task_by_branch
        add_task(
            repo="myapp", title="Lineage test", branch="feat/lin",
            created_by="gemini-conductor", created_by_cli="gemini",
            created_by_model="gemini-3.1-pro",
        )
        task = get_task_by_branch("myapp", "feat/lin")
        assert task["created_by"] == "gemini-conductor"
        assert task["created_by_cli"] == "gemini"
        assert task["created_by_model"] == "gemini-3.1-pro"

    def test_context_fields(self):
        from task_db import add_task, get_task_by_branch
        add_task(
            repo="myapp", title="Conductor task", branch="feat/ctx",
            context_type="conductor", context_ref="conductor/tracks/auth-login",
            conductor_track="auth-login",
        )
        task = get_task_by_branch("myapp", "feat/ctx")
        assert task["context_type"] == "conductor"
        assert task["context_ref"] == "conductor/tracks/auth-login"
        assert task["conductor_track"] == "auth-login"


@pytest.mark.unit
class TestTaskImportRender:
    """Test TASKS.md import and render."""

    @pytest.fixture(autouse=True)
    def _setup_test_db(self):
        import db as webapp_db
        self._td = tempfile.TemporaryDirectory()
        test_db = Path(self._td.name) / "test.db"
        self._originals = {
            "DB_PATH": webapp_db.DB_PATH,
            "DB_DIR": webapp_db.DB_DIR,
            "DEVICE_DB_DIR": webapp_db.DEVICE_DB_DIR,
        }
        device_db_dir = Path(self._td.name) / "devices"
        webapp_db.DB_PATH = test_db
        webapp_db.DB_DIR = Path(self._td.name)
        webapp_db.DEVICE_DB_DIR = device_db_dir
        webapp_db.init_webapp_db()
        webapp_db.init_device_db("")
        # Seed repos table so resolve_task_org works for 'testapp' and 'myapp'
        with webapp_db.get_device_db("") as conn:
            conn.execute(
                "INSERT OR IGNORE INTO organizations (name, ssh_host_alias, ssh_key) "
                "VALUES ('testorg', 'github.com', 'none')"
            )
            conn.execute(
                "INSERT OR IGNORE INTO repos (name, org, default_branch) "
                "VALUES ('testapp', 'testorg', 'main')"
            )
            conn.execute(
                "INSERT OR IGNORE INTO repos (name, org, default_branch) "
                "VALUES ('myapp', 'testorg', 'main')"
            )
        yield
        webapp_db.DB_PATH = self._originals["DB_PATH"]
        webapp_db.DB_DIR = self._originals["DB_DIR"]
        webapp_db.DEVICE_DB_DIR = self._originals["DEVICE_DB_DIR"]
        self._td.cleanup()

    def test_import_from_tasks_md(self):
        from task_db import import_from_tasks_md, list_tasks
        tasks_file = Path(self._td.name) / "TASKS.md"
        tasks_file.write_text(
            "## Active\n"
            "### Task 1: Login\n"
            "Branch: feat/login\n"
            "Context: conductor/tracks/login\n"
            "Created-by: gemini (gemini-3.1-pro) @ 2026-03-15\n"
            "Implement login flow.\n"
            "Verification: pytest passes\n\n"
            "### Task 2: API\n"
            "Branch: feat/api\n"
            "Context: github:42\n"
            "Create REST API.\n"
            "Verification: curl test passes\n\n"
            "## Done\n"
        )
        imported, _, _ = import_from_tasks_md("myapp", str(tasks_file))
        assert imported == 2
        tasks = list_tasks("myapp")
        assert len(tasks) == 2
        assert tasks[0]["context_type"] == "conductor"
        assert tasks[0]["context_ref"] == "conductor/tracks/login"

    def test_render_tasks_md(self):
        from task_db import add_task, render_tasks_md
        add_task(repo="myapp", title="Login", branch="feat/login",
                 verification="pytest passes", created_by="gemini")
        md = render_tasks_md("myapp")
        assert "# TASKS.md — myapp" in md
        assert "## Active" in md
        assert "Task 1: Login" in md
        assert "feat/login" in md

    def test_import_skip_duplicates(self):
        from task_db import add_task, import_from_tasks_md
        add_task(repo="myapp", title="Existing", branch="feat/x")
        tasks_file = Path(self._td.name) / "TASKS.md"
        tasks_file.write_text(
            "## Active\n### Task 1: Existing\nBranch: feat/x\nVerification: v\n"
        )
        imported, skipped, updated = import_from_tasks_md("myapp", str(tasks_file))
        assert imported == 0
        assert skipped == 1  # already exists by branch

    def test_import_idempotent_by_title(self):
        """Branchless tasks are deduplicated by title (auto-branch is generated)."""
        from task_db import import_from_tasks_md, list_tasks
        tasks_file = Path(self._td.name) / "TASKS.md"
        tasks_file.write_text(
            "## Active\n### Task 1: No branch task\nDescription.\nVerification: v\n"
        )
        # First import: creates task with auto-generated branch
        imported1, _, _ = import_from_tasks_md("myapp", str(tasks_file))
        assert imported1 == 1
        # Second import: should skip (idempotent)
        imported2, skipped, _ = import_from_tasks_md("myapp", str(tasks_file))
        assert imported2 == 0
        assert skipped == 1
        assert len(list_tasks("myapp")) == 1

    def test_import_auto_generates_branch(self):
        """Branchless tasks get auto-generated branch names during import."""
        from task_db import import_from_tasks_md, list_tasks
        tasks_file = Path(self._td.name) / "TASKS.md"
        tasks_file.write_text(
            "## Active\n### Task 1: Fix login flow\nDescription.\nVerification: v\n"
        )
        import_from_tasks_md("myapp", str(tasks_file))
        tasks = list_tasks("myapp")
        assert len(tasks) == 1
        assert tasks[0]["branch"] != ""  # branch was auto-generated
        assert "fix-login-flow" in tasks[0]["branch"]

    def test_import_force_creates_duplicates(self):
        """FORCE=1 clears existing tasks for repo and re-imports fresh."""
        from task_db import add_task, import_from_tasks_md, list_tasks
        # Branchless tasks are the realistic FORCE use case
        add_task(repo="myapp", title="Refactor module")
        tasks_file = Path(self._td.name) / "TASKS.md"
        tasks_file.write_text(
            "## Active\n### Task 1: Refactor module\nNew desc.\nVerification: v\n"
        )
        imported, skipped, _ = import_from_tasks_md("myapp", str(tasks_file), force=True)
        assert imported == 1
        assert skipped == 0
        assert len(list_tasks("myapp")) == 1  # old cleared, fresh import

    def test_import_update_existing(self):
        """UPDATE=1 updates fields of existing tasks instead of skipping."""
        from task_db import add_task, get_task_by_branch, import_from_tasks_md
        add_task(repo="myapp", title="Auth flow", branch="feat/auth",
                 description="Old desc", verification="old verify")
        tasks_file = Path(self._td.name) / "TASKS.md"
        tasks_file.write_text(
            "## Active\n### Task 1: Auth flow\nBranch: feat/auth\n"
            "New description.\nVerification: new verify\n"
        )
        imported, skipped, updated = import_from_tasks_md(
            "myapp", str(tasks_file), update=True
        )
        assert imported == 0
        assert updated == 1
        task = get_task_by_branch("myapp", "feat/auth")
        assert task["description"] == "New description."
        assert task["verification"] == "new verify"

    def test_slug_computed_on_add(self):
        """Slug is auto-populated when adding a task."""
        from task_db import add_task, compute_slug, get_task_by_branch
        add_task(repo="myapp", title="Auth", branch="feat/auth", description="test")
        task = get_task_by_branch("myapp", "feat/auth")
        assert task["slug"] == compute_slug("Auth", "test")
        assert len(task["slug"]) == 8

    def test_same_branch_different_slug_allowed(self):
        """Two tasks on same branch with different content are allowed."""
        from task_db import add_task, list_tasks
        add_task(repo="myapp", title="Task A", branch="feat/auth", description="first")
        add_task(repo="myapp", title="Task B", branch="feat/auth", description="second")
        tasks = list_tasks("myapp")
        assert len(tasks) == 2  # both coexist


@pytest.mark.unit
class TestContextResolution:
    """Test resolve_context for different context types."""

    @pytest.fixture(autouse=True)
    def _setup_test_db(self):
        import db as webapp_db
        self._td = tempfile.TemporaryDirectory()
        test_db = Path(self._td.name) / "test.db"
        self._originals = {
            "DB_PATH": webapp_db.DB_PATH,
            "DB_DIR": webapp_db.DB_DIR,
            "DEVICE_DB_DIR": webapp_db.DEVICE_DB_DIR,
        }
        device_db_dir = Path(self._td.name) / "devices"
        webapp_db.DB_PATH = test_db
        webapp_db.DB_DIR = Path(self._td.name)
        webapp_db.DEVICE_DB_DIR = device_db_dir
        webapp_db.init_webapp_db()
        webapp_db.init_device_db("")
        # Seed repos table for org resolution
        with webapp_db.get_device_db("") as conn:
            conn.execute(
                "INSERT OR IGNORE INTO organizations (name, ssh_host_alias, ssh_key) "
                "VALUES ('testorg', 'github.com', 'none')"
            )
            for r in ('app', 'myapp', 'testapp'):
                conn.execute(
                    "INSERT OR IGNORE INTO repos (name, org, default_branch) "
                    f"VALUES ('{r}', 'testorg', 'main')"
                )
        yield
        webapp_db.DB_PATH = self._originals["DB_PATH"]
        webapp_db.DB_DIR = self._originals["DB_DIR"]
        webapp_db.DEVICE_DB_DIR = self._originals["DEVICE_DB_DIR"]
        self._td.cleanup()

    def test_resolve_inline(self):
        from task_db import resolve_context
        task = {"context_type": "inline", "description": "Fix the bug"}
        result = resolve_context(task)
        assert result == "Fix the bug"

    def test_resolve_conductor_tracks(self):
        from task_db import resolve_context
        repo_dir = self._td.name
        track = Path(repo_dir) / "conductor" / "tracks" / "auth"
        track.mkdir(parents=True)
        (track / "spec.md").write_text("# Auth Spec\nImplement OAuth2.")
        (track / "plan.md").write_text("# Plan\n- [ ] Create login endpoint")
        task = {"context_type": "conductor", "context_ref": "conductor/tracks/auth"}
        result = resolve_context(task, repo_dir)
        assert "Auth Spec" in result
        assert "Plan" in result
        assert "login endpoint" in result

    def test_resolve_conductor_not_found(self):
        from task_db import resolve_context
        task = {"context_type": "conductor", "context_ref": "conductor/tracks/missing"}
        result = resolve_context(task, self._td.name)
        assert "not found" in result

    def test_resolve_github_no_gh(self):
        from task_db import resolve_context
        task = {"context_type": "github", "context_ref": "99999", "github_repo": ""}
        result = resolve_context(task)
        # Should gracefully handle missing gh CLI
        assert "99999" in result


@pytest.mark.unit
class TestParseTasksContext:
    """Test enhanced parse_tasks.py with Context/Created-by fields."""

    def test_parse_context_conductor(self):
        from parse_tasks import parse_tasks_md
        content = "## Active\n### Task 1: Auth\nBranch: feat/auth\nContext: conductor/tracks/auth\nDescription.\nVerification: passes\n"
        tasks = parse_tasks_md(content)
        assert tasks[0]["context_type"] == "conductor"
        assert tasks[0]["context_ref"] == "conductor/tracks/auth"

    def test_parse_context_github(self):
        from parse_tasks import parse_tasks_md
        content = "## Active\n### Task 1: Fix\nBranch: fix/x\nContext: github:42\nDescription.\nVerification: passes\n"
        tasks = parse_tasks_md(content)
        assert tasks[0]["context_type"] == "github"
        assert tasks[0]["context_ref"] == "42"

    def test_parse_context_inline(self):
        from parse_tasks import parse_tasks_md
        content = "## Active\n### Task 1: Fix\nBranch: fix/x\nContext: inline\nDescription.\nVerification: passes\n"
        tasks = parse_tasks_md(content)
        assert tasks[0]["context_type"] == "inline"

    def test_parse_created_by(self):
        from parse_tasks import parse_tasks_md
        content = "## Active\n### Task 1: T\nBranch: b\nCreated-by: gemini-conductor (gemini-3.1-pro) @ 2026-03-15\nDesc.\nVerification: passes\n"
        tasks = parse_tasks_md(content)
        assert tasks[0]["created_by_cli"] == "gemini-conductor"
        assert tasks[0]["created_by_model"] == "gemini-3.1-pro"

    def test_parse_assigned_dispatched_skipped(self):
        from parse_tasks import parse_tasks_md
        content = (
            "## Active\n### Task 1: T\nBranch: b\n"
            "Assigned: server1 (claude)\nDispatched: 2026-03-15T14:00:00Z\n"
            "Do the thing.\nVerification: passes\n"
        )
        tasks = parse_tasks_md(content)
        assert tasks[0]["description"] == "Do the thing."

    def test_no_context_defaults_inline(self):
        from parse_tasks import parse_tasks_md
        content = "## Active\n### Task 1: T\nBranch: b\nDesc.\nVerification: passes\n"
        tasks = parse_tasks_md(content)
        assert tasks[0]["context_type"] == "inline"
        assert tasks[0]["context_ref"] == ""


@pytest.mark.unit
class TestParseConductorFormat:
    """Test parse_tasks_md with Gemini conductor checkbox format."""

    def test_parse_conductor_checkbox(self):
        from parse_tasks import parse_tasks_md
        content = (
            "## 1. Auth Module\n"
            "- [ ] **Task 1.1: Unit tests for login**\n"
            "  - **Branch**: `test/auth-login`\n"
            "  - Write unit tests for all login endpoints\n"
            "  - **Verification**: `pytest tests/test_login.py` passes\n"
        )
        tasks = parse_tasks_md(content)
        assert len(tasks) == 1
        assert tasks[0]["title"] == "Unit tests for login"
        assert tasks[0]["branch"] == "test/auth-login"
        assert "pytest tests/test_login.py" in tasks[0]["verification"]
        assert "Write unit tests" in tasks[0]["description"]
        assert tasks[0]["section"] == "Active"

    def test_parse_conductor_multiple_sections(self):
        from parse_tasks import parse_tasks_md
        content = (
            "# TASKS.md — Testing\n\n"
            "## 1. Auth Module\n"
            "- [ ] **Task 1.1: Login tests**\n"
            "  - **Branch**: `test/login`\n"
            "  - Login testing\n"
            "  - **Verification**: `make test` passes\n\n"
            "## 2. API Module\n"
            "- [ ] **Task 2.1: API endpoints**\n"
            "  - **Branch**: `test/api`\n"
            "  - API testing\n"
            "  - **Verification**: `make test` passes\n"
        )
        tasks = parse_tasks_md(content)
        assert len(tasks) == 2
        assert tasks[0]["title"] == "Login tests"
        assert tasks[0]["branch"] == "test/login"
        assert tasks[1]["title"] == "API endpoints"
        assert tasks[1]["branch"] == "test/api"

    def test_parse_conductor_backtick_branch(self):
        from parse_tasks import parse_tasks_md
        content = (
            "## 1. Scripts\n"
            "- [ ] **Task 1.1: Fix parser**\n"
            "  - **Branch**: `fix/parser-edge-cases`\n"
            "  - Handle edge cases\n"
            "  - **Verification**: `pytest` passes\n"
        )
        tasks = parse_tasks_md(content)
        assert tasks[0]["branch"] == "fix/parser-edge-cases"

    def test_parse_mixed_format(self):
        """Both canonical and conductor format in same content."""
        from parse_tasks import parse_tasks_md
        content = (
            "## Active\n"
            "### Task 1: Manual task\n"
            "Branch: feat/manual\n"
            "Manual description.\n"
            "Verification: passes\n\n"
            "## 1. Auto-generated\n"
            "- [ ] **Task 1.1: Auto task**\n"
            "  - **Branch**: `feat/auto`\n"
            "  - Auto description\n"
            "  - **Verification**: `make test`\n"
        )
        tasks = parse_tasks_md(content)
        assert len(tasks) == 2
        assert tasks[0]["title"] == "Manual task"
        assert tasks[0]["branch"] == "feat/manual"
        assert tasks[1]["title"] == "Auto task"
        assert tasks[1]["branch"] == "feat/auto"

@pytest.mark.unit
class TestQueryTasks:
    """Test query_tasks with rich filters."""

    @pytest.fixture(autouse=True)
    def _setup_test_db(self):
        import db as webapp_db
        self._td = tempfile.TemporaryDirectory()
        test_db = Path(self._td.name) / "test.db"
        self._originals = {
            "DB_PATH": webapp_db.DB_PATH,
            "DB_DIR": webapp_db.DB_DIR,
            "DEVICE_DB_DIR": webapp_db.DEVICE_DB_DIR,
        }
        device_db_dir = Path(self._td.name) / "devices"
        webapp_db.DB_PATH = test_db
        webapp_db.DB_DIR = Path(self._td.name)
        webapp_db.DEVICE_DB_DIR = device_db_dir
        webapp_db.init_webapp_db()
        webapp_db.init_device_db("")
        # Seed repos table for org resolution
        with webapp_db.get_device_db("") as conn:
            conn.execute(
                "INSERT OR IGNORE INTO organizations (name, ssh_host_alias, ssh_key) "
                "VALUES ('testorg', 'github.com', 'none')"
            )
            for r in ('app', 'app1', 'app2', 'myapp', 'testapp'):
                conn.execute(
                    "INSERT OR IGNORE INTO repos (name, org, default_branch) "
                    f"VALUES ('{r}', 'testorg', 'main')"
                )
        yield
        webapp_db.DB_PATH = self._originals["DB_PATH"]
        webapp_db.DB_DIR = self._originals["DB_DIR"]
        webapp_db.DEVICE_DB_DIR = self._originals["DEVICE_DB_DIR"]
        self._td.cleanup()

    def test_query_by_pattern(self):
        from task_db import add_task, query_tasks
        add_task(repo="app", title="Auth login flow", branch="feat/auth")
        add_task(repo="app", title="API endpoints", branch="feat/api")
        results = query_tasks(pattern="auth")
        assert len(results) == 1
        assert results[0]["title"] == "Auth login flow"

    def test_query_by_context_type(self):
        from task_db import add_task, query_tasks
        add_task(repo="app", title="T1", branch="b1", context_type="conductor")
        add_task(repo="app", title="T2", branch="b2", context_type="github")
        add_task(repo="app", title="T3", branch="b3", context_type="inline")
        results = query_tasks(context_type="conductor")
        assert len(results) == 1
        assert results[0]["title"] == "T1"

    def test_query_by_created_by(self):
        from task_db import add_task, query_tasks
        add_task(repo="app", title="T1", branch="b1", created_by="gemini-conductor")
        add_task(repo="app", title="T2", branch="b2", created_by="human")
        results = query_tasks(created_by="gemini")
        assert len(results) == 1

    def test_query_cross_repo(self):
        from task_db import add_task, query_tasks
        add_task(repo="app1", title="T1", branch="b1")
        add_task(repo="app2", title="T2", branch="b2")
        all_tasks = query_tasks()
        assert len(all_tasks) == 2
        repo1 = query_tasks(repo="app1")
        assert len(repo1) == 1

    def test_query_with_limit(self):
        from task_db import add_task, query_tasks
        for i in range(5):
            add_task(repo="app", title=f"T{i}", branch=f"b{i}")
        results = query_tasks(limit=3)
        assert len(results) == 3


@pytest.mark.unit
class TestRegisterTask:
    """Test register_task with auto-detection."""

    @pytest.fixture(autouse=True)
    def _setup_test_db(self):
        import db as webapp_db
        self._td = tempfile.TemporaryDirectory()
        test_db = Path(self._td.name) / "test.db"
        self._originals = {
            "DB_PATH": webapp_db.DB_PATH,
            "DB_DIR": webapp_db.DB_DIR,
            "DEVICE_DB_DIR": webapp_db.DEVICE_DB_DIR,
        }
        device_db_dir = Path(self._td.name) / "devices"
        webapp_db.DB_PATH = test_db
        webapp_db.DB_DIR = Path(self._td.name)
        webapp_db.DEVICE_DB_DIR = device_db_dir
        webapp_db.init_webapp_db()
        webapp_db.init_device_db("")
        # Seed repos table for org resolution
        with webapp_db.get_device_db("") as conn:
            conn.execute(
                "INSERT OR IGNORE INTO organizations (name, ssh_host_alias, ssh_key) "
                "VALUES ('testorg', 'github.com', 'none')"
            )
            for r in ('app', 'myapp', 'testapp'):
                conn.execute(
                    "INSERT OR IGNORE INTO repos (name, org, default_branch) "
                    f"VALUES ('{r}', 'testorg', 'main')"
                )
        yield
        webapp_db.DB_PATH = self._originals["DB_PATH"]
        webapp_db.DB_DIR = self._originals["DB_DIR"]
        webapp_db.DEVICE_DB_DIR = self._originals["DEVICE_DB_DIR"]
        self._td.cleanup()

    def test_register_conductor_auto_detect(self):
        from task_db import get_task_by_branch, register_task
        register_task(
            repo="app", title="Auth", branch="feat/auth",
            context_ref="conductor/tracks/auth", cli="gemini",
        )
        task = get_task_by_branch("app", "feat/auth")
        assert task["context_type"] == "conductor"
        assert task["created_by"] == "gemini"
        assert task["created_by_cli"] == "gemini"

    def test_register_github_auto_detect(self):
        from task_db import get_task_by_branch, register_task
        register_task(
            repo="app", title="Fix", branch="fix/x",
            context_ref="github:42", cli="claude",
        )
        task = get_task_by_branch("app", "fix/x")
        assert task["context_type"] == "github"
        assert task["context_ref"] == "42"

    def test_register_inline_default(self):
        from task_db import get_task_by_branch, register_task
        register_task(repo="app", title="Manual", branch="feat/m", cli="codex")
        task = get_task_by_branch("app", "feat/m")
        assert task["context_type"] == "inline"
        assert task["created_by"] == "codex"

    def test_register_conductor_track(self):
        from task_db import get_task_by_branch, register_task
        register_task(
            repo="app", title="Track task", branch="feat/t",
            conductor_track="login", cli="gemini",
        )
        task = get_task_by_branch("app", "feat/t")
        assert task["context_type"] == "conductor"
        assert task["context_ref"] == "conductor/tracks/login"
        assert task["created_by"] == "gemini-conductor"
        assert task["conductor_track"] == "login"


@pytest.mark.unit
class TestWebappTasksAPI:
    """Test webapp /task-db API endpoints."""

    @pytest.fixture(autouse=True)
    def _setup_test_db(self):
        import db as webapp_db
        self._td = tempfile.TemporaryDirectory()
        test_db = Path(self._td.name) / "test.db"
        self._originals = {
            "DB_PATH": webapp_db.DB_PATH,
            "DB_DIR": webapp_db.DB_DIR,
            "DEVICE_DB_DIR": webapp_db.DEVICE_DB_DIR,
        }
        device_db_dir = Path(self._td.name) / "devices"
        webapp_db.DB_PATH = test_db
        webapp_db.DB_DIR = Path(self._td.name)
        webapp_db.DEVICE_DB_DIR = device_db_dir
        # Reset task_db module state (may be stale from test_api.py)
        from task_db import set_device
        set_device("testdev")
        webapp_db.init_webapp_db()
        webapp_db.init_device_db("testdev")
        # Seed repos table for org resolution
        with webapp_db.get_device_db("testdev") as conn:
            conn.execute(
                "INSERT OR IGNORE INTO organizations (name, ssh_host_alias, ssh_key) "
                "VALUES ('testorg', 'github.com', 'none')"
            )
            for r in ('app', 'myapp', 'testapp'):
                conn.execute(
                    "INSERT OR IGNORE INTO repos (name, org, default_branch) "
                    f"VALUES ('{r}', 'testorg', 'main')"
                )
        yield
        webapp_db.DB_PATH = self._originals["DB_PATH"]
        webapp_db.DB_DIR = self._originals["DB_DIR"]
        webapp_db.DEVICE_DB_DIR = self._originals["DEVICE_DB_DIR"]
        self._td.cleanup()

    def test_api_register_and_list(self):
        import asyncio

        async def _run():
            try:
                import httpx
                from httpx import ASGITransport
            except ImportError:
                pytest.skip("httpx not installed")

            sys.path.insert(0, str(ROOT_DIR / "webapp"))
            from server import app

            transport = ASGITransport(app=app)
            async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
                resp = await client.post("/api/task-db", json={
                    "repo": "myapp", "title": "Test task", "branch": "feat/test",
                })
                assert resp.status_code == 200
                data = resp.json()
                assert data["ok"] is True
                tid = data["task_id"]

                resp = await client.get("/api/task-db", params={"repo": "myapp"})
                assert resp.status_code == 200
                assert resp.json()["count"] == 1

                resp = await client.patch(f"/api/task-db/{tid}", json={"status": "done"})
                assert resp.status_code == 200
                assert "status" in resp.json()["updated"]

        asyncio.run(_run())

    def test_api_render(self):
        import asyncio

        from task_db import add_task
        add_task(repo="myapp", title="Render test", branch="feat/r")

        async def _run():
            try:
                import httpx
                from httpx import ASGITransport
            except ImportError:
                pytest.skip("httpx not installed")

            sys.path.insert(0, str(ROOT_DIR / "webapp"))
            from server import app

            transport = ASGITransport(app=app)
            async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
                resp = await client.get("/api/task-db/render/myapp")
                assert resp.status_code == 200
                assert "Render test" in resp.json()["content"]

        asyncio.run(_run())

    def test_api_query_with_pattern(self):
        import asyncio

        from task_db import add_task
        add_task(repo="myapp", title="Auth login", branch="feat/auth")
        add_task(repo="myapp", title="API fix", branch="fix/api")

        async def _run():
            try:
                import httpx
                from httpx import ASGITransport
            except ImportError:
                pytest.skip("httpx not installed")

            sys.path.insert(0, str(ROOT_DIR / "webapp"))
            from server import app

            transport = ASGITransport(app=app)
            async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
                resp = await client.get("/api/task-db", params={"pattern": "auth"})
                assert resp.status_code == 200
                assert resp.json()["count"] == 1

        asyncio.run(_run())
