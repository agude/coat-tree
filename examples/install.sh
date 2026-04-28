#!/usr/bin/env bash
#
# install — wire this repo's coat-tree hooks into ~/.config/coat-tree.
#
# Idempotent: safe to re-run after pulls. Each run removes any prior
# symlinks pointing into this repo, then recreates the canonical set.
# Renamed or deleted hooks disappear automatically.
#
# To adopt:
#   1. Copy this file into your repo (e.g. scripts/install) and `chmod +x`.
#   2. Set HOOK_PREFIX to something unique. Convention: NNN.reponame.
#      The numeric prefix orders execution across coat-tree-using repos
#      (lower runs first). Pick a number that doesn't collide.
#   3. Fill HOOKS with event:script-basename pairs. Each script must be
#      executable and live next to this install script (or adjust
#      SCRIPT_DIR below).
#   4. Run the script. Re-run after every git pull.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

COAT_TREE_HOOKS="${XDG_CONFIG_HOME:-$HOME/.config}/coat-tree/hooks.d"

# --- Customize for your repo ---

HOOK_PREFIX="050.myrepo"

HOOKS=(
    # "EventName:script-basename"
    # "SessionStart:my-session-start"
    # "PreToolUse:my-pretool-guard"
)

# --- End customization ---

# Safety: refuse to run with template defaults. Cleanup deletes any
# symlink pointing into $REPO_ROOT, so an uncustomized run from a path
# like $HOME would wipe other repos' hooks.
if [[ "$HOOK_PREFIX" == "050.myrepo" ]]; then
    echo "ERROR: HOOK_PREFIX is still the template default." >&2
    echo "Edit this script and set HOOK_PREFIX to NNN.<your-repo-name>." >&2
    exit 1
fi
if (( ${#HOOKS[@]} == 0 )); then
    echo "ERROR: HOOKS array is empty. Add at least one event:script entry." >&2
    exit 1
fi
case "$REPO_ROOT" in
    "$HOME"|/|"")
        echo "ERROR: REPO_ROOT resolved to '$REPO_ROOT' — refusing to run." >&2
        echo "This template assumes <repo>/scripts/install layout so REPO_ROOT" >&2
        echo "is bounded to one project. Move the script or adjust REPO_ROOT." >&2
        exit 1
        ;;
esac

# Cleanup: remove every prior symlink pointing into this repo. Whichever
# entries we still want get recreated below; renamed or removed hooks
# stay gone. Clean slate is simpler than tracking which names are stale.
removed=0
for link in "${COAT_TREE_HOOKS}"/*/* ; do
    [[ -L "$link" ]] || continue
    target="$(readlink "$link")"
    case "$target" in
        "${REPO_ROOT}/"*)
            rm "$link"
            removed=$((removed + 1))
            ;;
    esac
done
if (( removed > 0 )); then
    echo "Removed $removed prior symlink(s)."
fi

echo "Installing hooks..."
for pair in "${HOOKS[@]}"; do
    event="${pair%%:*}"
    script="${pair##*:}"
    mkdir -p "${COAT_TREE_HOOKS}/${event}"
    ln -sf "${SCRIPT_DIR}/${script}" "${COAT_TREE_HOOKS}/${event}/${HOOK_PREFIX}"
    echo "  ${event}/${HOOK_PREFIX}"
done

echo "Done."
