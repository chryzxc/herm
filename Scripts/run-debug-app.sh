#!/bin/sh
# Build and launch Herm as a real macOS app bundle.
# Running `swift run` directly does not reliably transfer keyboard focus from
# the invoking terminal to this menu-bar application.

set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IDENTIFIER="app.herm.Herm"
PROCESS_NAME="Herm"

cd "$PROJECT_DIR"
. "$PROJECT_DIR/Scripts/appintents.sh"

# Keep debug builds independent from user-level Swift/Clang caches. This is
# important in managed environments where ~/.cache may be read-only, and it
# also makes the script reproducible when launched from Xcode or a terminal.
DEBUG_CACHE_DIR="$PROJECT_DIR/.build/debug-cache"
mkdir -p "$DEBUG_CACHE_DIR/clang-module-cache" "$DEBUG_CACHE_DIR/swiftpm-cache" "$DEBUG_CACHE_DIR/scratch"
export CLANG_MODULE_CACHE_PATH="$DEBUG_CACHE_DIR/clang-module-cache"

# Serialize launches. Concurrent runs (terminal, agents, worktrees) would each
# pass the close step below and leave several Herm instances alive; queued, the
# last run closes the previous one, so exactly one stays up.
LOCK_DIR="$DEBUG_CACHE_DIR/run-debug-app.lock"
until mkdir "$LOCK_DIR" 2>/dev/null; do
    holder=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
        rm -rf "$LOCK_DIR"
        continue
    fi
    echo "Waiting for another Herm launch (pid ${holder:-?}) to finish..."
    sleep 1
done
echo $$ >"$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT
trap 'exit 1' INT TERM

# Always ask SwiftPM to build. It is incremental, but it owns the full input
# graph (including generated sources and package metadata), unlike a shell
# timestamp probe that can incorrectly reuse an old executable after edits.
echo "[1/4] Building Herm..."
swift_build_with_appintents \
    --disable-automatic-resolution \
    --disable-sandbox \
    --cache-path "$DEBUG_CACHE_DIR/swiftpm-cache" \
    --scratch-path "$DEBUG_CACHE_DIR/scratch"

# SwiftPM places products under the scratch path when one is supplied. Ask it
# for the authoritative bin directory instead of assuming the default .build
# location, which can otherwise leave the app bundle running an older binary.
BUILD_DIR=$(swift build \
    --disable-automatic-resolution \
    --disable-sandbox \
    --cache-path "$DEBUG_CACHE_DIR/swiftpm-cache" \
    --scratch-path "$DEBUG_CACHE_DIR/scratch" \
    --show-bin-path)
APP_PATH="$BUILD_DIR/Herm.app"
EXECUTABLE_PATH="$BUILD_DIR/Herm"

echo "[2/4] Closing running Herm instances..."
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

# Herm's `hermes serve` backends lead their own process group, so they survive
# the app and get reparented to launchd. An orphan keeps holding its session
# lock ("This chat is open in another Hermes window"), so reap them — plus
# their MCP children — now that Herm is gone.
orphan_backends() {
    ps -axo pid=,ppid=,command= | awk '$2 == 1 && / serve --host 127\.0\.0\.1 --port 0$/ { print $1 }'
}
orphans=$(orphan_backends)
if [ -n "$orphans" ]; then
    echo "Stopping orphaned Hermes backend(s): $(echo $orphans)"
    for pid in $orphans; do kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true; done
    attempt=0
    while [ -n "$(orphan_backends)" ] && [ "$attempt" -lt 30 ]; do
        sleep 0.1
        attempt=$((attempt + 1))
    done
    for pid in $(orphan_backends); do kill -KILL -- "-$pid" 2>/dev/null || true; done
fi

echo "[3/4] Replacing and signing the debug app bundle..."
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$EXECUTABLE_PATH" "$APP_PATH/Contents/MacOS/Herm"
cp "$PROJECT_DIR/Sources/Herm/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$PROJECT_DIR/Sources/Herm/Resources/DockAppIcon.icns" "$APP_PATH/Contents/Resources/DockAppIcon.icns"
# Keep SwiftPM image resources inside the signed app so it remains self-contained.
cp -R "$BUILD_DIR/Herm_Herm.bundle" "$APP_PATH/Contents/Resources/"
cp -Rf "$BUILD_DIR/SwiftTerm_SwiftTerm.bundle" "$APP_PATH/Contents/Resources/"
embed_appintents_metadata "$BUILD_DIR" "$APP_PATH/Contents/Resources"
# `cp` can retain a restrictive mode from an older bundle. Launch Services
# requires the bundle executable to be discoverable as a normal app binary.
chmod 755 "$APP_PATH/Contents/MacOS/Herm"
codesign --force --sign - --identifier "$APP_IDENTIFIER" "$APP_PATH"
codesign --verify --strict "$APP_PATH"

echo "[4/4] Launching the newly-built app..."
# Hermes is a menu-bar app. Explicitly request the panel for debug launches so
# startup exercises the same presentation path users see when opening it.
rm -f /private/tmp/hermes-status-item-diagnostic.txt

# Optional debug flags (only when explicitly enabled via environment variable).
# Performance tracing adds I/O overhead in hot paths; enable only when debugging.
DEBUG_ARGS=""
if [ "${HERMES_DOCK_DEBUG:-0}" = "1" ]; then
    DEBUG_ARGS="--status-item-diagnostics --perf-trace"
fi

if ! open -n "$APP_PATH" --args --show-panel $DEBUG_ARGS; then
    # Launch Services is unavailable in some managed/headless environments.
    # The signed bundle executable still has the same Bundle.main context, so
    # use it as a deterministic fallback instead of reporting a false build
    # failure.
    echo "Launch Services unavailable; starting the bundle executable directly..."
    "$APP_PATH/Contents/MacOS/Herm" \
        --show-panel \
        $DEBUG_ARGS \
        >/private/tmp/hermes-debug-app.log 2>&1 &
fi

# `open` only confirms that Launch Services accepted the request; it returns
# success even if the app crashes during its first layout pass. Wait for a
# stable process so this script has an honest success/failure result.
attempt=0
while ! pgrep -x "$PROCESS_NAME" >/dev/null 2>&1 && [ "$attempt" -lt 50 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
done

if ! pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
    echo "Herm exited during startup. Check the newest crash report in:" >&2
    echo "  ~/Library/Logs/DiagnosticReports/Herm-*.ips" >&2
    exit 1
fi

# The known transcript crash occurs immediately after the menu-bar item is
# registered, so ensure the process also survives that first presentation.
sleep 2
if ! pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
    echo "Herm crashed during initial presentation. Check the newest crash report in:" >&2
    echo "  ~/Library/Logs/DiagnosticReports/Herm-*.ips" >&2
    exit 1
fi

echo "Herm is running."
if [ -f /private/tmp/hermes-status-item-diagnostic.txt ]; then
    echo "Status-item diagnostic:"
    sed -n '1,5p' /private/tmp/hermes-status-item-diagnostic.txt
fi
