#!/usr/bin/env bats
#
# Unit tests for dispatch.sh — each test sets up a temp hooks.d/ and
# pipes a hand-crafted event JSON to the dispatcher.

load test_helper

setup() {
    COAT_TREE_DIR="$(mktemp -d)"
    export COAT_TREE_DIR
}

teardown() {
    rm -rf "$COAT_TREE_DIR"
}

# --- input handling ---

@test "missing hook_event_name: exit 2" {
    run run_dispatch '{}'
    [ "$status" -eq 2 ]
}

@test "invalid JSON on stdin: exit 2" {
    run run_dispatch 'not json'
    [ "$status" -eq 2 ]
}

# --- event routing ---

@test "missing event directory: exit 0, no output" {
    run run_dispatch '{"hook_event_name":"PreToolUse"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "empty event directory: exit 0, no output" {
    mkdir -p "$COAT_TREE_DIR/hooks.d/PreToolUse"
    run run_dispatch '{"hook_event_name":"PreToolUse"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- stdout passthrough ---

@test "single hook stdout is passed through" {
    make_hook PreToolUse "010.echo.sh" '#!/usr/bin/env bash
echo hello'
    run run_dispatch '{"hook_event_name":"PreToolUse"}'
    [ "$status" -eq 0 ]
    ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")
    [[ "$ctx" == *"hello"* ]]
    [[ "$ctx" == *'<hook source="010.echo.sh">'* ]]
}

@test "numeric ordering: 010 runs before 020" {
    local log="$COAT_TREE_DIR/log"
    make_hook PreToolUse "010.first.sh" "#!/usr/bin/env bash
echo 010 >> '$log'"
    make_hook PreToolUse "020.second.sh" "#!/usr/bin/env bash
echo 020 >> '$log'"
    run run_dispatch '{"hook_event_name":"PreToolUse"}'
    [ "$status" -eq 0 ]
    [ "$(cat "$log")" = "$(printf '010\n020')" ]
}

@test "output merging: all hooks' outputs are aggregated" {
    make_hook PreToolUse "010.first.sh" '#!/usr/bin/env bash
echo first'
    make_hook PreToolUse "020.second.sh" '#!/usr/bin/env bash
echo second'
    run run_dispatch '{"hook_event_name":"PreToolUse"}'
    [ "$status" -eq 0 ]
    ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")
    [[ "$ctx" == *"first"* ]]
    [[ "$ctx" == *"second"* ]]
    [[ "$ctx" == *'<hook source="010.first.sh">'* ]]
    [[ "$ctx" == *'<hook source="020.second.sh">'* ]]
}

@test "output merging: silent hook contributes nothing" {
    make_hook PreToolUse "010.first.sh" '#!/usr/bin/env bash
echo first'
    make_hook PreToolUse "020.silent.sh" '#!/usr/bin/env bash
exit 0'
    run run_dispatch '{"hook_event_name":"PreToolUse"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"first"* ]]
    [[ "$output" != *'020.silent.sh'* ]]
}

# --- exit code handling ---

@test "exit 2 aborts; subsequent hooks do not run" {
    local marker="$COAT_TREE_DIR/ran"
    make_hook PreToolUse "010.abort.sh" '#!/usr/bin/env bash
exit 2'
    make_hook PreToolUse "020.marker.sh" "#!/usr/bin/env bash
touch '$marker'"
    run run_dispatch '{"hook_event_name":"PreToolUse"}'
    [ "$status" -eq 2 ]
    [ ! -f "$marker" ]
}

@test "non-2 non-zero exit: warning logged, execution continues" {
    local marker="$COAT_TREE_DIR/ran"
    make_hook PreToolUse "010.fail.sh" '#!/usr/bin/env bash
exit 1'
    make_hook PreToolUse "020.marker.sh" "#!/usr/bin/env bash
touch '$marker'
echo ok"
    run run_dispatch '{"hook_event_name":"PreToolUse"}'
    [ "$status" -eq 0 ]
    [ -f "$marker" ]
    [[ "$output" == *"ok"* ]]
}

# --- hook-matcher ---

@test "hook-matcher matches tool_name" {
    make_hook PreToolUse "010.bash.sh" '#!/usr/bin/env bash
# hook-matcher: Bash
echo matched'
    run run_dispatch '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"matched"* ]]
}

@test "hook-matcher non-match: hook is skipped" {
    make_hook PreToolUse "010.bash.sh" '#!/usr/bin/env bash
# hook-matcher: Bash
echo should-not-run'
    run run_dispatch '{"hook_event_name":"PreToolUse","tool_name":"Write"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook-matcher regex alternation matches multiple tools" {
    make_hook PreToolUse "010.multi.sh" '#!/usr/bin/env bash
# hook-matcher: Bash|Edit
echo matched'
    run run_dispatch '{"hook_event_name":"PreToolUse","tool_name":"Edit"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"matched"* ]]
}

@test "absent matcher on tool event: hook runs" {
    make_hook PreToolUse "010.no-matcher.sh" '#!/usr/bin/env bash
echo ran'
    run run_dispatch '{"hook_event_name":"PreToolUse","tool_name":"AnyTool"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ran"* ]]
}

@test "non-tool event: hook-matcher header is ignored" {
    make_hook SessionStart "010.always.sh" '#!/usr/bin/env bash
# hook-matcher: Bash
echo always'
    run run_dispatch '{"hook_event_name":"SessionStart"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"always"* ]]
}

# --- script filtering ---

@test "hidden (dotfile) scripts are skipped" {
    mkdir -p "$COAT_TREE_DIR/hooks.d/PreToolUse"
    printf '%s\n' '#!/usr/bin/env bash' 'echo hidden' \
        > "$COAT_TREE_DIR/hooks.d/PreToolUse/.disabled.sh"
    chmod +x "$COAT_TREE_DIR/hooks.d/PreToolUse/.disabled.sh"
    run run_dispatch '{"hook_event_name":"PreToolUse"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "non-executable scripts are skipped" {
    mkdir -p "$COAT_TREE_DIR/hooks.d/PreToolUse"
    printf '%s\n' '#!/usr/bin/env bash' 'echo plain' \
        > "$COAT_TREE_DIR/hooks.d/PreToolUse/010.plain.sh"
    # no chmod +x
    run run_dispatch '{"hook_event_name":"PreToolUse"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "scripts in subdirectories are ignored" {
    mkdir -p "$COAT_TREE_DIR/hooks.d/PreToolUse/disabled"
    printf '%s\n' '#!/usr/bin/env bash' 'echo nope' \
        > "$COAT_TREE_DIR/hooks.d/PreToolUse/disabled/010.off.sh"
    chmod +x "$COAT_TREE_DIR/hooks.d/PreToolUse/disabled/010.off.sh"
    run run_dispatch '{"hook_event_name":"PreToolUse"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- decision aggregation ---

@test "PreToolUse: deny beats allow regardless of order" {
    make_hook PreToolUse "010.allow.sh" '#!/usr/bin/env bash
echo '\''{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"ok"}}'\'''
    make_hook PreToolUse "020.deny.sh" '#!/usr/bin/env bash
echo '\''{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"forbidden"}}'\'''
    run run_dispatch '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
    [ "$status" -eq 0 ]
    decision=$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")
    [ "$decision" = "deny" ]
    reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
    [[ "$reason" == *"[010.allow.sh]"* ]]
    [[ "$reason" == *"[020.deny.sh]"* ]]
}

