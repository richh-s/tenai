#!/bin/bash
# config/cli/hooks/scripts/audit-log.sh — Log tool usage for auditing
# Triggered by: PostToolUse / AfterTool
# Purpose: Append tool usage records to an audit log file
set -euo pipefail

LOG_FILE="${HOOK_AUDIT_LOG:-$HOME/.tenai/audit/cli-hooks.log}"
mkdir -p "$(dirname "$LOG_FILE")"

INPUT=$(cat)
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Use python3 for both parsing and JSON serialization to avoid:
#   1. grep -P (not portable on macOS/BSD)
#   2. Unsafe string interpolation breaking JSON output
echo "$INPUT" | python3 -c "
import json, sys

ts = '$TIMESTAMP'
try:
    data = json.load(sys.stdin)
    tool = data.get('tool_name', data.get('toolName', 'unknown'))
    session = data.get('session_id', data.get('sessionId', 'unknown'))
    event = data.get('hook_event_name', data.get('hookEventName', 'unknown'))
except Exception:
    tool, session, event = 'unknown', 'unknown', 'unknown'

# json.dumps handles escaping of special characters
print(json.dumps({'ts': ts, 'event': event, 'tool': tool, 'session': session}))
" >> "$LOG_FILE" 2>/dev/null || true

exit 0
