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

# Portable ISO-8601: %Y-%m-%dT%H:%M:%S%z works on both GNU and BSD date.
# GNU's `date -Iseconds` is not available on macOS.
echo "Session started at $(date '+%Y-%m-%dT%H:%M:%S%z')."
