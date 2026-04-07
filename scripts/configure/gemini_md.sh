#!/bin/bash
# scripts/configure/gemini_md.sh — write GEMINI.md for Conductor task generation
set -euo pipefail
source "$(dirname "$0")/../detect.sh"

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
PROJECT_NAME="${PROJECT_NAME:-$(basename "$PROJECT_DIR")}"

cat > "${PROJECT_DIR}/GEMINI.md" << GEMINIMD
# GEMINI.md — ${PROJECT_NAME}
# Conductor configuration for Gemini CLI task generation
# This file guides the Gemini Conductor to generate ATC-passing tasks for AI coding agents.

## Project Identity
- **Name**: ${PROJECT_NAME}
- **Type**: <!-- e.g. Python API / React app / ML pipeline / CLI tool -->
- **Primary language**: <!-- Python / TypeScript / Rust / etc -->

## Environment Setup

Before running any code, check the project's build system for setup commands.
If the project has a \`Makefile\`, **always check it first** to discover available targets
for setup, testing, linting, deployment, and other operations. Run \`make help\` to see
all targets. Use Makefile targets rather than raw commands — they handle environment
activation, path setup, and cross-platform concerns automatically.

## Conductor Workflow
You are the task architect for this project. Your job is:
1. **Spec** — Analyze the codebase. Understand current state, gaps, and goals.
2. **Plan** — Decompose work into parallelizable micro-tasks.
3. **Write** — Populate TASKS.md with ATC-passing tasks for AI coding agents.

## ATC Filter (every task MUST pass all 5)
- **Self-Contained**: Agent needs only repo + spec. No human clarification mid-task.
- **Verifiable**: Deterministic success criterion (test passes, lint clean, file exists).
- **Bounded**: Fits in ~4K–8K tokens of context. One module/file/feature max.
- **Parallelizable**: No file conflicts with 3 other concurrent tasks.
- **Resume-safe**: If agent crashes, it can recover from last commit.

## Task Format (write to TASKS.md)
\`\`\`markdown
- [ ] TASK-NNN: <imperative verb> <specific scope> | verify: <test/lint/check command> | worktree: <suggested branch name>
\`\`\`

Examples:
\`\`\`markdown
- [ ] TASK-001: Add unit tests for AuthService.login() covering success, wrong-password, and user-not-found cases | verify: pytest tests/test_auth.py -v | worktree: feat/auth-tests
- [ ] TASK-002: Refactor database.py to use connection pooling via SQLAlchemy pool_size=10 | verify: make test && python -c "from database import engine; print(engine.pool.size())" | worktree: feat/db-pooling
- [ ] TASK-003: Add OpenAPI docstrings to all endpoints in routes/api.py | verify: python -m pytest tests/test_docs.py | worktree: feat/api-docs
\`\`\`

## Project-Specific Context
<!-- Fill this section with key architecture decisions, naming conventions, etc. -->

### Architecture Overview
<!-- e.g. FastAPI + PostgreSQL + Redis, deployed on a server device -->

### Key Modules
<!-- List the main files/modules agents should know about -->

### Constraints
- Never modify: \`.env\`, \`*.pem\`, \`*.key\`, \`migrations/\`
- Always run lint and test commands before committing (check the \`Makefile\` or \`package.json\` for exact targets)
- Branch naming: \`feat/<scope>\`, \`fix/<scope>\`, \`test/<scope>\`
- **Always check the \`Makefile\`** (if present) to discover available targets. Run \`make help\` to see all targets.

### Current Epics
<!-- High-level goals for the Conductor to decompose -->
1. <!-- Epic 1 -->
2. <!-- Epic 2 -->
3. <!-- Epic 3 -->

## Output Instructions
When generating tasks:
1. Write all tasks to \`TASKS.md\` under the \`## Active\` section
2. Order by priority (highest value, lowest risk first)
3. Ensure no two tasks operate on the same primary file
4. Include the \`worktree:\` field for every task
5. Aim for 5–10 tasks per generation session

## Agent Completion Workflow
Dispatched agents should follow this exact sequence after implementation:

1. Run lint and test: \`make lint && make test\` (or project-specific commands)
2. Create \`PROOF.md\` with: test results, files changed, walkthrough
3. Commit: \`git add -A && git commit -m "feat: <summary>"\`
4. Push: \`git push -u origin <branch>\`
5. Create PR: \`gh pr create --base main --fill 2>/dev/null || true\`
6. Exit

## Agent Restrictions
- Do NOT install system packages (no \`apt\`, \`brew\`, \`npm -g\`, \`pip install\`)
- Do NOT debug infrastructure issues (SSH, auth, permissions) — report and move on
- Do NOT commit \`.env\` files
GEMINIMD

echo "✓ GEMINI.md written to ${PROJECT_DIR}/GEMINI.md"
