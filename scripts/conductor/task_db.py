#!/usr/bin/env python3
"""Task database CRUD — unified task management across repos and sources.

Provides:
  - CRUD operations on the `tasks` table in ~/.tenai/tenai.db
  - Import from TASKS.md (with Context/Created-by fields)
  - Render TASKS.md from database
  - Context resolution (conductor tracks, GitHub issues, inline)

Usage:
    python scripts/conductor/task_db.py list --repo myapp
    python scripts/conductor/task_db.py query --repo myapp --pattern "auth" --since 2026-03-01
    python scripts/conductor/task_db.py add --repo myapp --title "Fix bug" --branch fix/bug
    python scripts/conductor/task_db.py register --repo myapp --title "Auth" --branch feat/auth --cli claude
    python scripts/conductor/task_db.py import --repo myapp /path/to/TASKS.md
    python scripts/conductor/task_db.py import-track --repo myapp /path/to/conductor/tracks/my_track
    python scripts/conductor/task_db.py render --repo myapp > TASKS.md
    python scripts/conductor/task_db.py resolve --repo myapp --branch feat/auth
    python scripts/conductor/task_db.py status --repo myapp --branch feat/auth --status done
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# Reuse webapp DB infrastructure
sys.path.insert(0, str(Path(__file__).parent.parent.parent / "webapp"))
from db import get_device_db, init_device_db, init_webapp_db  # noqa: E402

SCRIPT_DIR = Path(__file__).parent

# Module-level active device — set via set_device() or --device CLI flag
_DEVICE = ""


def set_device(device: str):
    """Set the active device for all task_db operations."""
    global _DEVICE
    _DEVICE = device


def _db():
    """Context manager for the active device DB."""
    return get_device_db(_DEVICE)


def _init():
    """Initialize both webapp and current device DBs."""
    init_webapp_db()
    init_device_db(_DEVICE)


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def compute_slug(title: str, description: str = "") -> str:
    """Compute a short hash slug from title + description.

    Used as part of the UNIQUE(repo, branch, slug) constraint to allow
    multiple tasks on the same branch with different content.
    """
    content = f"{title}|{description or ''}"
    return hashlib.md5(content.encode()).hexdigest()[:8]


# ── Org Resolution ────────────────────────────────────────────────────────────


def resolve_task_org(repo: str) -> str:
    """Resolve the org for a repo name by looking up the repos table.

    Returns the org if exactly one match is found.
    Raises ValueError if the repo is ambiguous (multiple orgs) or not found.
    """
    _init()
    with _db() as conn:
        rows = conn.execute(
            "SELECT DISTINCT org FROM repos WHERE name = ?", (repo,)
        ).fetchall()
    if len(rows) == 1:
        return rows[0][0]
    if len(rows) > 1:
        orgs = [r[0] for r in rows]
        raise ValueError(
            f"Ambiguous repo '{repo}': found in orgs {orgs}. "
            f"Specify --org explicitly."
        )
    raise ValueError(
        f"Repo '{repo}' not found in repos table. "
        f"Sync repos first (make sync-all) or specify --org explicitly."
    )


# ── Instruction Generation ────────────────────────────────────────────────────


def generate_instruction(
    context_type: str,
    title: str,
    description: str = "",
    plan_document: str = "",
    spec_document: str = "",
    context_ref: str = "",
    subtasks: list[dict] | None = None,
) -> str:
    """Generate agent-facing instruction based on context_type.

    This is the single deterministic function that produces the ``instruction``
    field for every task.  It guarantees non-empty output.
    """
    if context_type == "conductor":
        parts = [f"## Conductor Track: {context_ref}"]
        parts.append("Read the full implementation plan before starting:")
        if plan_document:
            parts.append(f"- `{plan_document}`")
        if spec_document:
            parts.append(f"- `{spec_document}`")
        parts.append("")
        parts.append("Implement the subtasks below **in phase order**.")
        parts.append("After completing each, update its status via the API")
        parts.append("(subtask IDs are shown in parentheses).")
        parts.append("")
        parts.append("Commit any artifacts generated in the conductor track directory.")
        if subtasks:
            parts.append("")
            parts.append("### Subtask Overview")
            cur_phase = ""
            for st in subtasks:
                phase = st.get("phase", "")
                if phase and phase != cur_phase:
                    parts.append(f"\n**{phase}**")
                    cur_phase = phase
                sid = st.get("id", "?")
                parts.append(f"- (#{sid}) {st['title']}")
        return "\n".join(parts)

    if context_type == "github":
        parts = []
        if context_ref:
            parts.append(f"GitHub Issue: `{context_ref}`")
            parts.append("Run `gh issue view <number>` for full context.\n")
        if description:
            parts.append(description)
        return "\n".join(parts) or title

    if context_type == "ai-dlc":
        parts = ["## AI-DLC Task"]
        if plan_document:
            parts.append(f"Read the plan document: `{plan_document}`")
        if description:
            parts.append("")
            parts.append(description)
        return "\n".join(parts) or title

    # inline / adhoc — description is the instruction
    return description or title


# ── CRUD ──────────────────────────────────────────────────────────────────────


def add_task(
    repo: str,
    title: str,
    branch: str = "",
    org: str = "",
    description: str = "",
    instruction: str = "",
    verification: str = "",
    context_type: str = "inline",
    context_ref: str = "",
    plan_document: str = "",
    spec_document: str = "",
    created_by: str = "",
    created_by_user: str = "",
    created_by_cli: str = "",
    created_by_model: str = "",
    github_issue: int | None = None,
    github_repo: str = "",
    conductor_track: str = "",
    timelimit: int | None = None,
) -> int:
    """Add a task, return its ID.

    ``instruction`` is auto-generated via ``generate_instruction()`` if empty.
    Enforces that org is known. If not provided, auto-resolves from repos DB.
    """
    if not org:
        org = resolve_task_org(repo)
    # Guarantee instruction is never empty
    if not instruction:
        instruction = generate_instruction(
            context_type, title, description,
            plan_document, spec_document, context_ref,
        )
    _init()
    slug = compute_slug(title, description)
    # Auto-assign task number per repo
    with _db() as conn:
        row = conn.execute(
            "SELECT COALESCE(MAX(number), 0) + 1 FROM tasks WHERE repo = ?", (repo,)
        ).fetchone()
        number = row[0]

        conn.execute(
            """INSERT INTO tasks
            (number, title, repo, org, branch, slug, description, instruction,
             verification, context_type, context_ref, plan_document, spec_document,
             created_by, created_by_user, created_by_cli, created_by_model,
             github_issue, github_repo, conductor_track, timelimit)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (number, title, repo, org, branch, slug, description, instruction,
             verification, context_type, context_ref, plan_document, spec_document,
             created_by, created_by_user, created_by_cli, created_by_model,
             github_issue, github_repo, conductor_track, timelimit),
        )
        return conn.execute("SELECT last_insert_rowid()").fetchone()[0]