@test "PreToolUse: ask beats allow" {
    make_hook PreToolUse "010.allow.sh" '#!/usr/bin/env bash
echo '\''{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'\'''
    make_hook PreToolUse "020.ask.sh" '#!/usr/bin/env bash
echo '\''{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}'\'''
    run run_dispatch '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
    [ "$status" -eq 0 ]
    decision=$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")
    [ "$decision" = "ask" ]
}

@test "PreToolUse: deny beats ask" {
    make_hook PreToolUse "010.ask.sh" '#!/usr/bin/env bash
echo '\''{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}'\'''
    make_hook PreToolUse "020.deny.sh" '#!/usr/bin/env bash
echo '\''{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"}}'\'''
    run run_dispatch '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
    [ "$status" -eq 0 ]
    decision=$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")
    [ "$decision" = "deny" ]
}

@test "PreToolUse: additionalContext from multiple hooks is concatenated" {
    make_hook PreToolUse "010.a.sh" '#!/usr/bin/env bash
echo '\''{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"alpha"}}'\'''
    make_hook PreToolUse "020.b.sh" '#!/usr/bin/env bash
echo '\''{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"beta"}}'\'''
    run run_dispatch '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
    [ "$status" -eq 0 ]
    ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")
    [[ "$ctx" == *"alpha"* ]]
    [[ "$ctx" == *"beta"* ]]
    [[ "$ctx" == *'<hook source="010.a.sh">'* ]]
    [[ "$ctx" == *'<hook source="020.b.sh">'* ]]
}

@test "SessionStart: outputs concatenated as plain text with source tags" {
    make_hook SessionStart "010.knowledge.sh" '#!/usr/bin/env bash
echo "knowledge content"'
    make_hook SessionStart "020.wiki.sh" '#!/usr/bin/env bash
echo "wiki content"'
    run run_dispatch '{"hook_event_name":"SessionStart"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"knowledge content"* ]]
    [[ "$output" == *"wiki content"* ]]
    [[ "$output" == *'<hook source="010.knowledge.sh">'* ]]
    [[ "$output" == *'<hook source="020.wiki.sh">'* ]]
}

@test "PostToolUse: any block decision propagates" {
    make_hook PostToolUse "010.ok.sh" '#!/usr/bin/env bash
echo "looks fine"'
    make_hook PostToolUse "020.block.sh" '#!/usr/bin/env bash
echo '\''{"decision":"block","reason":"violated policy"}'\'''
    run run_dispatch '{"hook_event_name":"PostToolUse","tool_name":"Bash"}'
    [ "$status" -eq 0 ]
    decision=$(jq -r '.decision' <<<"$output")
    [ "$decision" = "block" ]
    reason=$(jq -r '.reason' <<<"$output")
    [[ "$reason" == *"[020.block.sh]"* ]]
    [[ "$reason" == *"violated policy"* ]]
}
