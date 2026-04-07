#!/usr/bin/env python3
"""Orchestrator daemon — poll→dispatch→monitor→merge loop.

Ties together the full agent workflow:
  1. Poll task sources (TASKS.md / GitHub Issues)
  2. Filter for ATC-compliant, dispatchable tasks
  3. Dispatch to agents in isolated worktrees
  4. Monitor agents for completion
  5. Validate proofs, run tests
  6. Merge safely when all done

Usage:
    # Full automated loop
    python scripts/conductor/orchestrator.py --repo-dir /path/to/repo --loop

    # One-shot: dispatch all active tasks
    python scripts/conductor/orchestrator.py --repo-dir /path/to/repo --dispatch-all

    # Check status of all running agents
    python scripts/conductor/orchestrator.py --repo-dir /path/to/repo --status

    # Run merge pipeline after all agents complete
    python scripts/conductor/orchestrator.py --repo-dir /path/to/repo --merge

    # Listen for ntfy webhook triggers (GitHub Issue events)
    python scripts/conductor/orchestrator.py --webhook --ntfy-topic my-topic
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
REPO_ROOT = SCRIPT_DIR.parent.parent


def _run(cmd: list[str], cwd: str | None = None, timeout: int = 60) -> tuple[bool, str]:
    """Run a command, return (success, output)."""
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=cwd)
        return result.returncode == 0, result.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        return False, str(e)


def _make(target: str, env: dict | None = None, timeout: int = 120) -> tuple[bool, str]:
    """Run a make target from the infra repo root."""
    cmd = ["make", "-C", str(REPO_ROOT), target]
    full_env = {**os.environ, **(env or {})}
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=full_env)
        return result.returncode == 0, result.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        return False, str(e)


# ── Task Loading ──────────────────────────────────────────────────────────────


def load_dispatchable_tasks(repo_dir: str) -> list[dict]:
    """Load tasks from TASKS.md that are ready for dispatch (fallback source)."""
    sys.path.insert(0, str(SCRIPT_DIR))
    from parse_tasks import parse_tasks_md, validate_tasks

    tasks_path = Path(repo_dir) / "TASKS.md"
    if not tasks_path.exists():
        return []

    tasks = parse_tasks_md(tasks_path.read_text())
    dispatchable = [t for t in tasks if t["section"] == "Active" and t["branch"]]

    # Validate
    warnings = validate_tasks(dispatchable)
    if warnings:
        for w in warnings:
            print(f"  ⚠ {w}")

    return dispatchable


def load_dispatchable_from_db(
    repo_name: str,
    task_ids: list[int] | None = None,
    pattern: str | None = None,
) -> list[dict]:
    """Load dispatchable tasks from the task database (primary source).

    Args:
        repo_name: Repository name.
        task_ids: If set, only return tasks with these DB IDs.
        pattern: If set, filter by title/description/branch match.

    Auto-generates branches for branchless tasks.
    """
    sys.path.insert(0, str(SCRIPT_DIR))
    from task_db import generate_branch_name, query_tasks, update_task

    tasks = query_tasks(repo=repo_name, status="active", pattern=pattern)

    # Filter by specific task IDs if provided
    if task_ids:
        tasks = [t for t in tasks if t["id"] in task_ids]

    # Auto-generate branches for branchless tasks
    for t in tasks:
        if not t.get("branch"):
            branch = generate_branch_name(
                t["title"], t.get("conductor_track", "")
            )
            update_task(t["id"], branch=branch)
            t["branch"] = branch
            print(f"  → Auto-branch: {t['title']} → {branch}")

    return [t for t in tasks if t.get("branch")]


def load_github_tasks(repo: str) -> list[dict]:
    """Load tasks from GitHub Issues labeled 'agent-task'."""
    sys.path.insert(0, str(SCRIPT_DIR))
    from github_issues import issues_to_tasks, list_issues
    from parse_tasks import parse_tasks_md

    issues = list_issues(repo)
    if not issues:
        return []

    tasks_content = issues_to_tasks(issues)
    tasks = parse_tasks_md(tasks_content)
    return [t for t in tasks if t["section"] == "Active" and t["branch"]]


# ── Dispatch ──────────────────────────────────────────────────────────────────


def dispatch_task(repo_dir: str, task: dict, cli: str = "claude", host: str | None = None) -> bool:
    """Dispatch a single task to an agent via worktree.sh."""
    env = {
        "REPO_DIR": repo_dir,
        "ACTION": "dispatch",
        "BRANCH": task["branch"],
        "TASK": f"Task {task['number']}: {task['title']}. {task.get('description', '')}",
        "AGENT_CLI": cli,
    }
    if host:
        env["HOST"] = host

    ok, output = _make("dispatch", env=env)
    if ok:
        print(f"  ✓ Dispatched Task {task['number']}: {task['title']} → {task['branch']} ({cli})")
        # Update DB status
        _update_task_status(repo_dir, task, "dispatched")
    else:
        print(f"  ✗ Failed Task {task['number']}: {output[:100]}")
        _update_task_status(repo_dir, task, "failed")
    return ok


def dispatch_all(repo_dir: str, tasks: list[dict], cli: str = "claude", host: str | None = None) -> int:
    """Dispatch all tasks. Returns count of successfully dispatched."""
    dispatched = 0
    for task in tasks:
        if dispatch_task(repo_dir, task, cli, host):
            dispatched += 1
            # Update TASKS.md status
            _move_task(repo_dir, task["number"], "In Progress")
    return dispatched


def _move_task(repo_dir: str, task_number: int, section: str) -> None:
    """Move a task to a new section in TASKS.md (legacy support)."""
    sys.path.insert(0, str(SCRIPT_DIR))
    from parse_tasks import move_task

    tasks_path = Path(repo_dir) / "TASKS.md"
    if tasks_path.exists():
        try:
            new_content = move_task(tasks_path.read_text(), task_number, section)
            tasks_path.write_text(new_content)
        except ValueError:
            pass


def _update_task_status(repo_dir: str, task: dict, status: str) -> None:
    """Update task status in DB, including timestamps."""
    sys.path.insert(0, str(SCRIPT_DIR))
    try:
        from task_db import _now, update_task_by_branch

        repo = Path(repo_dir).name
        kwargs: dict = {"status": status}
        section_map = {
            "active": "Active", "dispatched": "In Progress",
            "running": "In Progress", "done": "Done", "failed": "Active",
        }
        kwargs["section"] = section_map.get(status, "Active")
        if status == "dispatched":
            kwargs["dispatched_at"] = _now()
        elif status == "done":
            kwargs["completed_at"] = _now()
        update_task_by_branch(repo, task.get("branch", ""), **kwargs)
    except Exception as e:
        print(f"  ⚠ DB status update failed: {e}")


def _render_ephemeral_tasks(repo_dir: str) -> None:
    """Re-render TASKS.md and FAILED_TASKS.md from DB state."""
    sys.path.insert(0, str(SCRIPT_DIR))
    try:
        from task_db import query_tasks, render_tasks_md

        repo = Path(repo_dir).name
        # Render active/in-progress/done tasks
        md = render_tasks_md(repo)
        Path(repo_dir, "TASKS.md").write_text(md)

        # Render failed tasks separately
        failed = query_tasks(repo=repo, status="failed")
        if failed:
            lines = [f"# FAILED_TASKS.md — {repo}", ""]
            lines.append("> Failed tasks. Dispatch with FAILED=1 to retry.")
            lines.append("")
            for t in failed:
                lines.append(f"### Task {t['number']}: {t['title']}")
                if t.get("branch"):
                    lines.append(f"Branch: {t['branch']}")
                if t.get("description"):
                    lines.append(t["description"])
                lines.append("")
            Path(repo_dir, "FAILED_TASKS.md").write_text("\n".join(lines))
    except Exception as e:
        print(f"  ⚠ Ephemeral render failed: {e}")


def _persist_proof(repo_dir: str, task: dict, session: dict) -> None:
    """Copy PROOF.md from worktree to .artifacts/ and store in jobs DB."""
    wt_path = Path(session["path"])
    proof_path = wt_path / "PROOF.md"
    worktree_path = wt_path / "WORKTREE.md"
    if not proof_path.exists():
        return

    proof_content = proof_path.read_text()

    # Store in jobs DB
    try:
        _find_and_update_job_proof(task, proof_content)
    except Exception as e:
        print(f"  ⚠ Job proof DB update failed: {e}")

    # Copy to in-repo .artifacts/ folder
    try:
        device = os.environ.get("DEVICE_NAME", "local")
        task_id = task.get("id", 0)
        branch_slug = task.get("branch", "unknown").replace("/", "-")
        # Hash suffix from WORKTREE.md for uniqueness across re-runs
        wt_content = worktree_path.read_text() if worktree_path.exists() else ""
        wt_hash = hashlib.md5(wt_content.encode()).hexdigest()[:10]
        folder_name = f"{device}-{task_id}-{branch_slug}"
        artifacts_dir = Path(repo_dir) / ".artifacts" / folder_name
        artifacts_dir.mkdir(parents=True, exist_ok=True)

        # Copy with hash suffix
        shutil.copy2(proof_path, artifacts_dir / f"PROOF-{wt_hash}.md")
        if worktree_path.exists():
            shutil.copy2(worktree_path, artifacts_dir / f"WORKTREE-{wt_hash}.md")
        print(f"  📁 Artifacts → .artifacts/{folder_name}/")
    except Exception as e:
        print(f"  ⚠ Artifact copy failed: {e}")


def _find_and_update_job_proof(task: dict, proof_content: str) -> None:
    """Find the matching job and store proof content."""
    sys.path.insert(0, str(REPO_ROOT / "webapp"))
    from db import get_device_db, update_job_proof

    device = os.environ.get("DEVICE_NAME", "")
    task_id = task.get("id")
    if not task_id:
        return
    with get_device_db(device) as conn:
        row = conn.execute(
            "SELECT id FROM jobs WHERE task_id=? ORDER BY id DESC LIMIT 1",
            (task_id,)
        ).fetchone()
        if row:
            update_job_proof(row["id"], proof_content, device=device)


def _sync_github_issue(task: dict) -> None:
    """Post proof and close GitHub Issue for completed task."""
    github_issue = task.get("github_issue")
    github_repo = task.get("github_repo")
    if not github_issue or not github_repo:
        return
    try:
        sys.path.insert(0, str(SCRIPT_DIR))
        from github_issues import post_proof, update_status

        proof_path = task.get("proof_path", "")
        if proof_path and Path(proof_path).exists():
            post_proof(github_repo, int(github_issue), proof_path)
        update_status(github_repo, int(github_issue), "done")
        print(f"  🔗 GitHub Issue #{github_issue} → done")
    except Exception as e:
        print(f"  ⚠ GitHub sync failed: {e}")


# ── Config Loading ────────────────────────────────────────────────────────────


def _load_orchestrator_config() -> dict:
    """Load orchestrator config from merged config (defaults + local)."""
    try:
        sys.path.insert(0, str(REPO_ROOT))
        from scripts.lib.load_config import load_config
        cfg = load_config()
        return cfg.get("orchestrator", {})
    except Exception:
        pass
    return {}


# ── Garbage Collection ────────────────────────────────────────────────────────


def gc_stale_worktrees(repo_dir: str, config: dict) -> int:
    """Garbage-collect stale worktrees: dangling completed + timed-out.

    Returns count of cleaned worktrees.
    """
    gc_cfg = config.get("gc", {})
    if not gc_cfg.get("enabled", True):
        return 0

    global_timeout = config.get("task_timelimit", 120)
    archive_dir = Path(os.path.expanduser(gc_cfg.get("archive_dir", "~/.tenai/artifacts")))
    copy_artifacts = gc_cfg.get("copy_artifacts", True)
    cleaned = 0

    # Check all worktrees
    trees_dir = Path(repo_dir) / ".trees"
    if not trees_dir.exists():
        return 0

    # Get task status from DB for all branches
    repo_name = Path(repo_dir).name
    sys.path.insert(0, str(SCRIPT_DIR))
    from task_db import get_task_by_branch, update_task

    for wt in sorted(trees_dir.iterdir()):
        if not wt.is_dir():
            continue

        branch = wt.name
        task = get_task_by_branch(repo_name, branch) or get_task_by_branch(
            repo_name, branch.replace("-", "/", 1)
        )

        # Case 1: Dangling worktree (task already done/failed in DB)
        if task and task.get("status") in ("done", "failed"):
            print(f"  🗑 Dangling worktree: {branch} (status={task['status']})")
            _kill_tmux_window(repo_name, branch)
            _remove_worktree(repo_dir, wt)
            cleaned += 1
            continue

        # Case 2: Check timelimit
        session_file = wt / ".session_start"
        if not session_file.exists():
            continue

        started_at = None
        for line in session_file.read_text().strip().split("\n"):
            if "T" in line and not line.startswith("#") and "=" not in line:
                started_at = line.strip()
                break

        if not started_at:
            continue

        try:
            start = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
            elapsed_min = (datetime.now(timezone.utc) - start).total_seconds() / 60
        except (ValueError, TypeError):
            continue

        limit = (task.get("timelimit") if task else None) or global_timeout
        if limit == 0:  # 0 = never expire
            continue
        if elapsed_min <= limit:
            continue

        print(f"  ⏰ Timed out: {branch} ({int(elapsed_min)}m > {limit}m limit)")

        # Archive before removal
        if copy_artifacts:
            _archive_worktree(wt, repo_name, branch, archive_dir, started_at)

        # Copy to in-repo .artifacts/ if task info available
        if task:
            _copy_to_repo_artifacts(repo_dir, wt, task)

        # Kill + remove
        _kill_tmux_window(repo_name, branch)
        _remove_worktree(repo_dir, wt)

        # Update DB
        if task:
            update_task(task["id"], status="failed", completed_at=_now_str())

        cleaned += 1

    return cleaned


def _now_str() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _archive_worktree(
    wt: Path, repo_name: str, branch: str, archive_dir: Path, started_at: str,
) -> None:
    """Copy artifacts to ~/.tenai/artifacts/{repo}/{hash}/."""
    content_hash = hashlib.md5(f"{branch}|{started_at}".encode()).hexdigest()[:10]
    dest = archive_dir / repo_name / content_hash
    dest.mkdir(parents=True, exist_ok=True)

    for fname in ("PROOF.md", "WORKTREE.md", ".session_start"):
        src = wt / fname
        if src.exists():
            shutil.copy2(src, dest / fname)

    # Metadata
    meta = {
        "repo": repo_name, "branch": branch, "started_at": started_at,
        "archived_at": _now_str(), "reason": "gc_timeout",
    }
    (dest / "metadata.json").write_text(json.dumps(meta, indent=2))
    print(f"  📦 Archived → {dest}")


def _copy_to_repo_artifacts(repo_dir: str, wt: Path, task: dict) -> None:
    """Copy artifacts to in-repo .artifacts/ folder."""
    device = os.environ.get("DEVICE_NAME", "local")
    task_id = task.get("id", 0)
    branch_slug = task.get("branch", "unknown").replace("/", "-")
    worktree_path = wt / "WORKTREE.md"
    wt_content = worktree_path.read_text() if worktree_path.exists() else ""
    wt_hash = hashlib.md5(wt_content.encode()).hexdigest()[:10]
    folder_name = f"{device}-{task_id}-{branch_slug}"
    artifacts_dir = Path(repo_dir) / ".artifacts" / folder_name
    artifacts_dir.mkdir(parents=True, exist_ok=True)

    proof = wt / "PROOF.md"
    if proof.exists():
        shutil.copy2(proof, artifacts_dir / f"PROOF-{wt_hash}.md")
    if worktree_path.exists():
        shutil.copy2(worktree_path, artifacts_dir / f"WORKTREE-{wt_hash}.md")


def _kill_tmux_window(repo_name: str, branch: str) -> None:
    """Kill a tmux window for an agent."""
    session = f"{repo_name}-agents"
    _run(["tmux", "kill-window", "-t", f"{session}:{branch}"], timeout=5)


def _remove_worktree(repo_dir: str, wt_path: Path) -> None:
    """Remove a git worktree."""
    _run(["git", "worktree", "remove", "--force", str(wt_path)], cwd=repo_dir, timeout=30)
    # Fallback: rm -rf if git worktree remove fails
    if wt_path.exists():
        shutil.rmtree(wt_path, ignore_errors=True)


# ── Monitor ───────────────────────────────────────────────────────────────────


def check_agents(repo_dir: str) -> dict:
    """Check status of all agent sessions for this repo."""
    sys.path.insert(0, str(SCRIPT_DIR))
    from session_history import get_worktree_sessions

    sessions = get_worktree_sessions(repo_dir)
    running = [s for s in sessions if s["status"] == "running"]
    completed = [s for s in sessions if s["status"] == "completed"]
    with_proof = [s for s in sessions if s["has_proof"]]

    return {
        "total": len(sessions),
        "running": len(running),
        "completed": len(completed),
        "with_proof": len(with_proof),
        "sessions": sessions,
        "all_done": len(running) == 0 and len(sessions) > 0,
    }


# ── Merge Safety ──────────────────────────────────────────────────────────────


def run_merge_pipeline(repo_dir: str, host: str | None = None) -> bool:
    """Run the full merge safety pipeline: check-conflicts → validate → merge."""
    repo_name = Path(repo_dir).name
    env_base = {"REPO": repo_name}
    if host:
        env_base["HOST"] = host

    steps = [
        ("check-conflicts", "Checking file conflicts..."),
        ("validate-worktrees", "Validating all worktrees..."),
        ("integration-test", "Running integration test..."),
        ("merge-sequential", "Merging branches sequentially..."),
    ]

    for target, msg in steps:
        print(f"  → {msg}")
        ok, output = _make(target, env=env_base, timeout=300)
        if not ok:
            print(f"  ✗ {target} failed: {output[:200]}")
            return False
        print(f"  ✓ {target} passed")

    return True


# ── Webhook Listener ──────────────────────────────────────────────────────────


def listen_for_webhooks(ntfy_topic: str, repo_dir: str, cli: str = "claude") -> None:
    """Listen on ntfy.sh for agent-task triggers.

    Expected message format (JSON):
        {"action":"dispatch","repo":"myapp","branch":"feat/x","task":"description","cli":"claude"}
    Or plain text:
        dispatch:myapp:feat/x:task description
    """
    print(f"── Webhook Listener (ntfy.sh/{ntfy_topic}) ──")
    print(f"   Repo: {repo_dir}")
    print()

    url = f"https://ntfy.sh/{ntfy_topic}/json"
    try:
        proc = subprocess.Popen(
            ["curl", "-s", url],
            stdout=subprocess.PIPE,
            text=True,
        )
    except FileNotFoundError:
        print("  ✗ curl not found")
        return

    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
            body = msg.get("message", "")

            # Try JSON body first
            try:
                payload = json.loads(body)
                _handle_webhook_payload(payload, repo_dir, cli)
                continue
            except (json.JSONDecodeError, TypeError):
                pass

            # Try colon-separated format: action:repo:branch:task
            parts = body.split(":", 3)
            if len(parts) >= 3 and parts[0] == "dispatch":
                _handle_webhook_payload({
                    "action": "dispatch",
                    "repo": parts[1],
                    "branch": parts[2],
                    "task": parts[3] if len(parts) > 3 else "",
                }, repo_dir, cli)

        except json.JSONDecodeError:
            continue


def _handle_webhook_payload(payload: dict, default_repo_dir: str, default_cli: str) -> None:
    """Handle a parsed webhook payload."""
    action = payload.get("action", "")
    repo = payload.get("repo", "")
    branch = payload.get("branch", "")
    task = payload.get("task", "")
    cli = payload.get("cli", default_cli)

    if action == "dispatch" and branch:
        print(f"  ← Webhook: dispatch {repo}/{branch}")
        task_dict = {
            "number": 0,
            "title": task or branch,
            "branch": branch,
            "description": task,
        }
        # Resolve repo dir
        base_dir = os.path.expanduser("~/tenai-projects")
        repo_dir = str(Path(base_dir) / repo) if repo else default_repo_dir
        dispatch_task(repo_dir, task_dict, cli)

    elif action == "status":
        status = check_agents(default_repo_dir)
        print(f"  ← Status: {status['running']} running, {status['completed']} completed")

    elif action == "merge":
        print("  ← Webhook: merge triggered")
        run_merge_pipeline(default_repo_dir)

    else:
        print(f"  ← Unknown action: {action}")


# ── Orchestrator Loop ─────────────────────────────────────────────────────────


def orchestrator_loop(
    repo_dir: str,
    interval: int = 30,
    cli: str = "claude",
    host: str | None = None,
    github_repo: str | None = None,
    auto_merge: bool = True,
    task_ids: list[int] | None = None,
    pattern: str | None = None,
    one_shot: bool = False,
) -> None:
    """Full automated orchestrator loop.

    Args:
        task_ids: Only dispatch tasks with these DB IDs.
        pattern: Filter tasks by title/description/branch match.
        one_shot: Run one dispatch+check cycle then exit.
    """
    config = _load_orchestrator_config()
    max_concurrent = config.get("max_concurrent", 4)
    github_sync = config.get("github_sync", True)

    mode = "one-shot" if one_shot else f"every {interval}s"
    filter_desc = ""
    if task_ids:
        filter_desc = f"  |  IDs: {task_ids}"
    elif pattern:
        filter_desc = f"  |  Pattern: {pattern}"
    print(f"══ Orchestrator: {Path(repo_dir).name} ({mode}) ══")
    print(f"   CLI: {cli}  |  Auto-merge: {auto_merge}  |  Max: {max_concurrent}{filter_desc}")
    if github_repo:
        print(f"   GitHub: {github_repo}")
    print()

    dispatched_branches: set[str] = set()

    while True:
        try:
            # 1. Load tasks — DB is primary, TASKS.md is fallback
            repo_name = Path(repo_dir).name
            tasks = load_dispatchable_from_db(repo_name, task_ids=task_ids, pattern=pattern)

            # Fallback: also check TASKS.md for tasks not yet in DB
            if not task_ids:  # skip fallback when filtering by IDs
                md_tasks = load_dispatchable_tasks(repo_dir)
                existing_branches = {t["branch"] for t in tasks}
                tasks.extend(t for t in md_tasks if t.get("branch") not in existing_branches)

            if github_repo and not task_ids:
                gh_tasks = load_github_tasks(github_repo)
                existing_branches = {t["branch"] for t in tasks}
                tasks.extend(t for t in gh_tasks if t["branch"] not in existing_branches)

            # Sort by priority DESC (higher priority dispatched first)
            tasks.sort(key=lambda t: t.get("priority", 0), reverse=True)

            # 2. Check running agents (for parallelism cap)
            status = check_agents(repo_dir)
            running_count = status["running"]

            # 3. Dispatch new tasks (respecting parallelism cap)
            new_tasks = [t for t in tasks if t["branch"] not in dispatched_branches]
            if new_tasks:
                slots = max(0, max_concurrent - running_count)
                to_dispatch = new_tasks[:slots] if slots else []
                if len(new_tasks) > slots:
                    print(f"  → {len(new_tasks)} task(s) pending, {slots} slot(s) available")
                for task in to_dispatch:
                    if dispatch_task(repo_dir, task, cli, host):
                        dispatched_branches.add(task["branch"])

            # 4. Check running agents (post-dispatch)
            status = check_agents(repo_dir)
            if status["total"] > 0:
                print(f"  📊 {status['running']} running | {status['completed']} done | {status['with_proof']} proofs")

            # 5. Mark completed tasks as Done + persist proof
            for session in status["sessions"]:
                if session["status"] == "completed" and session["has_proof"]:
                    branch = session["branch"]
                    for task in tasks:
                        safe = task["branch"].replace("/", "-")
                        if safe == branch:
                            _update_task_status(repo_dir, task, "done")
                            _move_task(repo_dir, task["number"], "Done")
                            _persist_proof(repo_dir, task, session)
                            if github_sync:
                                _sync_github_issue(task)
                            break

            # 6. Garbage collection
            gc_cleaned = gc_stale_worktrees(repo_dir, config)
            if gc_cleaned:
                print(f"  🗑 GC: cleaned {gc_cleaned} worktree(s)")

            # 7. Re-render ephemeral TASKS.md from DB
            _render_ephemeral_tasks(repo_dir)

            # 8. One-shot mode: exit after first cycle
            if one_shot:
                print("\n  → One-shot mode: exiting after single cycle")
                break

            # 9. Auto-merge when all done
            if status["all_done"] and status["with_proof"] > 0 and auto_merge:
                print("\n  ✓ All agents done — starting merge pipeline")
                success = run_merge_pipeline(repo_dir, host)
                if success:
                    print("  ✓ Merge pipeline complete!")
                    _send_ntfy(
                        os.environ.get("NTFY_TOPIC", ""),
                        "Orchestrator: All Done",
                        f"{status['completed']} agents completed, merge successful.",
                    )
                else:
                    print("  ✗ Merge pipeline failed — manual intervention needed")
                break

            time.sleep(interval)

        except KeyboardInterrupt:
            print("\n  Orchestrator stopped.")
            break


def _send_ntfy(topic: str, title: str, message: str) -> None:
    """Send ntfy notification."""
    if not topic:
        return
    _run(["curl", "-s", "-X", "POST", f"https://ntfy.sh/{topic}",
          "-H", f"Title: {title}", "-H", "Tags: robot", "-d", message])


# ── CLI ───────────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(description="Agent orchestrator daemon")
    parser.add_argument("--repo-dir", default=os.getcwd(), help="Path to target repo")
    parser.add_argument("--cli", default="claude", help="Default CLI (claude, gemini, codex)")
    parser.add_argument("--host", default=None, help="Remote host for dispatch")
    parser.add_argument("--github-repo", default=None, help="GitHub repo (org/name) for issue sync")
    parser.add_argument("--interval", type=int, default=30, help="Poll interval (seconds)")
    parser.add_argument("--no-auto-merge", action="store_true", help="Disable automatic merge")

    # Task filtering
    parser.add_argument("--task-ids", default=None, help="Comma-separated task DB IDs to target")
    parser.add_argument("--pattern", default=None, help="Filter tasks by title/description/branch")

    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--loop", action="store_true", help="Full orchestrator loop")
    group.add_argument("--one-shot", action="store_true", help="Run one cycle then exit")
    group.add_argument("--dispatch-all", action="store_true", help="Dispatch all Active tasks")
    group.add_argument("--status", action="store_true", help="Check agent status")
    group.add_argument("--merge", action="store_true", help="Run merge pipeline")
    group.add_argument("--webhook", action="store_true", help="Listen for ntfy webhook triggers")

    parser.add_argument("--ntfy-topic", default=os.environ.get("NTFY_TOPIC", ""), help="ntfy.sh topic")

    args = parser.parse_args()
    repo_dir = str(Path(args.repo_dir).expanduser().resolve())

    # Parse task IDs
    task_ids = None
    if args.task_ids:
        task_ids = [int(x.strip()) for x in args.task_ids.split(",") if x.strip()]

    if args.loop or args.one_shot:
        orchestrator_loop(
            repo_dir, args.interval, args.cli, args.host,
            args.github_repo, not args.no_auto_merge,
            task_ids=task_ids, pattern=args.pattern,
            one_shot=args.one_shot,
        )

    elif args.dispatch_all:
        repo_name = Path(repo_dir).name
        tasks = load_dispatchable_from_db(repo_name, task_ids=task_ids, pattern=args.pattern)
        if not tasks:
            tasks = load_dispatchable_tasks(repo_dir)
        if not tasks:
            print("  No dispatchable tasks found")
            return
        count = dispatch_all(repo_dir, tasks, args.cli, args.host)
        print(f"\n  ✓ Dispatched {count}/{len(tasks)} tasks")

    elif args.status:
        status = check_agents(repo_dir)
        if status["total"] == 0:
            print("  No agent sessions found")
        else:
            print(f"  Running:   {status['running']}")
            print(f"  Completed: {status['completed']}")
            print(f"  Proofs:    {status['with_proof']}/{status['total']}")
            if status["all_done"]:
                print("  → All done. Run --merge to start merge pipeline.")

    elif args.merge:
        success = run_merge_pipeline(repo_dir, args.host)
        sys.exit(0 if success else 1)

    elif args.webhook:
        if not args.ntfy_topic:
            print("  ✗ --ntfy-topic required for webhook mode")
            sys.exit(1)
        listen_for_webhooks(args.ntfy_topic, repo_dir, args.cli)


if __name__ == "__main__":
    main()
