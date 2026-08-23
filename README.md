# Hermes Agent Dock

Hermes Agent Dock is a native macOS menu-bar control surface for a local Hermes
Agent session. Its unified popover keeps Ask, voice, sessions, and quick capture
on the left, with Today, Inbox, Activity, and Core controls on the right.

## Features

- **Local Hermes connection.** Starts a loopback-only Hermes backend, establishes
  an authenticated WebSocket session, and clearly shows whether the CLI agent is
  connected.
- **Conversation workspace.** Streams assistant messages, supports multiple image
  attachments and approvals, and lets you interrupt an in-progress request.
  Selected and pasted images can be reviewed and removed individually before
  sending. Image bytes are uploaded through Hermes' dedicated attachment RPC.
  While Hermes is responding, the same composer automatically submits typed
  guidance as in-turn steering. Tool calls stay
  out of the conversation transcript. Streaming deltas are coalesced before
  publication to keep long responses responsive, and session restoration shows
  an explicit loading state that prevents prompts from being sent while a
  conversation is being rehydrated.
- **Explicit session lifecycle.** Restoring or selecting an existing session
  never creates a replacement session implicitly. A backend session is created
  only after the user chooses New Chat, and the new-chat transition is guarded
  while creation is in progress so prompts, voice, and control actions cannot
  race session setup.
- **Interactive clarification requests.** When Hermes pauses for clarification,
  the conversation shows the question as an action-needed state, presents any
  suggested choices, and lets the user edit and submit a response through
  `clarify.respond`. The Dock preserves the clarification state until Hermes
  accepts the response and resumes the turn.
- **Native Markdown links.** Links in assistant Markdown retain native
  SwiftUI/AppKit interaction, including link tinting, hover behavior, and text
  selection without breaking paragraph wrapping.
- **General control center.** Today summarizes current focus, approvals,
  failures, due Apple Reminders, active Hermes work, and scheduled jobs. Inbox
  groups actionable approvals, clarifications, failures, and completed work.
  Activity and Core expose live runtime information, capabilities, integrations,
  health, and setup guidance. Current focus is an authoritative Hermes session
  or most recently selected control reference; any local task completion label
  is presentation metadata, not a second source of truth.
- **Provider setup guidance.** Today renders setup cards for unavailable
  Reminders, Notes, Calendar, Messaging, and Email providers instead of showing
  empty or invented content. When Hermes' installed skill documents a setup
  command, the card offers it as a copy-only recovery action.
- **Active-work projection.** Today can show active Hermes sessions and managed
  delegated agents, and managed processes, with controls to open related
  sessions when Hermes provides their identifiers.
- **Scheduled-work controls.** Today lists cron jobs and supports related-session
  opening.
- **Automations.** The Automations tab can review, create, and remove Hermes cron
  jobs through `cron.manage` only when the runtime scheduler
  capability is verified, and reads recent run history
  through Hermes `cron runs`. When the installed Hermes CLI supports it, a
  confirmed Run Now action starts a job immediately. Jobs expose a confirmed
  edit form only for name, schedule, and prompt values explicitly returned by
  Hermes; unchanged or unavailable fields are never sent. History remains a
  live CLI projection rather than a second local execution database, and report
  files are not read from Hermes' private filesystem.
- **Hermes Projects.** Projects reads the authoritative `projects.tree`
  projection from Hermes, showing active project context, repository counts,
  and grouped session previews without maintaining a second project database.
  Selecting a project loads its grouped sessions through
  `projects.project_sessions`; selecting a session activates it in Ask.
- **Connected-source search.** Search keeps a lightweight in-memory projection
  of Hermes sessions, projects, Inbox items, and Apple Reminders. Hermes remains
  authoritative for session results, and no durable local search database is
  introduced until cross-source indexing requires one.
- **Narrow-screen mode.** On displays too narrow for the split view, the Dock
  switches between Ask and Control as a single pane without horizontal clipping.
- **Readable controls.** UI text uses a 12pt minimum for labels, metadata, and
  status text so the compact menu-bar surface remains legible.
