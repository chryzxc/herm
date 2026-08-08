# Hermes Agent Dock

Hermes Agent Dock is a native macOS menu-bar control surface for a local Hermes
Agent session. Its unified popover keeps Ask, voice, sessions, and quick capture
on the left, with Today, Inbox, Activity, and Core controls on the right.

## Features

- **Local Hermes connection.** Starts a loopback-only Hermes backend, establishes
  an authenticated WebSocket session, and clearly shows whether the CLI agent is
  connected.
- **Conversation workspace.** Streams assistant messages, supports attachments
  and approvals, and lets you interrupt an in-progress request. Tool calls stay
  out of the conversation transcript.
- **General control center.** Today summarizes current focus, approvals,
  failures, due Apple Reminders, active Hermes work, and scheduled jobs. Inbox
  groups actionable approvals, clarifications, failures, and completed work.
  Activity and Core expose live runtime information, capabilities, integrations,
  health, and setup guidance.
- **Provider setup guidance.** Today renders setup cards for unavailable
  Reminders, Notes, Calendar, and Messaging providers instead of showing empty
  or invented content.
- **Active-work projection.** Today can show active Hermes sessions and managed
  delegated agents, and managed processes, with controls to open related
  sessions when Hermes provides their identifiers.
- **Scheduled-work controls.** Today lists cron jobs and supports confirmed
  pause/resume actions plus related-session opening.
- **Automations.** The Automations tab can review, create, pause, resume, and
  remove Hermes cron jobs through `cron.manage`, and reads recent run history
  through Hermes `cron runs`. History remains a live CLI projection rather than
  a second local execution database.
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
- **Quick capture.** The composer offers transparent prompt shortcuts for
  reminders, Notes, research, summaries, recurring automation, review, email,
  messaging, connected-source search, and Kanban tasks. Provider availability is
  shown in Core before use. Core also provides a recorder for the configurable
  global shortcut that opens the Dock and focuses Ask.
- **Kanban boundary.** When Hermes exposes its Kanban CLI, the Kanban tab reads
  the authoritative board and supports confirmed task creation through Hermes
  `shell.exec`, plus confirmed complete, block/unblock, and archive actions. The
  Dock does not create a competing local board or expose permanent purge;
  desktop Kanban RPC actions remain unavailable.
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
- **Safe reminder completion.** Clicking a due reminder opens a confirmation
  before the Dock submits a transparent completion request through Hermes and
  the Apple Reminders skill.
- **Conditional development context.** Repository status appears only when the
  active Hermes work references a repository; development is a contextual module,
  not the product's organizing model.
- **Live agent activity.** Shows real Hermes subagents by name, their
  current activity, and a pipeline containing both subagent work and main-agent
  tool activity. Its Now view persists one task per Hermes session, keeps task
  state synchronized with live execution, and shows the selected repository's
  branch, working-tree state, and latest commit. It deliberately does not fall
  back to sample or mock data.
- **Runtime core.** Exposes the active provider/model, execution limits,
  installed skills, configured MCP servers, and enabled plugins supplied by
  Hermes. Unavailable gateway/version states include copyable recovery commands;
  the Dock never runs update or recovery commands automatically. When a session
  is active, configured MCP tools can be explicitly reloaded after confirmation.
  Core also shows a live, read-only MCP inventory with each server's transport,
  tool scope, and enabled state; third-party MCP browsing/actions remain
  dependent on future Hermes RPCs.
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

## Run locally

```sh
swift run
```

The app expects the `hermes` executable to be available on the user’s PATH. On launch it starts a loopback-only Hermes backend, connects over Hermes’s authenticated `/api/ws` WebSocket gateway, and speaks the TUI Gateway JSON-RPC protocol. It uses `session.create`, `prompt.submit`, `session.interrupt`, and `approval.respond`, streams assistant messages, and surfaces approval requests in the native UI.

## Documentation rule

Every user-facing feature or behavior change must update the relevant section of
this README in the same change set. Mark incomplete work as planned, and do not
describe mock data or provider capabilities as live functionality. Calendar,
email, iMessage, full automation editing, and third-party MCP browsing remain
planned follow-on integrations. Read-only MCP connection inventory is available
today; the Dock does not add, remove, authenticate, or invoke MCP servers
directly.

## Quality checks

Run the same baseline checks before submitting changes:

```sh
swift build
swift test
```

Keep transport and process-launch concerns in the gateway/runtime services, persistent workspace state in `WorkspaceStore`, and presentation state in `DockModel`. New parsing or state-transition behavior should be extracted into testable helpers instead of expanding view types.
