# Herm simulator tool

This user-installed Hermes plugin adds `herm_simulator` to the existing terminal
toolset using `PluginContext.register_tool`. Hermes supplies its tool schema to
the agent. No engine patch, custom RPC, keyword interception, or transcript
scraping is required. The installed engine's `tool.complete` event carries the
JSON result; Herm admits only a successful, live completion of this named tool
in the current session, from the local host.

The agent can infer the platform from the conversation or supply a project
folder for automatic detection. A sole running device is reused. Otherwise a
sole installed device is selected, or a structured device list is returned so
the agent can resolve the choice from context or ask. Explicit device IDs/names
must match exactly. Cross-platform projects require conversational context.
`list` never starts a device. `launch` waits for confirmed boot and returns the
device ID for subsequent build/install/run commands through existing tools.

Installation (after reviewing these two source files):

```sh
mkdir -p ~/.hermes/plugins/herm-simulator
cp integrations/herm-simulator/plugin.yaml integrations/herm-simulator/__init__.py ~/.hermes/plugins/herm-simulator/
hermes plugins enable herm-simulator
```

Enable in each Hermes profile where the tool is needed. Existing agent sessions
may retain their cached tool catalog: start a new session after activation.
If the CLI reports a backend restart is needed, restart only when live work has
finished. Herm also needs the updated app build; this integration does not
relaunch either application automatically.

Examples: “Launch the iOS simulator”, “Open the Android emulator for this
project”, “Run this app on the iPhone simulator”. Build/install/run remains the
agent's normal project workflow; the launch tool does not invent a build command.

Requirements: a local macOS gateway, Xcode/iOS runtimes or Android SDK and AVDs,
terminal tools enabled, and the [direct bridge](../../docs/direct-simulators.md).
iOS boots through simctl without opening Simulator.app. New Android devices start
with `-no-window -grpc-use-token`. Existing devices are reused without restarting
them, so an already-open external window is not forcibly closed. There is no
window capture fallback. Device processes survive tab closure and startup timeout.

Validation: `python3 -B -m unittest discover -s integrations/herm-simulator`.
Tests substitute the device commands; they never start a real emulator.
