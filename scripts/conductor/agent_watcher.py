#!/usr/bin/env python3
"""Agent Watcher — polls GitHub for CI/review feedback and routes to agent sessions.

The default notification mode (replaces ntfy.sh). Monitors agent pushes
recorded in watcher.db, polls GitHub via `gh api` for CI results and PR
reviews, and injects feedback into the agent's tmux session via send-keys.

Usage:
    python agent_watcher.py --watch                     # continuous daemon
    python agent_watcher.py --check                     # one-shot check
    python agent_watcher.py --status                    # show active watches
    python agent_watcher.py --watch --interval 15       # custom poll interval

Requires: gh (GitHub CLI, authenticated), tmux
"""

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from watcher_db import (  # noqa: E402
    add_seen_review,
    get_active_watches,
    increment_cycle,
    list_watches,
    record_action,
    update_watch,
)


# ── Helpers ───────────────────────────────────────────────────────────────────


def _run(cmd: list[str], timeout: int = 30) -> tuple[bool, str]:
    """Run a command, return (success, stdout)."""
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return result.returncode == 0, result.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False, ""


def _log(msg: str) -> None:
    print(f"  {msg}", flush=True)


def _get_hostname() -> str:
    """Get the local hostname (fallback for missing DEVICE_NAME)."""
    import socket

    return socket.gethostname()


def _load_config() -> dict:
    """Load agent_watcher config from merged config (defaults + local)."""
    defaults = {
        "poll_interval": 30,
        "watch_duration": 3600,
        "max_review_cycles": 3,
        "exclude_logins": [],
        "review_notify_enabled": True,
    }
    try:
        sys.path.insert(0, str(SCRIPT_DIR.parent.parent))
        from scripts.lib.load_config import load_config
        cfg = load_config()
        ci = cfg.get("ci", {})
        watcher = ci.get("agent_watcher", {})
        review = ci.get("review_notify", {})
        return {
            "poll_interval": watcher.get("poll_interval", 30),
            "watch_duration": watcher.get("watch_duration", 3600),
            "max_review_cycles": watcher.get("max_review_cycles", 3),
            "exclude_logins": review.get("exclude_logins", []),
            "review_notify_enabled": review.get("enabled", True),
        }
    except Exception:
        pass
    return defaults


# ── TSID Parsing ──────────────────────────────────────────────────────────────


def parse_tsid(tsid: str) -> dict:
    """Parse TSID string into components.

    Format: device:owner/repo:branch:session:window
    """
    parts = tsid.split(":", 4)
    result = {"device": "", "repo": "", "branch": "", "session": "", "window": ""}
    if len(parts) >= 1:
        result["device"] = parts[0]
    if len(parts) >= 2:
        result["repo"] = parts[1]
    if len(parts) >= 3:
        result["branch"] = parts[2]
    if len(parts) >= 4:
        result["session"] = parts[3]
    if len(parts) >= 5:
        result["window"] = parts[4]
    return result


# ── GitHub Polling ────────────────────────────────────────────────────────────


def poll_ci_status(watch: dict) -> dict | None:
    """Check latest CI run for the branch.

    Returns dict with: status, conclusion, html_url, run_id (or None).
    Filters by branch in Python to avoid jq injection from branch names.
    """
    repo = watch["repo"]
    branch = watch["branch"]

    ok, output = _run([
        "gh", "api", f"repos/{repo}/actions/runs",
        "--jq", (
            "[.workflow_runs[] | "
            "{status: .status, conclusion: .conclusion, "
            "html_url: .html_url, run_id: .id, branch: .head_branch}]"
        ),
    ])

    if not ok or not output:
        return None

    try:
        runs = json.loads(output)
    except (json.JSONDecodeError, TypeError):
        return None

    # Filter by branch in Python (safe from injection)
    matching = [r for r in runs if r.get("branch") == branch]
    if not matching:
        return None
    # Return most recent (list is already sorted by API)
    data = matching[0]
    return data if data.get("status") else None


