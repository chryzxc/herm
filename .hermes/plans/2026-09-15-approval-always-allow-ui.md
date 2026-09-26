# Plan: Approval "Always Allow" — Dock UI + Smart Approvals

Handoff plan for Forge (Luna). Written 2026-09-15 by Archon-pattern. One repository: `/Users/christian/Projects/hermes-agent-dock`. Engine (`~/.hermes/hermes-agent`) is READ-ONLY — never edit it; the feature is pure Dock UI plus one Hermes config command.

## Objective

Stop repeated approval prompts for the same non-risky commands: (1) add an "Always allow" choice to the Dock approval card that tells Hermes to persist the command pattern to its `command_allowlist`; (2) flip Hermes `approvals.mode` from `manual` to `smart` so low-risk commands never prompt at all. High-risk commands still prompt exactly as today.

## Verified facts (do not re-derive)

- Dock sends approval choices as plain strings: `DockModel.respondToApproval(_ choice: String)` at `Sources/HermesAgentDock/Conversation/DockModel.swift:2029` — already generic; NO signature change needed.
- Current buttons: `Sources/HermesAgentDock/Conversation/Views.swift:2368` (Deny → `"deny"`) and `:2386` (Allow once → `"once"`), inside an `HStack(spacing: 6)` approval card.
- `ApprovalPresentation` (`Sources/HermesAgentDock/ControlCenter/ControlModels.swift:150`) already extracts the exact command text into `detail` (keys `command`/`cmd`) — use it for the persistence preview line.
- Engine contract (verified in engine source, do not change): `approval.respond` accepts `choice` values including `"always"` and `"session"`. `"always"` persists the pattern into `command_allowlist` in Hermes config (future sessions honor it). Content-level (Tirith) findings are auto-downgraded to session by the engine itself.
- CLI for the viewer: `hermes config get command_allowlist` prints the persisted patterns (JSON/YAML text). Adapter pattern to copy: `HermesCLIAdapter.kanbanAttributeSession` at `Sources/HermesAgentDock/HermesRuntime/HermesCLIAdapter.swift` (bash + args word-array style) or `kanbanAttachments` (plain hermes words).

## Work packets

### WP1 — Tests first (RED)

File: `Tests/HermesAgentDockTests/HermesCLIAdapterTests.swift` (mirror the existing `CLITestRPCClient` pattern at line ~146).

1. Add `configGetCommandAllowlist()` test: expects command `'hermes' 'config' 'get' 'command_allowlist'`.
2. File `Tests/HermesAgentDockTests/ApprovalChoiceTests.swift`: pure unit test asserting the three choice constants ("deny", "once", "always") and that the always-preview text equals `"Never ask again for: " + command` for a sample `ApprovalPresentation`.

Run: `swift test --filter HermesCLIAdapterTests` and `--filter ApprovalChoiceTests` → both FAIL (RED). That is the expected outcome of WP1.

### WP2 — Adapter method (GREEN for WP1.1)

File: `Sources/HermesAgentDock/HermesRuntime/HermesCLIAdapter.swift`, next to `kanbanAttributeSession` (~line 188).

Add exactly:
```swift
func configGetCommandAllowlist() async throws -> HermesCLIResult {
    try await run(["hermes", "config", "get", "command_allowlist"])
}
```
Gate: `swift test --filter HermesCLIAdapterTests` passes.

### WP3 — Approval card UI (GREEN for WP1.2)

File: `Sources/HermesAgentDock/Conversation/Views.swift`, the button `HStack` at ~2367–2400.

1. Keep Deny and Allow once exactly as they are (do not restyle).
2. Add a third button after Allow once: title `"Always allow"`, action `model.respondToApproval("always")`, same `DockActionLabel`/`borderless`/min-height 36 styling, `minWidth: 112`, tint `Color.dockAccent` but with `opacity(0.82)` fill instead of solid so it reads secondary to Allow once. Disabled under the same `model.isRespondingToApproval`.
3. Directly BELOW the HStack, add one caption `Text` (11pt, `Color.dockMetadataText`, wrapped): `"Always allow persists this command in Hermes' allowlist. Never ask again for: "` followed by the card's command (`model`'s current approval presentation detail; reuse whatever binding the card above already uses for its detail text). If the detail is not a command (no `command`/`cmd` key — presentation title != "Run command"), show instead: `"Hermes may limit this to the current session for content findings."`.
4. Do not add menus, popovers, or new state. Do not touch Deny/once behavior.

Gate: `swift build` + `swift test --filter ApprovalChoiceTests` pass. Manual check: run `swift run --show-panel`, trigger any approval, confirm three buttons + caption render and Deny/once still work.

### WP4 — Read-only allowlist viewer in Core

Files: adapter method from WP2; new section in the Core runtime surface. Locate the existing read-only MCP inventory section in `Sources/HermesAgentDock/ControlCenter/` (search files for "MCP inventory") and copy its section pattern (header + rows + explicit unavailable state).

Behavior: on Core refresh, call `configGetCommandAllowlist()`; if it succeeds and parses to a non-empty list, render one row per pattern (monospaced 11pt) under header "Command Allowlist"; empty output → "No always-allowed commands"; command failure → the section's existing unavailable state (fail closed, no retry loop). Add a copyable footer hint only: `hermes config edit` (copy-only, never executed by the Dock).

Gate: `swift build` + full `swift test` (except pre-existing `OfficePreviewSimulationTests` failures — those are known debt, not yours).

### WP5 — Hermes approvals mode (config only, no code)

Run exactly:
```sh
hermes config set approvals.mode smart
hermes approvals test "swift test --filter HermesCLIAdapterTests"   # expect: not flagged / allowed
hermes approvals test "rm -rf /tmp/x"                                # expect: still requires approval
```
If the second command unexpectedly returns "requires approval", STOP and report — do not change any other approvals keys. Do NOT touch `cron_mode`, `single_query_mode`, `unattended_mode`, `deny`, or `timeout`.

## Validation gates (all required before COMMIT_READY)

1. `swift build` → Build complete.
2. `swift test --skip OfficePreviewSimulationTests` → all pass.
3. Manual: approval card shows Deny / Allow once / Always allow + caption; "Always allow" sends choice `"always"` (verify via DebugLog or Hermes session events), prompt disappears, and `hermes config get command_allowlist` shows the new entry after use.
4. WP5 checks pass exactly as written.

## Non-goals

- No engine edits, no session-choice menu (engine handles session downgrade), no allowlist removal UI (copy-only hint), no changes to Deny/Allow once, no direct writes to Hermes config from the Dock.

## Commit

One commit, Conventional Commits: `feat: add always-allow approval choice and allowlist viewer`.

## Stop rules

Standard: no RED after 5 minutes on WP1, `--forceExit` needed, styling divergence from neighboring components, or any engine file touched → `BLOCKED` with evidence.
