"""
tests/test_db.py — Unit tests for webapp/db.py SQLite persistence layer.

Each test class uses its own fresh temporary database to ensure isolation.
"""
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

# Make webapp/ importable
sys.path.insert(0, str(Path(__file__).parent.parent / "webapp"))

import db as db_module  # noqa: E402


@pytest.fixture(autouse=True)
def isolated_db(tmp_path):
    """Every test gets its own fresh SQLite database (webapp + device)."""
    db_path = tmp_path / "test.db"
    device_db_dir = tmp_path / "devices"
    with patch.object(db_module, "DB_PATH", db_path), \
         patch.object(db_module, "DB_DIR", tmp_path), \
         patch.object(db_module, "DEVICE_DB_DIR", device_db_dir):
        db_module.init_webapp_db()
        db_module.init_device_db("")  # empty-string device for tests
        yield db_module


# ── Schema & Init ────────────────────────────────────────────────────────────


@pytest.mark.unit
class TestInitDB:
    def test_creates_webapp_tables(self, isolated_db):
        """init_webapp_db creates devices and settings tables."""
        with isolated_db.get_webapp_db() as conn:
            tables = {
                row[0]
                for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
            }
        assert "devices" in tables
        assert "settings" in tables

    def test_creates_device_tables(self, isolated_db):
        """init_device_db creates org/repo/job/task tables."""
        with isolated_db.get_device_db("") as conn:
            tables = {
                row[0]
                for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
            }
        assert "organizations" in tables
        assert "repos" in tables
        assert "jobs" in tables
        assert "job_logs" in tables
        assert "tasks" in tables
        assert "subtasks" in tables

    def test_idempotent(self, isolated_db):
        """Calling init twice doesn't error."""
        isolated_db.init_webapp_db()
        isolated_db.init_device_db("")
        with isolated_db.get_webapp_db() as conn:
            tables = conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
        assert len(tables) >= 2


# ── Organizations ────────────────────────────────────────────────────────────


@pytest.mark.unit
class TestOrganizations:
    def test_upsert_and_get(self, isolated_db):
        isolated_db.upsert_org("test-org", "github.com", "github-test", "~/.ssh/key", "main")
        org = isolated_db.get_org("test-org")
        assert org is not None
        assert org["name"] == "test-org"
        assert org["github_url"] == "github.com"
        assert org["ssh_host_alias"] == "github-test"
        assert org["default_branch"] == "main"

    def test_upsert_updates_existing(self, isolated_db):
        isolated_db.upsert_org("org1", "github.com", "alias1", "key1", "main")
        isolated_db.upsert_org("org1", "github.com", "alias2", "key2", "develop")
        org = isolated_db.get_org("org1")
        assert org["ssh_host_alias"] == "alias2"
        assert org["default_branch"] == "develop"

    def test_list_orgs(self, isolated_db):
        isolated_db.upsert_org("a-org", "github.com", "a", "k", "main")
        isolated_db.upsert_org("b-org", "github.com", "b", "k", "main")
        orgs = isolated_db.list_orgs()
        assert len(orgs) == 2
        assert orgs[0]["name"] == "a-org"  # sorted by name

    def test_get_org_not_found(self, isolated_db):
        assert isolated_db.get_org("nonexistent") is None

    def test_delete_org(self, isolated_db):
        isolated_db.upsert_org("del-org", "github.com", "alias", "key", "main")
        isolated_db.upsert_repo(org="del-org", name="repo1")
        isolated_db.delete_org("del-org")
        assert isolated_db.get_org("del-org") is None
        # Repos for that org should also be deleted
        repos = isolated_db.list_repos(org="del-org")
        assert len(repos) == 0


# ── Repos ────────────────────────────────────────────────────────────────────


@pytest.mark.unit
class TestRepos:
    def _setup_org(self, isolated_db):
        isolated_db.upsert_org("org1", "github.com", "alias", "key", "main")

    def test_upsert_and_get(self, isolated_db):
        self._setup_org(isolated_db)
        isolated_db.upsert_repo("org1", "my-repo", "main", "A cool repo", "2025-01-01")
        repo = isolated_db.get_repo("org1", "my-repo")
        assert repo is not None
        assert repo["name"] == "my-repo"
        assert repo["description"] == "A cool repo"
        assert repo["pushed_at"] == "2025-01-01"

    def test_upsert_preserves_pushed_at_when_empty(self, isolated_db):
        """COALESCE(NULLIF(excluded.pushed_at, ''), repos.pushed_at) preserves existing."""
        self._setup_org(isolated_db)
        isolated_db.upsert_repo("org1", "repo1", pushed_at="2025-06-01")
        isolated_db.upsert_repo("org1", "repo1", pushed_at="")  # empty update
        repo = isolated_db.get_repo("org1", "repo1")
        assert repo["pushed_at"] == "2025-06-01"

    def test_list_repos_by_org(self, isolated_db):
        self._setup_org(isolated_db)
        isolated_db.upsert_org("org2", "github.com", "a2", "k2", "main")
        isolated_db.upsert_repo("org1", "repo-a")
        isolated_db.upsert_repo("org2", "repo-b")
        repos = isolated_db.list_repos(org="org1")
        assert len(repos) == 1
        assert repos[0]["org"] == "org1"

    def test_list_repos_with_query(self, isolated_db):
        self._setup_org(isolated_db)
        isolated_db.upsert_repo("org1", "alpha-service")
        isolated_db.upsert_repo("org1", "beta-worker")
        repos = isolated_db.list_repos(query="alpha")
        assert len(repos) == 1
        assert repos[0]["name"] == "alpha-service"

    def test_get_repo_not_found(self, isolated_db):
        assert isolated_db.get_repo("no-org", "no-repo") is None


