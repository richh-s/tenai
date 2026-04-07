#!/usr/bin/env python3
"""Watcher DB — SQLite state for the agent watcher daemon.

Tracks agent push events and daemon actions (CI signals, PR reviews)
so the daemon knows what to poll and agents can see delivery history.

Usage (CLI):
    python watcher_db.py register --tsid <TSID> --repo <owner/repo> --branch <b> --sha <sha>
    python watcher_db.py list [--status active]
    python watcher_db.py actions [--tsid <TSID>]
    python watcher_db.py expire --id <watch_id>
"""

import argparse
import json
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path


DB_DIR = Path.home() / ".tenai"
DB_PATH = DB_DIR / "watcher.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS watches (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    tsid           TEXT    NOT NULL,
    repo           TEXT    NOT NULL,
    branch         TEXT    NOT NULL,
    pr_number      INTEGER DEFAULT 0,
    commit_sha     TEXT    DEFAULT '',
    push_type      TEXT    DEFAULT 'commit',
    message        TEXT    DEFAULT '',
    pushed_at      TEXT    NOT NULL,
    expires_at     TEXT    NOT NULL,
    cycles         INTEGER DEFAULT 0,
    max_cycles     INTEGER DEFAULT 3,
    last_ci_status TEXT    DEFAULT '',
    seen_reviews   TEXT    DEFAULT '[]',
    status         TEXT    DEFAULT 'active',
    created_at     TEXT    NOT NULL
);

