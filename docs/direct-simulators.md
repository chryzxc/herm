# Direct simulator tabs

Herm displays device pixels and sends input directly. It never captures or embeds
the Simulator.app / Android Emulator desktop window. Screen Recording and macOS
Accessibility permissions are not used by these tabs.

## Setup

From the Herm project:

```sh
Scripts/setup-simulator-bridge.sh
# iOS only:
brew install facebook/fb/idb-companion
```

The setup script installs pinned Python gRPC/protobuf packages in
`~/Library/Application Support/Herm/simulator-bridge`, separate from system Python.
Python 3.10+ is required. Advanced installations can set `HERM_SIMULATOR_PYTHON`
to the Python executable in an equivalent environment. Distributing Herm.app alone
does not install these dependencies; run setup on each Mac. The bundled bridge
and protocol definitions ship as app resources, with upstream license notices.

Select a full Xcode installation with installed iOS runtimes. The idb companion
must support that Xcode/runtime version. Android needs SDK Emulator and an AVD.
Update the user-installed `herm_simulator` plugin using its README installation
steps to pick up headless launch arguments. Existing agent sessions may need a new
session to load the updated plugin code; this change does not restart them.

## Use

Ask chat to launch an iOS simulator or Android emulator. A verified launch receipt
opens the owning session's tab and selects its exact device. You can also open a
tab from the inspector + menu and choose a running device. A sole device is selected
automatically; multiple devices require selection.

Click the display to focus, drag to swipe, and type to send keys. Home and Power
are available on both platforms; Android has Back and Apps. Reconnect retries the
selected device. Refresh discovers newly booted devices. Hidden/closed tabs stop
the bridge and release held input without shutting down the virtual device.

## Connections and limitations

- Android reads the local emulator discovery file, connects only to loopback, and
  uses its bearer token. Tokens are never placed in arguments, output, or Herm state.
  New plugin launches use `-no-window -grpc-use-token`. A reused emulator keeps its
  existing window if it had one; Herm never captures it. Tokenless/JWT-only
  configurations fail with setup guidance rather than disabling authentication.
- iOS starts an owned companion on a private temporary Unix socket and shuts down
  only that companion on disconnect. Device pixels use MJPEG; touch coordinates
  use the companion's point dimensions. The bridge requires idb, not only simctl.
- Input is single-touch. Hardware keyboard support is limited to mapped keys on
  iOS; IME/composed Unicode text, multi-touch, and clipboard sharing are not yet
  supported. Use device controls or the on-screen keyboard where needed.
- A failed stream clears the display and presents recovery. No window mirroring
  or external-app fallback is offered. A static screen is not treated as a timeout
  after its first frame. The first-frame deadline is 30 seconds.

## Verification

```sh
"$HOME/Library/Application Support/Herm/simulator-bridge/bin/python3" -B Scripts/test-simulator-bridge.py
python3 -B integrations/herm-simulator/test_plugin.py
swift test --disable-automatic-resolution --no-parallel --filter SessionSimulatorTests
make guard
```

Protocol sources: Android SDK emulator `lib/emulator_controller.proto` (Apache-2.0)
and facebook/idb `proto/idb.proto` (MIT). Python bindings were generated with
`grpcio-tools==1.78.0`; regenerate both when updating protocols. This is a local
integration, not remote device forwarding.

**Settings → Chat → Simulators → Open simulators in Herm** defaults on. At the
Herm RPC boundary, each submitted message, redirect, and steer carries the current
launch preference. When on, agents are instructed to use `herm_simulator`, report
missing tooling instead of opening external windows, and use returned device IDs
for app build/install commands. Successful local launch receipts automatically
open the matching session tab only while this preference is on. Turning it off
sends an explicit override of previous ON instructions on the next message and
stops automatic tab opening; existing devices and manually opened tabs stay intact.
This is agent guidance, not a terminal-command security boundary or runtime veto.
