#!/usr/bin/env bash
#
# coat tree — modular hook dispatcher for Claude Code.
#
# All hook events in settings.json point here. The dispatcher reads
# hook_event_name from stdin JSON, scans hooks.d/<event>/ for numbered
# scripts, runs them in order, and aggregates their outputs into a
# single response Claude Code accepts.
#
# Aggregation mirrors Claude Code's own multi-hook semantics:
#   - PreToolUse: most-restrictive permissionDecision wins
#     (deny > ask > allow). All additionalContext concatenated.
#   - PostToolUse, Stop: any {"decision":"block"} blocks; otherwise
#     plain text concatenated.
#   - SessionStart, UserPromptSubmit: stdout / additionalContext
#     concatenated as plain text injection.
#   - SessionEnd, Notification: outputs are ignored by Claude Code
#     anyway; scripts run for side effects.
#
# Note: Claude Code hooks share a 60-second timeout across the entire
# invocation. The dispatcher does not enforce per-script timeouts —
# slow scripts should use `timeout` internally.

# Fail on undefined variables and broken pipes. Do NOT set -e: we need
# to inspect exit codes from script invocations manually.
set -uo pipefail

# Hooks directory — like .bashrc, a fixed config location independent of
# where the dispatcher is installed. Override with COAT_TREE_DIR.
HOOKS_DIR="${COAT_TREE_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/coat-tree}/hooks.d"

# Tool events where hook-matcher applies against .tool_name
TOOL_EVENTS="PreToolUse|PostToolUse|PostToolUseFailure|PermissionRequest|PermissionDenied"

debug() {
    if [[ "${DISPATCH_DEBUG:-}" == "1" ]]; then
        echo "[dispatch] $*" >&2
    fi
}

# Log to syslog unconditionally. Provides a paper trail without visible
# noise — check with: journalctl -t coat-tree
log() {
    logger -t coat-tree "$@" 2>/dev/null || true
}

# --- Read and parse stdin ---
# Buffer stdin so multiple scripts can receive it. Note: command
# substitution strips trailing newlines — acceptable for JSON input.
INPUT="$(cat)"

EVENT=$(printf '%s\n' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
if [[ -z "$EVENT" ]]; then
    echo "[dispatch] failed to extract hook_event_name from stdin" >&2
    exit 2
fi
debug "event=$EVENT"

# Extract tool_name for tool events
TOOL_NAME=""
if [[ "$EVENT" =~ ^($TOOL_EVENTS)$ ]]; then
    TOOL_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
    debug "tool_name=$TOOL_NAME"
fi

# --- Find scripts ---
EVENT_DIR="$HOOKS_DIR/$EVENT"
if [[ ! -d "$EVENT_DIR" ]]; then
    debug "no directory $EVENT_DIR — noop"
    exit 0
fi

# Collect executable, non-hidden, regular files (or symlinks to them),
# sorted lexicographically.
scripts=()
while IFS= read -r -d '' entry; do
    scripts+=("$entry")
done < <(find "$EVENT_DIR" -maxdepth 1 -not -name '.*' \( -type f -o -type l \) -exec test -x {} \; -print0 | sort -z)

if [[ ${#scripts[@]} -eq 0 ]]; then
    debug "no scripts in $EVENT_DIR — noop"
    exit 0
fi

# --- Aggregation state ---
# Permission decision: most-restrictive wins. deny=3 > ask=2 > allow=1 > none=0
decision_value=""
decision_rank=0
decision_reasons=""        # accumulated permissionDecisionReason (attributed)
contexts=""                # accumulated additionalContext + plain text outputs
block_present=0            # any script returned {"decision":"block"}
block_reasons=""           # accumulated block reasons (attributed)

rank_decision() {
    case "$1" in
        deny)  echo 3 ;;
        ask)   echo 2 ;;
        allow) echo 1 ;;
        *)     echo 0 ;;
    esac
}

