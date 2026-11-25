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
not publish transcript updates. The transcript resolves mounted row bounds together in
one document-space geometry reader. Activity and reply content share one measured row,
including zero-height hidden rows.
Mounted native Markdown replies share clip notifications and batch geometry
changes. Completed replies reuse their current layout during an active resize
and solve the final width when the drag ends. The transcript indexes stored
rows in both directions so the outgoing cache gathers metadata for its 36
retained messages directly.
`DockModel` buffers stored transcript history in 240-row pages by default.
The coordinator requests a refill before its mounted window reaches the oldest loaded rows.
The first recent-session publication starts a bounded warm-up for two pinned or
recent chats. The all-profile scan can fill the remaining preview cache. A foreground
open can join the matching first-page read while it is in flight. New speculative
reads wait for foreground history reads. An exact, complete stored preload with a
current read boundary can paint before unread review.
The workspace shell observes the transcript tail and opening state. The composer
and its trays observe the input and session controls they display. The session rail
discovers references as history arrives and publishes changes for that session's cards.
An externally running turn's history watch belongs to the selected transcript
and streaming message. Views of the same session share in-flight reads and
one-second results with the same gateway and profile. A paginated one-row tail
check skips unchanged work. Bounded reconciliation merges stored row identities
into the local transcript without replacing older pages, changing their cursor,
or moving a reader to the tail. Failed reads back off to 24 seconds without
extending the idle deadline. Switching sessions or shutting down cancels the watch.
`ConversationMessageWindow` sets eight-message history pages, a 12-message initial
window, and the existing 36-row backstop with visible-row protection. Markdown
prefetch uses that same page size in both directions.
Stored transcript images and cached switch previews share a worker. Hydration
pulls four attachments at a time, prioritizes the visible transcript, and
applies completed message attachments by ID. A successfully transferred preview
attachment is not decoded again during fresh history hydration.
Markdown section parsing is independent of AppKit;
adjacent-page prefetch runs off the main actor, while styling and exact measurement
remain on it. The shared completed-height cache retains numbers only. The native streaming
coordinator retains stable chunk sections and byte offsets, rebuilding only changed
suffixes and reading canonical text from `StreamingText`. Large restore and
stream batches prepare their bounded chunks on a cancellable worker, with new
deltas queued in order. Completion never waits for obsolete live chunks.
Activity row inputs are
scoped by their tool-call identities before the equatable view boundary.
`DockModel` caches an immutable `MessageNavigatorSnapshot` at message/history
mutation boundaries. Long maps build their index on a worker and reuse stored
prompt previews across prepends. A result is accepted only for the current
session and revision. Known prompt appends and reply edits update their indexed
rows. Transcript equality compares the snapshot's identity. Ordinary Markdown
keeps a nil rich-document parse request;
only visual replies schedule parsing, keyed by source, stream completion, and reply identity.
Find matches immutable navigator items in a cancellable background task. Queries
show loaded matches first and share an in-flight read for the recent unloaded
history. The text cache retains up to 8 MiB. Older pages are read and matched
individually without retaining their bodies.
Older matches carry stored row IDs so selection can prepend through the requested
row. Deep jumps publish at complete turn boundaries, leaving already loaded
history intact if the next jump supersedes them. A turn spanning more than one
REST page is kept together so its tool results do not detach from the reply.
The wide message map requests its stored prompt timeline only while visible
and looks up viewport targets by row ID. Find's
`MessageNavigatorSearchState` scopes results and queued Return selection to the
query, session, and snapshot identity; views never rescan history on submission.

The workspace's unread projection shares one timer and three background read slots
across visible badges and bot counts. An opening unread review reads independently.
Plan rails and file previews share a bounded, revision-keyed memory cache. Rail
discovery reuses a short-lived folder inventory, and each rail keeps its own
transcript mention index. The gateway router indexes conversation subscribers by
their current runtime, storage, and dispatch IDs. Global observers still receive the
full stream, and worker events can match through subagent ownership.

`SessionTraceModel` owns Timeline’s focused execution subscriptions and coalesced
projection, caching completed request inputs by `DockModel.messagesRevision`.
Within the same history revision, Timeline updates the live turn and any
historical turns touched by changed tools or workers. Participant request IDs
deduplicate with sets, and one turn index attaches Bot appearances without
walking the full timeline for each appearance.
`SessionTraceRowViewport` adapts the native vertical clip view for both fixed-height
label and bar windows; it owns presentation geometry only. Clock bounds and visible
grid/ruler drawing keep time ticks independent of history length.

