#!/bin/sh
set -eu
# Separate environment: never modify the user's system Python installation.
BRIDGE_ENV="${HERM_SIMULATOR_ENV:-$HOME/Library/Application Support/Herm/simulator-bridge}"
python3 -m venv "$BRIDGE_ENV"
"$BRIDGE_ENV/bin/python3" -m pip install 'grpcio==1.78.0' 'protobuf==6.33.5'
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
mkdir -p "$BRIDGE_ENV/resources"
cp "$SCRIPT_DIR"/../Sources/Herm/Resources/SimulatorBridge/*.py "$BRIDGE_ENV/resources/"
echo "Direct simulator bridge installed. For iOS also install: brew install facebook/fb/idb-companion"
