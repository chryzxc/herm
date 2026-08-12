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

if [ -x "$EXECUTABLE_PATH" ] && \
   ! find "$PROJECT_DIR/Sources" "$PROJECT_DIR/Package.swift" "$PROJECT_DIR/Package.resolved" \
        -newer "$EXECUTABLE_PATH" -print -quit | grep -q .; then
    echo "[1/4] Debug build is up to date; skipping SwiftPM build."
else
    echo "[1/4] Building Hermes Agent Dock..."
    swift build --disable-automatic-resolution
fi

echo "[2/4] Closing running Hermes Agent Dock instances..."
pkill -x "$PROCESS_NAME" 2>/dev/null || true

# Wait for macOS to finish tearing down the old process before replacing and
# reopening its bundle. Without this, Launch Services can reactivate the old
# instance even though a newly-built executable is already on disk.
attempt=0
while pgrep -x "$PROCESS_NAME" >/dev/null 2>&1 && [ "$attempt" -lt 50 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
done

if pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
    echo "Could not stop the existing $PROCESS_NAME process." >&2
    exit 1
fi

echo "[3/4] Replacing and signing the debug app bundle..."
mkdir -p "$APP_PATH/Contents/MacOS"
cp "$EXECUTABLE_PATH" "$APP_PATH/Contents/MacOS/HermesAgentDock"
cp "$PROJECT_DIR/Sources/HermesAgentDock/Info.plist" "$APP_PATH/Contents/Info.plist"
codesign --force --sign - --identifier "$APP_IDENTIFIER" "$APP_PATH"
codesign --verify --strict "$APP_PATH"

echo "[4/4] Launching the newly-built app..."
open -n "$APP_PATH"