`SessionNavSidebarModel` publishes one navigation snapshot for the Chats list,
board, and split tabs. Coalesced activity projects immutable inputs on a utility
task. Session selection updates the affected status marks using the existing
inventory. Profile changes can replace a pending projection immediately.
Seen timestamps publish to their owning rows and coalesce local persistence
off the UI thread.
Bot activity indexes session contributions by owner and updates the affected
Bot on live events. Inventory changes reconcile against the shared roster.
The snapshot includes the Chats list's resolved status marks and pin presentations.
The workspace shell observes only the selected session's menu, title, and
project path fields. The rail and session picker observe the navigation snapshot
for inventory and activity. Control pages opt in to the live chat fields they
display instead of observing the entire conversation model.
Workspace navigation receives only the request, restore flag, and alert values
that it acts on.
Control Center keeps session and profile ownership when batching gateway events.
Global inventory can refresh independently of focused cockpit, budget, verification,
and process reads. Delegation uses the fast poll only for live workers.
The Talk stage owns microphone observations and its orb observes audio levels.

Chats Tiles prepares large board snapshots and search results on a worker and
publishes them together. Visible cards subscribe to tool activity by session ID
and share a bounded preview-read budget. The archive activity feed retains each
session's newest candidates by its Hermes revision and merges the global feed
off the main actor.
Sidebar search uses the same navigation snapshot and matches it off the main actor.
The right-hand session rail runs discovery and refresh only while visible.
Restoring a split layout loads the focused column first and queues the remaining
columns in order.
Session Kanban polls share a short-lived archive index. Each consumer matches
session aliases and observed task IDs against the same parsed card summaries.
Board inventory refresh failures stay in the board projection.
Project detail, navigation, and membership share in-flight reads by profile and
project. A batch navigation refresh runs up to four project reads at once and
publishes one snapshot.
Workspace project attachment merges a returned session inventory into local
metadata in one pass. The store publishes the merged tasks and references once
and does not save an unchanged refresh.
Each composer shares one in-flight process read and queues one follow-up as needed.
Cancelling a WebSocket RPC waiter releases the local continuation and deadline
without interrupting Hermes or the shared connection.

- `HermesRuntime/` — the Hermes boundary: `HermesControlRPC` (WebSocket JSON-RPC), `HermesCLIAdapter` (quoted-word Hermes CLI commands via `shell.exec`), `HermesCapabilityService` (fail-closed capability probes), `HermesFeatureContract` (feature IDs). All transport/process-launch concerns live here.
- `Conversation/` — `DockModel` (central presentation state machine; stored state + init in `DockModel.swift`, behaviour in `DockModel+<Feature>.swift` extensions), `DockPopover` (+ extensions, same pattern), session navigation rail/queue/session rows, transcript views, composer, session lifecycle guards.
- `ControlCenter/` — `ControlCenterModel` (same extension split), `WorkspaceActivitySidebar` (+ extensions per panel), command-center models, control-tower presentation.
- `Settings/` — shared settings components (`SettingsCategory`, `SettingsSection`, rows).
- `Kanban/`, `Calendar/`, `Office/` — kanban board, work calendar, and the 3D office scene.
- `EdgeDock/` — edge dock, notch/island previews, quick message, result peek.
  `EdgeQuickConversationModel` mounts a disposable `DockModel` for Quick Message's
  captured session and for detached chats and inactive split columns. It shares
  the gateway and standard session resume/history path. Each projection accepts
  events for its session, aliases, and tracked workers, plus unscoped gateway
  events. The workspace model owns automatic session-index refreshes.
  The workspace owns the gateway and handles reconnect replay. Conversation
  projections borrow the client and close only their own subscriptions.
  Loaded split columns retain their conversation models across focus changes.
  The inspector follows the focused model while global feeds stay bound to the
  workspace.
  `ConversationTranscriptView` renders the projection, and `QuickDraftStore`
  retains only unsent material.
  Detached worktree pickers read project paths from the shared `WorkspaceStore`.
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
- Credentials remain in dedicated authentication services and transient request buffers, outside conversation and presentation projections. Native Keychain access runs on a serial background queue and restricts legacy item access to Herm. Browser sign-ins stay in native stores scoped to each Hermes profile; only a nonsecret sign-out reset UUID is persisted by Herm. The browser never accesses Herm Keychain items. Credential values never enter diagnostics or ordinary UI.
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

Automatic app updates require a complete GitHub asset SHA-256 digest. Ad-hoc builds
verify the DMG's detached Ed25519 signature with the installed app's pinned public
key before mounting. Developer ID builds require the installed bundle's
Apple-validated team on the update. Both paths verify mounted and staged code
signatures. The user downloads explicitly and requests installation and restart;
Herm waits for the current turn and retains the existing rollback helper.

The composer reads the selected live session’s automation snapshot through `session.control.read` and projects `session.control.update` events. Hermes remains authoritative for goals, loops, and heartbeats.
