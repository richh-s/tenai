"""Tests for agent watcher DB and daemon utilities."""

import json

import pytest


class TestWatcherDB:
    """Tests for watcher_db.py."""

    @pytest.fixture(autouse=True)
    def setup_db(self, tmp_path):
        """Create a temporary DB for each test."""
        self.db_path = tmp_path / "watcher.db"

    def test_get_db_creates_schema(self):
        import sys
        sys.path.insert(0, "scripts/conductor")
        from watcher_db import get_db

        conn = get_db(self.db_path)
        # Check tables exist
        tables = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()
        table_names = {t["name"] for t in tables}
        assert "watches" in table_names
        assert "actions" in table_names
        conn.close()

    def test_register_push_creates_watch(self):
        import sys
        sys.path.insert(0, "scripts/conductor")
        from watcher_db import get_db, register_push

        watch_id = register_push(
            tsid="dev1:org/repo:feat/x:sess:win",
            repo="org/repo",
            branch="feat/x",
            pr_number=42,
            commit_sha="abc123",
            message="test commit",
            db_path=self.db_path,
        )
        assert watch_id > 0

        # Verify in DB
        conn = get_db(self.db_path)
        row = conn.execute("SELECT * FROM watches WHERE id = ?", (watch_id,)).fetchone()
        assert row is not None
        assert row["tsid"] == "dev1:org/repo:feat/x:sess:win"
        assert row["pr_number"] == 42
        assert row["status"] == "active"
        conn.close()

    def test_register_push_updates_existing(self):
        import sys
        sys.path.insert(0, "scripts/conductor")
        from watcher_db import register_push

        id1 = register_push(
            tsid="dev1:org/repo:feat/x:s:w",
            repo="org/repo", branch="feat/x",
            pr_number=10, commit_sha="aaa",
            db_path=self.db_path,
        )
        id2 = register_push(
            tsid="dev1:org/repo:feat/x:s:w",
            repo="org/repo", branch="feat/x",
            pr_number=11, commit_sha="bbb",
            db_path=self.db_path,
        )
        assert id1 == id2  # same watch updated

    def test_get_active_watches(self):
        import sys
        sys.path.insert(0, "scripts/conductor")
        from watcher_db import get_active_watches, register_push

        register_push(
            tsid="dev1:org/repo:feat/a:s:w",
            repo="org/repo", branch="feat/a",
            db_path=self.db_path,
        )
        register_push(
            tsid="dev2:org/repo:feat/b:s:w",
            repo="org/repo", branch="feat/b",
            db_path=self.db_path,
        )

        watches = get_active_watches(self.db_path)
        assert len(watches) == 2
        assert all(w["status"] == "active" for w in watches)

    def test_expire_watch(self):
        import sys
        sys.path.insert(0, "scripts/conductor")
        from watcher_db import expire_watch, get_active_watches, register_push

        wid = register_push(
            tsid="dev1:org/repo:feat/x:s:w",
            repo="org/repo", branch="feat/x",
            db_path=self.db_path,
        )
        expire_watch(wid, self.db_path)

        watches = get_active_watches(self.db_path)
        assert len(watches) == 0

    def test_record_action(self):
        import sys
        sys.path.insert(0, "scripts/conductor")
        from watcher_db import get_actions, record_action, register_push

        wid = register_push(
            tsid="dev1:org/repo:feat/x:s:w",
            repo="org/repo", branch="feat/x",
            db_path=self.db_path,
        )
        aid = record_action(
            wid, "dev1:org/repo:feat/x:s:w", "ci_signal",
            body="CI passed", delivered=True,
            db_path=self.db_path,
        )
        assert aid > 0

        actions = get_actions(watch_id=wid, db_path=self.db_path)
        assert len(actions) == 1
        assert actions[0]["action_type"] == "ci_signal"
        assert actions[0]["delivered"] == 1

    def test_add_seen_review(self):
        import sys
        sys.path.insert(0, "scripts/conductor")
        from watcher_db import add_seen_review, get_db, register_push

        wid = register_push(
            tsid="dev1:org/repo:feat/x:s:w",
            repo="org/repo", branch="feat/x",
            db_path=self.db_path,
        )
        add_seen_review(wid, 12345, self.db_path)
        add_seen_review(wid, 67890, self.db_path)
        add_seen_review(wid, 12345, self.db_path)  # duplicate, should not add

        conn = get_db(self.db_path)
        row = conn.execute("SELECT seen_reviews FROM watches WHERE id = ?", (wid,)).fetchone()
        seen = json.loads(row["seen_reviews"])
        assert seen == [12345, 67890]
        conn.close()

    def test_increment_cycle_and_auto_expire(self):
        import sys
        sys.path.insert(0, "scripts/conductor")
        from watcher_db import get_watch, increment_cycle, register_push

        wid = register_push(
            tsid="dev1:org/repo:feat/x:s:w",
            repo="org/repo", branch="feat/x",
            max_cycles=2,
            db_path=self.db_path,
        )
        c1 = increment_cycle(wid, self.db_path)
        assert c1 == 1
        c2 = increment_cycle(wid, self.db_path)
        assert c2 == 2

        # Should be auto-expired after reaching max_cycles
        watch = get_watch(wid, self.db_path)
        assert watch["status"] == "expired"


class TestAgentWatcherHelpers:
    """Tests for agent_watcher.py helper functions."""

    def test_parse_tsid_full(self):
        import sys
        sys.path.insert(0, "scripts/conductor")
        from agent_watcher import parse_tsid

        result = parse_tsid("dev1:org/repo:feat/auth:myapp-agents:feat-auth")
        assert result["device"] == "dev1"
        assert result["repo"] == "org/repo"
        assert result["branch"] == "feat/auth"
        assert result["session"] == "myapp-agents"
        assert result["window"] == "feat-auth"

    def test_parse_tsid_partial(self):
        import sys
        sys.path.insert(0, "scripts/conductor")
        from agent_watcher import parse_tsid

        result = parse_tsid("dev1:org/repo")
        assert result["device"] == "dev1"
        assert result["repo"] == "org/repo"
        assert result["branch"] == ""

    def test_format_ci_signal_success(self):
        import sys
        sys.path.insert(0, "scripts/conductor")
        from agent_watcher import format_ci_signal

        msg = format_ci_signal({"conclusion": "success", "run_id": 123})
        assert "CI PASSED" in msg
        assert "123" in msg

    def test_format_ci_signal_failure(self):
        import sys
        sys.path.insert(0, "scripts/conductor")
        from agent_watcher import format_ci_signal

        msg = format_ci_signal({"conclusion": "failure", "run_id": 456})
        assert "CI FAILED" in msg
        assert "456" in msg

    def test_format_review_approved(self):
        import sys
        sys.path.insert(0, "scripts/conductor")
        from agent_watcher import format_review

        msg = format_review({"user": "copilot", "state": "APPROVED", "body": "Looks good!"})
        assert "✅" in msg
        assert "copilot" in msg

    def test_format_review_changes_requested(self):
        import sys
        sys.path.insert(0, "scripts/conductor")
        from agent_watcher import format_review

        msg = format_review({"user": "reviewer", "state": "CHANGES_REQUESTED", "body": "Fix bug"})
        assert "🔴" in msg
        assert "Fix bug" in msg
