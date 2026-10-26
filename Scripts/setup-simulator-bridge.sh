#!/bin/sh
set -eu
# Separate environment: never modify the user's system Python installation.
BRIDGE_ENV="${HERM_SIMULATOR_ENV:-$HOME/Library/Application Support/Herm/simulator-bridge}"
python3 -m venv "$BRIDGE_ENV"
"$BRIDGE_ENV/bin/python3" -m pip install 'grpcio==1.78.0' 'protobuf==6.33.5'
echo "Direct simulator bridge installed. For iOS also install: brew install facebook/fb/idb-companion"
