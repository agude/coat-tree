#!/usr/bin/env bash
# hook-matcher: Bash
#
# Example: deny `curl ... | sh` pipelines. Illustrative only — copy,
# adapt, or delete. Demonstrates:
#   - hook-matcher header scoping the hook to Bash
#   - parsing tool_input.command from stdin
#   - returning a JSON deny decision with a reason shown to Claude
#   - building JSON safely with jq instead of string interpolation

set -uo pipefail

INPUT=$(cat)
COMMAND=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [[ "$COMMAND" =~ curl[[:space:]].*\|[[:space:]]*(sh|bash) ]]; then
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "curl-pipe-to-shell is blocked. Download the script, review it, then run it."
      }
    }'
fi

exit 0
