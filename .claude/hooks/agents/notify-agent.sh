#!/bin/bash
# ============================================================
# Agent: notify-agent
# Purpose: Desktop notification when Claude needs attention
# Events: Notification
# Blocking: no
# ============================================================

set -uo pipefail

INPUT=$(cat)
MESSAGE=$(echo "$INPUT" | jq -r '.message // "Claude Code needs your attention"' 2>/dev/null)

# Linux (WSL2 or native)
if command -v notify-send &>/dev/null; then
  notify-send "Claude Code" "$MESSAGE" 2>/dev/null || true
# macOS
elif command -v osascript &>/dev/null; then
  osascript -e "display notification \"$MESSAGE\" with title \"Claude Code\"" 2>/dev/null || true
# Windows (WSL2 fallback via powershell.exe)
elif command -v powershell.exe &>/dev/null; then
  powershell.exe -Command "[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); [System.Windows.Forms.MessageBox]::Show('$MESSAGE','Claude Code')" >/dev/null 2>&1 || true
fi

exit 0
