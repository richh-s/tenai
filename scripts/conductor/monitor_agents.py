#!/usr/bin/env python3
"""Agent completion monitor — watches tmux sessions for agent exits.

Daemon that polls tmux agent sessions and reacts when agents complete:
- Detects agent pane exit (tmux pane dead)
- Reads PROOF.md from the worktree
- Updates TASKS.md status (Active → Done)
- Posts proof to GitHub Issue if configured
- Sends ntfy notification
- Updates webapp job status via API

Usage:
    python scripts/conductor/monitor_agents.py --watch
    python scripts/conductor/monitor_agents.py --watch --repo myapp --interval 15
    python scripts/conductor/monitor_agents.py --check   # one-shot check
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path


def _run(cmd: list[str], timeout: int = 10) -> str | None:
    """Run a command, return stdout or None."""
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip() if result.returncode == 0 else None
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None


def get_agent_sessions(repo_filter: str | None = None) -> list[dict]:
    """Find tmux sessions that look like agent worktree sessions.

    Returns list of dicts with: session, window, pane_id, pane_dead, pane_pid, path
    """
    fmt = "#{session_name}\t#{window_name}\t#{pane_id}\t#{pane_dead}\t#{pane_pid}\t#{pane_current_path}"
    raw = _run(["tmux", "list-panes", "-a", "-F", fmt])
    if not raw:
        return []

    sessions = []
    for line in raw.split("\n"):
        parts = line.split("\t")
        if len(parts) < 6:
            continue
        session, window, pane_id, pane_dead, pane_pid, path = parts[:6]

        # Filter to agent sessions (worktrees are in .trees/)
        if "/.trees/" not in path:
            continue

        if repo_filter and repo_filter not in path:
            continue

        sessions.append({
            "session": session,
            "window": window,
            "pane_id": pane_id,
            "pane_dead": pane_dead == "1",
            "pane_pid": pane_pid,
            "path": path,
        })

    return sessions


def extract_worktree_info(path: str) -> dict:
    """Extract repo, branch, and org from a worktree path like /path/to/repo/.trees/feat-auth."""
    parts = path.split("/.trees/")
    if len(parts) < 2:
        return {"repo": "", "branch": "", "worktree_dir": path}

    repo_dir = parts[0]
    safe_branch = parts[1].rstrip("/")
    branch = safe_branch.replace("-", "/", 1)  # feat-auth → feat/auth (best guess)
    repo_name = Path(repo_dir).name

    return {
        "repo": repo_name,
        "repo_dir": repo_dir,
        "branch": branch,
        "safe_branch": safe_branch,
        "worktree_dir": path,
    }


def read_proof(worktree_dir: str) -> str | None:
    """Read PROOF.md from a worktree if it exists."""
    proof_path = Path(worktree_dir) / "PROOF.md"
    if proof_path.exists():
        return proof_path.read_text()
    return None


def send_ntfy(topic: str, title: str, message: str, tags: str = "robot") -> None:
    """Send notification via ntfy.sh."""
    if not topic:
        return
    try:
        subprocess.run(
            ["curl", "-s", "-X", "POST", f"https://ntfy.sh/{topic}",
             "-H", f"Title: {title}",
             "-H", f"Tags: {tags}",
             "-d", message],
            capture_output=True, timeout=10,
        )
    except Exception:
        pass


def update_webapp_job(api_url: str, job_data: dict) -> None:
    """Update webapp job status via API."""
    if not api_url:
        return
    try:
        subprocess.run(
            ["curl", "-s", "-X", "POST", f"{api_url}/api/jobs/update-status",
             "-H", "Content-Type: application/json",
             "-d", json.dumps(job_data)],
            capture_output=True, timeout=10,
        )
    except Exception:
        pass


def handle_completion(session_info: dict, ntfy_topic: str, webapp_url: str) -> None:
    """Handle an agent that has completed its work."""
    info = extract_worktree_info(session_info["path"])
    proof = read_proof(session_info["path"])

    status_icon = "✓" if proof else "⚠"
    proof_status = "with PROOF.md" if proof else "NO PROOF.md found"

    print(f"  {status_icon} Agent completed: {info.get('repo', '?')}/{info.get('safe_branch', '?')} ({proof_status})")

    # Try to post proof to GitHub if available
    if proof and info.get("repo"):
        # Check for org in parent path
        repo_dir = info.get("repo_dir", "")
        org_dir = Path(repo_dir).parent.name if repo_dir else ""
        if org_dir:
            gh_repo = f"{org_dir}/{info['repo']}"
            # Try to find issue number from branch name
            issue_match = re.search(r"issue/(\d+)", info.get("branch", ""))
            if issue_match:
                issue_num = issue_match.group(1)
                proof_path = Path(session_info["path"]) / "PROOF.md"
                _run([
                    sys.executable, str(Path(__file__).parent / "github_issues.py"),
                    gh_repo, "--post-proof", issue_num, str(proof_path),
                ])

    # Send ntfy notification
    send_ntfy(
        ntfy_topic,
        f"Agent Done: {info.get('repo', '?')}/{info.get('safe_branch', '?')}",
        f"Agent completed in {session_info['session']}/{session_info['window']}. {proof_status}",
        tags="white_check_mark" if proof else "warning",
    )

    # Update webapp
    if webapp_url:
        update_webapp_job(webapp_url, {
            "session": session_info["session"],
            "window": session_info["window"],
            "status": "completed" if proof else "completed_no_proof",
            "repo": info.get("repo", ""),
            "branch": info.get("branch", ""),
        })


def check_once(repo_filter: str | None, ntfy_topic: str, webapp_url: str) -> int:
    """One-shot check of all agent sessions. Returns count of completed agents."""
    sessions = get_agent_sessions(repo_filter)
    completed = 0

    for sess in sessions:
        if sess["pane_dead"]:
            handle_completion(sess, ntfy_topic, webapp_url)
            completed += 1
        else:
            info = extract_worktree_info(sess["path"])
            print(f"  ◐ Running: {info.get('repo', '?')}/{info.get('safe_branch', '?')} (pid {sess['pane_pid']})")

    if not sessions:
        print("  (no agent sessions found)")

    return completed


def watch_loop(repo_filter: str | None, interval: int, ntfy_topic: str, webapp_url: str) -> None:
    """Continuous monitoring loop."""
    seen_completed: set[str] = set()  # Track already-reported completions

    print(f"── Agent Monitor (polling every {interval}s) ──")
    if repo_filter:
        print(f"   Filtering: *{repo_filter}*")
    print()

    while True:
        try:
            sessions = get_agent_sessions(repo_filter)
            running = 0

            for sess in sessions:
                key = f"{sess['session']}:{sess['window']}:{sess['path']}"

                if sess["pane_dead"]:
                    if key not in seen_completed:
                        handle_completion(sess, ntfy_topic, webapp_url)
                        seen_completed.add(key)
                else:
                    running += 1

            if running == 0 and seen_completed:
                print(f"\n  ✓ All agents done ({len(seen_completed)} completed)")
                # Send summary ntfy
                send_ntfy(
                    ntfy_topic,
                    "All Agents Done",
                    f"{len(seen_completed)} agent(s) completed. Ready for merge safety checks.",
                    tags="tada",
                )
                break

            time.sleep(interval)

        except KeyboardInterrupt:
            print("\n  Monitoring stopped.")
            break


def main():
    parser = argparse.ArgumentParser(description="Monitor agent tmux sessions for completion")
    parser.add_argument("--watch", action="store_true", help="Continuous monitoring mode")
    parser.add_argument("--check", action="store_true", help="One-shot check")
    parser.add_argument("--repo", default=None, help="Filter by repo name")
    parser.add_argument("--interval", type=int, default=15, help="Poll interval in seconds (default: 15)")
    parser.add_argument("--ntfy-topic", default=os.environ.get("NTFY_TOPIC", ""), help="ntfy.sh topic")
    parser.add_argument("--webapp-url", default=os.environ.get("WEBAPP_URL", ""), help="Webapp API URL")

    args = parser.parse_args()

    if args.watch:
        watch_loop(args.repo, args.interval, args.ntfy_topic, args.webapp_url)
    elif args.check:
        check_once(args.repo, args.ntfy_topic, args.webapp_url)
    else:
        # Default: one-shot check
        check_once(args.repo, args.ntfy_topic, args.webapp_url)


if __name__ == "__main__":
    main()