- **Single-row session configuration.** The active model and thinking depth
  live in one divider-led control rail, keeping both settings visible and
  independently selectable without adding a second configuration row.
- **Design-system interactions.** Primary icon controls retain their compact
  36pt glass appearance while using 44pt hit targets, matching the interaction
  guidance in `DESIGN.md`.
- **Quick capture.** The composer offers transparent prompt shortcuts for
  reminders, Notes, research, summaries, recurring automation, review, email,
  messaging, connected-source search, and Kanban tasks. Provider availability is
  shown in Core before use. Core also provides a recorder for the configurable
  global shortcut that opens the Dock and focuses Ask.
- **Kanban boundary.** When Hermes exposes its Kanban CLI, the Kanban tab reads
  the authoritative board and supports confirmed task creation through Hermes
  `shell.exec`, plus confirmed complete, block/unblock, archive, comment,
  schedule, assign/reassign, promote, and reclaim actions when their individual
  Hermes CLI contracts are verified. The Dock can also open structured task
  details and run history when the installed CLI exposes the corresponding JSON
  commands. Native status/assignee/mine/sort filters are forwarded to Hermes,
  including an optional current-session filter, and the assignment picker is
  populated from `kanban assignees --json`. Hermes v0.19.1 does not provide an
  unschedule operation, so the Dock deliberately does not invent one. The
  Dock treats board selection as local view state and scopes every supported
  task command with Hermes' per-call `kanban --board <slug>` option. Choosing a
  board in the Dock never changes Hermes' shared current-board pointer. The
  Dock does not create a competing local board or expose permanent purge;
  desktop Kanban RPC actions remain unavailable.
- **Daily workflow controls.** The Control sidebar includes a local Command-K
  palette for existing Dock actions and local Inbox filters. The palette cannot
  execute arbitrary shell or Hermes commands.
- **Developer command center.** Today starts with a Mission Control focus strip
  and an honest readiness state. Changes provides a read-only, bounded Git
  working-tree and bounded diff projection, including new untracked files.
  Loaded diffs receive a local, added-line-only
  pre-commit signal pass for conflict markers, likely credential assignments,
  debug statements, unfinished-work markers, and bare Python exception clauses;
  suspected credential values are never repeated in the UI. Verification reuses Hermes-provided project
  facts and evidence without inventing commands; Repositories lists local
  repositories explicitly attached to Hermes sessions. Command-K includes
  capability-aware navigation, refresh, and transparent built-in review recipes.
- **Repository review and watch.** Changes can run a bounded repository-wide
  local review over staged, unstaged, and untracked files, reporting only safe
  finding metadata and clearly marking truncated, binary, unreadable, or
  over-limit coverage as partial. A complete baseline also requires every
  covered file to be explicitly marked reviewed; any Git-derived fingerprint
  change immediately makes it stale. Partial coverage can be acknowledged only
  after every covered file is reviewed and remains visibly partial. Baselines
  persist only stable fingerprints and acknowledged finding IDs. Repositories can be passively watched with
  opt-in notifications; multiple explicitly watched repositories share a
  managed watcher, and a detected change refreshes local state and adds an
  in-app notice with explicit review and verification actions, but never starts
  Hermes work automatically. Repositories also
  expose a read-only worktree fleet with local session association controls;
  inspection is bounded to eight worktrees at once.
- **Canonical-source projections.** Hermes remains authoritative for sessions,
  agents, approvals, tools, skills, profiles, and cron. Apple Reminders remains
  authoritative for reminder content. The Dock stores references, display state,
  UI preferences, and cached metadata rather than duplicating those systems.
- **Inbox presentation state.** Dismissed items remain dismissed locally, while
  snoozed items reappear automatically after one hour. Neither action mutates
  the Hermes or Apple source. Due Apple Reminders are projected into the same
  stable attention stream with `appleReminder:<id>` references.
- **Clarification responses.** Inbox clarification requests open a response
  sheet and submit the entered text through Hermes `clarify.respond`. Approval,
  clarification, and failure notifications open the exact attention item.
