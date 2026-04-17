#!/usr/bin/env bash
# hook-matcher: Write|Edit
#
# Example: prompt the user before writing or editing files under
# ~/.ssh or ~/.gnupg. Illustrative only — copy, adapt, or delete.
# Demonstrates:
#   - a multi-tool matcher (`Write|Edit` is a regex alternation)
#   - parsing tool_input.file_path from stdin
#   - returning a JSON `ask` decision with an interpolated reason
#   - building JSON with jq so arbitrary paths cannot break quoting

set -uo pipefail

INPUT=$(cat)
PATH_ARG=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

case "$PATH_ARG" in
    */.ssh/*|*/.gnupg/*)
        jq -n --arg path "$PATH_ARG" '{
          hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "ask",
            permissionDecisionReason: ("Sensitive file: " + $path + " — confirm before editing.")
          }
        }'
        ;;
esac

exit 0
