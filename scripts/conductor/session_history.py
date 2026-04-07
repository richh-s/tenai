#!/usr/bin/env python3
"""Agent session history — aggregates work logs from worktrees, tmux, and Gastown.

Provides a timeline of agent work across all worktrees for a given repo.

Sources:
  - .session_start files in worktrees (created by dispatch)
  - PROOF.md files (agent proof-of-work)
  - git log in each worktree (what changed)
  - tmux session info (running/dead)
  - Gastown hooks (if available)

Usage:
    python scripts/conductor/session_history.py /path/to/repo
    python scripts/conductor/session_history.py /path/to/repo --json
    python scripts/conductor/session_history.py /path/to/repo --summary
"""

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def _run(cmd: list[str], cwd: str | None = None) -> str | None:
    """Run a command, return stdout or None."""
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10, cwd=cwd)
        return result.stdout.strip() if result.returncode == 0 else None
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None


def get_worktree_sessions(repo_dir: str) -> list[dict]:
    """Gather session info from all worktrees."""
    trees_dir = Path(repo_dir) / ".trees"
    if not trees_dir.exists():
        return []

    sessions = []
    for wt in sorted(trees_dir.iterdir()):
        if not wt.is_dir():
            continue

        session: dict = {
            "branch": wt.name,
            "path": str(wt),
            "started": None,
            "cli": None,
            "task": None,
            "has_proof": False,
            "proof_summary": None,
            "commit_count": 0,
            "files_changed": 0,
            "status": "unknown",
            "duration": None,
        }

        # Read .session_start if present
        session_file = wt / ".session_start"
        if session_file.exists():
            for line in session_file.read_text().strip().split("\n"):
                if line and not line.startswith("#"):
                    if "=" in line:
                        key, val = line.split("=", 1)
                        if key == "cli":
                            session["cli"] = val
                        elif key == "task":
                            session["task"] = val or None
                        elif key == "session":
                            session["tmux_session"] = val
                        elif key == "window":
                            session["tmux_window"] = val
                    elif "T" in line:  # ISO timestamp
                        session["started"] = line.strip()

        # Read PROOF.md
        proof_path = wt / "PROOF.md"
        if proof_path.exists():
            session["has_proof"] = True
            content = proof_path.read_text()
            # Extract first heading after ## as summary
            for ln in content.split("\n"):
                if ln.startswith("## ") and "PROOF" not in ln.upper():
                    session["proof_summary"] = ln[3:].strip()
                    break

        # Git stats
        commits = _run(["git", "log", "--oneline", "HEAD", "--not", "origin/HEAD"], cwd=str(wt))
        if commits:
            session["commit_count"] = len(commits.strip().split("\n"))

        diff_stat = _run(["git", "diff", "--stat", "HEAD~1"], cwd=str(wt))
        if diff_stat:
            lines = diff_stat.strip().split("\n")
            if lines:
                session["files_changed"] = max(0, len(lines) - 1)

        # Check tmux status
        tmux_session = session.get("tmux_session", "")
        tmux_window = session.get("tmux_window", wt.name)
        if tmux_session:
            pane_info = _run([
                "tmux", "list-panes", "-t", f"{tmux_session}:{tmux_window}",
                "-F", "#{pane_dead}",
            ])
            if pane_info is not None:
                session["status"] = "completed" if pane_info.strip() == "1" else "running"
            else:
                session["status"] = "no_session"
        else:
            session["status"] = "no_session"

        # Calculate duration
        if session["started"]:
            try:
                start = datetime.fromisoformat(session["started"].replace("Z", "+00:00"))
                now = datetime.now(timezone.utc)
                delta = now - start
                hours = int(delta.total_seconds() // 3600)
                mins = int((delta.total_seconds() % 3600) // 60)
                session["duration"] = f"{hours}h {mins}m"
            except (ValueError, TypeError):
                pass

        sessions.append(session)

    return sessions


def get_gastown_hooks(repo_name: str) -> list[dict]:
    """Get Gastown hooks for this repo if available."""
    raw = _run(["gt", "hook", "list", "--rig", repo_name])
    if not raw:
        return []
    hooks = []
    for line in raw.strip().split("\n"):
        if line.strip():
            hooks.append({"raw": line.strip()})
    return hooks


def print_table(sessions: list[dict]) -> None:
    """Print human-readable session table."""
    status_icons = {
        "running": "◐",
        "completed": "●",
        "no_session": "○",
        "unknown": "?",
    }

    print(f"{'':2} {'Branch':<30} {'CLI':<8} {'Status':<10} {'Duration':<10} {'Proof':<6} {'Commits':<8}")
    print(f"{'':2} {'-'*30} {'-'*8} {'-'*10} {'-'*10} {'-'*6} {'-'*8}")

    for s in sessions:
        icon = status_icons.get(s["status"], "?")
        cli = s["cli"] or "?"
        duration = s["duration"] or "-"
        proof = "✓" if s["has_proof"] else "-"
        print(f"  {icon} {s['branch']:<30} {cli:<8} {s['status']:<10} {duration:<10} {proof:<6} {s['commit_count']:<8}")

        if s["task"]:
            print(f"      Task: {s['task'][:60]}")
        if s["proof_summary"]:
            print(f"      Proof: {s['proof_summary'][:60]}")


def print_summary(sessions: list[dict]) -> None:
    """Print a concise summary."""
    total = len(sessions)
    running = sum(1 for s in sessions if s["status"] == "running")
    completed = sum(1 for s in sessions if s["status"] == "completed")
    with_proof = sum(1 for s in sessions if s["has_proof"])
    total_commits = sum(s["commit_count"] for s in sessions)

    print(f"  Sessions: {total} ({running} running, {completed} completed)")
    print(f"  Proofs:   {with_proof}/{total}")
    print(f"  Commits:  {total_commits}")

    if running == 0 and completed > 0:
        print("  → All agents done. Ready for merge safety checks.")
    elif running > 0:
        print(f"  → {running} agent(s) still running.")


def main():
    parser = argparse.ArgumentParser(description="Agent session history aggregator")
    parser.add_argument("repo_dir", help="Path to repo")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    parser.add_argument("--summary", action="store_true", help="Show summary only")

    args = parser.parse_args()
    repo_dir = Path(args.repo_dir).expanduser().resolve()

    if not repo_dir.exists():
        print(f"Repo not found: {repo_dir}", file=sys.stderr)
        sys.exit(1)

    repo_name = repo_dir.name
    sessions = get_worktree_sessions(str(repo_dir))

    if not sessions:
        print(f"  No worktree sessions found for {repo_name}")
        print(f"  (looking in {repo_dir}/.trees/)")
        return

    print(f"══ Agent History: {repo_name} ══\n")

    if args.json:
        print(json.dumps(sessions, indent=2, default=str))
    elif args.summary:
        print_summary(sessions)
    else:
        print_table(sessions)
        print()
        print_summary(sessions)

    # Gastown hooks (if available)
    hooks = get_gastown_hooks(repo_name)
    if hooks:
        print(f"\n  Gastown hooks: {len(hooks)}")
        for h in hooks[:5]:
            print(f"    {h['raw']}")


if __name__ == "__main__":
    main()
