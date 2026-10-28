# Herm — Repo Map

updated: 2026-10-17 · head: 938aeb6 (+ folder restructure)

## Entry points

- `HermApp` (`App/`) — @main SwiftUI Settings shell; all real UI lives in the menu-bar panel.
- `HermDelegate` (`App/`) — NSApplicationDelegate: owns `DockModel`, builds `DockPanelController`, installs the double-tap-Command shortcut, requests notifications.
- `DockPanelController` — menu-bar status item + popover; debug `--show-panel` launch flag peeks the notch.

## Modules

The chat transcript uses `ConversationTranscriptView` over a disposable
`ConversationTranscriptSnapshot`. `ConversationTranscriptSource` subscribes to specific
model publishers; Hermes-owned messages remain in `DockModel`.
The snapshot scopes bot steps to selected-session record identities and omits live
activity for unmounted streaming rows; canonical activity remains in `DockModel`.
`ConversationTranscriptCoordinator` owns the session-scoped mounted window, page
transaction, navigation generation, and deferred native scroll work. Geometry does
not publish transcript updates. Each mounted message has one geometry/identity
container around activity and reply content, including zero-height hidden rows.
`ConversationMessageWindow` sets eight-message history pages, a 12-message initial
window, and the existing 36-row backstop with visible-row protection. Markdown
prefetch uses that same page size in both directions.
Markdown section parsing is independent of AppKit;
adjacent-page prefetch runs off the main actor, while styling and exact measurement
remain on it. The shared completed-height cache retains numbers only. The native streaming
coordinator retains stable chunk sections and byte offsets, rebuilding only changed
suffixes and reading canonical text from `StreamingText`. Activity row inputs are
scoped by their tool-call identities before the equatable view boundary.
`DockModel` caches an immutable `MessageNavigatorSnapshot` at message/history
mutation boundaries; transcript equality compares its identity instead of walking
all navigator entries. Ordinary Markdown keeps a nil rich-document parse request;
only visual replies schedule parsing, keyed by source, stream completion, and reply identity.
Find matches immutable navigator items in a cancellable background task. Its
`MessageNavigatorSearchState` scopes results and queued Return selection to the
query, session, and snapshot identity; views never rescan history on submission.

`SessionTraceModel` owns Timeline’s focused execution subscriptions and coalesced
projection, caching completed request inputs by `DockModel.messagesRevision`.
`SessionTraceRowViewport` adapts the native vertical clip view for both fixed-height
label and bar windows; it owns presentation geometry only. Clock bounds and visible
grid/ruler drawing keep time ticks independent of history length.

- `HermesRuntime/` — the Hermes boundary: `HermesControlRPC` (WebSocket JSON-RPC), `HermesCLIAdapter` (quoted-word Hermes CLI commands via `shell.exec`), `HermesCapabilityService` (fail-closed capability probes), `HermesFeatureContract` (feature IDs). All transport/process-launch concerns live here.
- `Conversation/` — `DockModel` (central presentation state machine; stored state + init in `DockModel.swift`, behaviour in `DockModel+<Feature>.swift` extensions), `DockPopover` (+ extensions, same pattern), session navigation rail/queue/session rows, transcript views, composer, session lifecycle guards.
- `ControlCenter/` — `ControlCenterModel` (same extension split), `WorkspaceActivitySidebar` (+ extensions per panel), command-center models, control-tower presentation.
- `Settings/` — shared settings components (`SettingsCategory`, `SettingsSection`, rows).
- `Kanban/`, `Calendar/`, `Office/` — kanban board, work calendar, and the 3D office scene.
- `EdgeDock/` — edge dock, notch/island previews, quick message, result peek.
  `EdgeQuickConversationModel` mounts a disposable `DockModel` for Quick Message's
  captured session, sharing gateway events and the standard session resume/history
  path. `ConversationTranscriptView` renders it; the existing `QuickDraftStore`
  retains only unsent material, and the workspace session stays separate.
- `DesignSystem/` — theme, component styles, icons (`PhosphorIcons`), modal/menu/hover primitives.
- `Bots/` — Bot roster page, avatar presentation (stable FNV-1a fallback identity), bot editor, bot chat routing.
- `Repository/` — GitHub remote discovery, pull-request center, source control, code editor.
- `Review/` — shared immutable diff documents, native canvas, read-only comparison loading, private revision notes, captured local changes, and review-guide coordination.
- `SessionWorkspace/` — session-scoped file explorer, browser, terminal, and execution trace waterfall.
- `Gateway/` — gateway state, connection health, recovery guidance.
- `Workspace/` — `WorkspaceStore`: persistent local state (preferences, filters, cached metadata). Never a second copy of Hermes-owned data.
- `Quota/` — provider quota adapters (Codex/OpenCode Go/GLM/Claude/Antigravity) plus the quota/usage/provider-connect views.
- `Voice/` — native voice gateway preference + labelled local fallback.
- `Operations/`, `Automation/`, `Profiles/`, `Knowledge/`, `Appearance/`, `Extensions/`, `Agents/`, `Configuration/`, `Plans/` — supporting subsystems for their named concerns.

## Generative UI and artifacts

`Features/GenerativeUI/` owns versioned typed rendering, `RichFeatureRegistry`,
`RichGenerationContext`, `RichArtifactReference`, native presentation preferences,
and the isolated HTML host. Registry examples drive the next submission's prompt
catalog through GenerativeUIIntegration. App composition registers connected feature
readers/resolvers in RichHostActionRouter; it never creates a second capability probe.

`Plans/ArtifactService` extracts validated surfaces from assistant text through the
same RichDocument decoder as chat. Artifact records use typed content, original source,
and canonical message references, not fabricated paths. ArtifactIndexStore coalesces
reads per model/profile/session and keeps a bounded disposable cache shared by global
and session browsers. Source history remains in Hermes. WorkspacePresentationStore
holds only references and bounded user input/selection preferences; exports are
independent user documents. Existing provider models and action handlers own writes.

## Data flow

WebSocket `/api/ws` (authenticated; loopback in local mode, HTTPS/WSS for remote/cloud, or SSH-forwarded loopback) → `HermesControlRPC` → `DockModel`/`ControlCenterModel` projection → SwiftUI views. Mutations flow back only through typed RPCs or capability-gated CLI calls; Hermes responses remain authoritative — Herm never optimistically invents final state.

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
- Credentials remain in dedicated authentication services and transient request buffers, outside conversation and presentation projections. Native Keychain access runs on a serial background queue and restricts legacy item access to Herm. Opt-in shared browser cookies are cached in memory and AES-GCM sealed on disk. Credential values never enter diagnostics or ordinary UI.
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
Labels are changed with add/remove deltas. Provider data remains authoritative; persistence is limited to
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


Native generated command blocks route explicit clicks through `RichHostActionRouter`
to the existing `TerminalTabStore` and session inspector navigation. The router checks
the loaded reply revision and profile/session; app composition rechecks the captured
local project/worktree directory. Each command starts in a fresh terminal shell.
No generated executor, output store, Hermes RPC or HTML host bridge is added.

## File and update safety

Repository status read failures remain unavailable, including review baselines and
clean-tree labels. Git commands share a bounded process-group runner with deadlines
and cancellation. Editor saves compare the loaded contents inside file coordination;
draft edits made during saving remain unsaved. Only images explicitly created by
Herm are eligible for attachment cleanup.

Automatic app updates require a complete GitHub asset SHA-256 digest and a Developer
ID signature matching the installed Herm bundle's Apple-validated team. Both the
mounted and staged bundles are verified; ad-hoc builds require manual updates.