# ── Devices ──────────────────────────────────────────────────────────────────


@pytest.mark.unit
class TestDevices:
    def test_upsert_and_get(self, isolated_db):
        isolated_db.upsert_device("srv1", "100.1.1.1", "ubuntu", "server", '["conductor"]')
        dev = isolated_db.get_device("srv1")
        assert dev is not None
        assert dev["ip"] == "100.1.1.1"
        assert dev["user"] == "ubuntu"
        assert dev["type"] == "server"

    def test_list_devices(self, isolated_db):
        isolated_db.upsert_device("dev-a", "1.1.1.1", "u1")
        isolated_db.upsert_device("dev-b", "2.2.2.2", "u2")
        devices = isolated_db.list_devices()
        assert len(devices) == 2
        assert devices[0]["name"] == "dev-a"  # sorted by name

    def test_update_device_status(self, isolated_db):
        isolated_db.upsert_device("srv1", "1.1.1.1", "u")
        isolated_db.update_device_status("srv1", True)
        dev = isolated_db.get_device("srv1")
        assert dev["online"] == 1
        assert dev["last_seen"] is not None

        isolated_db.update_device_status("srv1", False)
        dev = isolated_db.get_device("srv1")
        assert dev["online"] == 0

    def test_get_device_not_found(self, isolated_db):
        assert isolated_db.get_device("ghost") is None


# ── Jobs ─────────────────────────────────────────────────────────────────────


@pytest.mark.unit
class TestJobs:
    def _setup_device(self, isolated_db, name="srv1"):
        isolated_db.init_device_db(name)
        isolated_db.upsert_device(name, "1.1.1.1", "ubuntu")

    def test_create_and_get(self, isolated_db):
        self._setup_device(isolated_db)
        job_id = isolated_db.create_job(
            "srv1", "echo hello", org="org1", repo="repo1", cli="claude", tmux_session="sess1"
        )
        assert job_id is not None
        job = isolated_db.get_job(job_id, device="srv1")
        assert job["device"] == "srv1"
        assert job["command"] == "echo hello"
        assert job["status"] == "running"

    def test_update_job_status(self, isolated_db):
        self._setup_device(isolated_db)
        job_id = isolated_db.create_job("srv1", "cmd")
        isolated_db.update_job_status(job_id, "completed", device="srv1")
        job = isolated_db.get_job(job_id, device="srv1")
        assert job["status"] == "completed"
        assert job["ended_at"] is not None

    def test_update_job_status_failed(self, isolated_db):
        self._setup_device(isolated_db)
        job_id = isolated_db.create_job("srv1", "cmd")
        isolated_db.update_job_status(job_id, "failed", device="srv1")
        job = isolated_db.get_job(job_id, device="srv1")
        assert job["status"] == "failed"
        assert job["ended_at"] is not None

    def test_list_jobs_filter_by_device(self, isolated_db):
        self._setup_device(isolated_db)
        self._setup_device(isolated_db, "srv2")
        isolated_db.create_job("srv1", "cmd1")
        isolated_db.create_job("srv2", "cmd2")
        jobs, total = isolated_db.list_jobs(device="srv1")
        assert len(jobs) == 1
        assert jobs[0]["device"] == "srv1"
        assert total == 1

    def test_list_jobs_filter_by_status(self, isolated_db):
        self._setup_device(isolated_db)
        j1 = isolated_db.create_job("srv1", "cmd1")
        j2 = isolated_db.create_job("srv1", "cmd2")
        isolated_db.update_job_status(j1, "completed", device="srv1")
        jobs, total = isolated_db.list_jobs(status="running", device="srv1")
        assert len(jobs) == 1
        assert jobs[0]["id"] == j2

    def test_list_jobs_limit(self, isolated_db):
        self._setup_device(isolated_db)
        for i in range(10):
            isolated_db.create_job("srv1", f"cmd{i}")
        jobs, total = isolated_db.list_jobs(limit=3, device="srv1")
        assert len(jobs) == 3
        assert total == 10

    def test_get_job_not_found(self, isolated_db):
        assert isolated_db.get_job(99999) is None

    def test_update_job_vt_session(self, isolated_db):
        self._setup_device(isolated_db)
        job_id = isolated_db.create_job("srv1", "cmd")
        isolated_db.update_job_vt_session(job_id, "vt-123", "http://1.1.1.1:4020/session/vt-123", device="srv1")
        job = isolated_db.get_job(job_id, device="srv1")
        assert job["vt_session_id"] == "vt-123"
        assert job["vt_url"] == "http://1.1.1.1:4020/session/vt-123"


