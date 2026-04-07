#!/bin/bash
# config/cli/hooks/scripts/post-compact-context.sh — Re-inject context after compaction
# Triggered by: SessionStart(compact) / PreCompress
# Purpose: Re-inject critical project rules after context compaction
set -euo pipefail

# Read stdin (hook input JSON) but we emit context to stdout
cat > /dev/null 2>&1 || true

# Emit critical reminders to stdout — these are injected into the session
cat <<'CONTEXT'
Reminder after compaction:
- Python: use `uv`, never `pip3`
- Run `make lint && make test` after every code change
- All scripts must be idempotent and cross-platform
- SSH commands: use create_subprocess_exec (not shell)
- Webapp runs in Docker; jobs execute via SSH, not inside container
- Do not rename marker strings (TENAI INFRA ALIASES/SSH START/END)
- Check AGENTS.md / GEMINI.md for full project rules
CONTEXT

exit 0