def list_tasks(repo: str, status: str | None = None, section: str | None = None) -> list[dict]:
    """List tasks for a repo, optionally filtered."""
    _init()
    with _db() as conn:
        query = "SELECT * FROM tasks WHERE repo = ?"
        params: list = [repo]
        if status:
            query += " AND status = ?"
            params.append(status)
        if section:
            query += " AND section = ?"
            params.append(section)
        query += " ORDER BY number"
        rows = conn.execute(query, params).fetchall()
        return [dict(r) for r in rows]


def query_tasks(
    repo: str | None = None,
    status: str | None = None,
    pattern: str | None = None,
    context_type: str | None = None,
    created_by: str | None = None,
    since: str | None = None,
    until: str | None = None,
    priority: int | None = None,
    limit: int = 100,
    offset: int = 0,
    count_only: bool = False,
) -> list[dict] | int:
    """Rich query with filters across all repos. Returns list or count."""
    _init()
    with _db() as conn:
        query = "SELECT * FROM tasks WHERE 1=1"
        count_q = "SELECT COUNT(*) FROM tasks WHERE 1=1"
        params: list = []
        if repo:
            clause = " AND repo = ?"
            query += clause
            count_q += clause
            params.append(repo)
        if status:
            clause = " AND status = ?"
            query += clause
            count_q += clause
            params.append(status)
        if pattern:
            clause = " AND (title LIKE ? OR description LIKE ? OR branch LIKE ?)"
            query += clause
            count_q += clause
            p = f"%{pattern}%"
            params.extend([p, p, p])
        if context_type:
            clause = " AND context_type = ?"
            query += clause
            count_q += clause
            params.append(context_type)
        if created_by:
            clause = " AND (created_by LIKE ? OR created_by_cli LIKE ?)"
            query += clause
            count_q += clause
            cb = f"%{created_by}%"
            params.extend([cb, cb])
        if since:
            clause = " AND created_at >= ?"
            query += clause
            count_q += clause
            params.append(since)
        if until:
            clause = " AND created_at <= ?"
            query += clause
            count_q += clause
            params.append(until)
        if priority is not None:
            clause = " AND priority = ?"
            query += clause
            count_q += clause
            params.append(priority)
        if count_only:
            return conn.execute(count_q, params).fetchone()[0]
        query += " ORDER BY repo, number LIMIT ? OFFSET ?"
        rows = conn.execute(query, params + [limit, offset]).fetchall()
        return [dict(r) for r in rows]


def register_task(
    repo: str,
    title: str,
    branch: str = "",
    org: str = "",
    description: str = "",
    instruction: str = "",
    verification: str = "",
    context_ref: str = "",
    plan_document: str = "",
    spec_document: str = "",
    cli: str = "",
    model: str = "",
    github_issue: int | None = None,
    conductor_track: str = "",
    timelimit: int | None = None,
) -> int:
    """Register a task with standardized format. Auto-detects context type."""
    # Auto-detect context type from context_ref
    context_type = "inline"
    if context_ref.startswith("conductor/"):
        context_type = "conductor"
    elif context_ref.startswith("github:"):
        context_type = "github"
        context_ref = context_ref[7:].strip()
    elif context_ref.startswith("linear:"):
        context_type = "linear"

    # Auto-detect created_by source
    created_by = cli if cli else "manual"
    if conductor_track:
        created_by = f"{cli}-conductor" if cli else "conductor"
        context_type = "conductor"
        if not context_ref:
            context_ref = f"conductor/tracks/{conductor_track}"

    return add_task(
        repo=repo,
        title=title,
        branch=branch,
        org=org,
        description=description,
        instruction=instruction,
        verification=verification,
        context_type=context_type,
        context_ref=context_ref,
        plan_document=plan_document,
        spec_document=spec_document,
        created_by=created_by,
        created_by_cli=cli,
        created_by_model=model,
        github_issue=github_issue,
        conductor_track=conductor_track,
        timelimit=timelimit,
    )


def update_task(task_id: int, **kwargs) -> None:
    """Update task fields by ID."""
    _init()
    allowed = {
        "title", "branch", "description", "verification", "context_type",
        "context_ref", "status", "section", "priority", "timelimit",
        "instruction", "plan_document", "spec_document",
        "assigned_to", "assigned_cli", "dispatch_device", "dispatch_cli",
        "worktree_path", "tmux_session", "proof_path", "proof_summary",
        "dispatched_at", "completed_at",
    }
    fields = {k: v for k, v in kwargs.items() if k in allowed}
    if not fields:
        return
    fields["updated_at"] = _now()
    set_clause = ", ".join(f"{k} = ?" for k in fields)
    with _db() as conn:
        conn.execute(
            f"UPDATE tasks SET {set_clause} WHERE id = ?",  # noqa: S608
            [*fields.values(), task_id],
        )


def update_task_by_branch(repo: str, branch: str, **kwargs) -> None:
    """Update task by repo + branch."""
    _init()
    with _db() as conn:
        row = conn.execute(
            "SELECT id FROM tasks WHERE repo = ? AND branch = ?", (repo, branch)
        ).fetchone()
        if row:
            update_task(row["id"], **kwargs)


def get_task_by_branch(repo: str, branch: str) -> dict | None:
    """Get single task by repo + branch."""
    _init()
    with _db() as conn:
        row = conn.execute(
            "SELECT * FROM tasks WHERE repo = ? AND branch = ?", (repo, branch)
        ).fetchone()
        return dict(row) if row else None


def delete_task(task_id: int) -> None:
    """Delete a task and its subtasks by ID."""
    _init()
    with _db() as conn:
        conn.execute("DELETE FROM subtasks WHERE task_id = ?", (task_id,))
        conn.execute("DELETE FROM tasks WHERE id = ?", (task_id,))