def poll_pr_reviews(watch: dict, exclude_logins: list[str] | None = None) -> list[dict]:
    """Get reviews on the PR, filtering by exclude list.

    Returns list of dicts with: id, user, state, body, html_url.
    """
    pr_number = watch.get("pr_number", 0)
    if not pr_number:
        return []

    repo = watch["repo"]
    ok, output = _run([
        "gh", "api", f"repos/{repo}/pulls/{pr_number}/reviews",
        "--jq", (
            "[.[] | {id: .id, user: .user.login, state: .state, "
            "body: .body, html_url: .html_url}]"
        ),
    ])

    if not ok or not output:
        return []

    try:
        reviews = json.loads(output)
    except (json.JSONDecodeError, TypeError):
        return []

    # Filter excludes
    excludes = set(exclude_logins or [])
    seen = set(json.loads(watch.get("seen_reviews", "[]")))

    return [
        r for r in reviews
        if r.get("id") and r["id"] not in seen
        and r.get("user", "") not in excludes
        and (r.get("body") or r.get("state") != "COMMENTED")
    ]


# ── tmux Routing ──────────────────────────────────────────────────────────────


def _tmux_session_exists(session: str, window: str = "") -> bool:
    """Check if a tmux session (and optionally window) exists."""
    if not session:
        return False
    ok, _ = _run(["tmux", "has-session", "-t", session], timeout=5)
    if not ok:
        return False
    if window:
        ok, windows = _run([
            "tmux", "list-windows", "-t", session, "-F", "#{window_name}",
        ], timeout=5)
        return ok and window in windows.split("\n")
    return True


def _sanitize_for_tmux(message: str) -> str:
    """Sanitize message for safe tmux send-keys injection.

    Replaces newlines/control chars and escapes single quotes.
    """
    import re

    msg = re.sub(r"[\r\n]+", " | ", message)  # flatten newlines
    msg = re.sub(r"[\x00-\x1f\x7f]", "", msg)  # strip control chars
    msg = msg.replace("'", "'\\''")
    return msg[:500]


def send_to_session(watch: dict, message: str) -> bool:
    """Send feedback to agent's tmux session. Returns True if delivered."""
    tsid_parts = parse_tsid(watch["tsid"])
    device = tsid_parts["device"]
    session = tsid_parts["session"]
    window = tsid_parts["window"]

    # Fail closed: if TSID has a device but DEVICE_NAME isn't set, skip
    local_device = os.environ.get("DEVICE_NAME", "") or _get_hostname()
    if device and device != local_device:
        return False  # not for this device

    if not session:
        return False

    target = f"{session}:{window}" if window else session

    if not _tmux_session_exists(session, window):
        return False

    safe_msg = _sanitize_for_tmux(message)
    _run(["tmux", "send-keys", "-t", target, "", ""])  # unstick
    _run(["tmux", "send-keys", "-t", target,
          f"echo '=== WATCHER: {safe_msg} ==='", "Enter"])
    return True


def _dead_queue(watch: dict, message: str) -> None:
    """Record undelivered message to dead-queue (actions table)."""
    record_action(
        watch["id"], watch["tsid"], "dead_queue",
        body=message, delivered=False,
    )
    _log(f"📭 Dead-queue: {watch['tsid'][:40]} — {message[:60]}")


# ── Signal Formatting ────────────────────────────────────────────────────────


def format_ci_signal(ci: dict) -> str:
    """Format CI status into a message for the agent."""
    conclusion = ci.get("conclusion", "pending")
    status = ci.get("status", "")
    run_id = ci.get("run_id", "")

    if status == "in_progress":
        return f"CI running (run {run_id})..."

    if conclusion == "success":
        return f"✅ CI PASSED (run {run_id}). Tests green — ready to merge or continue."
    if conclusion == "failure":
        return (
            f"❌ CI FAILED (run {run_id}). "
            f"Fix issues and push again. Check: gh run view {run_id} --log-failed"
        )
    return f"CI {conclusion} (run {run_id})"


def format_review(review: dict) -> str:
    """Format a PR review into a message for the agent."""
    user = review.get("user", "unknown")
    state = review.get("state", "")
    body = (review.get("body") or "")[:300]

    emoji = "💬"
    if state == "APPROVED":
        emoji = "✅"
    elif state == "CHANGES_REQUESTED":
        emoji = "🔴"

    msg = f"{emoji} Review by {user} ({state})"
    if body:
        msg += f": {body}"
    return msg


# ── Main Loop ─────────────────────────────────────────────────────────────────


