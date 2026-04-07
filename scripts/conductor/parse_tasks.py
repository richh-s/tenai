#!/usr/bin/env python3
"""Parse TASKS.md into structured JSON.

Reads a conductor-generated TASKS.md file and extracts tasks with their
metadata (title, branch, description, verification, section).

Usage:
    python scripts/conductor/parse_tasks.py /path/to/repo
    python scripts/conductor/parse_tasks.py /path/to/repo --section Active
    python scripts/conductor/parse_tasks.py /path/to/repo --json
    python scripts/conductor/parse_tasks.py /path/to/repo --move 1 "In Progress"
"""

import argparse
import json
import re
import sys
from pathlib import Path


def parse_tasks_md(content: str) -> list[dict]:  # noqa: C901
    """Parse TASKS.md content into a list of task dicts.

    Supports two formats:

    Canonical (dispatch-ready):
        ## Active
        ### Task 1: Title here
        Branch: feat/something
        Description text...
        Verification: `make test` passes

    Conductor checkbox format:
        ## 1. Category Name
        - [ ] **Task 1.1: Title here**
          - **Branch**: `feat/something`
          - Description text
          - **Verification**: `make test` passes
    """
    tasks = []
    current_section = "Active"
    current_task = None
    task_counter = 0

    for line in content.split("\n"):
        line_stripped = line.strip()

        # ── Section headers ──
        # Canonical: ## Active, ## In Progress, ## Done
        section_match = re.match(r"^##\s+(Active|In Progress|Done)\s*$", line_stripped)
        if section_match:
            if current_task:
                tasks.append(current_task)
                current_task = None
            current_section = section_match.group(1)
            continue

        # Conductor: ## 1. Category Name  or  ## N. Category (`path/`)
        conductor_section = re.match(
            r"^##\s+\d+\.\s+(.+)$", line_stripped
        )
        if conductor_section:
            if current_task:
                tasks.append(current_task)
                current_task = None
            # All conductor sections map to "Active" (they aren't status-based)
            continue

        # ── Task headers ──
        # Canonical: ### Task N: Title
        task_match = re.match(
            r"^###\s+Task\s+(\d+):\s*(.+)$", line_stripped
        )
        if task_match:
            if current_task:
                tasks.append(current_task)
            task_counter += 1
            current_task = _new_task(int(task_match.group(1)), task_match.group(2).strip(), current_section)
            continue

        # Conductor checkbox: - [ ] **Task 1.1: Title** or - [ ] **Task 1.1: Title here**
        checkbox_match = re.match(
            r"^-\s*\[[ x]\]\s*\*\*Task\s+([\d.]+):\s*(.+?)\*\*\s*$", line_stripped
        )
        if checkbox_match:
            if current_task:
                tasks.append(current_task)
            task_counter += 1
            title = checkbox_match.group(2).strip()
            current_task = _new_task(task_counter, title, current_section)
            continue

        # Alternative conductor: - **Task N: Title** (no checkbox)
        alt_task_match = re.match(
            r"^-\s*\*\*Task\s+([\d.]+):\s*(.+?)\*\*\s*$", line_stripped
        )
        if alt_task_match:
            if current_task:
                tasks.append(current_task)
            task_counter += 1
            title = alt_task_match.group(2).strip()
            current_task = _new_task(task_counter, title, current_section)
            continue

        if current_task is None:
            continue

        # ── Field lines ──
        # Branch: canonical or conductor
        branch_match = re.match(r"^(?:-\s*\*\*)?Branch\*?\*?:\s*`?([^`]+)`?\s*$", line_stripped)
        if branch_match:
            current_task["branch"] = branch_match.group(1).strip()
            continue

        # Context line: "Context: conductor/tracks/auth" or "Context: github:42"
        ctx_match = re.match(r"^(?:-\s*\*\*)?Context\*?\*?:\s*`?([^`]+)`?\s*$", line_stripped)
        if ctx_match:
            ref = ctx_match.group(1).strip()
            if ref.startswith("github:"):
                current_task["context_type"] = "github"
                current_task["context_ref"] = ref[7:].strip()
            elif ref.startswith("conductor/") or ref.startswith("linear:"):
                current_task["context_type"] = ref.split("/")[0].split(":")[0]
                current_task["context_ref"] = ref
            elif ref == "inline":
                current_task["context_type"] = "inline"
            else:
                current_task["context_type"] = "inline"
                current_task["context_ref"] = ref
            continue

        # Created-by line
        cb_match = re.match(r"^(?:-\s*\*\*)?Created-by\*?\*?:\s*(.+)$", line_stripped)
        if cb_match:
            raw = cb_match.group(1).strip()
            m = re.match(r"^([^(]+?)(?:\s*\(([^)]+)\))?(?:\s*@\s*.+)?$", raw)
            if m:
                current_task["created_by_cli"] = m.group(1).strip()
                current_task["created_by_model"] = (m.group(2) or "").strip()
            continue

        # Assigned / Dispatched — skip
        if re.match(r"^(?:-\s*\*\*)?(?:Assigned|Dispatched)\*?\*?:", line_stripped):
            continue

        # Verification line (canonical or conductor)
        verif_match = re.match(r"^(?:-\s*\*\*)?Verification\*?\*?:\s*`?(.+?)`?\s*$", line_stripped)
        if verif_match:
            current_task["verification"] = verif_match.group(1).strip()
            continue

        # Everything else is description
        if line_stripped and not line_stripped.startswith("<!--"):
            # Strip leading markdown list/bold markers for conductor format
            desc_text = re.sub(r"^-\s*", "", line_stripped)
            if current_task["description"]:
                current_task["description"] += " " + desc_text
            else:
                current_task["description"] = desc_text

    if current_task:
        tasks.append(current_task)

    return tasks