def duplicate_task(task_id: int, new_title: str | None = None) -> int:
    """Duplicate a task and its subtasks. Returns the new task ID."""
    _init()
    with _db() as conn:
        row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
        if not row:
            raise ValueError(f"Task {task_id} not found")
        task = dict(row)
        title = new_title or f"{task['title']} (copy)"
        # Generate new slug and branch from the new title
        slug = compute_slug(title, task.get("description", ""))
        branch = slug  # branch mirrors slug
        # Get next number for this repo
        num_row = conn.execute(
            "SELECT COALESCE(MAX(number), 0) + 1 FROM tasks WHERE repo = ?",
            (task["repo"],)
        ).fetchone()
        number = num_row[0]
        conn.execute(
            """INSERT INTO tasks
            (number, title, repo, org, branch, slug, description, verification,
             context_type, context_ref, created_by, created_by_user,
             created_by_cli, created_by_model, github_issue, github_repo,
             conductor_track, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active')""",
            (number, title, task["repo"], task.get("org", ""), branch, slug,
             task.get("description", ""), task.get("verification", ""),
             task.get("context_type", "inline"), task.get("context_ref", ""),
             task.get("created_by", ""), task.get("created_by_user", ""),
             task.get("created_by_cli", ""), task.get("created_by_model", ""),
             task.get("github_issue"), task.get("github_repo", ""),
             task.get("conductor_track", "")),
        )
        new_id = conn.execute("SELECT last_insert_rowid()").fetchone()[0]
        # Duplicate subtasks
        subs = conn.execute(
            "SELECT * FROM subtasks WHERE task_id = ? ORDER BY ordinal",
            (task_id,)
        ).fetchall()
        for s in subs:
            conn.execute(
                """INSERT INTO subtasks (task_id, title, phase, ordinal, status)
                VALUES (?, ?, ?, ?, 'pending')""",
                (new_id, s["title"], s["phase"], s["ordinal"]),
            )
        return new_id


def list_repos() -> list[str]:
    """Return distinct repo names from the task DB."""
    _init()
    with _db() as conn:
        rows = conn.execute(
            "SELECT DISTINCT repo FROM tasks ORDER BY repo"
        ).fetchall()
        return [r[0] for r in rows]


# ── Subtask CRUD ─────────────────────────────────────────────────────────────


def add_subtask(
    task_id: int,
    title: str,
    phase: str = "",
    ordinal: int = 0,
    status: str = "pending",
) -> int:
    """Add a subtask, return its ID."""
    _init()
    with _db() as conn:
        conn.execute(
            """INSERT INTO subtasks (task_id, title, phase, ordinal, status)
            VALUES (?, ?, ?, ?, ?)""",
            (task_id, title, phase, ordinal, status),
        )
        return conn.execute("SELECT last_insert_rowid()").fetchone()[0]


def list_subtasks(task_id: int) -> list[dict]:
    """List subtasks for a task, ordered by phase then ordinal."""
    _init()
    with _db() as conn:
        rows = conn.execute(
            "SELECT * FROM subtasks WHERE task_id = ? ORDER BY phase, ordinal",
            (task_id,),
        ).fetchall()
        return [dict(r) for r in rows]


def update_subtask(subtask_id: int, **kwargs) -> None:
    """Update subtask fields."""
    _init()
    allowed = {"title", "phase", "status", "ordinal", "checkpoint", "evidence"}
    fields = {k: v for k, v in kwargs.items() if k in allowed}
    if not fields:
        return
    fields["updated_at"] = _now()
    set_clause = ", ".join(f"{k} = ?" for k in fields)
    with _db() as conn:
        conn.execute(
            f"UPDATE subtasks SET {set_clause} WHERE id = ?",  # noqa: S608
            [*fields.values(), subtask_id],
        )


def delete_subtask(subtask_id: int) -> None:
    """Delete a subtask."""
    _init()
    with _db() as conn:
        conn.execute("DELETE FROM subtasks WHERE id = ?", (subtask_id,))


def import_subtasks_from_plan(task_id: int, plan_content: str) -> int:
    """Parse phases/tasks from plan.md content and create subtask entries."""
    imported = 0
    current_phase = ""
    ordinal = 0

    for line in plan_content.split("\n"):
        stripped = line.strip()
        phase_match = re.match(r"^##\s+(?:Phase\s+\d+:\s*)?(.+)$", stripped)
        if phase_match:
            current_phase = phase_match.group(1).strip()
            ordinal = 0
            continue

        task_match = re.match(r"^-\s*\[([ x])\]\s*(?:Task:\s*)?(.+)$", stripped)
        if not task_match:
            continue

        is_done = task_match.group(1) == "x"
        title = task_match.group(2).strip()
        ordinal += 1

        add_subtask(
            task_id=task_id,
            title=title,
            phase=current_phase,
            ordinal=ordinal,
            status="done" if is_done else "pending",
        )
        imported += 1

    return imported


# ── Task + Subtask Helpers ────────────────────────────────────────────────────


def get_task_with_subtasks(task_id: int) -> dict | None:
    """Return task dict enriched with subtasks list and progress info."""
    _init()
    with _db() as conn:
        row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
        if not row:
            return None
        task = dict(row)
    task["subtasks"] = list_subtasks(task_id)
    progress = compute_task_progress(task_id)
    task["progress"] = progress
    return task


def compute_task_progress(task_id: int) -> dict:
    """Compute % completion based on subtask statuses.

    Returns dict with total, completed, percent.
    """
    subtasks = list_subtasks(task_id)
    total = len(subtasks)
    if total == 0:
        return {"total": 0, "completed": 0, "percent": 0}
    completed = sum(1 for s in subtasks if s.get("status") == "done")
    return {"total": total, "completed": completed, "percent": round(100 * completed / total)}


