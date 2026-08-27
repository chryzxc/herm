#!/bin/sh
# Build HermesAgentDock as a signed .app bundle and package it into a .dmg.
#
# Usage:
#   Scripts/package-app.sh [version]
#
# When [version] is provided it is stamped into the bundle's
# CFBundleShortVersionString / CFBundleVersion.
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_NAME="HermesAgentDock"
APP_DISPLAY="Hermes Agent Dock"
VERSION="${1:-}"

echo "==> Building release (this may take a while)…"
swift build -c release --package-path "$ROOT_DIR"
BIN_DIR=$(swift build -c release --show-bin-path --package-path "$ROOT_DIR")
APP_DIR="$BIN_DIR/${APP_NAME}.app"
OUTPUT_DIR="$ROOT_DIR/dist"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Assemble .app bundle.
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Sources/HermesAgentDock/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "==> Validating bundle metadata…"
plutil -lint "$APP_DIR/Contents/Info.plist"
test -x "$APP_DIR/Contents/MacOS/$APP_NAME"

# Stamp version metadata into the bundle when provided.
if [ -n "$VERSION" ]; then
    PLIST="$APP_DIR/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$PLIST" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$PLIST" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"
fi

# Ad-hoc sign so the bundle launches on a clean macOS install.
codesign --force --deep --sign - "$APP_DIR"
echo "==> Verifying code signature…"
codesign --verify --strict --verbose=2 "$APP_DIR"
codesign -dv --verbose=2 "$APP_DIR" >/dev/null 2>&1

# Stage a DMG source folder with an /Applications symlink for drag-to-install.
STAGING="$OUTPUT_DIR/staging"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

DMG_PATH="$OUTPUT_DIR/${APP_NAME}.dmg"
echo "==> Creating ${DMG_PATH}…"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_DISPLAY" -fs HFS+ \
    -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"

# Tidy up staging; keep the .dmg.
rm -rf "$STAGING"

echo "==> Done"
echo "    App: $APP_DIR"
echo "    DMG: ${DMG_PATH}"
