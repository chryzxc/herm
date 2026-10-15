#!/bin/sh
# Explicitly opt into local, credential-free workflow contract checks.
set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 herm-acceptance-PROFILE" >&2
    exit 2
fi
PROFILE_NAME=$1
case "$PROFILE_NAME" in
    herm-acceptance-*) ;;
    *) echo "Use a dedicated herm-acceptance- profile." >&2; exit 2 ;;
esac
case "$PROFILE_NAME" in
    *[!a-zA-Z0-9-]*) echo "Invalid profile name." >&2; exit 2 ;;
esac
PROFILE_DIR="$HOME/.hermes/profiles/$PROFILE_NAME"
if [ ! -d "$PROFILE_DIR" ]; then
    echo "Create the test profile through Hermes first, without cloning credentials." >&2
    exit 2
fi
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$PROJECT_DIR"
# A clean child environment prevents shell credentials and Git fixture overrides from leaking in.
env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    HERMES_HOME="$PROFILE_DIR" HERM_ACCEPTANCE_PROFILE="$PROFILE_NAME" \
    HERM_RUN_LIVE_ACCEPTANCE=1 PYTHONDONTWRITEBYTECODE=1 \
    swift test --disable-automatic-resolution --no-parallel \
    --build-path "${HERM_ACCEPTANCE_BUILD_PATH:-.build/workflow-acceptance}" \
    --filter WorkflowLiveAcceptanceTests
