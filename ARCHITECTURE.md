# Herm — Repo Map

updated: 2026-10-17 · head: 938aeb6 (+ folder restructure)

## Entry points

- `HermApp` (`App/`) — @main SwiftUI Settings shell; all real UI lives in the menu-bar panel.
- `HermDelegate` (`App/`) — NSApplicationDelegate: owns `DockModel`, builds `DockPanelController`, installs the double-tap-Command shortcut, requests notifications.
- `DockPanelController` — menu-bar status item + popover; debug `--show-panel` launch flag peeks the notch.

## Modules

- `HermesRuntime/` — the Hermes boundary: `HermesControlRPC` (WebSocket JSON-RPC), `HermesCLIAdapter` (quoted-word Hermes CLI commands via `shell.exec`), `HermesCapabilityService` (fail-closed capability probes), `HermesFeatureContract` (feature IDs). All transport/process-launch concerns live here.
- `Conversation/` — `DockModel` (central presentation state machine; stored state + init in `DockModel.swift`, behaviour in `DockModel+<Feature>.swift` extensions), `DockPopover` (+ extensions, same pattern), Mission Control rail/queue/session rows, transcript views, composer, session lifecycle guards.
- `ControlCenter/` — `ControlCenterModel` (same extension split), `WorkspaceActivitySidebar` (+ extensions per panel), command-center models, control-tower presentation.
- `Settings/` — shared settings components (`SettingsCategory`, `SettingsSection`, rows).
- `Kanban/`, `Calendar/`, `Office/` — kanban board, work calendar, and the 3D office scene.
- `EdgeDock/` — edge dock, notch/island previews, quick message, result peek.
- `DesignSystem/` — theme, component styles, icons (`PhosphorIcons`), modal/menu/hover primitives.
- `Bots/` — Bot roster page, avatar presentation (stable FNV-1a fallback identity), bot editor, bot chat routing.
- `Repository/` — GitHub remote discovery, pull-request center, source control, code editor.
- `SessionWorkspace/` — session-scoped file explorer, browser, terminal, activity overview.
- `Gateway/` — gateway state, connection health, recovery guidance.
- `Workspace/` — `WorkspaceStore`: persistent local state (preferences, filters, cached metadata). Never a second copy of Hermes-owned data.
- `Quota/` — provider quota adapters (Codex/OpenCode Go/GLM/Claude/Antigravity) plus the quota/usage/provider-connect views.
- `Voice/` — native voice gateway preference + labelled local fallback.
- `Operations/`, `Automation/`, `Profiles/`, `Knowledge/`, `Appearance/`, `Extensions/`, `Agents/`, `Configuration/`, `Plans/` — supporting subsystems for their named concerns.

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
- `DockModel` is still the largest presentation type (split across extension files, but one type); new behavior goes into extracted testable helpers, not view types. Members are internal (not `private`) so extensions can span files.
- `ComposerQueueOrderingTests` is timing-sensitive: fails under parallel load, passes alone (pre-existing).
- The Hermes engine install is upstream-managed and read-only; extend only via the user-state layer (see `~/.hermes/HARNESS.md`).


## GitHub feature modules

`PullRequests/` and `Issues/` are feature folders within the existing Herm target.
Their center models own list selection, browsing preferences, detail loading, and
in-memory drafts. Global and session centers keep separate list state and share `PullRequestDetailStore` for PR details, discussion data, and per-item drafts. Tests use isolated stores. App
composition in `DockPopover+Context` handles navigation using `GitHubItemReference`;
features do not reach into one another's models.

`GitHub/` owns REST/GraphQL transport, pagination, errors, shared metadata editors,
authoring, and discussion presentation. Provider dictionaries stay in services.
Labels are changed with add/remove deltas. Projects use V2 item IDs and actual
Status option IDs. Provider data remains authoritative; persistence is limited to
references and presentation preferences.

`Markdown/` owns `MarkdownRenderDocumentBuilder`, block parsing, attributed text,
and native document hosting/caches. `MarkdownMessageView` is the shared facade for
chat, GitHub descriptions/discussion, and previews. Hosts may adapt sizing or
streaming without adding another parser or formatting policy.

Conflict analysis creates and removes an isolated bare repository, fetches the
base and PR ref, verifies both snapshot revisions, then runs `merge-tree` with NUL
output. It never operates on the user's checkout/index/refs. Cancellation, a
120-second deadline, and a 512 MiB repository budget bound the operation. Landing
mutations refresh capabilities and supply the confirmed expected head to GitHub.
