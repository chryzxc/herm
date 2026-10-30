#!/bin/sh
# Source this file. SwiftPM does not produce the App Intents metadata that
# Shortcuts and Spotlight read, so build with the compiler's const-value output
# and run Apple's metadata processor over it by hand (what Xcode does).
#
#   . "$ROOT_DIR/Scripts/appintents.sh"
#   swift_build_with_appintents <swift build args…>
#   embed_appintents_metadata <bin-dir> <App.app/Contents/Resources>

APPINTENTS_ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE:-$0}")/.." && pwd)

# The Metal toolchain mounts at a new path after a reboot or Xcode update, but
# SwiftPM's build description keeps the old one and fails with "unable to spawn
# process ... metal". Drop that cached state whenever the path changes.
reset_stale_metal_cache() {
    scratch=$APPINTENTS_ROOT/.build
    while [ $# -gt 0 ]; do
        [ "$1" = "--scratch-path" ] && scratch=$2
        shift
    done
    metal=$(xcrun --find metal 2>/dev/null) || return 0
    # Xcode updates drop the downloadable Metal Toolchain; SwiftTerm's shaders
    # then fail deep in the build with an opaque CompileMetalFile error.
    if ! xcrun metal --version >/dev/null 2>&1; then
        echo "error: Metal Toolchain missing. Run: xcodebuild -downloadComponent MetalToolchain" >&2
        return 1
    fi
    stamp=$scratch/.metal-toolchain-path
    [ "$(cat "$stamp" 2>/dev/null)" = "$metal" ] && return 0
    rm -rf "$scratch/out/XCBuildData" "$scratch/out/Intermediates.noindex/XCBuildData" \
        "$scratch/out/Intermediates.noindex/SwiftTerm.build" \
        "$scratch/out/Products/"*/SwiftTerm_SwiftTerm.bundle
    mkdir -p "$scratch" && printf %s "$metal" > "$stamp"
}

swift_build_with_appintents() {
    reset_stale_metal_cache "$@"
    swift build "$@" \
        -Xswiftc -emit-const-values \
        -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file \
        -Xswiftc -Xfrontend -Xswiftc "$APPINTENTS_ROOT/Scripts/appintents-protocols.json"
}

embed_appintents_metadata() {
    bin_dir=$1
    resources_dir=$2
    work=$(mktemp -d)
    # Xcode 27's SwiftPM keeps intermediates outside the bin dir.
    if ! ls "$bin_dir"/Herm.build/*.swiftconstvalues > "$work/const.list" 2>/dev/null; then
        find "$bin_dir/../../Intermediates.noindex/Herm.build/$(basename "$bin_dir")" \
            -name '*.swiftconstvalues' > "$work/const.list"
        test -s "$work/const.list"
    fi
    find "$APPINTENTS_ROOT/Sources/Herm" -name '*.swift' > "$work/src.list"
    : > "$work/meta.list"
    xcrun appintentsmetadataprocessor \
        --output "$work/out" \
        --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
        --module-name Herm \
        --sdk-root "$(xcrun --show-sdk-path)" \
        --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
        --platform-family macOS \
        --deployment-target 14.0 \
        --target-triple "$(uname -m)-apple-macosx14.0" \
        --source-file-list "$work/src.list" \
        --swift-const-vals-list "$work/const.list" \
        --metadata-file-list "$work/meta.list" \
        --static-metadata-file-list "$work/meta.list"
    rm -rf "$resources_dir/Metadata.appintents"
    cp -R "$work/out/Metadata.appintents" "$resources_dir/Metadata.appintents"
    rm -rf "$work"
}