- **Completion alerts.** Core provides an opt-in, locally persisted notification
  for completed Hermes work while the Dock is hidden; it is disabled by default.
- **Menu-bar unread badge.** A compact red badge appears on the Hermes status
  icon when hidden work completes or needs attention, and clears when the Dock
  is opened.
- **Safe reminder completion.** Clicking a due reminder opens a confirmation
  before the Dock submits a transparent completion request through Hermes and
  the Apple Reminders skill.
- **Conditional development context.** Repository status appears only when the
  active Hermes work references a repository; development is a contextual module,
  not the product's organizing model.
- **Live agent activity.** Shows real Hermes subagents by name, with a stable
  identity-based accent color and a compact current-status card. Selecting an
  agent expands its Hermes event history grouped into Pending, Running, and
  Completed states. The Active Pipeline likewise stays collapsed until an
  individual event is selected; the expanded detail can show the Hermes event
  text, tool name, handoff target, tool input/result, and a color-coded diff
  preview when Hermes supplied one. Batch `delegate_task` calls render one row
  per worker, using Hermes' human-facing `agent_role` (or a goal-derived role
  for older payloads), and background dispatch acknowledgements remain running
  until Hermes emits the worker's terminal lifecycle event. Each bounded
  activity window is retained locally by Hermes session ID, so switching
  sessions or relaunching the Dock restores that session's agents and pipeline.
  This local projection is operational context, not an audit database. Its Now
  view persists one task per Hermes session, keeps task state
  synchronized with live execution, and shows the selected repository's
  branch, working-tree state, and latest commit. It deliberately does not fall
  back to sample or mock data. The Active Agents section includes an inline
  handoff map derived from live parent IDs and Hermes handoff events. The map
  lays out recursive agent-to-agent delegation as a left-to-right scrollable
  tree, resolving both stable agent IDs and child-session parent references so
  every reported generation remains nested. It animates active directional
  flows and shows each agent's current task, lifecycle, and tool count. The
  activity surface can switch between a bounded Live view and the full
  available history; embedded views limit the newest pipeline items and reduce
  continuous animation to keep the compact Control pane responsive.
  Selecting a node discloses that agent's canonical in-memory
  activity beneath the map. Parent-session tool calls are labelled Orchestrator
  so they remain distinct from explicitly attributed delegated-agent activity.
- **Session inspector activity summary.** The session inspector surfaces the
  latest bounded pipeline activity first, with task-oriented labels and details;
  when no pipeline activity is available, it falls back to the newest session
  events rather than relying on insertion order.
- **Session Cockpit.** Core shows the active session's Hermes-reported token
  usage and context breakdown when available. It also shows Hermes prompt
  budget, verification evidence, and a compact steering control while a turn is
  working. Steering queues guidance for Hermes's next tool-result boundary
  without restarting the turn; rejected text remains in the field instead of
  being silently discarded.
- **Adaptive composer.** The chat composer grows with longer prompts up to six
  lines, then scrolls within the field so the send controls remain visible.
- **Context guardrails and handoffs.** Hermes-reported context use is labelled
  normal below 80%, warning at 80–89.99%, and critical at 90% or higher. The
  Dock offers explicit branch, confirmed compression, and a confirmed no-edit
  Hermes background handoff. Handoff Markdown is retained only in the current
  runtime and can be copied or opened as an editable Kanban draft.
- **Verification Center.** Core consumes Hermes `project.facts` and
  `verification.status` to show detected manifests, package managers, exact
  verification commands, and best-known evidence. Targeted evidence remains
  labelled targeted; the Dock never upgrades it into a repository-wide claim.
  Commands can be copied or submitted to Hermes as explicit background tasks.
- **Background tasks.** Activity can submit a prompt through Hermes
  `prompt.background`, track its task ID, and display the eventual
  `background.complete` output. Background rows are collapsed by default and
  are retained only in the current Dock runtime window.
