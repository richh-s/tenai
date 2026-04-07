#!/bin/bash
# config/cli/hooks/scripts/notify.sh — Cross-platform notification hook
# Triggered by: Notification event (Claude, Gemini)
# Purpose: Alert the user when the CLI needs input
set -euo pipefail

TITLE="${HOOK_TITLE:-CLI Agent}"
MESSAGE="${HOOK_MESSAGE:-needs your attention}"

# Read stdin (hook input JSON) but we don't need it for notification
cat > /dev/null 2>&1 || true

case "$(uname -s)" in
  Darwin)
    osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\"" 2>/dev/null || true
    ;;
  Linux)
    if command -v notify-send &>/dev/null; then
      notify-send "$TITLE" "$MESSAGE" 2>/dev/null || true
    elif command -v termux-notification &>/dev/null; then
      termux-notification --title "$TITLE" --content "$MESSAGE" 2>/dev/null || true
    fi
    ;;
  MINGW*|MSYS*|CYGWIN*)
    powershell.exe -Command "[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); [System.Windows.Forms.MessageBox]::Show('$MESSAGE', '$TITLE')" 2>/dev/null || true
    ;;
esac

exit 0
