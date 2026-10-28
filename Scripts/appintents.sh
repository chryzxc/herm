#!/bin/sh
# Source this file. SwiftPM does not produce the App Intents metadata that
# Shortcuts and Spotlight read, so build with the compiler's const-value output
# and run Apple's metadata processor over it by hand (what Xcode does).
#
#   . "$ROOT_DIR/Scripts/appintents.sh"
#   swift_build_with_appintents <swift build args…>
#   embed_appintents_metadata <bin-dir> <App.app/Contents/Resources>

APPINTENTS_ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE:-$0}")/.." && pwd)

swift_build_with_appintents() {
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
