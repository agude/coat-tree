# coat tree

A modular hook dispatcher for [Claude Code](https://claude.ai/code).

Claude Code's hook system lets a single command handle each event. Coat
tree is that command: it reads the event JSON on stdin, finds matching
scripts under `hooks.d/<EventName>/`, and runs them in numeric order.

Hooks are ordinary shell scripts. Drop one in, make it executable, done.
No config file, no plugin manifest.

## Why

Writing one monolithic hook script per event gets unwieldy fast. Coat
tree lets you split concerns into small, numbered scripts:

```
~/.config/coat-tree/hooks.d/
└── PreToolUse/
    ├── 010.git-guard.sh        # block --no-verify, signing bypasses
    ├── 020.git-push-guard.sh   # block force push, push to main
    └── 030.gh-guard.sh         # classify gh subcommands
```

Each hook checks one thing. The dispatcher composes them.

## Install

```bash
git clone https://github.com/agude/coat-tree.git ~/.local/share/coat-tree
ln -s ~/.local/share/coat-tree/dispatch.sh ~/.local/bin/coat-tree
```

Make sure `~/.local/bin` is on your `PATH`.

## Configure Claude Code

Point every hook event you care about at `coat-tree` in
`~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      { "hooks": [ { "type": "command", "command": "coat-tree" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "coat-tree" } ] }
    ]
  }
}
```

The dispatcher reads `hook_event_name` from stdin and routes to the
matching `hooks.d/<EventName>/` directory, so one command entry covers
every event.

## Write hooks

See [`examples/`](examples/) for runnable hook scripts covering the
common patterns: a non-tool event, a `PreToolUse` deny with a matcher
header, and a file-path-aware `ask` decision.

See [HOOKS.md](HOOKS.md) for:

- File conventions (`NNN.name.sh`, executable, matcher headers)
- Reading stdin, exit codes, and JSON output
- The `permissionDecision` values (`allow`, `deny`, `ask`, `defer`)
- Output merging, timeouts, debugging

## Environment

| Variable | Purpose | Default |
|---|---|---|
| `COAT_TREE_DIR` | Override hooks directory | `$XDG_CONFIG_HOME/coat-tree` |
| `DISPATCH_DEBUG` | Log matcher decisions to stderr | unset |

Execution is also logged to syslog under the `coat-tree` tag:

```bash
journalctl -t coat-tree
```

## License

[CC0 1.0 Universal](LICENSE). Public domain — do what you want.
