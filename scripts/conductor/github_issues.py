#!/usr/bin/env python3
"""GitHub Issues adapter for the agent orchestration system.

Bridges TASKS.md ↔ GitHub Issues using the `gh` CLI.

Usage:
    # List issues labeled 'agent-task'
    python scripts/conductor/github_issues.py ORG/REPO --list

    # Import GitHub issues to TASKS.md format
    python scripts/conductor/github_issues.py ORG/REPO --to-tasks

    # Export TASKS.md tasks to GitHub issues
    python scripts/conductor/github_issues.py ORG/REPO --from-tasks /path/to/TASKS.md

    # Post proof-of-work as issue comment
    python scripts/conductor/github_issues.py ORG/REPO --post-proof 42 /path/to/PROOF.md

    # Update issue status (label swap)
    python scripts/conductor/github_issues.py ORG/REPO --update-status 42 done
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


AGENT_LABEL = "agent-task"
STATUS_LABELS = {
    "active": "status:active",
    "in-progress": "status:in-progress",
    "done": "status:done",
}


def _gh(*args: str) -> str | None:
    """Run a gh CLI command and return stdout, or None on failure."""
    try:
        result = subprocess.run(
            ["gh", *args],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode != 0:
            print(f"  ⚠ gh {' '.join(args[:3])}...: {result.stderr.strip()}", file=sys.stderr)
            return None
        return result.stdout.strip()
    except FileNotFoundError:
        print("  ⊘ gh CLI not installed", file=sys.stderr)
        sys.exit(1)
    except subprocess.TimeoutExpired:
        print("  ⚠ gh command timed out", file=sys.stderr)
        return None


def list_issues(repo: str, status: str | None = None) -> list[dict]:
    """List GitHub issues labeled with 'agent-task'."""
    label_filter = AGENT_LABEL
    if status and status in STATUS_LABELS:
        label_filter += f",{STATUS_LABELS[status]}"

    raw = _gh(
        "issue", "list",
        "--repo", repo,
        "--label", label_filter,
        "--json", "number,title,body,labels,state,assignees",
        "--limit", "50",
    )
    if not raw:
        return []
    return json.loads(raw)


def issues_to_tasks(issues: list[dict]) -> str:
    """Convert GitHub issues to TASKS.md format."""
    sections: dict[str, list[str]] = {"Active": [], "In Progress": [], "Done": []}

    for issue in issues:
        labels = [lb["name"] for lb in issue.get("labels", [])]
        if "status:done" in labels:
            section = "Done"
        elif "status:in-progress" in labels:
            section = "In Progress"
        else:
            section = "Active"

        body = issue.get("body", "") or ""
        # Try to extract branch from body
        branch_match = re.search(r"Branch:\s*(\S+)", body)
        branch = branch_match.group(1) if branch_match else f"issue/{issue['number']}"

        # Try to extract verification from body
        verif_match = re.search(r"Verification:\s*(.+)", body)
        verification = verif_match.group(1).strip() if verif_match else ""

        # Clean description (remove metadata lines)
        desc_lines = []
        for line in body.split("\n"):
            if not re.match(r"^(Branch|Verification):", line.strip()):
                desc_lines.append(line.strip())
        description = " ".join(ln for ln in desc_lines if ln)

        block = f"### Task {issue['number']}: {issue['title']}\n"
        block += f"Branch: {branch}\n"
        if description:
            block += f"{description}\n"
        if verification:
            block += f"Verification: {verification}\n"

        sections[section].append(block)

    output = "# TASKS.md\n\n"
    for sec_name in ["Active", "In Progress", "Done"]:
        output += f"## {sec_name}\n\n"
        for task_block in sections[sec_name]:
            output += task_block + "\n"
    return output


def tasks_to_issues(repo: str, tasks_path: str) -> None:
    """Create GitHub issues from TASKS.md tasks."""
    # Import parse_tasks from sibling module
    sys.path.insert(0, str(Path(__file__).parent))
    from parse_tasks import parse_tasks_md

    content = Path(tasks_path).read_text()
    tasks = parse_tasks_md(content)

    for task in tasks:
        if task["section"] != "Active":
            continue  # Only create issues for Active tasks

        body = ""
        if task["branch"]:
            body += f"Branch: {task['branch']}\n"
        if task["description"]:
            body += f"\n{task['description']}\n"
        if task["verification"]:
            body += f"\nVerification: {task['verification']}\n"

        status_label = STATUS_LABELS.get(task["section"].lower().replace(" ", "-"), STATUS_LABELS["active"])

        result = _gh(
            "issue", "create",
            "--repo", repo,
            "--title", f"Task {task['number']}: {task['title']}",
            "--body", body,
            "--label", f"{AGENT_LABEL},{status_label}",
        )
        if result:
            print(f"  ✓ Created: {result}")


def post_proof(repo: str, issue_number: int, proof_path: str) -> None:
    """Post PROOF.md content as an issue comment."""
    proof_content = Path(proof_path).read_text()
    comment = f"## 🤖 Agent Proof of Work\n\n{proof_content}"

    result = _gh(
        "issue", "comment",
        "--repo", repo,
        str(issue_number),
        "--body", comment,
    )
    if result is not None:
        print(f"  ✓ Posted proof to issue #{issue_number}")


def update_status(repo: str, issue_number: int, new_status: str) -> None:
    """Update issue status by swapping labels."""
    if new_status not in STATUS_LABELS:
        print(f"  ✗ Unknown status: {new_status} (use: active, in-progress, done)", file=sys.stderr)
        return

    # Remove old status labels
    for label in STATUS_LABELS.values():
        _gh("issue", "edit", "--repo", repo, str(issue_number), "--remove-label", label)

    # Add new status label
    _gh("issue", "edit", "--repo", repo, str(issue_number), "--add-label", STATUS_LABELS[new_status])

    # Close if done
    if new_status == "done":
        _gh("issue", "close", "--repo", repo, str(issue_number))
        print(f"  ✓ Issue #{issue_number} → done (closed)")
    else:
        print(f"  ✓ Issue #{issue_number} → {new_status}")


def main():
    parser = argparse.ArgumentParser(description="GitHub Issues ↔ TASKS.md adapter")
    parser.add_argument("repo", help="GitHub repo (org/repo)")
    parser.add_argument("--list", action="store_true", help="List agent-task issues")
    parser.add_argument("--status", default=None, help="Filter by status (active, in-progress, done)")
    parser.add_argument("--to-tasks", action="store_true", help="Convert issues → TASKS.md format")
    parser.add_argument("--from-tasks", metavar="PATH", help="Create issues from TASKS.md")
    parser.add_argument("--post-proof", nargs=2, metavar=("ISSUE", "PATH"), help="Post PROOF.md to issue")
    parser.add_argument("--update-status", nargs=2, metavar=("ISSUE", "STATUS"), help="Update issue status")

    args = parser.parse_args()

    if args.list or (not args.to_tasks and not args.from_tasks and not args.post_proof and not args.update_status):
        issues = list_issues(args.repo, args.status)
        for iss in issues:
            labels = [lb["name"] for lb in iss.get("labels", [])]
            status = "●" if "status:done" in labels else "◐" if "status:in-progress" in labels else "○"
            print(f"  {status} #{iss['number']}: {iss['title']}")

    elif args.to_tasks:
        issues = list_issues(args.repo)
        print(issues_to_tasks(issues))

    elif args.from_tasks:
        tasks_to_issues(args.repo, args.from_tasks)

    elif args.post_proof:
        post_proof(args.repo, int(args.post_proof[0]), args.post_proof[1])

    elif args.update_status:
        update_status(args.repo, int(args.update_status[0]), args.update_status[1])


if __name__ == "__main__":
    main()
