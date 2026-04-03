#!/bin/bash
# ============================================================
# Hook Orchestrator
# ============================================================
# Automatic guardrail orchestrator for the Partnerships site.
#
# How it works:
#   1. Reads event JSON from stdin
#   2. Looks up which agents handle this event in config.json
#   3. Runs matching agents sequentially (sorted by priority)
#   4. Stops on first BLOCK (exit 2) — stderr is forwarded
#   5. Non-blocking agents always run, failures are logged
#
# Exit codes:
#   0 = all agents passed (or no agents matched)
#   2 = an agent blocked the action (stderr has the reason)
#
# Environment:
#   SRI_DEBUG=1    — verbose logging to stderr
#   SRI_DRY_RUN=1  — log what would run without executing
# ============================================================

set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${HOOKS_DIR}/config.json"
LOG_PREFIX="[orchestrator]"

# ---- Helpers ------------------------------------------------

debug() {
  if [ "${SRI_DEBUG:-}" = "1" ]; then
    echo "${LOG_PREFIX} $*" >&2
  fi
}

log_error() {
  echo "${LOG_PREFIX} ERROR: $*" >&2
}

# ---- Read stdin (event JSON) --------------------------------

INPUT=$(cat)
if [ -z "$INPUT" ]; then
  debug "No input received — exiting clean"
  exit 0
fi

# Extract event metadata
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

if [ -z "$HOOK_EVENT" ]; then
  debug "No hook_event_name in input — exiting clean"
  exit 0
fi

debug "Event: ${HOOK_EVENT} | Tool: ${TOOL_NAME:-n/a}"

# ---- Load config --------------------------------------------

if [ ! -f "$CONFIG_FILE" ]; then
  log_error "Config not found: ${CONFIG_FILE}"
  exit 0  # Don't block if config is missing
fi

# ---- Find matching agents -----------------------------------

# Get all enabled agents that listen to this event, sorted by priority
MATCHING_AGENTS=$(jq -r --arg event "$HOOK_EVENT" '
  .agents
  | to_entries[]
  | select(.value.enabled == true)
  | select(.value.events | index($event))
  | [.value.priority, .key, .value.script, .value.matcher, (.value.blocking // false | tostring)]
  | @tsv
' "$CONFIG_FILE" 2>/dev/null | sort -n -k1)

if [ -z "$MATCHING_AGENTS" ]; then
  debug "No agents match event: ${HOOK_EVENT}"
  exit 0
fi

# ---- Run agents sequentially --------------------------------

BLOCKED=false
BLOCK_MESSAGE=""

while IFS=$'\t' read -r priority name script matcher blocking; do
  debug "Checking agent: ${name} (priority=${priority}, matcher=${matcher}, blocking=${blocking})"

  # If agent has a matcher, check if the tool name matches
  if [ -n "$matcher" ] && [ -n "$TOOL_NAME" ]; then
    if ! echo "$TOOL_NAME" | grep -qE "$matcher"; then
      debug "  Skipped: tool '${TOOL_NAME}' doesn't match '${matcher}'"
      continue
    fi
  fi

  AGENT_SCRIPT="${HOOKS_DIR}/${script}"

  if [ ! -x "$AGENT_SCRIPT" ]; then
    debug "  Skipped: script not executable or missing: ${AGENT_SCRIPT}"
    continue
  fi

  # Dry run mode
  if [ "${SRI_DRY_RUN:-}" = "1" ]; then
    debug "  [DRY RUN] Would execute: ${AGENT_SCRIPT}"
    continue
  fi

  debug "  Running: ${name} (${AGENT_SCRIPT})"

  # Execute agent, passing the original event JSON via stdin
  AGENT_STDERR_FILE=$(mktemp)
  AGENT_STDOUT=$(echo "$INPUT" | "$AGENT_SCRIPT" 2>"$AGENT_STDERR_FILE")
  AGENT_EXIT=$?
  AGENT_STDERR=$(cat "$AGENT_STDERR_FILE")
  rm -f "$AGENT_STDERR_FILE"

  debug "  Exit code: ${AGENT_EXIT}"

  if [ $AGENT_EXIT -eq 2 ]; then
    # Agent wants to BLOCK
    debug "  BLOCKED by ${name}"
    BLOCKED=true
    BLOCK_MESSAGE="${AGENT_STDERR}"
    break  # Stop pipeline on first block
  elif [ $AGENT_EXIT -ne 0 ]; then
    # Agent errored (not a block, just a failure)
    log_error "Agent '${name}' failed with exit ${AGENT_EXIT}: ${AGENT_STDERR}"
    # Non-blocking agents don't stop the pipeline
    if [ "$blocking" = "true" ]; then
      debug "  Blocking agent failed — treating as block"
      BLOCKED=true
      BLOCK_MESSAGE="Agent '${name}' encountered an error: ${AGENT_STDERR}"
      break
    fi
  fi

  # Forward stdout if agent produced any (e.g., JSON output for PermissionRequest)
  if [ -n "$AGENT_STDOUT" ]; then
    echo "$AGENT_STDOUT"
  fi

done <<< "$MATCHING_AGENTS"

# ---- Final verdict ------------------------------------------

if [ "$BLOCKED" = true ]; then
  if [ -n "$BLOCK_MESSAGE" ]; then
    echo "$BLOCK_MESSAGE" >&2
  fi
  exit 2
fi

exit 0