def _new_task(number: int, title: str, section: str) -> dict:
    """Create a new task dict with default fields."""
    return {
        "number": number,
        "title": title,
        "branch": "",
        "description": "",
        "verification": "",
        "section": section,
        "context_type": "inline",
        "context_ref": "",
        "created_by_cli": "",
        "created_by_model": "",
    }


def move_task(content: str, task_number: int, target_section: str) -> str:
    """Move a task from its current section to target_section in TASKS.md.

    Returns the modified TASKS.md content.
    """
    tasks = parse_tasks_md(content)
    task = next((t for t in tasks if t["number"] == task_number), None)
    if not task:
        raise ValueError(f"Task {task_number} not found")
    if task["section"] == target_section:
        return content  # Already in target section

    # Build the task block text
    task_block = f"### Task {task['number']}: {task['title']}\n"
    if task["branch"]:
        task_block += f"Branch: {task['branch']}\n"
    if task["description"]:
        task_block += f"{task['description']}\n"
    if task["verification"]:
        task_block += f"Verification: {task['verification']}\n"

    # Remove the task from its current section (find and remove the block)
    lines = content.split("\n")
    new_lines = []
    skip_until_next = False
    for line in lines:
        if skip_until_next:
            # Stop skipping at next task header, section header, or end
            if re.match(r"^###\s+Task\s+\d+:", line.strip()) or re.match(
                r"^##\s+", line.strip()
            ):
                skip_until_next = False
                new_lines.append(line)
            continue

        task_match = re.match(
            r"^###\s+Task\s+(\d+):", line.strip()
        )
        if task_match and int(task_match.group(1)) == task_number:
            skip_until_next = True
            continue

        new_lines.append(line)

    # Insert the task block after the target section header
    result = []
    inserted = False
    for line in new_lines:
        result.append(line)
        if not inserted and re.match(
            rf"^##\s+{re.escape(target_section)}\s*$", line.strip()
        ):
            result.append("")
            result.append(task_block.rstrip())
            result.append("")
            inserted = True

    return "\n".join(result)