- **Session and runtime controls.** Core provides confirmed rename, redirect,
  branch, compress, undo, delegation pause/resume, native-agent interrupt, and
  session-scoped process-stop actions. Hermes responses remain authoritative;
  the Dock does not optimistically invent final state.
- **Runtime core.** Exposes the active provider/model, execution limits,
  installed skills, configured MCP servers, and enabled plugins supplied by
  Hermes. Unavailable gateway/version states include copyable recovery commands;
  the Dock never runs update or recovery commands automatically. When a session
  is active, configured MCP tools can be explicitly reloaded after confirmation.
  Core also shows a live, read-only MCP inventory with each server's transport,
  tool scope, and enabled state; third-party MCP browsing/actions remain
  dependent on future Hermes RPCs. When Hermes exposes `mcp test`, Core can run
  a read-only connection test for a configured server and show the result.
- **Read-only Hermes health.** When the installed CLI advertises the commands,
  Core displays a compact Journey projection plus sanitized session-store and
  memory-health summaries. These cards never edit memory, sessions, skills, or
  Hermes configuration.
- **Kanban health and attachments.** Kanban diagnostics and attachments are
  read-only, board/task scoped, and use Hermes JSON output. Diagnostic and
  attachment identities remain stable even when Hermes omits an ID. Prompt
  budget and Kanban refreshes retain their last successful projection when a
  transient request fails and mark the section stale.
- **Capability-gated controls.** Optional Dock controls are classified at
  runtime as verified Hermes gateway RPCs, stable read-only Hermes CLI
  projections, confirmed CLI mutations, unsupported operations, or external
  setup. Mutation probes require the documented help terms the Dock will send,
  not merely a successful `--help` exit. A missing or failed capability probe fails closed and leaves the
  existing recovery guidance visible; the Dock does not infer support from a
  Hermes version string alone.
- **Refresh resilience.** Automations, Projects, Core, Kanban, cron history,
  and MCP inventory show their own refresh state. A transient Hermes failure
  keeps the last successful projection visible, marks it stale, and keeps the
  error local to that section instead of replacing the data with an empty state.
- **Voice conversation.** Prefers Hermes' native voice gateway: server VAD,
  Hermes transcription, streaming TTS, and spoken barge-in. The Dock retains
  macOS speech recognition and system speech as an explicitly labelled fallback
  when Hermes voice dependencies are unavailable. The voice orb responds to
  microphone loudness in local fallback mode, and the voice toolbar includes
  both the Control surface and request cancellation. Native voice also shows
  time to first streamed text and end-to-end turn duration.

## Voice behaviour today

Voice now prefers Hermes' native continuous voice loop:

```text
microphone → Hermes VAD/transcription → Hermes text request → streaming TTS
           → full-duplex listening / spoken barge-in
```

If Hermes reports unavailable voice dependencies, the Dock presents a visible
`LOCAL VOICE FALLBACK` state and uses the earlier continuous turn-based flow:
Apple speech recognition → end-of-turn silence → Hermes text request → macOS
speech synthesis → listening resumes.

The selected Hermes model still affects response latency and quality, but it
does not by itself make a provider-native audio session. Tool use, model
queueing, turn detection, and the configured TTS provider also contribute to
perceived delay.

## Realtime voice plan

This is the implementation plan for true low-latency, interruptible voice while
keeping Hermes as the provider/model control plane.

1. **Expose model capabilities from Hermes.** Extend the gateway/catalogue data
   to report whether the selected provider and model support text chat, streaming
   audio input/output, server VAD, and interruption. The picker must prevent a
   realtime mode from being selected for a text-only model.
2. **Add a provider-neutral voice-session protocol.** Define a Hermes gateway
   voice-session lifecycle (create, configure, send audio, receive audio/text,
   cancel, close). Hermes can then route to OpenAI or another provider without
   putting vendor-specific transport details in the Dock UI.
3. **Stream audio instead of waiting for transcription.** Capture small PCM
   chunks, send them during speech, and play returned audio chunks as they
   arrive. Use server-side VAD when available, with a local VAD fallback and
   configurable turn-detection thresholds.
