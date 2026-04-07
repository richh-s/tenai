#!/bin/bash
# config/cli/hooks/scripts/protect-files.sh — Block edits to protected files
# Triggered by: PreToolUse / BeforeTool (Edit|Write|write_file|replace)
# Purpose: Prevent accidental edits to .env, lockfiles, .git/
set -euo pipefail

INPUT=$(cat)

# Try to extract file_path from tool_input — works across all CLIs
FILE_PATH=""
if command -v jq &>/dev/null; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || echo "")
else
  # Fallback: python3 JSON parsing (portable — no grep -P dependency)
  FILE_PATH=$(echo "$INPUT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    ti = data.get('tool_input', {})
    print(ti.get('file_path', '') or ti.get('path', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")
fi

# No file path found — allow the action
[[ -z "$FILE_PATH" ]] && exit 0

# Protected patterns
PROTECTED_PATTERNS=(
  ".env"
  "package-lock.json"
  "yarn.lock"
  "pnpm-lock.yaml"
  "Gemfile.lock"
  "poetry.lock"
  ".git/"
)

for pattern in "${PROTECTED_PATTERNS[@]}"; do
  if [[ "$FILE_PATH" == *"$pattern"* ]]; then
    echo "Blocked: $FILE_PATH matches protected pattern '$pattern'" >&2
    exit 2
  fi
done

exit 0