# --- Run scripts ---
for script in "${scripts[@]}"; do
    name="$(basename "$script")"

    # Check hook-matcher header on tool events
    if [[ -n "$TOOL_NAME" ]]; then
        matcher=$(grep -m1 '^# hook-matcher:' "$script" 2>/dev/null | sed 's/^# hook-matcher:[[:space:]]*//')
        if [[ -n "$matcher" ]]; then
            if [[ ! "$TOOL_NAME" =~ $matcher ]]; then
                debug "skip $name — matcher '$matcher' does not match '$TOOL_NAME'"
                continue
            fi
            debug "match $name — matcher '$matcher' matches '$TOOL_NAME'"
        else
            debug "run $name — no matcher (tool event, runs for all)"
        fi
    else
        debug "run $name — non-tool event"
    fi

    # Run the script with buffered input via here-string. Avoids a
    # pipeline subshell so background processes spawned by the script
    # (e.g., nohup in session-end) survive after the script exits.
    _out_file=$(mktemp)
    "$script" > "$_out_file" 2>&2 <<< "$INPUT"
    rc=$?
    output=$(<"$_out_file")
    rm -f "$_out_file"

    if [[ $rc -eq 2 ]]; then
        debug "ABORT $name — exit code 2"
        log "$EVENT $name ABORT"
        exit 2
    elif [[ $rc -ne 0 ]]; then
        echo "[dispatch] warning: $name exited $rc" >&2
        log "$EVENT $name FAIL rc=$rc"
    else
        log "$EVENT $name ok"
    fi

    [[ -z "$output" ]] && continue

    # Recognize structured output: a JSON object containing either
    # hookSpecificOutput (PreToolUse/UserPromptSubmit) or top-level
    # decision (PostToolUse/Stop). Anything else is plain text.
    if echo "$output" | jq -e 'type == "object" and ((.hookSpecificOutput // .decision) != null)' >/dev/null 2>&1; then
        decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
        reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
        ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
        block_decision=$(echo "$output" | jq -r '.decision // empty' 2>/dev/null)
        block_reason=$(echo "$output" | jq -r '.reason // empty' 2>/dev/null)

        if [[ -n "$decision" ]]; then
            new_rank=$(rank_decision "$decision")
            if (( new_rank > decision_rank )); then
                decision_rank=$new_rank
                decision_value="$decision"
            fi
            if [[ -n "$reason" ]]; then
                decision_reasons+="[$name] $reason"$'\n'
            fi
        fi
        if [[ -n "$ctx" ]]; then
            contexts+="<hook source=\"$name\">"$'\n'"$ctx"$'\n'"</hook>"$'\n'
        fi
        if [[ "$block_decision" == "block" ]]; then
            block_present=1
            if [[ -n "$block_reason" ]]; then
                block_reasons+="[$name] $block_reason"$'\n'
            fi
        fi
    else
        contexts+="<hook source=\"$name\">"$'\n'"$output"$'\n'"</hook>"$'\n'
    fi
    debug "$name produced output (${#output} bytes)"
done

# --- Emit aggregated output ---

# Strip trailing whitespace/newlines for clean output
# shellcheck disable=SC2001  # sed is cleaner than extglob for multi-line strings
strip() { sed -e 's/[[:space:]]*$//' <<< "$1"; }

contexts="$(strip "$contexts")"
decision_reasons="$(strip "$decision_reasons")"
block_reasons="$(strip "$block_reasons")"

case "$EVENT" in
    PreToolUse)
        if [[ -n "$decision_value" ]] || [[ -n "$contexts" ]]; then
            jq -n \
                --arg event "$EVENT" \
                --arg decision "$decision_value" \
                --arg reason "$decision_reasons" \
                --arg ctx "$contexts" \
                '{
                    hookSpecificOutput: (
                        {hookEventName: $event}
                        + (if $decision != "" then {permissionDecision: $decision} else {} end)
                        + (if $reason   != "" then {permissionDecisionReason: $reason} else {} end)
                        + (if $ctx      != "" then {additionalContext: $ctx} else {} end)
                    )
                }'
        fi
        ;;
    PostToolUse|Stop)
        if (( block_present )); then
            jq -n --arg reason "$block_reasons" '{decision: "block", reason: $reason}'
        elif [[ -n "$contexts" ]]; then
            printf '%s\n' "$contexts"
        fi
        ;;
    *)
        # SessionStart, UserPromptSubmit, SessionEnd, Notification, others.
        # Plain-text concatenation. (UserPromptSubmit also accepts plain
        # text per docs; SessionEnd/Notification outputs are ignored.)
        if [[ -n "$contexts" ]]; then
            printf '%s\n' "$contexts"
        fi
        ;;
esac

exit 0