def build_worktree_md(task: dict, subtasks: list[dict] | None = None) -> str:
    """Build a rich WORKTREE.md for an agent to consume.

    Uses the ``instruction`` field (never description) for agent-facing content.
    Embeds subtask IDs so agents can update progress via API.
    Adds context-type-specific guidance sections.
    """
    from datetime import datetime, timezone  # noqa: I001

    title = task.get("title", "Untitled")
    branch = task.get("branch", "")
    org = task.get("org", "")
    repo = task.get("repo", "")
    instruction = task.get("instruction", "") or task.get("description", "")
    verification = task.get("verification", "")
    context_type = task.get("context_type", "inline")
    context_ref = task.get("context_ref", "")
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    lines = [
        f"# Task: {title}",
        f"- **Branch**: {branch}",
        f"- **Repo**: {org}/{repo}" if org else f"- **Repo**: {repo}",
        f"- **Context**: {context_type}" + (f" (`{context_ref}`)" if context_ref else ""),
        f"- **Created**: {now}",
        "",
    ]

    # ── Context-type-specific guidance ──
    if context_type == "conductor" and context_ref:
        lines += [
            "## Conductor Track",
            f"This task is part of conductor track `{context_ref}`.",
            "Read the full plan and spec **before** starting implementation:",
            f"- `{context_ref}/plan.md` — implementation plan with phases",
        ]
        if task.get("spec_document"):
            lines.append(f"- `{task['spec_document']}` — specification")
        lines += [
            "",
            "After completing work, **commit** any artifacts in the track directory.",
            "",
        ]
    elif context_type == "github" and context_ref:
        issue_num = context_ref.split("#")[-1] if "#" in context_ref else context_ref
        lines += [
            "## GitHub Issue",
            f"Source: `{context_ref}`",
            f"Run `gh issue view {issue_num} --json body,comments,title` for full context.",
            "",
        ]

    # ── Instruction (agent-facing content) ──
    if instruction:
        lines += ["## Description", instruction, ""]

    # ── Subtask checklist with IDs ──
    if subtasks is None:
        subtasks = task.get("subtasks", [])
    if subtasks:
        lines.append("## Subtasks")
        phases_seen: list[str] = []
        for st in subtasks:
            p = st.get("phase", "")
            if p and p not in phases_seen:
                phases_seen.append(p)
        if len(phases_seen) > 1:
            for phase in phases_seen:
                lines.append(f"### {phase}")
                for st in subtasks:
                    if st.get("phase", "") == phase:
                        marker = "x" if st.get("status") == "done" else " "
                        sid = st.get("id", "?")
                        lines.append(f"- [{marker}] (#{sid}) {st['title']}")
                lines.append("")
            phaseless = [st for st in subtasks if not st.get("phase")]
            for st in phaseless:
                marker = "x" if st.get("status") == "done" else " "
                sid = st.get("id", "?")
                lines.append(f"- [{marker}] (#{sid}) {st['title']}")
        else:
            for st in subtasks:
                marker = "x" if st.get("status") == "done" else " "
                sid = st.get("id", "?")
                phase = f"[{st['phase']}] " if st.get("phase") else ""
                lines.append(f"- [{marker}] (#{sid}) {phase}{st['title']}")
        lines.append("")

    # ── Verification ──
    if verification:
        lines += ["## Verification", verification, ""]
    else:
        lines += [
            "## Verification",
            "Run: `make lint && make test`",
            "",
        ]

    # ── Agent instructions ──
    base_branch = task.get("base_branch", "main")
    task_id = task.get("id", "TASK_ID")
    lines += [
        "## Instructions",
        "1. Read this file to understand your task scope",
        "2. If no subtasks are listed above, break this task into 3-7 concrete subtasks",
        "   and add them as a checklist in this file before starting implementation.",
        "   **Register each subtask in the database** so it can be tracked:",
        f"   `curl -s -X POST http://localhost:7700/api/task-db/{task_id}/subtasks "
        "-H 'Content-Type: application/json' -d '{\"title\": \"<subtask title>\"}'`",
        "3. Implement each subtask in order, checking them off as you go",
        "4. After completing each subtask, update its status:",
        "   `curl -s -X PATCH http://localhost:7700/api/task-db/subtasks/{id} "
        "-H 'Content-Type: application/json' -d '{\"status\": \"done\"}'`",
        "5. Run verification (see ## Verification above)",
        "6. Create `PROOF.md` with: test results, files changed, brief walkthrough",
        f"7. Commit all changes and push: `git add -A && git commit -m 'feat: <summary>' "
        f"&& git push -u origin {branch}`",
        f"8. Create a PR: `gh pr create --base {base_branch} --title '<task title>' "
        f"--body 'Automated PR from agent task' --fill 2>/dev/null || true`",
        "9. Exit when complete",
        "",
        "## Do not",
        "- Install system packages or tools (no apt, brew, npm -g, pip install)."
        " If a tool is missing, skip that step and note it in PROOF.md",
        "- Modify files outside this worktree's scope",
        "- Commit .env files",
        "- Merge from other branches (let CI handle it)",
        "- Spend time debugging infrastructure issues (SSH, auth, permissions)"
        " — report them and move on",
    ]
    return "\n".join(lines)




def generate_branch_name(title: str, conductor_track: str = "") -> str:
    """Auto-generate a branch name from task title or conductor track."""
    import re as _re
    base = conductor_track or title
    # Slugify: lowercase, replace non-alnum with hyphens, collapse
    slug = _re.sub(r"[^a-z0-9]+", "-", base.lower()).strip("-")
    if len(slug) > 50:
        slug = slug[:50].rstrip("-")
    prefix = "feat" if not conductor_track else "track"
    return f"{prefix}/{slug}"


# ── Import / Render ──────────────────────────────────────────────────────────


def find_existing_task(repo: str, title: str, branch: str = "", description: str = "") -> dict | None:
    """Find existing task by branch+slug (if branch set) or by repo+title.

    Checks branch+slug first (matching the UNIQUE constraint), then falls back
    to title match. This ensures idempotent imports.
    """
    slug = compute_slug(title, description)
    _init()
    with _db() as conn:
        if branch:
            # Match the UNIQUE constraint: repo + branch + slug
            row = conn.execute(
                "SELECT * FROM tasks WHERE repo = ? AND branch = ? AND slug = ?",
                (repo, branch, slug),
            ).fetchone()
            if row:
                return dict(row)
        # Fall back to title match within repo
        row = conn.execute(
            "SELECT * FROM tasks WHERE repo = ? AND title = ?",
            (repo, title),
        ).fetchone()
        return dict(row) if row else None