def _deliver_or_queue(watch: dict, msg: str, action_type: str) -> bool:
    """Deliver message to tmux session or add to dead-queue."""
    delivered = send_to_session(watch, msg)
    if delivered:
        record_action(watch["id"], watch["tsid"], action_type, body=msg, delivered=True)
    else:
        _dead_queue(watch, msg)
    return delivered


def _check_ci_for_watch(watch: dict) -> int:
    """Check CI status for a single watch. Returns 1 if action taken, 0 otherwise."""
    ci = poll_ci_status(watch)
    if not ci or not ci.get("conclusion"):
        return 0

    ci_key = f"{ci.get('run_id')}:{ci.get('conclusion')}"
    if ci_key == watch.get("last_ci_status"):
        return 0

    msg = format_ci_signal(ci)
    delivered = _deliver_or_queue(watch, msg, "ci_signal")
    if delivered:
        _log(f"  → CI signal delivered: {ci.get('conclusion')}")
    update_watch(watch["id"], last_ci_status=ci_key)
    return 1


def _check_reviews_for_watch(watch: dict, exclude_logins: list[str]) -> int:
    """Check PR reviews for a single watch. Returns count of actions taken."""
    if not watch.get("pr_number"):
        return 0
    reviews = poll_pr_reviews(watch, exclude_logins)
    for review in reviews:
        msg = format_review(review)
        delivered = _deliver_or_queue(watch, msg, "review")
        if delivered:
            _log(f"  → Review delivered: {review.get('user')} ({review.get('state')})")
        add_seen_review(watch["id"], review["id"])

    if reviews:
        increment_cycle(watch["id"])
    return len(reviews)


def check_once(config: dict) -> int:
    """One-shot check of all active watches. Returns count of actions taken."""
    watches = get_active_watches()
    actions = 0

    if not watches:
        _log("No active watches")
        return 0

    exclude_logins = config.get("exclude_logins", [])
    review_enabled = config.get("review_notify_enabled", True)
    for watch in watches:
        _log(f"Checking: {watch['tsid'][:50]} (PR#{watch['pr_number']})")
        actions += _check_ci_for_watch(watch)
        if review_enabled:
            actions += _check_reviews_for_watch(watch, exclude_logins)

    return actions


def watch_loop(config: dict) -> None:
    """Continuous daemon loop."""
    interval = config.get("poll_interval", 30)
    print(f"══ Agent Watcher Daemon (every {interval}s) ══")
    print(f"   Device: {os.environ.get('DEVICE_NAME', '(unset)')}")
    print(f"   Config: poll={interval}s, duration={config.get('watch_duration', 3600)}s, "
          f"max_cycles={config.get('max_review_cycles', 3)}")
    print()

    while True:
        try:
            watches = get_active_watches()
            if watches:
                _log(f"── Checking {len(watches)} active watch(es) ──")
                check_once(config)
            time.sleep(interval)
        except KeyboardInterrupt:
            print("\n  Watcher stopped.")
            break


def show_status() -> None:
    """Show current watcher state."""
    active = list_watches("active")
    expired = list_watches("expired")

    print("══ Agent Watcher Status ══")
    print(f"  Active:  {len(active)}")
    print(f"  Expired: {len(expired)}")
    print()

    if active:
        print("── Active Watches ──")
        for w in active:
            print(f"  #{w['id']} {w['tsid'][:50]}")
            print(f"    PR#{w['pr_number']} | cycles={w['cycles']}/{w['max_cycles']} "
                  f"| CI={w['last_ci_status'] or 'none'}")
            print(f"    pushed={w['pushed_at']} expires={w['expires_at']}")
    else:
        print("  (no active watches)")


# ── CLI ───────────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(description="Agent Watcher daemon")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--watch", action="store_true", help="Continuous daemon loop")
    group.add_argument("--check", action="store_true", help="One-shot check")
    group.add_argument("--status", action="store_true", help="Show active watches")

    parser.add_argument("--interval", type=int, default=None, help="Override poll interval")

    args = parser.parse_args()
    config = _load_config()

    if args.interval:
        config["poll_interval"] = args.interval

    if args.watch:
        watch_loop(config)
    elif args.check:
        actions = check_once(config)
        if actions:
            print(f"\n  ✓ {actions} action(s) taken")
    elif args.status:
        show_status()


if __name__ == "__main__":
    main()
