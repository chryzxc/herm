#!/bin/sh
# Build Herm as a signed .app bundle and package it into a .dmg.
#
# Usage:
#   Scripts/package-app.sh [version]
#
# When [version] is provided it is stamped into the bundle's
# CFBundleShortVersionString / CFBundleVersion.
# CI can prepare an unsigned app with HERM_RELEASE_APP_ARCHIVE, then package the
# extracted bundle with HERM_PREBUILT_APP without repeating the Swift build.
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_NAME="Herm"
APP_DISPLAY="Herm"
VERSION="${1:-}"
SIGNING_IDENTITY="${HERM_CODESIGN_IDENTITY:--}"

. "$ROOT_DIR/Scripts/appintents.sh"

OUTPUT_DIR="$ROOT_DIR/dist"
if [ -n "${HERM_PREBUILT_APP:-}" ]; then
    APP_DIR=$HERM_PREBUILT_APP
    echo "==> Using the release app built by CI…"
    # The packaging workflow builds the optional host from its pinned revision.
    PLUGIN_HOST="$ROOT_DIR/Sources/Herm/Resources/DesktopPluginHost"
    if [ -f "$PLUGIN_HOST/sdk/sdk.js" ]; then
        RESOURCE_BUNDLE="$APP_DIR/Contents/Resources/Herm_Herm.bundle"
        if [ -d "$RESOURCE_BUNDLE/Contents/Resources" ]; then
            RESOURCE_BUNDLE="$RESOURCE_BUNDLE/Contents/Resources"
        fi
        PLUGIN_RESOURCES="$RESOURCE_BUNDLE/DesktopPluginHost"
        test -d "$PLUGIN_RESOURCES"
        rm -rf "$PLUGIN_RESOURCES/sdk"
        cp -R "$PLUGIN_HOST/sdk" "$PLUGIN_RESOURCES/sdk"
    fi
else
    echo "==> Building release (this may take a while)…"
    swift_build_with_appintents -c release --disable-automatic-resolution --package-path "$ROOT_DIR"
    BIN_DIR=$(swift build -c release --show-bin-path --package-path "$ROOT_DIR")
    APP_DIR="$BIN_DIR/${APP_NAME}.app"

    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
    cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
    cp "$ROOT_DIR/Sources/Herm/Info.plist" "$APP_DIR/Contents/Info.plist"
    cp "$ROOT_DIR/Sources/Herm/Resources/DockAppIcon.icns" "$APP_DIR/Contents/Resources/DockAppIcon.icns"
    # SwiftPM resource bundles ship inside the app for Bundle.module to find on other Macs.
    cp -R "$BIN_DIR/Herm_Herm.bundle" "$BIN_DIR/SwiftTerm_SwiftTerm.bundle" "$APP_DIR/Contents/Resources/"
    embed_appintents_metadata "$BIN_DIR" "$APP_DIR/Contents/Resources"
fi

echo "==> Validating bundle metadata…"
plutil -lint "$APP_DIR/Contents/Info.plist"
test -x "$APP_DIR/Contents/MacOS/$APP_NAME"

if [ -n "${HERM_RELEASE_APP_ARCHIVE:-}" ]; then
    tar -C "$(dirname "$APP_DIR")" -czf "$HERM_RELEASE_APP_ARCHIVE" "$(basename "$APP_DIR")"
    exit 0
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Stamp version metadata into the bundle when provided.
if [ -n "$VERSION" ]; then
    PLIST="$APP_DIR/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$PLIST" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$PLIST" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"
fi

# Nightly builds carry their channel and commit so Settings can label them.
if [ -n "${HERM_BUILD_CHANNEL:-}" ]; then
    PLIST="$APP_DIR/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :HermBuildChannel string $HERM_BUILD_CHANNEL" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :HermBuildCommit string ${HERM_BUILD_COMMIT:-}" "$PLIST"
fi

# Keep the signing identity stable across releases when a certificate is configured.
if [ "$SIGNING_IDENTITY" = "-" ]; then
    echo "Warning: ad-hoc signing changes Herm’s privacy identity on rebuild."
    echo "Set HERM_CODESIGN_IDENTITY to a stable signing certificate to retain permission grants."
fi
codesign --force --deep --sign "$SIGNING_IDENTITY" --identifier io.github.chryzxc.Herm "$APP_DIR"
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
