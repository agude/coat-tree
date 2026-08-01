#!/bin/bash
#
# Pre-commit hook: runs the repo's read-only checks via the task runner.
#
# This script deliberately contains no tool commands. `just lint` is the one
# definition of what "clean" means; the hook, CI, and the developer all call
# it. Install with `just hooks-install`.

STAGED=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.(sh|bats)$' || true)

if [ -z "$STAGED" ]; then
    exit 0
fi

if ! command -v just >/dev/null 2>&1; then
    echo "❌ just is not on PATH; cannot run the pre-commit checks." >&2
    exit 1
fi

echo "---"
echo "Running shellcheck on staged shell files..."
echo "---"

if ! just lint; then
    echo "---"
    echo "❌ Lint failed."
    exit 1
fi

echo "✅ Lint passed."
exit 0
