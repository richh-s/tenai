#!/bin/bash
# scripts/configure/agents_md.sh — write AGENTS.md for a project
# Usage: PROJECT_DIR=/path/to/project bash scripts/configure/agents_md.sh
# AGENTS.md is the universal agent instruction file supported by most AI coding CLIs
# (OpenAI Codex CLI, Cursor, Windsurf, etc.)
set -euo pipefail

source "$(dirname "$0")/../detect.sh"

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
PROJECT_NAME="${PROJECT_NAME:-$(basename "$PROJECT_DIR")}"

write_agents_md() {
  local output="${PROJECT_DIR}/AGENTS.md"

  echo "── Writing AGENTS.md to ${output} ──"

  cat > "$output" << AGENTSMD
# AGENTS.md — ${PROJECT_NAME}

> This file is read automatically by AI coding agents (Codex CLI, Cursor, Windsurf, etc.)
> when working in this repo. It provides essential context for safe, effective contributions.

## Project Overview
<!-- Describe what this project does in 2-3 sentences -->

## Structure
<!-- Key directories and their purpose -->
| Directory | Purpose |
|-----------|---------|
| \`src/\` | <!-- Main source code --> |
| \`tests/\` | <!-- Test suite --> |
| \`docs/\` | <!-- Documentation --> |

## Environment Setup

Before running any code, set up the development environment:

1. **Check for a \`Makefile\`** — if present, run \`make help\` to discover all available targets.
   Use Makefile targets rather than raw commands — they handle environment activation,
   path setup, and cross-platform concerns automatically.
2. **Install dependencies** using the project's build system:
   \`\`\`bash
   # Examples (check Makefile or project config for actual commands):
   make install-deps       # Makefile-based projects
   uv pip install -e ".[dev]"  # Python with pyproject.toml
   npm install             # Node.js projects
   \`\`\`

## Using the Makefile

**Always check the \`Makefile\`** (if present) to discover available targets for setup, testing,
linting, deployment, and other operations. Run \`make help\` to see the full list of targets
with descriptions. Use the appropriate Makefile targets rather than running raw commands —
they handle environment activation, path setup, and cross-platform concerns automatically.

## Verification

After modifying code, **always run** the project's lint and test commands:

\`\`\`bash
# Examples (check Makefile or project config for actual commands):
make lint        # lint / static analysis
make test        # run test suite
\`\`\`

## Rules
<!-- Add project-specific rules here -->
- All scripts and commands must be idempotent (safe to re-run)
- Never hard-code secrets, IPs, or environment-specific paths — use config files or env vars
- Follow existing code patterns — do not introduce new frameworks without approval

## Do NOT
- Add secrets to any tracked file (use \`.env\`)
- Modify \`.env\`, \`*.pem\`, or \`*.key\` files
- Skip running lint and tests before committing

## Context
<!-- Anything else agents need to know about this codebase -->
AGENTSMD

  echo "✓ AGENTS.md written to $output"
}

write_agents_md
