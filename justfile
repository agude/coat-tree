# Task runner for coat-tree. See the project-standards skill for the verb
# contract: lint is read-only and total, and check is the full gate CI runs.
#
# This is a Bash repo, so there is no formatter and no `format` recipe —
# omitted rather than aliased to something that does not format.

# Default: list available recipes
default:
    @just --list

# All read-only static checks
lint:
    shellcheck dispatch.sh $(find examples -name '*.sh')

# Run the bats suite
test *args:
    bats tests/ {{ args }}

# Everything CI runs
check: lint test

# Install the pre-commit hook into this clone
hooks-install:
    @mkdir -p .git/hooks
    @cp bin/pre-commit.sh .git/hooks/pre-commit
    @chmod +x .git/hooks/pre-commit
    @echo "Pre-commit hook installed."
