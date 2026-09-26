# Office Work Zones, Room Interactions, and Rich Bot Inspector

Date: 2026-09-25
Source audit: `DESIGN.md` (Office simulation and exterior), `AGENTS.md`,
`ControlCenter/OfficePreviewModels.swift`, `OfficePreviewSceneView.swift`,
`OfficeDesignSceneBuilder.swift`, `OfficeDesignNavigation.swift`,
`OfficePreviewView.swift`, `ControlCenterModel.swift` (Kanban detail loading),
`ControlModels.swift`, and Hermes `hermes_cli/kanban.py` / `kanban_output.py` /
`kanban_db.py` (installed at `~/.hermes/hermes-agent`).

## Goal

Make the 3D office read like a management sim: each bot goes to the room that
matches the kind of work it is really doing and uses that room's equipment.
Examples: a QA task goes to the QA Lab and handles test devices. A security
audit goes to a security console. Research goes to the library. Review goes to
Mission Control. The bot inspector should show the task data that Hermes
already exposes: comments, event history, runs, attachments, summary, and
dependencies.

Hard constraint from `DESIGN.md`: the office only projects real state. Rooms
and animations illustrate reported work. They never invent progress, results,
counts or handoffs. Every room choice must trace back to a real signal, and the
inspector must show which signal it was.

## Current state (what exists today)

- **Lane → location is coarse.** `OfficePreviewLane.location` maps
  `running`/`blocked` to `.desk`, `review` to `.reviewTable` (Mission Control
  consoles), `triage`/`ready` to `.kanbanBoard` (Planning room), and everything
  else to `.lounge`. `OfficePreviewLocation` has 5 cases, and `.waitingArea`
  (the help point) is authored but never used.
- **Phase is keyword-sniffed.** `OfficePreviewTaskData.phase` looks for
  test/read/research words in `currentStepKey`, `latestEventNote` and
  `latestEventKind`, but only to pick a pose at the desk. The bot never
  leaves its desk.
