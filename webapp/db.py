"""
webapp/db.py — Dual-DB persistence layer for TenAI Control Plane.

Two database scopes:
  - Webapp DB  (tenai.db):           devices, settings — global control plane
  - Device DB  (devices/{name}.db):  organizations, repos, tasks, subtasks, jobs, job_logs

DB directory: ~/.tenai/ (mounted as Docker volume)
"""
import os
import shutil
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


# ── Paths ─────────────────────────────────────────────────────────────────────

DB_DIR = Path(os.environ.get("TENAI_DB_DIR", Path.home() / ".tenai"))
DB_PATH = DB_DIR / "tenai.db"  # backward compat alias for webapp DB
DEVICE_DB_DIR = DB_DIR / "devices"


# ── Schemas ───────────────────────────────────────────────────────────────────

WEBAPP_SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (
    name          TEXT PRIMARY KEY,
    ip            TEXT NOT NULL,
    user          TEXT NOT NULL,
    type          TEXT NOT NULL DEFAULT 'server',
    capabilities  TEXT NOT NULL DEFAULT '[]',
    last_seen     TEXT,
    online        INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS settings (
    key           TEXT PRIMARY KEY,
    value         TEXT NOT NULL,
    updated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
"""

DEVICE_SCHEMA = """
CREATE TABLE IF NOT EXISTS organizations (
    name          TEXT PRIMARY KEY,
    github_url    TEXT NOT NULL DEFAULT 'github.com',
    ssh_host_alias TEXT NOT NULL,
    ssh_key       TEXT NOT NULL,
    default_branch TEXT NOT NULL DEFAULT 'main',
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE IF NOT EXISTS repos (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    org           TEXT NOT NULL REFERENCES organizations(name),
    name          TEXT NOT NULL,
    default_branch TEXT NOT NULL DEFAULT 'main',
    description   TEXT DEFAULT '',
    pushed_at     TEXT DEFAULT '',
    last_synced   TEXT,
    UNIQUE(org, name)
);

CREATE TABLE IF NOT EXISTS jobs (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    device        TEXT NOT NULL,
    org           TEXT,
    repo          TEXT,
    cli           TEXT,
    action        TEXT DEFAULT '',
    branch        TEXT DEFAULT '',
    task_id       INTEGER,
    command       TEXT NOT NULL,
    tmux_session  TEXT,
    status        TEXT NOT NULL DEFAULT 'pending',
    connect_cmd   TEXT,
    vt_session_id TEXT,
    vt_url        TEXT,
    worktree_md   TEXT,
    agent_prompt  TEXT,
    started_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    ended_at      TEXT
);

CREATE TABLE IF NOT EXISTS job_logs (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id        INTEGER NOT NULL REFERENCES jobs(id),
    line          TEXT NOT NULL,
    timestamp     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE IF NOT EXISTS tasks (
    -- Identity
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    number          INTEGER,
    title           TEXT NOT NULL,

    -- Scope
    repo            TEXT NOT NULL,
    org             TEXT DEFAULT '',
    branch          TEXT DEFAULT '',
    base_branch     TEXT DEFAULT 'main',
    slug            TEXT DEFAULT '',

    -- Content
    description     TEXT DEFAULT '',
    instruction     TEXT NOT NULL DEFAULT '',
    verification    TEXT DEFAULT '',
    context_type    TEXT DEFAULT 'inline',
    context_ref     TEXT DEFAULT '',

    -- Lifecycle
    status          TEXT NOT NULL DEFAULT 'active',
    section         TEXT NOT NULL DEFAULT 'Active',
    priority        INTEGER DEFAULT 0,

    -- Lineage / Provenance
    created_by      TEXT DEFAULT '',
    created_by_user TEXT DEFAULT '',
    created_by_cli  TEXT DEFAULT '',
    created_by_model TEXT DEFAULT '',
    assigned_to     TEXT DEFAULT '',
    assigned_cli    TEXT DEFAULT '',

    -- GitHub Issue link
    github_issue    INTEGER,
    github_repo     TEXT DEFAULT '',
    github_url      TEXT DEFAULT '',

    -- Conductor track link
    conductor_track TEXT DEFAULT '',
    plan_document   TEXT DEFAULT '',
    spec_document   TEXT DEFAULT '',

    -- Execution
    dispatch_device TEXT DEFAULT '',
    dispatch_cli    TEXT DEFAULT '',
    worktree_path   TEXT DEFAULT '',
    tmux_session    TEXT DEFAULT '',
    proof_path      TEXT DEFAULT '',
    proof_summary   TEXT DEFAULT '',

    -- Scheduling
    timelimit       INTEGER,      -- minutes (NULL = use global default, 0 = never expire)

    -- Timestamps
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    dispatched_at   TEXT,
    completed_at    TEXT

    -- Note: uniqueness on (repo, branch, slug) enforced via post-migration index.
    -- slug = hash(title+description) allowing multiple tasks per branch with different content.
);

-- NOTE: idx_tasks_repo_branch_slug is created in init_device_db() AFTER the slug
-- migration runs, so it works on both fresh and existing databases.
CREATE INDEX IF NOT EXISTS idx_tasks_repo ON tasks(repo);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_github ON tasks(github_issue, github_repo);

CREATE TABLE IF NOT EXISTS subtasks (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id         INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    title           TEXT NOT NULL,
    phase           TEXT DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'pending',
    ordinal         INTEGER DEFAULT 0,
    checkpoint      TEXT DEFAULT '',
    evidence        TEXT DEFAULT '',
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_subtasks_task ON subtasks(task_id);
"""

# Legacy combined schema for backward compatibility (used by old init_db)
SCHEMA = WEBAPP_SCHEMA + DEVICE_SCHEMA


# ── Helpers ───────────────────────────────────────────────────────────────────

def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _device_db_path(device: str) -> Path:
    """Return the SQLite DB path for a specific device.

    Always uses {devicename}.db — no local.db fallback.
    If ``device`` is empty, uses DEVICE_NAME env var.
    Raises ValueError if neither is set.
    """
    local_device = os.environ.get("DEVICE_NAME", "")
    name = device or local_device
    if not name:
        raise ValueError(
            "Cannot resolve device DB path: no device name provided "
            "and DEVICE_NAME env var is not set. "
            "Set DEVICE_NAME in .env or docker-compose.yml."
        )
    return DEVICE_DB_DIR / f"{name}.db"


def _connect_db(path: Path) -> sqlite3.Connection:
    """Create a connection with standard settings."""
    conn = sqlite3.connect(str(path))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


# ── Connection Managers ───────────────────────────────────────────────────────

@contextmanager
def get_webapp_db():
    """Context manager for the webapp (global) database."""
    conn = _connect_db(DB_PATH)
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


@contextmanager
def get_device_db(device: str):
    """Context manager for a device-scoped database.

    Auto-initializes the device DB if the file does not yet exist.
    """
    path = _device_db_path(device)
    auto_init = not path.exists()
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = _connect_db(path)
    try:
        if auto_init:
            conn.executescript(DEVICE_SCHEMA)
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


# Backward-compat aliases — default to webapp DB
@contextmanager
def get_db():
    """Context manager yielding a sqlite3 connection (webapp DB). Legacy alias."""
    with get_webapp_db() as conn:
        yield conn


# ── Initialization ────────────────────────────────────────────────────────────

def init_webapp_db():
    """Create webapp DB file and tables."""
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with get_webapp_db() as conn:
        conn.executescript(WEBAPP_SCHEMA)

def _merge_device_dbs(src: Path, dst: Path):
    """Merge tables from *src* DB into *dst* DB using INSERT OR IGNORE.

    Column-aware: only copies columns that exist in both source and
    destination, handling schema version mismatches gracefully.
    """
    dst_conn = _connect_db(dst)
    try:
        dst_conn.execute("ATTACH DATABASE ? AS old", (str(src),))
        for table in ["organizations", "repos", "tasks", "subtasks", "jobs", "job_logs"]:
            try:
                # Get columns in destination table
                dst_cols = {r[1] for r in dst_conn.execute(f"PRAGMA main.table_info({table})").fetchall()}
                if not dst_cols:
                    continue
                # Get columns in source table
                src_cols = {r[1] for r in dst_conn.execute(f"PRAGMA old.table_info({table})").fetchall()}
                if not src_cols:
                    continue
                # Only copy columns that exist in both
                common = sorted(dst_cols & src_cols)
                if not common:
                    continue
                cols = ", ".join(common)
                dst_conn.execute(f"INSERT OR IGNORE INTO main.{table} ({cols}) SELECT {cols} FROM old.{table}")
            except Exception:
                pass  # Table might not exist in old DB
        dst_conn.execute("DETACH DATABASE old")
        dst_conn.commit()
    finally:
        dst_conn.close()


def init_device_db(device: str):
    """Create device DB file and tables, run migrations."""
    DEVICE_DB_DIR.mkdir(parents=True, exist_ok=True)

    # ── Migration: merge old '.db' / 'local.db' data into canonical path ──
    # Historically, tasks were stored via device="" (→ .db) while jobs were
    # stored via device="myserver" (→ myserver.db).  Merge into the canonical
    # path so both tasks and jobs live in one file.
    canonical = _device_db_path(device)
    old_files = []
    for candidate in [DEVICE_DB_DIR / ".db", DEVICE_DB_DIR / "local.db"]:
        if candidate.exists() and candidate != canonical:
            old_files.append(candidate)

    for old_db in old_files:
        if not canonical.exists():
            # No canonical yet — just rename the old file
            shutil.move(str(old_db), str(canonical))
        else:
            # Both exist — merge tables from old into canonical
            try:
                _merge_device_dbs(old_db, canonical)
                old_db.rename(old_db.with_suffix(".db.migrated"))
            except Exception:
                pass  # Best-effort; don't crash startup
    with get_device_db(device) as conn:
        conn.executescript(DEVICE_SCHEMA)
        # Migrations: add columns if they don't exist yet
        repo_cols = {row[1] for row in conn.execute("PRAGMA table_info(repos)").fetchall()}
        if "pushed_at" not in repo_cols:
            conn.execute("ALTER TABLE repos ADD COLUMN pushed_at TEXT DEFAULT ''")
        # VibeTunnel session columns
        job_cols = {row[1] for row in conn.execute("PRAGMA table_info(jobs)").fetchall()}
        if "vt_session_id" not in job_cols:
            conn.execute("ALTER TABLE jobs ADD COLUMN vt_session_id TEXT")
        if "vt_url" not in job_cols:
            conn.execute("ALTER TABLE jobs ADD COLUMN vt_url TEXT")
        if "action" not in job_cols:
            conn.execute("ALTER TABLE jobs ADD COLUMN action TEXT DEFAULT ''")
        if "branch" not in job_cols:
            conn.execute("ALTER TABLE jobs ADD COLUMN branch TEXT DEFAULT ''")
        if "task_id" not in job_cols:
            conn.execute("ALTER TABLE jobs ADD COLUMN task_id INTEGER")
        if "worktree_md" not in job_cols:
            conn.execute("ALTER TABLE jobs ADD COLUMN worktree_md TEXT")
        if "agent_prompt" not in job_cols:
            conn.execute("ALTER TABLE jobs ADD COLUMN agent_prompt TEXT")
        if "proof_md" not in job_cols:
            conn.execute("ALTER TABLE jobs ADD COLUMN proof_md TEXT")
        # Migration: add slug column to tasks if missing
        task_cols = {row[1] for row in conn.execute("PRAGMA table_info(tasks)").fetchall()}
        if "base_branch" not in task_cols:
            conn.execute("ALTER TABLE tasks ADD COLUMN base_branch TEXT DEFAULT 'main'")
        if "timelimit" not in task_cols:
            conn.execute("ALTER TABLE tasks ADD COLUMN timelimit INTEGER")
        # Migration: add instruction column
        if "instruction" not in task_cols:
            conn.execute("ALTER TABLE tasks ADD COLUMN instruction TEXT NOT NULL DEFAULT ''")
            # Backfill: copy description → instruction for existing tasks
            conn.execute("UPDATE tasks SET instruction = description WHERE instruction = '' AND description != ''")
        # Migration: rename conductor_spec → spec_document, conductor_plan → plan_document
        if "conductor_spec" in task_cols and "spec_document" not in task_cols:
            conn.execute("ALTER TABLE tasks RENAME COLUMN conductor_spec TO spec_document")
        if "conductor_plan" in task_cols and "plan_document" not in task_cols:
            conn.execute("ALTER TABLE tasks RENAME COLUMN conductor_plan TO plan_document")
        if "slug" not in task_cols:
            conn.execute("ALTER TABLE tasks ADD COLUMN slug TEXT DEFAULT ''")
            import hashlib
            rows = conn.execute("SELECT id, title, description FROM tasks").fetchall()
            for row in rows:
                slug = hashlib.md5(
                    f"{row[1]}|{row[2] or ''}".encode()
                ).hexdigest()[:8]
                conn.execute("UPDATE tasks SET slug = ? WHERE id = ?", (slug, row[0]))
        # Always drop old index and ensure new slug-based index exists
        conn.execute("DROP INDEX IF EXISTS idx_tasks_repo_branch")
        conn.execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_repo_branch_slug
                ON tasks(repo, branch, slug) WHERE branch != ''
        """)
        # Migration: drop old table-level UNIQUE(repo, branch) constraint
        table_sql = conn.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='tasks'"
        ).fetchone()
        if table_sql and "UNIQUE(repo, branch)" in (table_sql[0] or ""):
            db_path = _device_db_path(device)
            shutil.copy2(str(db_path), str(db_path) + ".backup")
            # Get column names from old table before rename
            old_cols = {row[1] for row in conn.execute("PRAGMA table_info(tasks)").fetchall()}
            conn.execute("ALTER TABLE tasks RENAME TO _tasks_old")
            conn.executescript(DEVICE_SCHEMA)
            # Get column names from new table
            new_cols = {row[1] for row in conn.execute("PRAGMA table_info(tasks)").fetchall()}
            # Transfer only common columns to avoid column-count mismatch
            common = sorted(old_cols & new_cols)
            cols_str = ", ".join(common)
            conn.execute(f"""
                INSERT OR IGNORE INTO tasks ({cols_str})
                SELECT {cols_str} FROM _tasks_old
            """)
            conn.execute("DROP TABLE IF EXISTS _tasks_old")


def init_db(device: str = ""):
    """Initialize both webapp DB and optionally a device DB. Legacy entry point."""
    init_webapp_db()
    if device:
        init_device_db(device)


# ── Remote Device DB Sync ─────────────────────────────────────────────────────

# Cache of last sync times per device to support cooldown
_sync_timestamps: dict[str, float] = {}


async def sync_remote_device_db(
    device_name: str,
    local_device: str = "",
    cooldown_seconds: int = 30,
) -> dict:
    """SCP a remote device's DB files to the local device DB directory.

    Args:
        device_name: Name of the remote device to sync from.
        local_device: Name of the local device (skip sync if same).
        cooldown_seconds: Minimum seconds between syncs per device.

    Returns:
        dict with keys: ok, synced, reason
    """
    import asyncio
    import time

    # Skip sync for local device
    if device_name == local_device or not device_name:
        return {"ok": True, "synced": False, "reason": "local device"}

    # Cooldown check
    last_sync = _sync_timestamps.get(device_name, 0)
    elapsed = time.time() - last_sync
    if elapsed < cooldown_seconds:
        return {"ok": True, "synced": False,
                "reason": f"cooldown ({int(cooldown_seconds - elapsed)}s remaining)"}

    # Look up device info
    device = get_device(device_name)
    if not device:
        return {"ok": False, "synced": False, "reason": f"device not found: {device_name}"}

    user = device.get("user", "ubuntu")
    ip = device.get("ip", "")
    ssh_port = str(device.get("ssh_port", 22))
    remote_home = "/root" if user == "root" else f"/home/{user}"
    remote_db_dir = f"{remote_home}/.tenai/devices"

    # Ensure local dir exists
    DEVICE_DB_DIR.mkdir(parents=True, exist_ok=True)

    # SCP the device DB files (db, WAL, SHM)
    scp_args = [
        "scp", "-q",
        "-P", ssh_port,
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=10",
        "-o", "BatchMode=yes",
    ]

    # Copy device-specific DB file + WAL/SHM
    remote_files = [
        f"{user}@{ip}:{remote_db_dir}/{device_name}.db",
    ]
    # WAL and SHM may not exist — copy them separately
    wal_shm_files = [
        f"{user}@{ip}:{remote_db_dir}/{device_name}.db-wal",
        f"{user}@{ip}:{remote_db_dir}/{device_name}.db-shm",
    ]

    try:
        # Main DB file
        proc = await asyncio.create_subprocess_exec(
            *scp_args, *remote_files, str(DEVICE_DB_DIR) + "/",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await asyncio.wait_for(proc.communicate(), timeout=15)
        if proc.returncode != 0:
            return {"ok": False, "synced": False,
                    "reason": f"scp failed: {stderr.decode().strip()}"}

        # WAL/SHM (best-effort, may not exist)
        for remote_file in wal_shm_files:
            p = await asyncio.create_subprocess_exec(
                *scp_args, remote_file, str(DEVICE_DB_DIR) + "/",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await asyncio.wait_for(p.communicate(), timeout=10)

        _sync_timestamps[device_name] = time.time()
        return {"ok": True, "synced": True, "reason": ""}
    except asyncio.TimeoutError:
        return {"ok": False, "synced": False, "reason": "scp timeout"}
    except Exception as e:
        return {"ok": False, "synced": False, "reason": str(e)}


# ── Settings ─────────────────────────────────────────────────────────────────

def get_setting(key: str, default: str = "") -> str:
    """Get a setting value from webapp DB."""
    with get_webapp_db() as conn:
        row = conn.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        return row[0] if row else default


def set_setting(key: str, value: str):
    """Set a setting value in webapp DB."""
    with get_webapp_db() as conn:
        conn.execute("""
            INSERT INTO settings (key, value, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at
        """, (key, value, _now()))


def list_settings() -> list[dict]:
    """List all settings."""
    with get_webapp_db() as conn:
        rows = conn.execute("SELECT * FROM settings ORDER BY key").fetchall()
        return [dict(r) for r in rows]


def delete_setting(key: str):
    """Delete a setting."""
    with get_webapp_db() as conn:
        conn.execute("DELETE FROM settings WHERE key=?", (key,))


# ── Devices (webapp DB) ─────────────────────────────────────────────────────

def upsert_device(name: str, ip: str, user: str, device_type: str = "server",
                  capabilities: str = "[]"):
    with get_webapp_db() as conn:
        conn.execute("""
            INSERT INTO devices (name, ip, user, type, capabilities)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(name) DO UPDATE SET
                ip=excluded.ip,
                user=excluded.user,
                type=excluded.type,
                capabilities=excluded.capabilities
        """, (name, ip, user, device_type, capabilities))


def list_devices() -> list[dict]:
    with get_webapp_db() as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM devices ORDER BY name").fetchall()]


def get_device(name: str) -> Optional[dict]:
    with get_webapp_db() as conn:
        row = conn.execute("SELECT * FROM devices WHERE name=?", (name,)).fetchone()
        return dict(row) if row else None


def update_device_status(name: str, online: bool):
    with get_webapp_db() as conn:
        conn.execute(
            "UPDATE devices SET online=?, last_seen=? WHERE name=?",
            (1 if online else 0, _now(), name)
        )


# ── Organizations (device-scoped DB) ────────────────────────────────────────

def upsert_org(name: str, github_url: str, ssh_host_alias: str,
               ssh_key: str, default_branch: str = "main", *, device: str = ""):
    with get_device_db(device) as conn:
        conn.execute("""
            INSERT INTO organizations (name, github_url, ssh_host_alias, ssh_key, default_branch, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(name) DO UPDATE SET
                github_url=excluded.github_url,
                ssh_host_alias=excluded.ssh_host_alias,
                ssh_key=excluded.ssh_key,
                default_branch=excluded.default_branch,
                updated_at=excluded.updated_at
        """, (name, github_url, ssh_host_alias, ssh_key, default_branch, _now()))


def list_orgs(*, device: str = "") -> list[dict]:
    with get_device_db(device) as conn:
        rows = conn.execute("SELECT * FROM organizations ORDER BY name").fetchall()
        return [dict(r) for r in rows]


def get_org(name: str, *, device: str = "") -> Optional[dict]:
    with get_device_db(device) as conn:
        row = conn.execute("SELECT * FROM organizations WHERE name=?", (name,)).fetchone()
        return dict(row) if row else None


def delete_org(name: str, *, device: str = ""):
    with get_device_db(device) as conn:
        conn.execute("DELETE FROM repos WHERE org=?", (name,))
        conn.execute("DELETE FROM organizations WHERE name=?", (name,))


# ── Repos (device-scoped DB) ────────────────────────────────────────────────

def upsert_repo(org: str, name: str, default_branch: str = "main",
                description: str = "", pushed_at: str = "", *, device: str = ""):
    with get_device_db(device) as conn:
        conn.execute("""
            INSERT INTO repos (org, name, default_branch, description, pushed_at, last_synced)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(org, name) DO UPDATE SET
                default_branch=excluded.default_branch,
                description=excluded.description,
                pushed_at=COALESCE(NULLIF(excluded.pushed_at, ''), repos.pushed_at),
                last_synced=excluded.last_synced
        """, (org, name, default_branch, description, pushed_at, _now()))


def list_repos(org: Optional[str] = None, query: Optional[str] = None,
               *, device: str = "") -> list[dict]:
    with get_device_db(device) as conn:
        sql = "SELECT * FROM repos WHERE 1=1"
        params: list = []
        if org:
            sql += " AND org=?"
            params.append(org)
        if query:
            sql += " AND (name LIKE ? OR org LIKE ?)"
            params.extend([f"%{query}%", f"%{query}%"])
        sql += " ORDER BY COALESCE(NULLIF(pushed_at, ''), '1970-01-01') DESC, org, name"
        return [dict(r) for r in conn.execute(sql, params).fetchall()]


def get_repo(org: str, name: str, *, device: str = "") -> Optional[dict]:
    with get_device_db(device) as conn:
        row = conn.execute(
            "SELECT * FROM repos WHERE org=? AND name=?", (org, name)
        ).fetchone()
        return dict(row) if row else None


# ── Jobs (device-scoped DB) ─────────────────────────────────────────────────

def create_job(device: str, command: str, org: str = "", repo: str = "",
               cli: str = "", tmux_session: str = "", connect_cmd: str = "",
               vt_session_id: str = "", vt_url: str = "",
               action: str = "", branch: str = "", task_id: int | None = None,
               worktree_md: str = "", agent_prompt: str = "") -> int:
    with get_device_db(device) as conn:
        cur = conn.execute("""
            INSERT INTO jobs (device, org, repo, cli, action, branch, task_id,
                              command, tmux_session, status, connect_cmd,
                              vt_session_id, vt_url, worktree_md, agent_prompt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'running', ?, ?, ?, ?, ?)
        """, (device, org, repo, cli, action, branch, task_id,
              command, tmux_session, connect_cmd,
              vt_session_id or None, vt_url or None,
              worktree_md or None, agent_prompt or None))
        return cur.lastrowid


def update_job_vt_session(job_id: int, vt_session_id: str, vt_url: str,
                          *, device: str = ""):
    """Update a job with VibeTunnel session info after async attach."""
    with get_device_db(device) as conn:
        conn.execute(
            "UPDATE jobs SET vt_session_id=?, vt_url=? WHERE id=?",
            (vt_session_id, vt_url, job_id)
        )


def update_job_status(job_id: int, status: str, *, device: str = ""):
    with get_device_db(device) as conn:
        updates = {"status": status}
        if status in ("completed", "failed", "killed"):
            updates["ended_at"] = _now()
        set_clause = ", ".join(f"{k}=?" for k in updates)
        conn.execute(
            f"UPDATE jobs SET {set_clause} WHERE id=?",
            (*updates.values(), job_id)
        )


def list_jobs(status: Optional[str] = None, org: Optional[str] = None,
              repo: Optional[str] = None,
              limit: int = 50, offset: int = 0, *, device: str = "") -> tuple[list[dict], int]:
    with get_device_db(device) as conn:
        sql = "SELECT * FROM jobs WHERE 1=1"
        params: list = []
        if device:
            sql += " AND device=?"
            params.append(device)
        if status:
            sql += " AND status=?"
            params.append(status)
        if org:
            sql += " AND org=?"
            params.append(org)
        if repo:
            sql += " AND repo=?"
            params.append(repo)
        count_sql = sql.replace("SELECT *", "SELECT count(*)")
        total = conn.execute(count_sql, params).fetchone()[0]
        sql += " ORDER BY started_at DESC LIMIT ? OFFSET ?"
        params.extend([limit, offset])
        rows = [dict(r) for r in conn.execute(sql, params).fetchall()]
        return rows, total


def find_running_job(repo: str, branch: str, *, device: str = "") -> Optional[dict]:
    """Find a running job for the given repo and branch."""
    with get_device_db(device) as conn:
        row = conn.execute(
            "SELECT * FROM jobs WHERE repo=? AND branch=? AND status='running' "
            "ORDER BY started_at DESC LIMIT 1",
            (repo, branch)
        ).fetchone()
        return dict(row) if row else None


def find_running_job_by_task_id(task_id: int, *, device: str = "") -> Optional[dict]:
    """Find a running job for the given task_id."""
    with get_device_db(device) as conn:
        row = conn.execute(
            "SELECT * FROM jobs WHERE task_id=? AND status='running' "
            "ORDER BY started_at DESC LIMIT 1",
            (task_id,)
        ).fetchone()
        return dict(row) if row else None


def get_job(job_id: int, *, device: str = "") -> Optional[dict]:
    with get_device_db(device) as conn:
        row = conn.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
        return dict(row) if row else None


def append_job_log(job_id: int, line: str, *, device: str = ""):
    with get_device_db(device) as conn:
        conn.execute(
            "INSERT INTO job_logs (job_id, line) VALUES (?, ?)",
            (job_id, line)
        )


def get_job_logs(job_id: int, limit: int = 100, *, device: str = "") -> list[dict]:
    with get_device_db(device) as conn:
        rows = conn.execute(
            "SELECT * FROM job_logs WHERE job_id=? ORDER BY id DESC LIMIT ?",
            (job_id, limit)
        ).fetchall()
        return [dict(r) for r in reversed(rows)]


def update_job_proof(job_id: int, proof_md: str, *, device: str = ""):
    """Store PROOF.md content in job record."""
    with get_device_db(device) as conn:
        conn.execute(
            "UPDATE jobs SET proof_md=? WHERE id=?",
            (proof_md, job_id)
        )


def get_timed_out_jobs(device: str, global_timeout: int) -> list[dict]:
    """Find running jobs past their timelimit.

    Uses per-task timelimit if set, otherwise falls back to global_timeout.
    Returns empty list if global_timeout is 0 and task has no per-task limit.
    """
    with get_device_db(device) as conn:
        # Get running jobs with their task's timelimit
        rows = conn.execute("""
            SELECT j.*, t.timelimit as task_timelimit
            FROM jobs j
            LEFT JOIN tasks t ON j.task_id = t.id
            WHERE j.device = ? AND j.status = 'running'
        """, (device,)).fetchall()

    now = datetime.now(timezone.utc)
    timed_out = []
    for row in rows:
        job = dict(row)
        limit = job.get("task_timelimit")
        if limit is None:
            limit = global_timeout
        if limit == 0:  # 0 = never expire
            continue
        try:
            started = datetime.fromisoformat(
                job["started_at"].replace("Z", "+00:00")
            )
            elapsed_min = (now - started).total_seconds() / 60
            if elapsed_min > limit:
                job["elapsed_minutes"] = int(elapsed_min)
                timed_out.append(job)
        except (ValueError, TypeError, KeyError):
            continue
    return timed_out


def delete_job(job_id: int, *, device: str = ""):
    with get_device_db(device) as conn:
        conn.execute("DELETE FROM job_logs WHERE job_id=?", (job_id,))
        conn.execute("DELETE FROM jobs WHERE id=?", (job_id,))
