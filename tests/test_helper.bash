# Shared bats setup. Sourced from each *.bats file.

PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
DISPATCH="$PROJECT_ROOT/dispatch.sh"

# Run the dispatcher with a JSON event on stdin.
run_dispatch() {
    local input="$1"
    printf '%s' "$input" | "$DISPATCH"
}

# Create an executable hook script under the current COAT_TREE_DIR.
# Usage: make_hook <event> <filename> <body>
make_hook() {
    local event="$1" name="$2" body="$3"
    mkdir -p "$COAT_TREE_DIR/hooks.d/$event"
    local path="$COAT_TREE_DIR/hooks.d/$event/$name"
    printf '%s\n' "$body" > "$path"
    chmod +x "$path"
}