# ── Job Logs ─────────────────────────────────────────────────────────────────


@pytest.mark.unit
class TestJobLogs:
    def _setup(self, isolated_db):
        isolated_db.init_device_db("srv1")
        isolated_db.upsert_device("srv1", "1.1.1.1", "ubuntu")
        return isolated_db.create_job("srv1", "cmd")

    def test_append_and_get(self, isolated_db):
        job_id = self._setup(isolated_db)
        isolated_db.append_job_log(job_id, "Starting...", device="srv1")
        isolated_db.append_job_log(job_id, "Done!", device="srv1")
        logs = isolated_db.get_job_logs(job_id, device="srv1")
        assert len(logs) == 2
        assert logs[0]["line"] == "Starting..."
        assert logs[1]["line"] == "Done!"

    def test_logs_chronological_order(self, isolated_db):
        job_id = self._setup(isolated_db)
        for i in range(5):
            isolated_db.append_job_log(job_id, f"line-{i}", device="srv1")
        logs = isolated_db.get_job_logs(job_id, device="srv1")
        lines = [entry["line"] for entry in logs]
        assert lines == ["line-0", "line-1", "line-2", "line-3", "line-4"]

    def test_logs_limit(self, isolated_db):
        job_id = self._setup(isolated_db)
        for i in range(10):
            isolated_db.append_job_log(job_id, f"line-{i}", device="srv1")
        logs = isolated_db.get_job_logs(job_id, limit=3, device="srv1")
        assert len(logs) == 3


# ── Cross-Device Isolation ────────────────────────────────────────────────────


@pytest.mark.unit
class TestCrossDeviceIsolation:
    """Verify data written to one device DB is NOT visible in another."""

    def test_org_isolation(self, isolated_db):
        isolated_db.init_device_db("dev-a")
        isolated_db.init_device_db("dev-b")
        isolated_db.upsert_org("org-a", "github.com", "gh-a", "key-a", device="dev-a")
        isolated_db.upsert_org("org-b", "github.com", "gh-b", "key-b", device="dev-b")
        assert len(isolated_db.list_orgs(device="dev-a")) == 1
        assert isolated_db.list_orgs(device="dev-a")[0]["name"] == "org-a"
        assert len(isolated_db.list_orgs(device="dev-b")) == 1
        assert isolated_db.list_orgs(device="dev-b")[0]["name"] == "org-b"

    def test_job_isolation(self, isolated_db):
        isolated_db.init_device_db("dev-a")
        isolated_db.init_device_db("dev-b")
        isolated_db.upsert_device("dev-a", "1.1.1.1", "ubuntu")
        isolated_db.upsert_device("dev-b", "2.2.2.2", "ubuntu")
        isolated_db.create_job("dev-a", "echo a")
        isolated_db.create_job("dev-b", "echo b")
        # Both DBs have job id=1, but commands differ
        jobs_a, _ = isolated_db.list_jobs(device="dev-a")
        jobs_b, _ = isolated_db.list_jobs(device="dev-b")
        assert len(jobs_a) == 1
        assert jobs_a[0]["command"] == "echo a"
        assert len(jobs_b) == 1
        assert jobs_b[0]["command"] == "echo b"


# ── Settings CRUD ─────────────────────────────────────────────────────────────


@pytest.mark.unit
class TestSettingsCRUD:
    """Verify settings get/set/list/delete in webapp DB."""

    def test_set_and_get(self, isolated_db):
        isolated_db.set_setting("default_device", "dev-srv2")
        assert isolated_db.get_setting("default_device") == "dev-srv2"

    def test_get_default(self, isolated_db):
        assert isolated_db.get_setting("nonexistent", "fallback") == "fallback"

    def test_list_settings(self, isolated_db):
        isolated_db.set_setting("key1", "val1")
        isolated_db.set_setting("key2", "val2")
        settings = isolated_db.list_settings()
        keys = [s["key"] for s in settings]
        assert "key1" in keys
        assert "key2" in keys

    def test_delete_setting(self, isolated_db):
        isolated_db.set_setting("tmp", "val")
        isolated_db.delete_setting("tmp")
        assert isolated_db.get_setting("tmp", "gone") == "gone"

    def test_upsert_overwrites(self, isolated_db):
        isolated_db.set_setting("cli", "claude")
        isolated_db.set_setting("cli", "gemini")
        assert isolated_db.get_setting("cli") == "gemini"


# ── Device DB Auto-Init ──────────────────────────────────────────────────────


@pytest.mark.unit
class TestDeviceDbAutoInit:
    """Verify that get_device_db auto-initializes schema if DB doesn't exist."""

    def test_auto_init_new_device(self, isolated_db):
        """Accessing a never-initialized device should auto-create tables."""
        with isolated_db.get_device_db("new-device") as conn:
            tables = {
                row[0]
                for row in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                ).fetchall()
            }
        assert "organizations" in tables
        assert "repos" in tables
        assert "jobs" in tables
        assert "tasks" in tables