def validate_tasks(tasks: list[dict]) -> list[str]:
    """Check tasks for ATC compliance. Returns list of warnings."""
    warnings = []
    branches_seen = set()

    for t in tasks:
        num = t["number"]
        if not t["branch"]:
            warnings.append(f"Task {num}: missing Branch (required for dispatch)")
        elif t["branch"] in branches_seen:
            warnings.append(
                f"Task {num}: duplicate branch '{t['branch']}' (not parallelizable)"
            )
        else:
            branches_seen.add(t["branch"])

        if not t["verification"]:
            warnings.append(f"Task {num}: missing Verification (not verifiable)")

        if not t["description"]:
            warnings.append(f"Task {num}: missing description")

    return warnings


def main():
    parser = argparse.ArgumentParser(description="Parse TASKS.md into structured data")
    parser.add_argument("repo_dir", nargs="?", default=".", help="Path to repo")
    parser.add_argument("--file", default=None, help="Task file name (default: from config or TASKS.md)")
    parser.add_argument("--section", default=None, help="Filter by section: Active, 'In Progress', Done")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    parser.add_argument("--validate", action="store_true", help="Check ATC compliance")
    parser.add_argument(
        "--move", nargs=2, metavar=("TASK_NUM", "SECTION"),
        help="Move task N to section (Active, 'In Progress', Done)",
    )
    parser.add_argument("--dispatchable", action="store_true", help="Show only tasks ready for dispatch (Active + have branch)")
    parser.add_argument("--from-github", metavar="ORG/REPO", help="Import tasks from GitHub Issues (labeled 'agent-task')")
    parser.add_argument("--to-github", metavar="ORG/REPO", help="Export Active tasks to GitHub Issues")
    args = parser.parse_args()

    repo_dir = Path(args.repo_dir).expanduser().resolve()

    # Determine tasks file name
    tasks_file = args.file or "TASKS.md"
    if not args.file:
        # Try reading from config
        try:
            sys.path.insert(0, str(Path(__file__).parent.parent.parent))
            from scripts.lib.load_config import load_config
            cfg = load_config()
            tasks_file = cfg.get("conductor", {}).get("task_output_file", "TASKS.md")
        except Exception:
            pass

    tasks_path = repo_dir / tasks_file
    if not tasks_path.exists():
        print(f"No {tasks_file} found in {repo_dir}", file=sys.stderr)
        sys.exit(1)

    content = tasks_path.read_text()

    # GitHub integration modes
    if args.from_github:
        sys.path.insert(0, str(Path(__file__).parent))
        import github_issues
        issues = github_issues.list_issues(args.from_github)
        print(github_issues.issues_to_tasks(issues))
        return

    if args.to_github:
        sys.path.insert(0, str(Path(__file__).parent))
        import github_issues
        github_issues.tasks_to_issues(args.to_github, str(tasks_path))
        return

    # Move mode
    if args.move:
        task_num = int(args.move[0])
        target = args.move[1]
        new_content = move_task(content, task_num, target)
        tasks_path.write_text(new_content)
        print(f"✓ Task {task_num} moved to '{target}'")
        return

    tasks = parse_tasks_md(content)

    # Filter
    if args.section:
        tasks = [t for t in tasks if t["section"] == args.section]
    if args.dispatchable:
        tasks = [t for t in tasks if t["section"] == "Active" and t["branch"]]

    # Validate
    if args.validate:
        warnings = validate_tasks(tasks)
        if warnings:
            for w in warnings:
                print(f"⚠ {w}", file=sys.stderr)
            sys.exit(1)
        else:
            print("✓ All tasks pass ATC filter")
            return

    # Output
    if args.json:
        print(json.dumps(tasks, indent=2))
    else:
        for t in tasks:
            status = {"Active": "○", "In Progress": "◐", "Done": "●"}.get(t["section"], "?")
            print(f"  {status} Task {t['number']}: {t['title']}")
            if t["branch"]:
                print(f"    Branch: {t['branch']}")
            if t["verification"]:
                print(f"    Verify: {t['verification']}")
            print()


if __name__ == "__main__":
    main()
