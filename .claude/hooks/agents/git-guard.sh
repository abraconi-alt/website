#!/bin/bash
# ============================================================
# Agent: git-guard
# Purpose: Block commits/pushes AND edits on protected branches
# Events: PreToolUse (Bash, Edit, Write)
# Blocking: yes
#
# Protected branches: main
#
# After merging a PR, always create a new branch before working.
# This guard catches you BEFORE you edit, not just at commit time.
# ============================================================

set -uo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

PROTECTED_BRANCHES=("main")

# Get current branch
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")

if [ -z "$CURRENT_BRANCH" ]; then
  exit 0
fi

# Check if we're on a protected branch
ON_PROTECTED=false
for branch in "${PROTECTED_BRANCHES[@]}"; do
  if [ "$CURRENT_BRANCH" = "$branch" ]; then
    ON_PROTECTED=true
    break
  fi
done

# --- BLOCK: git push TARGETING a protected branch (from ANY branch) ---
if [ -n "$COMMAND" ] && echo "$COMMAND" | grep -qE '^\s*git\s+push\b'; then
  for branch in "${PROTECTED_BRANCHES[@]}"; do
    if echo "$COMMAND" | grep -qE "\b${branch}\b"; then
      echo "BLOCKED by git-guard: Cannot push to protected branch '${branch}' (even from '${CURRENT_BRANCH}')." >&2
      echo "Use a PR workflow: open a pull request to merge into '${branch}'." >&2
      exit 2
    fi
  done
fi

# Remaining checks only apply when ON a protected branch
if [ "$ON_PROTECTED" = false ]; then
  exit 0
fi

# --- BLOCK: git commit on protected branch ---
if [ -n "$COMMAND" ] && echo "$COMMAND" | grep -qE '^\s*git\s+commit\b'; then
  echo "BLOCKED by git-guard: Cannot commit directly to protected branch '${CURRENT_BRANCH}'." >&2
  echo "Create a feature branch first: git checkout -b feature/your-feature" >&2
  exit 2
fi

# --- BLOCK: git push from protected branch (no target specified) ---
if [ -n "$COMMAND" ] && echo "$COMMAND" | grep -qE '^\s*git\s+push\b'; then
  echo "BLOCKED by git-guard: Cannot push directly from protected branch '${CURRENT_BRANCH}'." >&2
  echo "Use a PR workflow: create a feature branch and open a pull request." >&2
  exit 2
fi

# --- BLOCK: Edit/Write source files on protected branch ---
# Only block edits to project source files (not .claude/ config which may need updating on any branch)
if [ -n "$FILE_PATH" ] && [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ]; then
  # Allow .claude/ config edits on any branch
  if echo "$FILE_PATH" | grep -qE '\.claude/'; then
    exit 0
  fi
  # Block source file edits on protected branches
  if echo "$FILE_PATH" | grep -qE '\.(html|css|js|json|md|txt|svg|png|jpg|jpeg|gif|ico|xml)$'; then
    echo "BLOCKED by git-guard: Cannot edit source files on protected branch '${CURRENT_BRANCH}'." >&2
    echo "You are on '${CURRENT_BRANCH}' after a merge. Create a new branch first:" >&2
    echo "  git checkout -b feature/your-feature" >&2
    echo "  git checkout -b fix/your-fix" >&2
    exit 2
  fi
fi

exit 0
