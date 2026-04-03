#!/bin/bash
# secrets-guard.sh — Block hardcoded secrets, credentials, and API keys

INPUT=$(cat)

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty')
CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_content // .tool_input.content // empty')

if [ "${SRI_DEBUG:-0}" = "1" ]; then
  echo "[secrets-guard] TOOL=$TOOL FILE=$FILE" >&2
fi

if [ "${SRI_DRY_RUN:-0}" = "1" ]; then
  echo "[secrets-guard] DRY RUN — would scan for secrets" >&2
  exit 0
fi

# Only intercept Edit and Write
if [[ "$TOOL" != "Edit" && "$TOOL" != "Write" ]]; then
  exit 0
fi

# Skip test files and fixtures
if echo "$FILE" | grep -qE '(\.test\.|\.spec\.|__tests__|fixtures|mocks|\.example|\.template)'; then
  if [ "${SRI_DEBUG:-0}" = "1" ]; then
    echo "[secrets-guard] Skipping test/fixture file: $FILE" >&2
  fi
  exit 0
fi

# Skip .env.example and template files
if echo "$FILE" | grep -qE '(\.env\.example|\.env\.template|settings\.local\.json\.template)'; then
  exit 0
fi

FOUND=""

# AWS Access Keys (AKIA...)
if echo "$CONTENT" | grep -qE 'AKIA[0-9A-Z]{16}'; then
  FOUND="AWS access key (AKIA...) detected"
fi

# Stripe live keys
if echo "$CONTENT" | grep -qE 'sk_live_[0-9a-zA-Z]{24,}|pk_live_[0-9a-zA-Z]{24,}'; then
  FOUND="Stripe live key detected"
fi

# Private keys
if echo "$CONTENT" | grep -qE '\-\-\-\-\-BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'; then
  FOUND="Private key block detected"
fi

# Hardcoded passwords (common patterns)
if echo "$CONTENT" | grep -qiE '(password|passwd|pwd)\s*=\s*["\x27][^"\x27]{4,}["\x27]'; then
  # Exclude known safe patterns
  if ! echo "$CONTENT" | grep -qiE '(password|passwd|pwd)\s*=\s*["\x27](process\.env|os\.environ|ssm|placeholder|your-|PASTE|example|test|changeme)["\x27]'; then
    FOUND="Hardcoded password detected"
  fi
fi

# API keys / tokens
if echo "$CONTENT" | grep -qiE '(api_key|api_secret|auth_token|access_token|secret_key)\s*=\s*["\x27][a-zA-Z0-9_\-]{16,}["\x27]'; then
  if ! echo "$CONTENT" | grep -qiE '(api_key|api_secret|auth_token|access_token|secret_key)\s*=\s*["\x27](process\.env|os\.environ|ssm|placeholder|your-|PASTE|example)["\x27]'; then
    FOUND="Hardcoded API key or token detected"
  fi
fi

# Google OAuth client secrets
if echo "$CONTENT" | grep -qiE 'client_secret\s*=\s*["\x27][a-zA-Z0-9_\-]{20,}["\x27]'; then
  if ! echo "$CONTENT" | grep -qiE 'client_secret\s*=\s*["\x27](process\.env|os\.environ|ssm|placeholder)["\x27]'; then
    FOUND="Hardcoded OAuth client secret detected"
  fi
fi

# Database connection strings with credentials
if echo "$CONTENT" | grep -qE '(mongodb|postgres|mysql|redis):\/\/[^:]+:[^@]+@'; then
  FOUND="Database connection string with credentials detected"
fi

# GitHub PATs
if echo "$CONTENT" | grep -qE 'gh[ps]_[a-zA-Z0-9]{36,}'; then
  FOUND="GitHub personal access token detected"
fi

if [ -n "$FOUND" ]; then
  echo "BLOCKED by secrets-guard: $FOUND in $FILE"
  echo ""
  echo "Secrets must never be hardcoded. Use instead:"
  echo "  JavaScript: Use environment variables or a secrets manager"
  echo "  Config:     ~/.claude/settings.json env block (never committed)"
  echo ""
  echo "If this is a test fixture, add .example or .template to the filename."
  exit 2
fi

exit 0