- **The rooms already exist but nobody works in them.** QA Lab (#5, test
  devices, repair stand, tool wall), Server Room (#6, racks, cable spool),
  Ops (#7, two consoles), Design Studio, Assembly Bay (#2, cradle and robot
  arm), Library, Parts Depot and Maintenance are used only as *leisure* spots
  (`LeisureAction.tinkering`/`.browsing`/`.charging`).
- **Pose system is ready for this.** `targetPose(for:time:)` already runs
  per-action scripted gestures (coffee, reading, arcade, charging, tinkering,
  browsing, chat beats). Work interactions can reuse the same `RigPose` +
  `gesture()` beat helpers and the per-frame blend.
- **The inspector is thin.** `OfficeAgentInspector` shows the title, step,
  running time, `OfficeTaskFields`, the assign menu and other tasks.
  `KanbanTaskDetail` parses only title/body/status/priority/assignee/model plus
  runs from a separate `kanban runs` call.
- **Hermes already returns much more.** `hermes kanban show --json <id>`
  returns:
  `task` (incl. `skills`, `workflow_template_id`, `current_step_key`,
  `workspace_kind/path`, `branch_name`, `result`, `last_failure_error`,
  `session_id`, `created_by/at`, `completion_contract`), `latest_summary`,
  `parents`, `children`, `comments[] {author, body, created_at}`,
  `events[] {kind, payload, created_at, run_id}`, and `runs[]` (profile,
  step_key, status, outcome, summary, error, …). Attachments come from
  `kanban attachments`, which is already wired up as
  `refreshKanbanAttachments`. The Dock currently throws most of this away.

## Design

### 1. Separate *lifecycle* from *work kind*

Kanban lanes answer **"is this bot working, waiting, or free?"** A new
`OfficeWorkKind` answers **"what kind of work, and therefore which room?"**
The lane still wins: only `running` (and, for review, `review`) tasks go to a
work-kind room. Queued, done and scheduled tasks keep today's behaviour.

| Lane | Destination | Interaction |
|---|---|---|
| triage, ready | Planning room kanban wall (existing) | Read cards, move a sticky note |
| todo, scheduled | Leisure (existing) | Existing leisure activities |
| **running** | **Room chosen by `OfficeWorkKind` (below)** | Room-specific script |
| review | Mission Control consoles (existing) | Point at wall, nod, pair review (existing plan) |
| blocked | **Help point** (`.waitingArea`, currently unused) | Raise hand, look around; bubble "Needs input" |
| done | Leisure; one short cheer on an *observed* running→done transition | Fist pump, then leisure |

Running work kinds (a small, fixed set so every kind owns a real room):

| `OfficeWorkKind` | Room (existing → reused) | Covers Hermes work like |
|---|---|---|
| `coding` (default) | Assigned desk | implement, refactor, fix, patch, terminal |
| `research` | Library (#) + new research carrel | web search, browse, read docs, investigate, summarize |
| `testing` | QA Lab (#5) | test, verify, validate, QA, e2e, regression |
| `security` | Ops (#7) → retitled **Security Ops** | pentest, audit, vuln, CVE, threat model, secrets scan |
| `infrastructure` | Server Room (#6) | deploy, infra, docker, k8s, CI, migrate DB, monitoring |
| `design` | Design Studio | UI, UX, mockup, image generation, figma, icon |
| `build` | Assembly Bay (#2) | build, package, release, bundle, compile |
| `writing` | Library reading desk | docs, README, changelog, write-up, copy |
| `orchestration` | Mission Control display wall | delegate, plan subtasks, coordinate (main session / `delegate` tool) |

Anything Hermes does that is not in the Kanban lane vocabulary (research,
pentesting, image generation and so on) is expressed through `OfficeWorkKind`,
not by inventing new lanes.

### 2. Classifier with evidence (honesty rule)

Add `OfficeWorkClassifier` (pure, `Sendable`, in `OfficePreviewModels.swift`
or a new `OfficeWorkKind.swift`). It returns
`(kind: OfficeWorkKind, evidence: Evidence)` and applies signals strongest
first. The first match wins:

1. `current_step_key` (explicit, reported by the worker/workflow).
2. `skills[]` on the task (for example `security-audit`, `web-research`).
3. Current run `step_key` / `profile`.
4. `workflow_template_id`.
5. Latest event `kind`/payload note (already carried as `latestEventKind/Note`).
6. For main sessions: the most recent tool names in
   `OfficeMainSession.activities` (`web_search`/`browser_*` → research,
   `terminal`/`patch`/`write_file` → coding, `delegate_task` → orchestration,
   `vision`/`image_generate` → design).
7. Task title (weakest). Always labelled "Inferred from title".
8. Otherwise `.coding` at the assigned desk, labelled "Default".

Matching uses a whole-word token table (reusing the existing
`split(whereSeparator:)` approach in `phase`) with a small synonym list per
kind, kept in one place and unit-tested. `Evidence` is shown in the inspector
("In QA Lab · from step `verify`"), so the room choice is never unexplained.
The existing `OfficePreviewPhase` for `running` derives from the kind, which
replaces the ad hoc keyword sniffing.

**Hysteresis:** a bot changes room only when the classification is stable
across one snapshot, or when the lane changes. This stops flapping when
`latestEventNote` changes on every heartbeat.

### 3. Stations per zone

- Extend `OfficePreviewLocation` with `.researchCarrel`, `.qaBench`,
  `.securityConsole`, `.serverAisle`, `.designStudio`, `.buildBay`,
  `.writingDesk`, `.missionWall`, keeping raw values human-readable because
  they appear in the inspector.
- Author stations in `OfficeDesignSceneBuilder` inside each room function
  (`verificationLab`, `serverRoom`, `operationsRoom`, `designStudio`,
  `library`, `missionControl`, Assembly Bay block). Use the same
  `navigation.stations[loc, default: []].append(...)` pattern that
  `missionControl` uses for review seats. Plan 2–4 seats per room. Each station
  also carries an `interaction: OfficeWorkInteraction` descriptor (prop anchor
  positions and beat script id).
- **Bug to avoid:** `bringWingsTogether` only remaps `.desk`, `.reviewTable`
  and `.kanbanBoard`. Change it to remap **every** non-outdoor location key so
  that new stations do not end up 6.5m off.
- **Capacity overflow:** when a room is full, the bot works at its assigned
  desk with the room-kind pose (for example holding a test device at its desk).
  It never uses the garden overflow row, and it never shares a seat. Add a
  per-location occupancy reservation next to the existing leisure reservation
  logic.
- Slot allocation within a room uses a stable hash of the bot id, so refreshes
  do not reshuffle seats. This follows the existing FNV `identitySeed`.

### 4. New and upgraded props (static geometry, cached meshes)

All props go through the builder's cached `box`/`oval`/`group` helpers and
`OfficeStaticMeshBatcher`. Per `DESIGN.md`, screens show **abstract glow
only**, never fake numbers, logs, pass/fail or clocks.

- **Library → research carrel:** two study carrels with a terminal, a pulled
  book stack, a document tray and a reading lamp. A book on the shelf is a
  named `prop-book` entity that the bot "pulls".
- **QA Lab:** named test devices (`prop-test-device-N`) that can be lifted, a
  probe on the repair stand, and a small device rack. The existing monitors and
  ESD mat stay.
- **Security Ops (Ops #7 retitled):** replace the two generic consoles with a
  shielded console (hood and privacy panel), a keycard reader on the Server Room
  door, a padlock-glyph sign, and a wall "network map" made of pins and threads
  (reuse `investigationBoard`, `thread` and `pin`). No real data is shown.
- **Server Room:** a crash cart (laptop on a rolling stand) and rack doors
  split into a hinged `prop-rack-door-N` child entity.
- **Design Studio:** a drawing tablet on the desk and a swatch board. The easel
  canvas gets a named `prop-canvas`.
- **Assembly Bay:** the robot arm joints split into named pivots so they can
  move while a `build` bot is present.
- **Planning room:** individually named sticky notes (`prop-note-N`) on the
  kanban wall so a planner can move one.

### 5. Interaction scripts ("beats")

Add `OfficeWorkInteraction`, a deterministic looping script per zone made of
beats. Each beat is `(target: prop anchor | seat, pose, duration)`, seeded by
bot id so that neighbours are out of phase. It is driven by the **existing**
per-frame pose driver in `targetPose`/`animateStationary`. There are no new
timers, `Task` loops or lights.

| Zone | Beats (loop) |
|---|---|
| Desk / coding | type → lean back and look at screen → type → sip mug |
| Research | walk to shelf → pull book → return to carrel → read (page-turn) → type notes |
| QA | pick up device → tap-tap → set down → look at monitor → type → probe at repair stand |
| Security | lean into hooded console → type fast → turn to network map and point → back |
| Server room | walk to rack → open door → plug patch lead → check crash-cart laptop → close door |
| Design | sketch at easel → step back and tilt head → tablet at desk |
| Build | stand at cradle → the arm moves (only while occupied) → inspect → nod |
| Writing | seated at reading desk → write → reread (head tilt) |
| Orchestration | stand at display wall → point at panels in turn → type at console |
| Planning | read cards → pick sticky note → place in another column → step back |
| Blocked | raise hand at help point → look around → idle sway (loop) |

Prop motion (door hinge, lifted device, robot arm, moved sticky note) is a
child transform animated by the same frame driver, and only while the owning
bot is at that station. When the bot leaves, props snap back to their authored
pose. Under **Reduce Motion**, bots snap to the primary pose of the zone and
props stay static, matching the existing leisure and chat rule.

Rules carried over from `DESIGN.md`:
- A reported task always preempts leisure and chats. This already holds and
  must keep holding for zone travel.
- Moving between zones on a real lane change (for example running in QA Lab →
  review in Mission Control) uses the existing smoothed routes. The bot may
  carry a `dataSlate` prop while travelling. That is decoration, not a claimed
  handoff.
- Pair interactions keep the existing rule: they need a shared board and phase.
  One new pair is allowed: two `testing` or two `security` bots on the same
  board may share a bench. The same rule applies.
- The done "cheer" only fires on a running→done transition observed within
  this session, at most once per task id. It is never replayed on reopen.

### 6. Rich bot inspector (parity with Hermes desktop)

**Data layer (shared with the Kanban page; do this first):**
- Extend `KanbanTaskDetail` with `latestSummary`, `result`,
  `lastFailureError`, `skills`, `workflowTemplateID`, `currentStepKey`,
  `workspaceKind/Path`, `branchName`, `sessionID`, `createdBy/At`,
  `startedAt/completedAt`, `parents`, `children`,
  `comments: [KanbanCommentSummary]`, `events: [KanbanEventSummary]`, and
  richer `KanbanRunSummary` (step_key, error, started/ended). Parse all of it in
  `parseKanbanTaskDetail`, which already reads `kanban show --json`. Use
  `runs[]` from `show` and drop the extra `kanban runs` call when present.
- Add the same fields that `kanban list --json` already returns (`skills`,
  `workflow_template_id`) to `KanbanTaskSummary`, so the classifier works
  without a detail fetch.
- **Do not reuse the single `kanbanDetail` slot.** The Kanban page and the
  office would clobber each other. Add a small keyed cache,
  `KanbanTaskDetailStore` (identity → detail/loading/error with a generation
  guard, LRU of about 20). The Kanban page and the office both read from it,
  and it refreshes when the selected task's `latestEventAt` changes. Load only
  on inspector selection ("scan first, inspect second").

**Inspector UI (`OfficeAgentInspector`)**, inside the existing 340pt
`OfficeHUDPanel`, using `OfficeCard`, `OfficeField` and the Dock tokens:

- **Header (fixed):** avatar and status dot, name, status pill, and a new
  zone line ("QA Lab · Testing · from step `verify`"). Actions row:
  **Focus**, **Open session** (when `sessionID` exists), **Open in Kanban**.
- **Segmented tabs** in a fixed slot (no rows inserted above content, per
  AGENTS.md layout stability): **Overview · Activity · Runs · Comments ·
  Files**. Each tab keeps loading, empty and unavailable states in the same
  container, and uses 12pt semibold/12pt detail empty states.
  - *Overview:* current step, running time, latest summary / result
    (bounded, expandable), body (bounded markdown with a "Show more"
    disclosure), fields (priority, skills as chips, workflow, workspace/branch,
    model/provider, created by/at), a last failure error card when present, and
    **Dependencies**. Parent and child task chips focus the bot that owns that
    task, or open the board inspector filtered to it.
  - *Activity:* event timeline with a humanized `kind`, relative time and run
    id badge. Newest 30 first, then "Show more". Diagnostics-type events
    (`stuck_in_blocked`, `repeated_failures`, …) get the warning tint.
  - *Runs:* one row per run with status dot, profile, step, outcome, elapsed
    and a one-line summary that expands to the full summary and error. The
    current run is pinned on top with heartbeat age.
  - *Comments:* thread (author, relative time, body) plus an inline composer
    using the existing capability-gated `mutateKanban(.comment)` confirmed
    mutation with an in-place pending state. Disabled with a reason when the
    capability is unavailable.
  - *Files:* attachments from `kanbanAttachments` (name, kind, size), with
    Reveal and Open actions reusing the Kanban page's existing attachment
    actions.
- **Task actions:** Complete / Block / Unblock via the existing
  `updateKanbanTask`. They are capability-gated with confirmation, as on the
  Kanban page. Keep "Assign existing task…".
- **Queue section** (bot-level, below tabs): the bot's other assigned tasks
  grouped by lane, each row focusable into the same tabs. Recently completed
  tasks only appear from real `completedAt`.
- **Main-session inspector:** keep Open conversation. Add the inferred zone and
  evidence from tool names, and group recent tool activity by work kind.

**New inspectors:**
- **Room inspector (`OfficePreviewSelection.room(OfficeZone)`):** clicking a
  room sign or floor selects the room and lists which bots are there, what
  tasks they are on, and which work kinds map to it. Selecting a row focuses
  that bot. This is the "click the room" loop from Sims.
- **Board inspector:** task rows open the same tabbed detail view for
  unassigned tasks.

**Bubble:** add the zone's SF Symbol before the status in the full tier (for
example `testtube.2`, `lock.shield`, `server.rack`, `books.vertical`,
`paintbrush`, `hammer`) so the zone is readable at a glance.

### 7. Plain-language activity text

Bot titles, steps and events come straight from Hermes (`implement_step`,
`claimed`, `browser_navigate`, `kanban.show`), which is technical. Add
`OfficeActivityCopy`, one pure mapping used by the bubble, roster, inspector
and room inspector:

- **Tool names** (main session, and bot sessions when available) become
  present-tense phrases: `web_search` → "Searching the web", `browser_*` →
  "Browsing a website", `terminal` → "Running commands", `patch`/`write_file`
  → "Editing code", `read_file`/`search_files` → "Reading the codebase",
  `delegate_task` → "Handing work to a helper", `vision`/`image_generate` →
  "Working on images", `todo` → "Updating the plan", `memory` → "Taking
  notes", and approval/clarification → "Waiting for your go-ahead". Build on
  the existing `AgentActivityPresentation.toolActivityTitle` normalisation
  instead of adding a second tool table.
- **Kanban events:** `claimed` → "Picked up the task", `spawned` → "Started
  working", `heartbeat` → "Still working", `completed` → "Finished",
  `crashed` → "Stopped unexpectedly", `blocked` → "Needs help",
  `review_requested` → "Asked for a review", `commented` → "Left a comment",
  `reassign` → "Task handed over", `reprioritized` → "Priority changed",
  and diagnostics such as `stuck_in_blocked` → "Stuck waiting for help".
- **Step keys and work kinds:** `OfficeWorkKind` supplies a verb phrase
  ("Testing", "Researching", "Security check"). Unknown step keys are
  humanised (`write_migration_plan` → "Write migration plan").
- **Lanes:** triage → "Sorting new work", ready → "Up next", todo → "Queued",
  scheduled → "Scheduled", review → "In review", blocked → "Needs help",
  done → "Done".
- **Traceability:** the raw value is never lost. The inspector shows it as
  secondary 11pt monospaced text or a tooltip. Task titles written by people
  are shown as-is and are never rewritten.

### 8. Main agent (no spawned bots)

When no Kanban bots are running, the main session is the only worker. Today it
sits in the Main Agent office typing the whole time. Make it the most
expressive character in the office, still driven only by real session state:

- **Room-to-room travel from tool activity.** The same classifier runs on the
  main session's recent tools. Longer stretches take it to the matching room:
  research → Library carrel, tests → QA Lab, deploy/infra → Server Room,
  images → Design Studio. Short tool bursts stay in its own office. To stop
  rapid tool chains from making it run back and forth, a room change needs
  the same work kind for at least 20s (or 3 consecutive tool calls), and it
  then stays at least 30s. Reduce Motion keeps it at its desk.
- **More to do in its own office.** Add stations and props: a whiteboard (plan
  and todo updates), the bookcase (reading files and docs), a window spot where
  it paces while Hermes is thinking (reasoning events), the copier (exporting
  and attaching files), and the desk (editing, commands, replying).
- **Visible delegation.** When `delegate_task` produces real helper workers
  (already converted in `DockModel` around line 3644), the main agent walks to
  Mission Control and briefs at the display wall. Small helper bots, sized
  down from the bot model, then leave for the helpers' work rooms and walk back
  and fade out when the worker finishes. Helpers exist only while the worker
  exists and carry its real label.
- **Needs you.** Approval or clarification makes it walk to its office door
  facing the camera and raise a hand. The bubble reads "Waiting for your
  go-ahead" with Open conversation as the action.
- **Idle.** When the session is idle, it gets the same leisure behaviour as
  bots (coffee, library, chats), so the office still feels alive.

## Decisions (2026-09-25)

1. Title keywords are allowed as the weakest signal, labelled "Inferred from
   title".
2. Ops room #7 becomes **Security Ops**. No new room.
3. The comment composer is included in the office inspector.

## Phases

1. **Data layer:** parse the full `kanban show --json`, add summary fields,
   add `KanbanTaskDetailStore`, and move the Kanban page onto the store. Tests:
   parser fixtures from real `show --json` output, including older
   human-readable output falling back to summary.
2. **Classifier and routing (existing geometry):** add `OfficeWorkKind`,
   `OfficeWorkClassifier` with evidence, new locations, blocked → help point,
   and the `bringWingsTogether` fix. First route bots to seats that already
   exist in QA Lab, Ops, Server Room, Library and Design Studio, reusing
   current poses. Tests: classifier table tests, including precedence and
   title-only evidence; station allocation stability; no seat sharing;
   overflow → desk.
3. **Inspector v2 and plain-language text:** tabs, actions, comments
   composer, files, dependencies, room inspector, bubble zone icon, and
   `OfficeActivityCopy` everywhere the office shows activity.
4. **Props:** research carrel, Security Ops console and map, crash cart and
   rack doors, QA device rack, design tablet, robot-arm pivots, named sticky
   notes. Update obstacle capture and verify walkable routes into each new
   station.
5. **Interaction beats:** `OfficeWorkInteraction` scripts per zone, prop child
   animation while occupied, travel-carry slate, and done cheer. Reduce Motion
   paths.
5b. **Main agent:** in-office stations and props, tool-driven room travel with
   dwell rules, the "needs you" pose, and delegation helper bots.
6. **Docs:** update the `DESIGN.md` "Office simulation" section (zones table,
   evidence rule, prop-motion rule, inspector tabs) and the README.

Each phase ships on its own. Phases 1–3 deliver most of the value without new
geometry.

## Verification

- Unit: classifier precedence, token matching (`"test"` in `"latest"` must
  not match), hysteresis, lane overrides kind, main-session tool mapping,
  detail parsing, store generation guard (no stale detail after fast
  selection changes), and wing remap of all locations.
- Existing suites stay green: `OfficeBehaviorTests`,
  `OfficePreviewSimulationTests`.
- Manual via `Scripts/run-debug-app.sh`: create tasks on a scratch board with
  skills/steps for each kind, move them through lanes, and confirm that bots
  walk to the right room, use props, leave cleanly, and that the inspector tabs
  fill. Check Reduce Motion, light/dark themes, and a narrow container
  (roster hidden, inspector ≤ 340pt).
- Performance: frame time with 20+ bots all in beat scripts; there should be
  no per-frame allocations in the beat driver.

## Progress (2026-09-25)

- **Phase 1 done.** Full `kanban show --json` history is parsed. List summaries
  carry `skills` and `workflow_template_id`. A keyed inspection cache
  (`kanbanTaskInspections`, LRU 24, generation-guarded) is kept separate from
  the Kanban page's `kanbanDetail`; moving the page onto it is still open.
- **Phase 2 done.** `OfficeWorkKind.swift` holds the kind, the classifier with
  evidence, and `OfficeWorkStabilizer`. Noisy event/title changes must hold for
  20s; step, skill and workflow changes, and lane changes, apply at once. Seats
  (all in existing rooms): QA Lab 3, Security Ops 2 (Ops retitled, with two
  chairs), Server Room 2, Library 3 (research and writing), Design Studio 1,
  Assembly Bay 2, Mission Control wall 3. Seats are identity-hashed with
  probing and never shared; a full room sends the bot to its own desk.
  `bringWingsTogether` now remaps every location except the patio.
- **Deviations from the plan:**
  - Blocked bots stay at their desk with the waiting pose. The authored help
    point stands in the central hall walkway, between the chat spots.
  - Writing shares the Library seats until Phase 4 adds a writing desk.
  - The main agent is classified from its tools but stays in its office until
    Phase 5b adds the dwell rules.
