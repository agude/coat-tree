#!/usr/bin/env bash
#
# coat tree — modular hook dispatcher for Claude Code.
#
# All hook events in settings.json point here. The dispatcher reads
# hook_event_name from stdin JSON, scans hooks.d/<event>/ for numbered
# scripts, and runs them in order.
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

# --- Run scripts ---
last_output=""

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

    if [[ -n "$output" ]]; then
        if [[ -n "$last_output" ]]; then
            debug "warning: $name overwrites previous output"
        fi
        last_output="$output"
        debug "$name produced output (${#output} bytes)"
    fi
done

# Emit the last non-empty stdout
if [[ -n "$last_output" ]]; then
    printf '%s\n' "$last_output"
fi
