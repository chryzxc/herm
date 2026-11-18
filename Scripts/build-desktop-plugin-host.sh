#!/bin/sh
# Rebuilds Sources/Herm/Resources/DesktopPluginHost/sdk from a Hermes Agent checkout, so plugin
# pages link against Hermes Desktop's real SDK, React and stylesheet.
#   Scripts/build-desktop-plugin-host.sh [path/to/hermes-agent]   (default ~/.hermes/hermes-agent)
# Release builds use the revision in Scripts/desktop-plugin-host/HERMES_REVISION; build from that
# commit (and update the file) when refreshing the host, so the checked-in sdk-exports.json matches.
# Needs bun and the checkout's installed node_modules (Vite and Tailwind come from there). The output
# is git-ignored; `make package` runs this when it is missing. The checkout is only read.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
hermes=${1:-"$HOME/.hermes/hermes-agent"}
bun "$root/Scripts/desktop-plugin-host/build.ts" "$hermes/apps/desktop"
echo "sdk: $(du -sh "$root/Sources/Herm/Resources/DesktopPluginHost/sdk" | cut -f1)"