CREATE TABLE IF NOT EXISTS actions (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    watch_id       INTEGER REFERENCES watches(id),
    tsid           TEXT    NOT NULL,
    action_type    TEXT    NOT NULL,
    body           TEXT    DEFAULT '',
    delivered      INTEGER DEFAULT 0,
    created_at     TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_watches_status ON watches(status);
CREATE INDEX IF NOT EXISTS idx_watches_tsid ON watches(tsid);
CREATE INDEX IF NOT EXISTS idx_actions_watch_id ON actions(watch_id);
"""


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _future(seconds: int) -> str:
    from datetime import timedelta

    dt = datetime.now(timezone.utc) + timedelta(seconds=seconds)
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def get_db(db_path: Path | None = None) -> sqlite3.Connection:
    """Get a database connection, creating schema if needed."""
    path = db_path or DB_PATH

    # Auto-migration from legacy path
    old_path = Path.home() / ".tenacious" / "watcher.db"
    if not path.exists() and old_path.exists():
        import shutil
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(old_path, path)
        print(f"  [Migration] Copied DB {old_path} -> {path}", file=sys.stderr)

    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.executescript(SCHEMA)
    return conn


def register_push(
    tsid: str,
    repo: str,
    branch: str,
    pr_number: int = 0,
    commit_sha: str = "",
    push_type: str = "commit",
    message: str = "",
    watch_duration: int = 3600,
    max_cycles: int = 3,
    db_path: Path | None = None,
) -> int:
    """Register a push event for the watcher to track.

    Returns the watch ID.
    """
    conn = get_db(db_path)
    now = _now()
    expires = _future(watch_duration)

    # Check for existing active watch on same tsid — update instead of insert
    existing = conn.execute(
        "SELECT id FROM watches WHERE tsid = ? AND status = 'active' LIMIT 1",
        (tsid,),
    ).fetchone()

    if existing:
        conn.execute(
            """UPDATE watches SET
                pr_number = ?, commit_sha = ?, push_type = ?, message = ?,
                pushed_at = ?, expires_at = ?, max_cycles = ?, cycles = 0,
                last_ci_status = '', seen_reviews = '[]'
            WHERE id = ?""",
            (pr_number, commit_sha, push_type, message, now, expires,
             max_cycles, existing["id"]),
        )
        conn.commit()
        conn.close()
        return existing["id"]

    cursor = conn.execute(
        """INSERT INTO watches
            (tsid, repo, branch, pr_number, commit_sha, push_type, message,
             pushed_at, expires_at, max_cycles, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (tsid, repo, branch, pr_number, commit_sha, push_type, message,
         now, expires, max_cycles, now),
    )
    watch_id = cursor.lastrowid
    conn.commit()
    conn.close()
    return watch_id


def get_active_watches(db_path: Path | None = None) -> list[dict]:
    """Get all active, non-expired watches."""
    conn = get_db(db_path)
    now = _now()

    # Auto-expire watches past their deadline
    conn.execute(
        "UPDATE watches SET status = 'expired' WHERE status = 'active' AND expires_at < ?",
        (now,),
    )
    conn.commit()

    rows = conn.execute(
        "SELECT * FROM watches WHERE status = 'active' ORDER BY pushed_at DESC",
    ).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def get_watch(watch_id: int, db_path: Path | None = None) -> dict | None:
    """Get a single watch by ID."""
    conn = get_db(db_path)
    row = conn.execute("SELECT * FROM watches WHERE id = ?", (watch_id,)).fetchone()
    conn.close()
    return dict(row) if row else None


# Columns that update_watch is allowed to modify
_WATCH_COLUMNS = frozenset({
    "pr_number", "commit_sha", "push_type", "message",
    "pushed_at", "expires_at", "cycles", "max_cycles",
    "last_ci_status", "seen_reviews", "status",
})


def update_watch(
    watch_id: int,
    db_path: Path | None = None,
    **kwargs,
) -> None:
    """Update watch fields. Only columns in _WATCH_COLUMNS are accepted."""
    if not kwargs:
        return
    invalid = set(kwargs) - _WATCH_COLUMNS
    if invalid:
        raise ValueError(f"Invalid watch columns: {invalid}")
    conn = get_db(db_path)
    sets = ", ".join(f"{k} = ?" for k in kwargs)
    vals = list(kwargs.values()) + [watch_id]
    conn.execute(f"UPDATE watches SET {sets} WHERE id = ?", vals)  # noqa: S608
    conn.commit()
    conn.close()


def increment_cycle(watch_id: int, db_path: Path | None = None) -> int:
    """Increment cycle count. Returns new count."""
    conn = get_db(db_path)
    conn.execute("UPDATE watches SET cycles = cycles + 1 WHERE id = ?", (watch_id,))
    conn.commit()
    row = conn.execute("SELECT cycles, max_cycles FROM watches WHERE id = ?", (watch_id,)).fetchone()
    conn.close()
    if row and row["cycles"] >= row["max_cycles"]:
        expire_watch(watch_id, db_path)
    return row["cycles"] if row else 0


def expire_watch(watch_id: int, db_path: Path | None = None) -> None:
    """Mark a watch as expired."""
    update_watch(watch_id, db_path, status="expired")


def add_seen_review(watch_id: int, review_id: int, db_path: Path | None = None) -> None:
    """Add a review ID to the seen list."""
    conn = get_db(db_path)
    row = conn.execute("SELECT seen_reviews FROM watches WHERE id = ?", (watch_id,)).fetchone()
    if row:
        seen = json.loads(row["seen_reviews"] or "[]")
        if review_id not in seen:
            seen.append(review_id)
            conn.execute(
                "UPDATE watches SET seen_reviews = ? WHERE id = ?",
                (json.dumps(seen), watch_id),
            )
            conn.commit()
    conn.close()


def record_action(
    watch_id: int,
    tsid: str,
    action_type: str,
    body: str = "",
    delivered: bool = False,
    db_path: Path | None = None,
) -> int:
    """Record a daemon action (CI signal, review, dead-queue)."""
    conn = get_db(db_path)
    cursor = conn.execute(
        """INSERT INTO actions (watch_id, tsid, action_type, body, delivered, created_at)
        VALUES (?, ?, ?, ?, ?, ?)""",
        (watch_id, tsid, action_type, body, int(delivered), _now()),
    )
    action_id = cursor.lastrowid
    conn.commit()
    conn.close()
    return action_id


def get_actions(
    watch_id: int | None = None,
    tsid: str | None = None,
    limit: int = 50,
    db_path: Path | None = None,
) -> list[dict]:
    """Get actions, optionally filtered by watch or tsid."""
    conn = get_db(db_path)
    if watch_id:
        rows = conn.execute(
            "SELECT * FROM actions WHERE watch_id = ? ORDER BY created_at DESC LIMIT ?",
            (watch_id, limit),
        ).fetchall()
    elif tsid:
        rows = conn.execute(
            "SELECT * FROM actions WHERE tsid = ? ORDER BY created_at DESC LIMIT ?",
            (tsid, limit),
        ).fetchall()
    else:
        rows = conn.execute(
            "SELECT * FROM actions ORDER BY created_at DESC LIMIT ?",
            (limit,),
        ).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def list_watches(status: str | None = None, db_path: Path | None = None) -> list[dict]:
    """List watches, optionally filtered by status."""
    conn = get_db(db_path)
    if status:
        rows = conn.execute(
            "SELECT * FROM watches WHERE status = ? ORDER BY pushed_at DESC",
            (status,),
        ).fetchall()
    else:
        rows = conn.execute(
            "SELECT * FROM watches ORDER BY pushed_at DESC LIMIT 50",
        ).fetchall()
    conn.close()
    return [dict(r) for r in rows]


# ── CLI ───────────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(description="Agent watcher DB")
    sub = parser.add_subparsers(dest="command")

    # register
    reg = sub.add_parser("register", help="Register a push event")
    reg.add_argument("--tsid", required=True)
    reg.add_argument("--repo", required=True)
    reg.add_argument("--branch", required=True)
    reg.add_argument("--pr", type=int, default=0)
    reg.add_argument("--sha", default="")
    reg.add_argument("--type", default="commit", choices=["commit", "pr"])
    reg.add_argument("--message", default="")
    reg.add_argument("--duration", type=int, default=3600)
    reg.add_argument("--max-cycles", type=int, default=3)

    # list
    ls = sub.add_parser("list", help="List watches")
    ls.add_argument("--status", default=None)

    # actions
    act = sub.add_parser("actions", help="List actions")
    act.add_argument("--tsid", default=None)
    act.add_argument("--watch-id", type=int, default=None)

    # expire
    exp = sub.add_parser("expire", help="Expire a watch")
    exp.add_argument("--id", type=int, required=True)

    args = parser.parse_args()

    if args.command == "register":
        wid = register_push(
            tsid=args.tsid, repo=args.repo, branch=args.branch,
            pr_number=args.pr, commit_sha=args.sha, push_type=args.type,
            message=args.message, watch_duration=args.duration,
            max_cycles=args.max_cycles,
        )
        print(f'{{"ok": true, "watch_id": {wid}}}')

    elif args.command == "list":
        watches = list_watches(args.status)
        for w in watches:
            print(f"  [{w['status']}] #{w['id']} {w['tsid']} "
                  f"PR#{w['pr_number']} cycles={w['cycles']}/{w['max_cycles']} "
                  f"pushed={w['pushed_at']}")
        if not watches:
            print("  (no watches)")

    elif args.command == "actions":
        actions = get_actions(watch_id=args.watch_id, tsid=args.tsid)
        for a in actions:
            delivered = "✓" if a["delivered"] else "✗"
            print(f"  [{delivered}] {a['action_type']} → {a['tsid']} "
                  f"at {a['created_at']}: {a['body'][:80]}")
        if not actions:
            print("  (no actions)")

    elif args.command == "expire":
        expire_watch(args.id)
        print(f"  ✓ Watch #{args.id} expired")

    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
