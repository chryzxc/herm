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

A compact banner at the top of the chat identifies a simulator launched through
that session's tool flow once its direct display is connected. **Open tab** focuses
the matching simulator tab. A launch receipt alone never shows Connected. Other
sessions and manually selected unrelated devices do not acquire the banner. It
clears on disconnect, tab closure, or when the simulator surface becomes inactive;
the virtual device may remain running. The banner shares the existing chat overlay
slot so connection changes do not shift the header or transcript.

## Inspect and attach debugging context

**Annotate** freezes the displayed frame and reads the device UI hierarchy. Hover
highlights accessible elements; click selects the smallest matching element, or
drag to select a screenshot region. A comment popover opens at the selection. **Send** adds your comment, the cropped image
and available label, identifier, role, value, and normalized bounds to the current
session's draft. Custom-drawn controls may have no accessible metadata; region
selection remains available. **Stop annotating** or Escape returns to live input; sending also resumes input. Hierarchy reads
and display frames are separate snapshots, so animated screens can differ slightly.

**Send screenshot** adds a screenshot and device context. The debugging menu also
provides **Copy screenshot** and **App logs**. Android logs require an explicit
package ID and SDK platform-tools; they read up to 500 buffered entries for the
main app PID. iOS logs require the executable process name and read the last two
minutes of unified logs. Choose Errors or All levels, then edit the excerpt before
attaching it. These are on-demand snapshots, not continuous recording. They do
not include every crash report or stdout-only message. No message is sent automatically.

Requests have timeouts and bounded output. Diagnostic failures do not close the
direct display. Switching devices or disconnecting clears the inspector and logs;
stale responses cannot attach to another session. No desktop mirroring is used.

Manual device selection takes priority over an already-present launch receipt.
Choosing the empty device option stays unselected instead of reconnecting to the
only running device. Switching immediately invalidates the previous stream.
Inspector and log state belong to the retained device connection, so parent view
updates do not detach the controls from their results. The log sheet explains
that an app filter is required before Read logs becomes available.

## Setup and device shell

Both tabs remain available from + even before SDK installation. Discovery checks
Xcode's simctl or Android SDK emulator/adb, not IDE installation alone. Missing
tools produce setup guidance; an empty inventory explains where to create a device.
Stopped devices appear in the picker and require **Start device**. A sole running
device can connect automatically until the user makes a manual choice. Android
starts with `-no-window -grpc-use-token`; iOS boots through simctl without opening
Simulator.app. Boot timeouts leave the virtual device intact; check again before
retrying. Closing Herm's connection does not shut down the virtual device.

The neutral rounded device shell is presentation only, not a model-specific skin.
It uses the same screen rectangle for drawing, touch, and annotation. Screenshots
contain original device pixels, without the shell. Camera cutouts and system bars
are not overlaid or duplicated. No desktop window is captured.

## Device-side actions and 3D preview

Actions are arranged vertically beside the device in the black canvas. Power and
Copy screenshot are separate icons. The rail never covers the screen; its width
is reserved before scaling the display and it scrolls in short panels.

The cube icon opens a rotatable presentation of the live display. Drag or use
arrow keys to tilt the device; horizontal rotation is continuous, vertical tilt is limited, and scrolling controls zoom.
This neutral shell is a presentation effect, not an exact hardware model. Device
input and annotation pause while previewing; screenshots and logs remain available.
Return to device, the cube icon, or Escape restores flat interaction. Switching
devices or disconnecting resets the preview. Captured screenshots contain original
pixels without the shell, rotation, or action rail.

The simulator action rail is vertically centered beside the display and fits its visible actions. Empty feedback adds no row. The 3D preview uses a rounded solid body with a live front screen, continuous horizontal orbit, constrained vertical tilt, scroll zoom, double-click/Reset view, and Escape to return.

Both simulator tabs open 3D preview flat and front-facing. Dragging uses viewport-relative orbit with fixed framing, so rotation does not pump the zoom. Reset view returns to flat; the cube icon or Escape exits preview. App logs groups the app filter and severity above an editable excerpt, with a clear empty state and Attach logs action that adds only the reviewed text to the chat draft.
