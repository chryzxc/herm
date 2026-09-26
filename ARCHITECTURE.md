# Herm — Repo Map

updated: 2026-09-15 · head: ba3719e

## Entry points

- `HermApp` (`App/`) — @main SwiftUI Settings shell; all real UI lives in the menu-bar panel.
- `HermDelegate` (`App/`) — NSApplicationDelegate: owns `DockModel`, builds `DockPanelController`, installs the double-tap-Command shortcut, requests notifications.
- `DockPanelController` — menu-bar status item + popover; debug `--show-panel` launch flag.

## Modules

- `HermesRuntime/` — the Hermes boundary: `HermesControlRPC` (WebSocket JSON-RPC), `HermesCLIAdapter` (quoted-word Hermes CLI commands via `shell.exec`), `HermesCapabilityService` (fail-closed capability probes), `HermesFeatureContract` (feature IDs). All transport/process-launch concerns live here.
- `Conversation/` — `DockModel` (the central presentation state machine), transcript views, composer, session surfaces (Chat/Talk/Explorer/Source Control/Pull Requests), session lifecycle guards.
- `ControlCenter/` — Today/Inbox/Activity/Core surfaces, `ControlCenterModel`, Mission Control, Changes (Git projection + pre-commit signals), Verification Center.
- `Bots/` — Bot roster page, avatar presentation (stable FNV-1a fallback identity), bot editor, bot chat routing.
- `Repository/` — GitHub remote discovery, pull-request center, code-host models.
- `SessionWorkspace/` — session-scoped file explorer, blame-aware editor, source-control projection.
- `Gateway/` — gateway state, connection health, recovery guidance.
- `Workspace/` — `WorkspaceStore`: persistent local state (preferences, filters, cached metadata). Never a second copy of Hermes-owned data.
- `Quota/` — provider quota adapters (Codex/OpenCode Go/GLM/Claude/Antigravity).
- `Voice/` — native voice gateway preference + labelled local fallback.
- `Security/`, `Recovery/`, `Operations/`, `Automation/`, `Profiles/`, `Knowledge/`, `Appearance/`, `Extensions/`, `Agents/`, `Configuration/`, `RuntimeTools/`, `Plans/` — supporting subsystems for their named concerns.

## Data flow

WebSocket `/api/ws` (authenticated, loopback-only) → `HermesControlRPC` → `DockModel`/`ControlCenterModel` projection → SwiftUI views. Mutations flow back only through typed RPCs or capability-gated CLI calls; Hermes responses remain authoritative — Herm never optimistically invents final state.

## Contracts

- TUI Gateway JSON-RPC: `session.create`, `prompt.submit`, `session.interrupt`, `approval.respond`, `clarify.respond`, streamed message events, `profiles.*`, `projects.tree`, `cron.manage`, `voice.*`, attachment RPCs.
- Hermes CLI via `shell.exec`: `hermes kanban ...` (per-call `--board` scope), `hermes cron ...`, `hermes update`, `hermes mcp ...` — every command built as quoted words in `HermesCLIAdapter`.
- User-state helpers: `~/.hermes/scripts/kanban-attribute-session.sh` (session attribution without engine patches).

## Persistence

No databases. `WorkspaceStore` persists preferences/display state; transcripts and projections render from Hermes-owned sessions. Kanban/GitHub/Reminders data never duplicated locally.

## Test map

- `Tests/HermTests/` — one suite per subsystem (`HermesCLIAdapterTests`, `CommandCenterModelsTests`, `DirectBotRoutingTests`, `SessionConversationIsolationTests`, `OfficePreviewSimulationTests`, ...). Run: `swift test`; focused: `swift test --filter <Suite>`.

## Invariants

- Hermes is authoritative for sessions, agents, prompts, models, skills, profiles, MCP, cron; Herm stores references and display state only.
- Capability-gated, fail-closed: unavailable RPC/CLI contracts render explicit unavailable/stale states — never inferred from version strings.
- Credentials, memory, profile paths, and tool payloads never enter Herm state; suspected credential values are never repeated in UI.
- Session isolation: streamed events must prove ownership of the open session; identity mismatch fails closed.
- Documentation rule: every user-facing behavior change updates README in the same change set.

## Known sharp edges

- `OfficePreviewSimulationTests.routesConnectEveryActivityThroughWalkableSpace` currently fails (52 issues) — pre-existing debt in the office walking-mesh simulation; unrelated to kanban/runtime surfaces.
- `DockModel` is the largest presentation type; new behavior goes into extracted testable helpers, not view types.
- The Hermes engine install is upstream-managed and read-only; extend only via the user-state layer (see `~/.hermes/HARNESS.md`).
