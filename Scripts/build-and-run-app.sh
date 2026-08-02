#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN_DIR=$(swift build --show-bin-path --package-path "$ROOT_DIR")
APP_DIR="$BIN_DIR/HermesAgentDock.app"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/HermesAgentDock" "$APP_DIR/Contents/MacOS/HermesAgentDock"
cp "$ROOT_DIR/Sources/HermesAgentDock/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --sign - "$APP_DIR"
open "$APP_DIR"
