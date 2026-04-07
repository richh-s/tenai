#!/bin/bash
# scripts/configure/claude_md.sh — write CLAUDE.md for a project
# Usage: PROJECT_DIR=/path/to/project bash scripts/configure/claude_md.sh
set -euo pipefail

source "$(dirname "$0")/../detect.sh"

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
PROJECT_NAME="${PROJECT_NAME:-$(basename "$PROJECT_DIR")}"

write_claude_md() {
  local output="${PROJECT_DIR}/CLAUDE.md"

  echo "── Writing CLAUDE.md to ${output} ──"

  cat > "$output" << CLAUDEMD
# CLAUDE.md — ${PROJECT_NAME}

## Project Overview
<!-- Describe what this project does in 2-3 sentences -->

## Architecture
<!-- High-level system diagram or description -->

## Key Files
| File | Purpose |
|------|---------|
| \`README.md\` | Project overview |
| \`TASKS.md\` | Active task backlog |

## Environment Setup

Before running any code, check the project's build system for setup commands:

\`\`\`bash
# If the project has a Makefile:
make install-deps   # or: make install, make setup — check Makefile for the right target
# If using Python with pyproject.toml:
uv venv .venv && uv pip install -e ".[dev]"
# If using Node.js:
npm install
\`\`\`

## Using the Makefile

**Always check the \`Makefile\`** (if present) to discover available targets for setup, testing,
linting, deployment, and other operations. Run \`make help\` to see the full list of targets
with descriptions. Use the appropriate Makefile targets rather than running raw commands —
they handle environment activation, path setup, and cross-platform concerns automatically.

## Development

After making changes, always run the project's lint and test commands:

\`\`\`bash
# Example (check Makefile or package.json for actual commands):
make lint       # or: npm run lint, cargo clippy, etc.
make test       # or: npm test, cargo test, pytest, etc.
\`\`\`

## Completion Workflow

When you finish your task, follow this exact sequence:

1. Run lint and test: \`make lint && make test\` (or check Makefile for actual commands)
2. Create \`PROOF.md\` with: test results, files changed, walkthrough
3. Commit: \`git add -A && git commit -m "feat: <summary>"\`
4. Push: \`git push -u origin <branch>\`
5. Create PR: \`gh pr create --base main --fill 2>/dev/null || true\`
6. Exit

## Allowed Commands

The following commands are pre-approved and will not prompt for confirmation:
\`git\`, \`gh\`, \`make\`, \`curl\`, \`npm\`, \`python\`, \`cat\`, \`ls\`, \`grep\`, \`find\`

## Do Not
- Install system packages or tools (no \`apt\`, \`brew\`, \`npm -g\`, \`pip install\`)
- Modify files outside your task's scope
- Commit \`.env\` files
- Debug infrastructure issues (SSH, auth, permissions) — report them and move on

## Context
\<!-- Anything else Claude needs to know about this codebase --\>
CLAUDEMD

  echo "✓ CLAUDE.md written to $output"
}

write_tasks_md() {
  local output="${PROJECT_DIR}/TASKS.md"

  if [[ -f "$output" ]]; then
    echo "✓ TASKS.md already exists — skipping"
    return
  fi

  cat > "$output" << TASKSMD
# TASKS.md — ${PROJECT_NAME}

> Backlog for AI agent task dispatch. Each task must be self-contained and verifiable.

## Active
- [ ] TASK-001: Set up project structure
- [ ] TASK-002: Write initial tests
- [ ] TASK-003: Configure CI/CD

## In Progress
<!-- Move tasks here when working on them -->

## Done
<!-- Move completed tasks here -->

## Notes
<!-- Context for future tasks -->
TASKSMD

  echo "✓ TASKS.md written to $output"
}

write_claude_md
write_tasks_md
