# AGENTS.md

This file provides guidance to AI coding agents working in this repository.
`CLAUDE.md` and `GEMINI.md` are symlinks to this file.

## Project

Coat tree is a modular hook dispatcher for Claude Code. It lets users split hook logic into numbered scripts under `hooks.d/<EventName>/` instead of writing one monolithic script per event. The dispatcher runs them in order and aggregates their outputs.

## Commands

```bash
bats tests/                    # Run all tests
bats tests/dispatch.bats      # Run dispatcher unit tests only
bats tests/examples.bats      # Run example hook smoke tests only

shellcheck dispatch.sh examples/**/*.sh  # Lint all shell scripts
```

Dependencies: `bats`, `jq`, `shellcheck`. Tests run on Linux, macOS, and Bash 3.2.

## Architecture

**`dispatch.sh`** — The single entry point registered with Claude Code. All hook events point here.

Flow:
1. Reads event JSON from stdin, extracts `hook_event_name` and `tool_name`
2. Finds matching scripts in `$COAT_TREE_DIR/hooks.d/<EventName>/`
3. For tool events, checks each script's `# hook-matcher:` header against `tool_name`
4. Runs matching scripts in lexicographic order (010, 020, 030...)
5. Aggregates outputs: most-restrictive permission wins, contexts concatenate

**Output aggregation by event type:**
- PreToolUse: `deny` > `ask` > `allow`. All reasons and contexts concatenated with source attribution.
- PostToolUse/Stop: Any `{"decision":"block"}` blocks. Otherwise plain text concatenated.
- SessionStart/UserPromptSubmit: Plain text concatenated.
- SessionEnd/Notification: Side effects only, outputs ignored.

**Hook scripts** — Executable shell scripts in `hooks.d/<EventName>/NNN.name.sh`:
- Receive event JSON on stdin
- Exit 0 = success, exit 2 = abort (remaining hooks don't run), other = warning + continue
- For PreToolUse: JSON output with `hookSpecificOutput.permissionDecision` controls the tool call
- Plain text stdout is wrapped in `<hook source="NNN.name.sh">` tags

**`# hook-matcher: <regex>`** — Second-line header scoping a hook to specific tools. Matched against `tool_name` via bash `=~`. Absent = runs for all tools. Ignored on non-tool events.

## Testing

`tests/dispatch.bats` — Unit tests against synthetic hooks in a temp directory. Each test creates hooks via `make_hook`, runs the dispatcher, and asserts on output/exit code.

`tests/examples.bats` — Smoke tests the shipped `examples/` by pointing `COAT_TREE_DIR` at the real examples directory.

`tests/test_helper.bash` — Shared setup: `run_dispatch` pipes JSON to the dispatcher, `make_hook` creates executable test hooks.

## Key Behaviors

- Scripts must be executable and not hidden (no dotfiles)
- Scripts in subdirectories are ignored (use `disabled/` to park hooks)
- Exit code 2 aborts immediately; other non-zero exits warn but continue
- The 60-second Claude Code timeout is shared across all hooks — slow scripts should use `timeout` internally
- All execution is logged to syslog under tag `coat-tree`

## Environment Variables

- `COAT_TREE_DIR` — Override hooks directory (default: `$XDG_CONFIG_HOME/coat-tree`)
- `DISPATCH_DEBUG=1` — Log matcher decisions to stderr