def import_from_tasks_md(
    repo: str,
    tasks_path: str,
    created_by: str = "import",
    org: str = "",
    force: bool = False,
    update: bool = False,
) -> tuple[int, int, int]:
    """Import tasks from a TASKS.md file into the database.

    Idempotent by default: skips tasks whose title or branch+slug already exist.
    Auto-generates branch names for branchless tasks.

    Args:
        force: If True, always create new tasks (ignore duplicates).
        update: If True, update existing tasks with new field values.

    Returns:
        Tuple of (imported, skipped, updated) counts.
    """
    sys.path.insert(0, str(SCRIPT_DIR))
    from parse_tasks import parse_tasks_md

    tasks_file = Path(tasks_path)
    if not tasks_file.exists():
        print(f"  ✗ File not found: {tasks_path}")
        return 0, 0, 0
    content = tasks_file.read_text()
    tasks = parse_tasks_md(content)

    imported = 0
    skipped = 0
    updated = 0

    # Force mode: clear all existing tasks for this repo first
    if force:
        _init()
        with _db() as conn:
            existing_count = conn.execute(
                "SELECT COUNT(*) FROM tasks WHERE repo = ?", (repo,)
            ).fetchone()[0]
            if existing_count:
                conn.execute("DELETE FROM subtasks WHERE task_id IN "
                             "(SELECT id FROM tasks WHERE repo = ?)", (repo,))
                conn.execute("DELETE FROM tasks WHERE repo = ?", (repo,))
                print(f"  ♻ Cleared {existing_count} existing tasks for {repo}")

    for task in tasks:
        title = task["title"]
        branch = task.get("branch", "")
        description = task.get("description", "")

        # Auto-generate branch for branchless tasks
        if not branch:
            branch = generate_branch_name(
                title, conductor_track=task.get("conductor_track", "")
            )

        if not force:
            existing = find_existing_task(repo, title, branch, description)
            if existing:
                if update:
                    # Update mutable fields on the existing task
                    update_task(
                        existing["id"],
                        title=title,
                        branch=branch or existing.get("branch", ""),
                        description=description or existing.get("description", ""),
                        verification=task.get("verification", "") or existing.get("verification", ""),
                    )
                    updated += 1
                else:
                    skipped += 1
                continue

        add_task(
            repo=repo,
            title=title,
            branch=branch,
            org=org,
            description=description,
            verification=task.get("verification", ""),
            context_type=task.get("context_type", "inline"),
            context_ref=task.get("context_ref", ""),
            created_by=created_by,
            created_by_cli=task.get("created_by_cli", ""),
            created_by_model=task.get("created_by_model", ""),
        )
        imported += 1

    return imported, skipped, updated


def import_from_conductor_track(  # noqa: C901
    repo: str,
    track_dir: str,
    created_by: str = "conductor",
    org: str = "",
) -> int:
    """Import a conductor track as ONE task with structured subtasks.

    Each track = 1 task (branch = track/{track_id}).
    Each ``- [ ] Task:`` line in plan.md = 1 subtask.
    Indented ``- [ ]`` items are appended to the subtask title.

    Conductor plan.md format::

        ## Phase 1: Title
        - [ ] Task: Main task title
            - [ ] Sub-item A
            - [ ] Sub-item B
        - [x] Task: Already done
    """
    track_path = Path(track_dir)
    plan_file = track_path / "plan.md"
    meta_file = track_path / "metadata.json"

    if not plan_file.exists():
        raise FileNotFoundError(f"No plan.md in {track_dir}")

    # Read metadata
    track_id = track_path.name
    track_description = ""
    if meta_file.exists():
        meta = json.loads(meta_file.read_text())
        track_id = meta.get("track_id", track_id)
        track_description = meta.get("description", "")

    content = plan_file.read_text()
    context_ref = f"conductor/tracks/{track_id}"

    # Check if this track was already imported
    with _db() as conn:
        existing = conn.execute(
            "SELECT id FROM tasks WHERE repo = ? AND context_ref = ? "
            "AND context_type = 'conductor'",
            (repo, context_ref),
        ).fetchone()
    if existing:
        return 0

    # ── Parse plan.md: collect subtask items grouped by phase ──
    subtask_items: list[dict] = []
    current_phase = ""
    current_item: dict | None = None
    ordinal = 0

    for line in content.split("\n"):
        stripped = line.strip()

        # Phase headers: ## Phase 1: Title
        phase_match = re.match(r"^##\s+(?:Phase\s+\d+:\s*)?(.+)$", stripped)
        if phase_match:
            if current_item:
                subtask_items.append(current_item)
                current_item = None
            current_phase = phase_match.group(1).strip()
            continue

        # Top-level task line: - [ ] Task: Description  (not indented)
        if not line.startswith("    ") and not line.startswith("\t"):
            task_match = re.match(r"^-\s*\[([ x])\]\s*Task:\s*(.+)$", stripped)
            if not task_match:
                task_match = re.match(r"^-\s*\[([ x])\]\s+(.+)$", stripped)
            if task_match:
                if current_item:
                    subtask_items.append(current_item)
                ordinal += 1
                current_item = {
                    "title": task_match.group(2).strip(),
                    "is_done": task_match.group(1) == "x",
                    "phase": current_phase,
                    "ordinal": ordinal,
                    "sub_items": [],
                }
                continue

        # Indented sub-item: 4-space or tab indent, then - [ ] text
        if current_item and (line.startswith("    ") or line.startswith("\t")):
            sub_match = re.match(r"^\s+-\s*\[([ x])\]\s+(.+)$", line)
            if sub_match:
                current_item["sub_items"].append(sub_match.group(2).strip())
                continue

    if current_item:
        subtask_items.append(current_item)

    if not subtask_items:
        return 0

    # ── Create ONE task for the entire track ──
    title = track_description or track_id.replace("_", " ").title()
    branch = generate_branch_name(title, conductor_track=track_id)

    plan_doc = f"{context_ref}/plan.md"
    spec_file = track_path / "spec.md"
    spec_doc = f"{context_ref}/spec.md" if spec_file.exists() else ""

    tid = add_task(
        repo=repo,
        title=title,
        branch=branch,
        org=org,
        description=content,  # Full plan.md for human reading
        # instruction auto-generated by generate_instruction(context_type="conductor")
        verification="",
        context_type="conductor",
        context_ref=context_ref,
        plan_document=plan_doc,
        spec_document=spec_doc,
        created_by=created_by,
        created_by_cli="gemini",
        conductor_track=track_id,
    )

    # ── Create subtasks for each Task: line ──
    for item in subtask_items:
        # Include sub-items in the subtask title for agent context
        st_title = item["title"]
        if item["sub_items"]:
            details = " | ".join(item["sub_items"])
            st_title = f"{item['title']} [{details}]"

        add_subtask(
            task_id=tid,
            title=st_title,
            phase=item["phase"],
            ordinal=item["ordinal"],
            status="done" if item["is_done"] else "pending",
        )

    return 1  # 1 task created