4. **Support barge-in.** Hermes-native voice already handles spoken barge-in by
   cutting playback and interrupting the running turn; the existing Stop
   controls remain the manual equivalent. A provider-native audio session must
   preserve that same behavior.
5. **Make latency observable.** The Dock now displays time to first streamed
   text and end-to-end request completion for native Hermes voice. Extend the
   gateway later with audio-output timestamps to isolate provider audio latency
   from model and tool work.
6. **Degrade safely.** If the selected model, Hermes version, or network session
   lacks realtime support, keep the current continuous turn-based voice mode and
   explain why in the UI rather than silently pretending it is realtime.

The Dock currently integrates Hermes' `voice.toggle`, `voice.record`, and
voice events alongside `prompt.submit` and streamed message events. It does not
yet establish a provider-native bidirectional audio session. Therefore steps
1–3 still require gateway and provider work in Hermes, not only a Dock UI
change. An OpenAI realtime-capable model is one possible adapter, but it must be
surfaced by Hermes as a supported capability before the Dock uses it.

For the current continuous voice mode, the Dock keeps the ordinary turn recorder
closed while streamed TTS drains after `message.complete`. Hermes' full-duplex
listener still owns spoken barge-in during playback; the next quiet listening
turn opens only after the estimated speech and CoreAudio tail have finished.
This prevents speaker output from being transcribed as the user's next reply.

## Run locally

```sh
swift run
```

The app expects the `hermes` executable to be available on the user’s PATH. On launch it starts a loopback-only Hermes backend, connects over Hermes’s authenticated `/api/ws` WebSocket gateway, and speaks the TUI Gateway JSON-RPC protocol. It uses `session.create`, `prompt.submit`, `session.interrupt`, and `approval.respond`, streams assistant messages, and surfaces approval requests in the native UI.

The Dock targets the locally installed Hermes Agent v0.19.1 contract. Optional
controls fail closed when their Hermes RPC or CLI capability is unavailable.
The Dock does not update Hermes, configure providers, invoke arbitrary shell
commands, expose bulk destructive controls, or create a second Hermes runtime.

## Documentation rule

Every user-facing feature or behavior change must update the relevant section of
this README in the same change set. Mark incomplete work as planned, and do not
describe mock data or provider capabilities as live functionality. Calendar,
email, iMessage, automation fields Hermes does not return, and third-party MCP
browsing remain planned follow-on integrations. Read-only MCP connection inventory is available
today; the Dock does not add, remove, authenticate, or invoke MCP servers
directly.

## Hermes contracts still required

The Dock intentionally leaves these features unavailable until Hermes exposes a
stable, capability-advertised gateway RPC or JSON response:

- Project mutation: structured identifiers, current values, mutation
  request/response schemas, and conflict errors. Kanban board enumeration is
  available through Hermes v0.19.1's verified JSON/CLI contract. The Dock uses
  local board selection plus per-call `--board` scope, so it deliberately does
  not expose a shared-board switch action.
- Third-party MCP discovery/invocation: scoped authorization, tool schemas, and
  redacted results; the Dock will not call providers directly.
- Structured Cron reports and richer diagnostics: response schemas that avoid
  reading private Hermes directories or parsing terminal tables.
- Provider-neutral realtime audio: voice session create/configure/audio/cancel/
  close operations plus model VAD/audio capability metadata.
- Calendar access: explicit provider capability, authorization state, and
  stable event operations.
- Durable activity feeds, fleet session usage, PR/CI/error projections, and
  authoritative project repository enumeration: see
  `HERMES_COMMAND_CENTER_CONTRACTS.md` for the required fail-closed contracts.

## Quality checks

Run the same baseline checks before submitting changes:

```sh
swift build
swift test
```

At the current documented baseline, `swift test` runs 71 tests across 15 suites.

Keep transport and process-launch concerns in the gateway/runtime services, persistent workspace state in `WorkspaceStore`, and presentation state in `DockModel`. New parsing or state-transition behavior should be extracted into testable helpers instead of expanding view types.
