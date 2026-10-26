# Bundled protocol sources

`emulator_controller.proto`: Android SDK Emulator's published controller protocol,
Copyright 2018 The Android Open Source Project, Apache-2.0. See LICENSE-android.
Source: https://android.googlesource.com/platform/tools/base/+/refs/heads/mirror-goog-studio-main/emulator/proto/emulator_controller.proto

`idb.proto`: facebook/idb protocol retrieved 2026-10-26,
Copyright Meta Platforms, Inc. and affiliates, MIT. See LICENSE-idb.
Source: https://github.com/facebook/idb/blob/main/proto/idb.proto

The corresponding `_pb2.py` files are generated bindings, not handwritten code.
Regenerate with grpcio-tools 1.78.0:

```
python -m grpc_tools.protoc -I . --python_out=. idb.proto emulator_controller.proto
```

`bridge.py` is Herm's local adapter. Only display, input, and target description
RPCs are used. No desktop-window capture or unauthenticated network fallback exists.