def render_tasks_md(repo: str) -> str:
    """Render tasks from DB as TASKS.md format."""
    tasks = list_tasks(repo)

    sections: dict[str, list[dict]] = {"Active": [], "In Progress": [], "Done": []}
    for t in tasks:
        sec = t.get("section", "Active")
        if sec not in sections:
            sections[sec] = []
        sections[sec].append(t)

    lines = [f"# TASKS.md — {repo}", ""]
    lines.append("> Auto-generated from task database. Edit via: `make task-add`, webapp, or GitHub Issues.")
    lines.append("")

    for section_name in ["Active", "In Progress", "Done"]:
        lines.append(f"## {section_name}")
        lines.append("")
        for t in sections.get(section_name, []):
            lines.append(f"### Task {t['number']}: {t['title']}")
            if t.get("branch"):
                lines.append(f"Branch: {t['branch']}")
            ct = t.get("context_type", "inline")
            cr = t.get("context_ref", "")
            if ct != "inline" and cr:
                if ct == "github":
                    lines.append(f"Context: github:{cr}")
                else:
                    lines.append(f"Context: {cr}")
            if t.get("created_by"):
                provenance = t["created_by"]
                if t.get("created_by_model"):
                    provenance += f" ({t['created_by_model']})"
                if t.get("created_at"):
                    provenance += f" @ {t['created_at']}"
                lines.append(f"Created-by: {provenance}")
            if t.get("assigned_cli") and t.get("dispatch_device"):
                lines.append(f"Assigned: {t['dispatch_device']} ({t['assigned_cli']})")
            if t.get("dispatched_at"):
                lines.append(f"Dispatched: {t['dispatched_at']}")
            if t.get("description"):
                lines.append(t["description"])
            if t.get("verification"):
                lines.append(f"Verification: {t['verification']}")
            lines.append("")

    return "\n".join(lines)


# ── Context Resolution ────────────────────────────────────────────────────────


def resolve_context(task: dict, repo_dir: str = "") -> str:
    """Resolve a task's context pointer to full text."""
    ct = task.get("context_type", "inline")
    cr = task.get("context_ref", "")

    if ct == "conductor" or (ct == "inline" and cr.startswith("conductor/")):
        return _resolve_conductor_context(cr, repo_dir)
    elif ct == "github":
        return _resolve_github_context(cr, task.get("github_repo", ""))
    else:
        return task.get("description", "")


def _resolve_conductor_context(track_ref: str, repo_dir: str) -> str:
    """Read spec.md + plan.md from a conductor track."""
    base = Path(repo_dir) if repo_dir else Path.cwd()
    track_path = base / track_ref

    parts = []
    spec = track_path / "spec.md"
    if spec.exists():
        parts.append(f"## Specification\n\n{spec.read_text()}")

    plan = track_path / "plan.md"
    if plan.exists():
        parts.append(f"## Implementation Plan\n\n{plan.read_text()}")

    # Also read product context if available
    product = base / "conductor" / "product.md"
    if product.exists():
        parts.append(f"## Product Context\n\n{product.read_text()}")

    tech = base / "conductor" / "tech-stack.md"
    if tech.exists():
        parts.append(f"## Tech Stack\n\n{tech.read_text()}")

    if parts:
        return "\n\n---\n\n".join(parts)
    return f"(conductor track not found: {track_ref})"


def _resolve_github_context(issue_ref: str, github_repo: str = "") -> str:
    """Fetch issue body + comments from GitHub."""
    issue_num = issue_ref.replace("github:", "").strip()
    cmd = ["gh", "issue", "view", issue_num, "--json", "body,comments,title"]
    if github_repo:
        cmd.extend(["--repo", github_repo])

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if result.returncode != 0:
            return f"(GitHub issue #{issue_num} not accessible)"
        data = json.loads(result.stdout)
        parts = [f"## GitHub Issue #{issue_num}: {data.get('title', '')}"]
        parts.append(data.get("body", ""))
        comments = data.get("comments", [])
        if comments:
            parts.append("\n## Comments\n")
            for c in comments[:5]:
                parts.append(f"**{c.get('author', {}).get('login', '?')}**: {c.get('body', '')}\n")
        return "\n\n".join(parts)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return f"(gh CLI not available for issue #{issue_num})"


# ── Programmatic API (for notebooks / scripts) ───────────────────────────────


def task_db_cli(command: str, *args: str, json_output: bool = False):
    """Programmatic interface for task_db commands.

    Designed for use in Jupyter notebooks and scripts. Calls the same
    underlying functions as the CLI but returns Python objects directly.

    Args:
        command: One of 'list', 'query', 'render', 'import', 'status', 'add',
                 'register', 'delete'.
        *args: CLI-style arguments like '--repo=myapp', '--status=active'.
        json_output: If True, return parsed dicts/lists instead of formatted strings.

    Returns:
        For list/query with json_output=True: list[dict]
        For render: str (markdown)
        For import: tuple[int, int, int] (imported, skipped, updated)
        For add/register: int (task ID)
        For status: None
        Otherwise: str (formatted output)

    Example::

        from scripts.conductor.task_db import task_db_cli

        tasks = task_db_cli('list', '--repo=myapp', json_output=True)
        rendered = task_db_cli('render', '--repo=myapp')
    """
    # Parse CLI-style args into a dict
    parsed = {}
    positional = []
    for arg in args:
        if arg.startswith("--"):
            key_val = arg[2:].split("=", 1)
            key = key_val[0].replace("-", "_")
            val = key_val[1] if len(key_val) == 2 else True
            parsed[key] = val
        else:
            positional.append(arg)

    repo = parsed.get("repo", "")

    if command == "list":
        tasks = list_tasks(
            repo,
            status=parsed.get("status"),
            section=parsed.get("section"),
        )
        if parsed.get("pattern"):
            tasks = query_tasks(repo=repo, status=parsed.get("status"),
                                pattern=parsed.get("pattern"))
        if json_output:
            return tasks
        lines = []
        icons = {"active": "○", "dispatched": "◐", "running": "◑",
                 "done": "●", "failed": "✗"}
        for t in tasks:
            icon = icons.get(t["status"], "?")
            lines.append(f"  {icon} Task {t['number']}: {t['title']}")
            if t.get("branch"):
                lines.append(f"      Branch: {t['branch']}")
        return "\n".join(lines) if lines else "  (no tasks)"

    elif command == "query":
        tasks = query_tasks(
            repo=repo or None,
            status=parsed.get("status"),
            pattern=parsed.get("pattern"),
            context_type=parsed.get("context_type"),
            created_by=parsed.get("created_by"),
            since=parsed.get("since"),
            until=parsed.get("until"),
            limit=int(parsed.get("limit", 100)),
        )
        if json_output:
            return tasks
        lines = []
        for t in tasks:
            lines.append(f"  Task {t['number']}: {t['title']} [{t['status']}]")
        return "\n".join(lines) if lines else "  (no matching tasks)"

    elif command == "render":
        return render_tasks_md(repo)

    elif command == "import":
        tasks_file = positional[0] if positional else parsed.get("tasks_file", "")
        return import_from_tasks_md(
            repo, tasks_file,
            created_by=parsed.get("created_by", "import"),
            force=parsed.get("force", False) is True,
            update=parsed.get("update", False) is True,
        )

    elif command == "add":
        return add_task(
            repo=repo,
            title=parsed.get("title", ""),
            branch=parsed.get("branch", ""),
            description=parsed.get("description", ""),
            verification=parsed.get("verification", ""),
        )

    elif command == "register":
        return register_task(
            repo=repo,
            title=parsed.get("title", ""),
            branch=parsed.get("branch", ""),
            description=parsed.get("description", ""),
            cli=parsed.get("cli", ""),
            model=parsed.get("model", ""),
        )

    elif command == "status":
        section_map = {
            "active": "Active", "dispatched": "In Progress",
            "running": "In Progress", "done": "Done", "failed": "Active",
        }
        status_val = parsed.get("status", "")
        update_task_by_branch(
            repo, parsed.get("branch", ""),
            status=status_val,
            section=section_map.get(status_val, "Active"),
        )
        return None

    else:
        raise ValueError(f"Unknown task_db_cli command: {command}")


