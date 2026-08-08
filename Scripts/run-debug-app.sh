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

cd "$PROJECT_DIR"
swift build

pkill -f "$APP_PATH/Contents/MacOS/HermesAgentDock" 2>/dev/null || true
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
cp "$EXECUTABLE_PATH" "$APP_PATH/Contents/MacOS/HermesAgentDock"
cp "$PROJECT_DIR/Sources/HermesAgentDock/Info.plist" "$APP_PATH/Contents/Info.plist"
codesign --force --sign - --identifier "$APP_IDENTIFIER" "$APP_PATH"
codesign --verify --strict "$APP_PATH"
open "$APP_PATH"
