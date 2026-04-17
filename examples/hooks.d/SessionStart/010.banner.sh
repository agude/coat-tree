#!/usr/bin/env bash
#
# Example: announce the session start time. Illustrative only — copy,
# adapt, or delete. Demonstrates:
#   - a non-tool event (no hook-matcher header)
#   - plain stdout passed through to Claude Code
#   - buffering stdin even when unused (keeps the pattern consistent
#     with hooks that do parse input)

set -uo pipefail

INPUT=$(cat)
: "${INPUT:=}"  # silence unused-var warnings in stricter environments

echo "Session started at $(date -Iseconds)."