# ── CLI ───────────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(description="Task database CLI")
    # Global flags — apply to all subcommands
    parser.add_argument("--device", default=os.environ.get("DEVICE_NAME", ""),
                        help="Target device DB (default: $DEVICE_NAME or empty)")
    sub = parser.add_subparsers(dest="command", required=True)

    # list
    p_list = sub.add_parser("list", help="List tasks for a repo")
    p_list.add_argument("--repo", required=True)
    p_list.add_argument("--status", default=None)
    p_list.add_argument("--section", default=None)
    p_list.add_argument("--pattern", default=None, help="Filter by title/desc/branch regex")
    p_list.add_argument("--json", action="store_true")

    # query (rich filter)
    p_query = sub.add_parser("query", help="Query tasks with rich filters")
    p_query.add_argument("--repo", default=None, help="Filter by repo")
    p_query.add_argument("--status", default=None, help="active|dispatched|running|done|failed")
    p_query.add_argument("--pattern", default=None, help="Search title/desc/branch")
    p_query.add_argument("--context-type", default=None, help="inline|conductor|github")
    p_query.add_argument("--created-by", default=None, help="Filter by creator")
    p_query.add_argument("--since", default=None, help="Created after (ISO date)")
    p_query.add_argument("--until", default=None, help="Created before (ISO date)")
    p_query.add_argument("--priority", type=int, default=None)
    p_query.add_argument("--limit", type=int, default=100)
    p_query.add_argument("--json", action="store_true")

    # add
    p_add = sub.add_parser("add", help="Add a task (low-level)")
    p_add.add_argument("--repo", required=True)
    p_add.add_argument("--title", required=True)
    p_add.add_argument("--branch", default="")
    p_add.add_argument("--org", default="")
    p_add.add_argument("--description", default="")
    p_add.add_argument("--verification", default="")
    p_add.add_argument("--context-type", default="inline")
    p_add.add_argument("--context-ref", default="")
    p_add.add_argument("--created-by", default="manual")
    p_add.add_argument("--created-by-cli", default="")
    p_add.add_argument("--created-by-model", default="")

    # register (standardized entry from any CLI)
    p_reg = sub.add_parser("register", help="Register task (auto-detect context type)")
    p_reg.add_argument("--repo", required=True)
    p_reg.add_argument("--title", required=True)
    p_reg.add_argument("--branch", default="")
    p_reg.add_argument("--description", default="")
    p_reg.add_argument("--verification", default="")
    p_reg.add_argument("--context-ref", default="")
    p_reg.add_argument("--cli", default="", help="Source CLI (claude|gemini|codex)")
    p_reg.add_argument("--model", default="", help="Model used")
    p_reg.add_argument("--github-issue", type=int, default=None)
    p_reg.add_argument("--conductor-track", default="")

    # import
    p_import = sub.add_parser("import", help="Import from TASKS.md")
    p_import.add_argument("--repo", required=True)
    p_import.add_argument("--org", default="", help="GitHub org")
    p_import.add_argument("tasks_file", help="Path to TASKS.md")
    p_import.add_argument("--created-by", default="import")
    p_import.add_argument("--force", action="store_true",
                          help="Always create new tasks (ignore duplicates)")
    p_import.add_argument("--update", action="store_true",
                          help="Update existing tasks with new field values")

    # import-track
    p_track = sub.add_parser("import-track", help="Import from conductor track dir")
    p_track.add_argument("--repo", required=True)
    p_track.add_argument("--org", default="", help="GitHub org")
    p_track.add_argument("track_dir", help="Path to conductor/tracks/<id>/ directory")
    p_track.add_argument("--created-by", default="conductor")

    # render
    p_render = sub.add_parser("render", help="Render tasks as TASKS.md")
    p_render.add_argument("--repo", required=True)

    # resolve
    p_resolve = sub.add_parser("resolve", help="Resolve task context")
    p_resolve.add_argument("--repo", required=True)
    p_resolve.add_argument("--branch", required=True)
    p_resolve.add_argument("--repo-dir", default="")

    # status update
    p_status = sub.add_parser("status", help="Update task status")
    p_status.add_argument("--repo", required=True)
    p_status.add_argument("--branch", required=True)
    p_status.add_argument("--status", required=True, choices=["active", "dispatched", "running", "done", "failed"])

    # delete tasks
    p_del = sub.add_parser("delete", help="Delete tasks by ID list or title pattern")
    p_del.add_argument("--ids", help="Comma-separated task IDs (e.g. 1,2,3)")
    p_del.add_argument("--pattern", help="Regex pattern to match task titles")
    p_del.add_argument("--repo", help="Limit to a specific repo")
    p_del.add_argument("--status", help="Limit to a specific status")
    p_del.add_argument("--dry-run", action="store_true", help="Show what would be deleted without deleting")
    p_del.add_argument("--force", "-f", action="store_true", help="Skip confirmation prompt")

    args = parser.parse_args()
    # Set device routing before dispatching any command
    if args.device:
        set_device(args.device)
    _run_command(args)


