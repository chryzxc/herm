#!/bin/sh
set -eu
# Separate environment: never modify the user's system Python installation.
BRIDGE_ENV="${HERM_SIMULATOR_ENV:-$HOME/Library/Application Support/Herm/simulator-bridge}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
python3 -m venv "$BRIDGE_ENV"
"$BRIDGE_ENV/bin/python3" -m pip --isolated install --require-hashes --only-binary=:all: --index-url https://pypi.org/simple -r "$SCRIPT_DIR/../Sources/Herm/Resources/SimulatorBridge/requirements.lock"
mkdir -p "$BRIDGE_ENV/resources"
cp "$SCRIPT_DIR"/../Sources/Herm/Resources/SimulatorBridge/*.py "$BRIDGE_ENV/resources/"
echo "Direct simulator bridge installed. For iOS also install: brew install facebook/fb/idb-companion"
