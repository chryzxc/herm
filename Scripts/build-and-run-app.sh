#!/bin/sh
# Compatibility entry point. Keep legacy callers on the canonical launcher
# while the old name remains in circulation; remove this wrapper in the next
# minor release after callers have migrated.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$SCRIPT_DIR/run-debug-app.sh" "$@"