def _run_command(args):  # noqa: C901
    """Dispatch CLI command."""
    if args.command == "list":
        _cmd_list(args)
    elif args.command == "query":
        _cmd_query(args)
    elif args.command == "add":
        _cmd_add(args)
    elif args.command == "register":
        _cmd_register(args)
    elif args.command == "import":
        _cmd_import(args)
    elif args.command == "import-track":
        _cmd_import_track(args)
    elif args.command == "render":
        print(render_tasks_md(args.repo))
    elif args.command == "resolve":
        _cmd_resolve(args)
    elif args.command == "status":
        _cmd_status(args)
    elif args.command == "delete":
        _cmd_delete(args)


def _cmd_list(args):
    if getattr(args, "pattern", None):
        tasks = query_tasks(repo=args.repo, status=args.status, pattern=args.pattern)
    else:
        tasks = list_tasks(args.repo, args.status, args.section)
    if getattr(args, "json", False):
        print(json.dumps(tasks, indent=2, default=str))
    else:
        _print_tasks_table(tasks)


def _cmd_query(args):
    tasks = query_tasks(
        repo=args.repo, status=args.status, pattern=args.pattern,
        context_type=args.context_type, created_by=args.created_by,
        since=args.since, until=args.until, priority=args.priority,
        limit=args.limit,
    )
    if getattr(args, "json", False):
        print(json.dumps(tasks, indent=2, default=str))
    else:
        if not tasks:
            print("  (no matching tasks)")
            return
        print(f"  Found {len(tasks)} task(s):")
        print()
        _print_tasks_table(tasks)


def _cmd_add(args):
    tid = add_task(
        repo=args.repo, title=args.title, branch=args.branch, org=args.org,
        description=args.description, verification=args.verification,
        context_type=args.context_type, context_ref=args.context_ref,
        created_by=args.created_by, created_by_cli=args.created_by_cli,
        created_by_model=args.created_by_model,
    )
    print(f"  ✓ Added task #{tid}: {args.title}")


def _cmd_register(args):
    tid = register_task(
        repo=args.repo, title=args.title, branch=args.branch,
        description=args.description, verification=args.verification,
        context_ref=args.context_ref, cli=args.cli, model=args.model,
        github_issue=args.github_issue, conductor_track=args.conductor_track,
    )
    print(f"  ✓ Registered task #{tid}: {args.title}")


def _cmd_import(args):
    imported, skipped, updated = import_from_tasks_md(
        args.repo, args.tasks_file, args.created_by,
        org=args.org, force=args.force, update=args.update,
    )
    parts = [f"  ✓ Imported {imported}"]
    if skipped:
        parts.append(f"skipped {skipped}")
    if updated:
        parts.append(f"updated {updated}")
    parts_str = ", ".join(parts)
    print(f"{parts_str} tasks from {args.tasks_file}")


def _cmd_import_track(args):
    count = import_from_conductor_track(
        args.repo, args.track_dir, args.created_by, org=args.org,
    )
    track_name = Path(args.track_dir).name
    if count:
        print(f"  ✓ Imported track '{track_name}' as 1 task with subtasks")
    else:
        print(f"  · Track '{track_name}' already imported (skipped)")


def _cmd_resolve(args):
    task = get_task_by_branch(args.repo, args.branch)
    if not task:
        print(f"  ✗ No task found for {args.repo}/{args.branch}")
        sys.exit(1)
    context = resolve_context(task, args.repo_dir)
    print(context)


def _cmd_status(args):
    section_map = {
        "active": "Active", "dispatched": "In Progress",
        "running": "In Progress", "done": "Done", "failed": "Active",
    }
    update_task_by_branch(
        args.repo, args.branch,
        status=args.status,
        section=section_map.get(args.status, "Active"),
        completed_at=_now() if args.status == "done" else None,
    )
    print(f"  ✓ {args.repo}/{args.branch} → {args.status}")


def _print_tasks_table(tasks: list[dict]) -> None:
    """Print tasks in a formatted table."""
    icons = {"active": "○", "dispatched": "◐", "running": "◑", "done": "●", "failed": "✗"}
    for t in tasks:
        icon = icons.get(t["status"], "?")
        ctx = f" [{t['context_type']}]" if t["context_type"] != "inline" else ""
        repo = t.get("repo", "")
        print(f"  {icon} {repo}/Task {t['number']}: {t['title']}{ctx}")
        if t["branch"]:
            print(f"      Branch: {t['branch']}")
        if t.get("created_by"):
            by = t["created_by"]
            if t.get("created_by_model"):
                by += f" ({t['created_by_model']})"
            print(f"      By: {by}  @  {t.get('created_at', '')}")
    if not tasks:
        print("  (no tasks)")


def _cmd_delete(args):
    """Delete tasks by ID list or title pattern."""
    targets: list[dict] = []

    if args.ids:
        ids = [int(x.strip()) for x in args.ids.split(",") if x.strip().isdigit()]
        _init()
        with _db() as conn:
            for tid in ids:
                row = conn.execute("SELECT * FROM tasks WHERE id = ?", (tid,)).fetchone()
                if row:
                    targets.append(dict(row))
    elif args.pattern:
        all_tasks = query_tasks(repo=args.repo, status=args.status)
        pattern_re = re.compile(args.pattern, re.IGNORECASE)
        targets = [t for t in all_tasks if pattern_re.search(t["title"])]
    else:
        print("  ✗ Must provide --ids or --pattern")
        sys.exit(1)

    # Apply repo/status filters for ID-based delete too
    if args.ids and args.repo:
        targets = [t for t in targets if t["repo"] == args.repo]
    if args.ids and args.status:
        targets = [t for t in targets if t["status"] == args.status]

    if not targets:
        print("  (no matching tasks)")
        return

    print(f"  Will delete {len(targets)} task(s):")
    for t in targets:
        print(f"    #{t['id']} [{t['status']}] {t['repo']}/Task {t['number']}: {t['title']}")

    if args.dry_run:
        print("  (dry run — nothing deleted)")
        return

    if not args.force:
        confirm = input("  Confirm delete? [y/N] ").strip().lower()
        if confirm != "y":
            print("  Cancelled.")
            return

    for t in targets:
        delete_task(t["id"])
    print(f"  ✓ Deleted {len(targets)} task(s)")


if __name__ == "__main__":
    main()
