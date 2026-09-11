#!/bin/sh
# Build and launch Hermes Agent Dock as a real macOS app bundle.
# Running `swift run` directly does not reliably transfer keyboard focus from
# the invoking terminal to this menu-bar application.

set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$PROJECT_DIR/.build/arm64-apple-macosx/debug"
APP_PATH="$BUILD_DIR/HermesAgentDock.app"
EXECUTABLE_PATH="$BUILD_DIR/HermesAgentDock"
APP_IDENTIFIER="com.christian.HermesAgentDock"
PROCESS_NAME="HermesAgentDock"

cd "$PROJECT_DIR"

# Always ask SwiftPM to build. It is incremental, but it owns the full input
# graph (including generated sources and package metadata), unlike a shell
# timestamp probe that can incorrectly reuse an old executable after edits.
echo "[1/4] Building Hermes Agent Dock..."
swift build --disable-automatic-resolution

echo "[2/4] Closing running Hermes Agent Dock instances..."
existing_pids=$(pgrep -x "$PROCESS_NAME" 2>/dev/null || true)
if [ -n "$existing_pids" ]; then
    # A live process can keep an older signed executable and status-item host
    # alive while the bundle is replaced. Terminate the exact resolved PIDs so
    # this launch cannot silently reuse that stale app instance.
    kill $existing_pids 2>/dev/null || true
fi

# Wait for macOS to finish tearing down the old process before replacing and
# reopening its bundle. Without this, Launch Services can reactivate the old
# instance even though a newly-built executable is already on disk.
attempt=0
while pgrep -x "$PROCESS_NAME" >/dev/null 2>&1 && [ "$attempt" -lt 50 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
done

if pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
    echo "Force-stopping stale $PROCESS_NAME process(es)..."
    stale_pids=$(pgrep -x "$PROCESS_NAME" 2>/dev/null || true)
    if [ -n "$stale_pids" ]; then
        kill -KILL $stale_pids 2>/dev/null || true
    fi
    attempt=0
    while pgrep -x "$PROCESS_NAME" >/dev/null 2>&1 && [ "$attempt" -lt 20 ]; do
        sleep 0.1
        attempt=$((attempt + 1))
    done
    if pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
        echo "Could not stop the existing $PROCESS_NAME process." >&2
        exit 1
    fi
fi

echo "[3/4] Replacing and signing the debug app bundle..."
mkdir -p "$APP_PATH/Contents/MacOS"
cp "$EXECUTABLE_PATH" "$APP_PATH/Contents/MacOS/HermesAgentDock"
cp "$PROJECT_DIR/Sources/HermesAgentDock/Info.plist" "$APP_PATH/Contents/Info.plist"
codesign --force --sign - --identifier "$APP_IDENTIFIER" "$APP_PATH"
codesign --verify --strict "$APP_PATH"

echo "[4/4] Launching the newly-built app..."
# Hermes is a menu-bar app. Explicitly request the panel for debug launches so
# startup exercises the same presentation path users see when opening it.
rm -f /private/tmp/hermes-status-item-diagnostic.txt
open -n "$APP_PATH" --args --show-panel --status-item-diagnostics --perf-trace

# `open` only confirms that Launch Services accepted the request; it returns
# success even if the app crashes during its first layout pass. Wait for a
# stable process so this script has an honest success/failure result.
attempt=0
while ! pgrep -x "$PROCESS_NAME" >/dev/null 2>&1 && [ "$attempt" -lt 50 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
done

if ! pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
    echo "Hermes Agent Dock exited during startup. Check the newest crash report in:" >&2
    echo "  ~/Library/Logs/DiagnosticReports/HermesAgentDock-*.ips" >&2
    exit 1
fi

# The known transcript crash occurs immediately after the menu-bar item is
# registered, so ensure the process also survives that first presentation.
sleep 2
if ! pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
    echo "Hermes Agent Dock crashed during initial presentation. Check the newest crash report in:" >&2
    echo "  ~/Library/Logs/DiagnosticReports/HermesAgentDock-*.ips" >&2
    exit 1
fi

echo "Hermes Agent Dock is running."
if [ -f /private/tmp/hermes-status-item-diagnostic.txt ]; then
    echo "Status-item diagnostic:"
    sed -n '1,5p' /private/tmp/hermes-status-item-diagnostic.txt
fi
