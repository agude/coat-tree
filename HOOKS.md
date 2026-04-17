# Writing Coat Tree Hooks

## When to use hooks vs. settings

Hooks and permission rules in `settings.json` serve different purposes.
Use the right tool for the job:

| Situation | Mechanism | Example |
|-----------|-----------|---------|
| **Always safe** | `allow` in settings | `git log`, `ls`, `gh pr list` |
| **Never safe** | `deny` in settings | `sudo`, `reboot`, `dd` |
| **Nuanced** | Hook decides | `git push` (ok to feature, not to main) |
| **Dangerous, hard to filter** | Hook as smart filter | `gh` subcommands (many safe, some destructive) |

The `ask: *` rule in settings is the universal backstop. Any command not
explicitly allowed by a rule or hook still prompts the user. This means:

- **Hooks don't need to be exhaustive.** If a hook doesn't match, the
  command falls through to `ask` and the user decides.
- **Deny + hook is valid when the prefix matcher can't cover all forms.**
  Permission rules match command prefixes. `Bash(git commit --no-verify:*)`
  catches the flag at the start but misses `git commit -m "msg" --no-verify`
  where it appears later. Deny catches the obvious prefix forms; the hook
  catches reordered and short-flag variants the prefix matcher misses.
- **Hooks replace deny rules when you need nuance.** Move the command out
  of deny, write a hook that allows the safe cases and denies the dangerous
  ones, and let `ask` catch anything the hook doesn't cover.

## File conventions

- Place hooks in `hooks.d/<EventName>/NNN.name.sh`
- Number prefix controls execution order (010, 020, 030...)
- Must be executable (`chmod +x`)
- Dotfiles (`.disabled.sh`) and subdirectories are ignored
- Move scripts to a `disabled/` subdirectory to disable without deleting

## Matcher header

Scripts can declare which tool they apply to via a comment header:

```bash
#!/usr/bin/env bash
# hook-matcher: Bash
```

- Matched against `.tool_name` on tool events (PreToolUse, PostToolUse, etc.)
- Uses bash `=~` regex: `# hook-matcher: Bash|Edit` matches both
- Absent = runs for all tool names on that event
- Ignored on non-tool events (SessionStart, Stop, etc.)

## Reading input

Every hook receives the event JSON on stdin. Buffer it before parsing:

```bash
INPUT=$(cat)
COMMAND=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
```

Common fields by event:
- Tool events: `.hook_event_name`, `.tool_name`, `.tool_input`
- Session events: `.hook_event_name`, `.session_id`
- Stop: `.hook_event_name`, `.session_id`, `.last_assistant_message`

## Exit codes

| Code | Meaning |
|------|---------|
| 0    | Success. Stdout (if any) is passed to Claude Code. |
| 2    | Abort. Stderr is shown to user. All prior output discarded. |
| Other | Warning logged, execution continues with remaining hooks. |

Exit 2 is the simplest way to block a tool call, but Claude does not see
a reason — it just sees the call failed. Use JSON output for better UX.

## PreToolUse JSON output

For PreToolUse hooks, JSON stdout gives finer control than exit codes.
Return a `hookSpecificOutput` object:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Reason shown to Claude."
  }
}
```

### Permission decisions

| Decision | Effect |
|----------|--------|
| `allow`  | Skip the permission prompt. Tool runs immediately. Deny rules in settings.json still apply. |
| `deny`   | Block the tool call. Reason is shown to Claude so it can adjust. |
| `ask`    | Prompt the user to confirm. Reason shown to user. |
| `defer`  | Exit gracefully so the tool can be resumed later. |

Use `deny` over exit 2 when you want Claude to understand *why* and try
a different approach. Use `allow` to replace blanket deny rules with
judgment (e.g., allow pushes to feature branches but not main).

## Output merging

The dispatcher runs hooks in numeric order. Only the **last non-empty
stdout** is returned to Claude Code. If two hooks both produce output,
the first is silently overwritten (logged in debug mode).

Design hooks so that at most one produces output per invocation. Guard
hooks should exit 0 with no output when they don't match, and only emit
JSON when they have a decision.

## One concern per hook

Each hook should check one thing. The dispatcher composes them:

- `010.git-guard.sh` — blocks `--no-verify` and signing bypasses
- `020.git-push-guard.sh` — blocks force push and push to main
- `030.gh-guard.sh` — categorizes GitHub CLI operations

A git push with `--no-verify` hits git-guard first (exit 2, abort)
and never reaches the push guard. A clean push to a feature branch
passes git-guard (exit 0, no output) and gets allowed by push-guard.

## Stderr

Script stderr flows directly to the user's terminal. Use it for:
- Exit 2 abort messages
- Debug output (guard with `[[ "${DISPATCH_DEBUG:-}" == "1" ]]`)

Do not write to stderr on the happy path — it shows up as hook noise.

## Timeouts

Claude Code hooks share a 60-second timeout across all hooks for an
event. The dispatcher does not enforce per-script timeouts. If your
script may be slow, wrap the slow part with `timeout`:

```bash
output=$(timeout 5 some-slow-command)
```

## Symlink-safe scripts

When a hook is invoked through a symlink (as coat tree does), `$0`
resolves to the symlink, not the target. If you need to find sibling
scripts, resolve the symlink first:

```bash
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
```

## Debugging

Set `DISPATCH_DEBUG=1` to see which scripts match, skip, and produce output:

```bash
echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push"}}' \
  | DISPATCH_DEBUG=1 coat-tree
```

Check syslog for a persistent trail:

```bash
journalctl -t coat-tree
```
