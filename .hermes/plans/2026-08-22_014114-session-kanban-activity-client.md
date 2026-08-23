# Hermes Agent Dock: Session Kanban Activity — Client-Only Plan

> **For Hermes:** Implement this in the Hermes Agent Dock project only. Do **not** modify the upstream Hermes Agent CLI, core, database, plugin API, or gateway.

**Goal:** Present the current Hermes session’s durable Kanban work as a first-class visual in Hermes Agent Dock’s Activity surfaces, using the existing supported `hermes kanban list --json --session <session-id>` capability.

**Architecture:** Hermes Agent remains the source of truth and command provider. The Dock adds an independent, session-scoped read projection alongside its existing global Kanban board projection; it never changes the CLI contract, creates a second board, or infers task ownership. A reusable SwiftUI `SessionKanbanActivityView` renders that projection in both the workspace Activity tab and the Session Inspector’s Activity tab.

**Tech Stack:** Swift 6, SwiftUI, Observation/`ObservableObject`, Swift Testing, existing authenticated `HermesCLIAdapter` → `HermesControlRPC` command boundary.

---

## Scope boundaries

### In scope

- New **client-side** session-Kanban visuals in Hermes Agent Dock.
- Separate session-scoped Dock state and refresh lifecycle.
- Read-only cards/status/progress visuals based on Hermes’ existing JSON output.
- Manual refresh plus bounded polling only while the relevant Activity surface is visible.
- Navigation from the visual to the existing global Kanban tab/detail.
- Updating the local Development Team Orchestrator skill policy to use Kanban deliberately for durable workflows.

### Explicitly out of scope

- Any change under `/Users/christian/.hermes/hermes-agent`.
- New Hermes CLI flags, commands, database columns, APIs, plugins, dispatcher behavior, or event streams.
- Creating a physical board per session.
- Treating Dock-created manual Kanban cards as session-owned unless Hermes itself returns a matching `session_id`.
- Mutating Kanban tasks directly from the Activity visual. Existing confirmed actions remain in the full Kanban tab.
- Replacing the global Kanban board or the Dock’s lightweight background-task/activity views.

## Verified current state in the Dock

1. `Sources/HermesAgentDock/HermesCLIAdapter.swift` already forwards `KanbanListFilter.sessionID` as `hermes kanban list --json --session <id>`.
2. `ControlModels.swift` already models `KanbanListFilter.sessionID`.
3. `WorkspaceActivitySidebar.swift` already exposes a `SESSION` filter toggle in the **global Kanban** tab, but only by mutating the single shared `control.kanbanTasks` projection.
4. `WorkspaceActivitySidebar.activityContent` currently shows Background Tasks and `AgentBoardView`, but no Kanban session projection.
5. `SessionInspectorView` has an Activity tab that currently renders only `AgentBoardView`.
6. `ControlCenterModel.focus(sessionID:)` already owns session switch lifecycle through `refreshSessionScopedProjections(for:)`; it is the correct place to request a separate session-Kanban projection.
7. `ControlCenterModel.refreshKanban` protects the global board with a generation token, but cannot be reused for the Activity visual because it overwrites global board state and filters.

## Acceptance ledger

| ID | Criterion | Evidence |
|---|---|---|
| DSKA-1 | Session A’s Activity visual renders only cards Hermes returns for session A; session B never shows session A cards. | Model/parser and SwiftUI tests with two IDs; manual two-session check. |
| DSKA-2 | The global Kanban tab and its selected board/filter state remain unchanged when session Activity refreshes. | State-isolation test. |
| DSKA-3 | The visual clearly distinguishes active, blocked, waiting/review, and completed work; completed cards do not dominate active work. | Presentation tests and screenshots. |
| DSKA-4 | Board source, assignee/profile, status, task title, and dependency/blocker summary are shown only when Hermes supplied them. | Parsing and rendering tests. |
| DSKA-5 | Session switching, board switching, refresh races, and cancelled polling cannot display stale cards from a previous session/board. | Generation/race tests. |
| DSKA-6 | No upstream Hermes Agent source is modified. | Exact diff limited to Dock repository and explicitly approved local skill files. |
| DSKA-7 | The UI is read-only: no completion/block/archive/assignment mutation is exposed from Activity. | UI inspection and interaction tests. |
| DSKA-8 | When Kanban is unavailable or returns an error, Activity shows a compact truthful unavailable/error state without breaking agent/background activity. | Failure-state tests. |

---

### Task 0: Preserve the current Dock worktree and establish a client-only branch

**Objective:** Start safely without disturbing the large existing Dock worktree or any Hermes Agent source.

**Files:**
- Read: `Package.swift`
- Read: `Sources/HermesAgentDock/AGENTS.md` if added before implementation, otherwise repository root instructions
- Read: current `git status` for `/Users/christian/Projects/hermes-agent-dock`

**Steps:**

1. Record the current Dock branch, revision, dirty files, and untracked plans. The observed worktree contains many unrelated modified/new files; do not reset, stash, clean, reformat, or fold them into this work without explicit authorization.
2. Create a new dedicated feature/work branch from the designated current base only after protecting unrelated work. Never implement on `main`.
3. Confirm the implementation write set is limited to the Dock repository and, in the skill task, Christian’s local skill directory. Do not open or edit `/Users/christian/.hermes/hermes-agent`.
4. Run the existing baseline test command only if it can execute without changing generated/untracked state; classify existing failures separately from introduced failures.

---

### Task 1: Add an independent session-Kanban projection to `ControlCenterModel`

**Objective:** Fetch and store session-owned Kanban cards without changing the global Kanban board’s state.

**Files:**
- Modify: `Sources/HermesAgentDock/ControlCenterModel.swift`
- Modify: `Sources/HermesAgentDock/ControlModels.swift`
- Modify: `Tests/HermesAgentDockTests/CommandCenterModelsTests.swift` or create `Tests/HermesAgentDockTests/SessionKanbanProjectionTests.swift`
- Verify only: `Sources/HermesAgentDock/HermesCLIAdapter.swift`
- Verify only: `Tests/HermesAgentDockTests/HermesCLIAdapterTests.swift`

**Step 1: Write failing state-isolation tests.**

Cover these cases:

```swift
// Global board cards are preserved when the session projection succeeds.
#expect(control.kanbanTasks == globalTasks)
#expect(control.sessionKanbanTasks == sessionATasks)

// A completion from the stale request for session A cannot replace session B.
#expect(control.sessionKanbanSessionID == "session-B")
#expect(control.sessionKanbanTasks == sessionBTasks)
```

Also test missing session ID, unavailable `kanban` capability, a CLI failure, and a task list containing no matching cards.

**Step 2: Add separate published state.**

In `ControlCenterModel`, add a distinct projection rather than overloading `kanbanTasks` / `kanbanFilter`:

```swift
@Published private(set) var sessionKanbanTasks: [KanbanTaskSummary] = []
@Published private(set) var sessionKanbanSessionID: String?
@Published private(set) var sessionKanbanRefreshState: ProjectionRefreshState?
```

Use a dedicated `sessionKanbanRefreshGeneration` and retain the requested session ID and board slug in every completion guard. Reuse `KanbanListFilter(sessionID: sessionID, includeArchived: false, sort: "updated")` through the existing `HermesCLIAdapter`; do not construct commands in a view or add a CLI adapter method unless the current typed method cannot express the request.

**Step 3: Integrate into the existing session-focus lifecycle.**

Call `refreshSessionKanban(for:)` from `refreshSessionScopedProjections(for:)`. Clear the old session projection immediately on session change so session A’s card never remains painted during session B’s fetch. If there is no active session, retain no session cards and render no session Kanban visual.

**Step 4: Preserve board semantics.**

Use the same selected/current board behavior already used by the global Kanban projection. A session card visual must label the board when the summary provides a board slug. Do not implement client-side multi-board scanning in v1; that would require an explicit Hermes-side aggregate contract and is out of scope.

**Step 5: Extend data safely only where Hermes already provides fields.**

Confirm `KanbanTaskSummary` parsing in `ControlCenterModel.parseKanbanTasks` preserves the current fields and add `sessionID` only if it exists in the existing JSON response. Never assign `model.sessionID` to a card client-side merely to make it appear session-owned.

**Step 6: Run focused tests.**

```bash
swift test --filter SessionKanbanProjectionTests
swift test --filter HermesCLIAdapterTests
```

Expected: projection isolation, stale-result suppression, and the existing `--session` command forwarding test pass.

---

### Task 2: Create a pure presentation layer for session activity cards

**Objective:** Make visual ordering, labels, status colors, and empty-state behavior deterministic and testable outside a view body.

**Files:**
- Create: `Sources/HermesAgentDock/SessionKanbanActivityPresentation.swift`
- Create: `Tests/HermesAgentDockTests/SessionKanbanActivityPresentationTests.swift`
- Modify if required: `Sources/HermesAgentDock/ControlModels.swift`

**Step 1: Define display-only models.**

Create pure types such as `SessionKanbanActivityPresentation.Snapshot` and `Row`, generated only from `KanbanTaskSummary` plus the selected session/board context. The presentation layer must not call RPC, mutate tasks, or own refresh timers.

**Step 2: Establish the status priority.**

Sort active work before historical work:

1. `running`
2. `blocked`
3. `ready` / `scheduled`
4. `review` / `triage` / `todo`
5. `done` (collapsed summary only)

Use a single normalized status map so unusual/unknown Hermes statuses remain visible as `UNKNOWN` with neutral styling rather than being dropped.

**Step 3: Define the compact visual contract.**

Each row can show only data Hermes returned:

- title;
- status chip and semantic color;
- assignee/profile when non-empty;
- blockers/dependency count or concise detail when available;
- board provenance when available;
- last-updated/priority metadata if already represented by `KanbanTaskSummary`.

Do not manufacture agent names, progress percentages, dependencies, or state transitions.

**Step 4: Write tests.**

Test sorting, active/completed count, unknown status retention, empty result behavior, optional metadata suppression, and stable IDs across refreshes.

```bash
swift test --filter SessionKanbanActivityPresentationTests
```

---

### Task 3: Build the reusable Session Kanban Activity visual

**Objective:** Add a polished, compact read-only session-Kanban visual that fits the Dock’s existing Activity composition.

**Files:**
- Create: `Sources/HermesAgentDock/SessionKanbanActivityView.swift`
- Modify: `Sources/HermesAgentDock/WorkspaceActivitySidebar.swift`
- Modify: `Sources/HermesAgentDock/SessionInspectorView.swift`
- Modify if shared visual primitives are genuinely missing: `Sources/HermesAgentDock/ScifiComponentStyles.swift`
- Create: `Tests/HermesAgentDockTests/SessionKanbanActivityViewTests.swift`

**Step 1: Implement `SessionKanbanActivityView`.**

Accept only the session-scoped read projection, refresh state, session ID, and callbacks. The view must be usable in both existing Activity surfaces without recreating networking/state logic.

Recommended layout:

```text
SESSION KANBAN                         [refresh]
3 active · 1 blocked · current board

● RUNNING  Implement session activity  Luna       >
! BLOCKED  Review API contract          Terra      >
○ READY    Run UI verification          —          >

2 completed                              [expand]
Open full Kanban board →
```

Use existing sci-fi palette, typography, glass row, accessibility, reduced-motion, and hit-target conventions. Do not add decorative animation that competes with the live Agent Board.

**Step 2: Define truthful empty and failure states.**

- No current session: return `EmptyView()`.
- Loading with no cached result: compact skeleton/progress label.
- Successful empty session result: show a low-emphasis `No Kanban work for this session` state only in an Activity surface where the section is useful; do not expand the layout excessively.
- Capability unavailable: show a concise unavailable label and leave background/subagent activity intact.
- Failed/stale: show the last successful session projection with a small stale/error indicator and a Retry control.

**Step 3: Mount it in both appropriate client surfaces.**

- In `WorkspaceActivitySidebar.activityContent`, place Session Kanban between Background Tasks and `AgentBoardView`.
- In `SessionInspectorView`’s `.activity` case, place the same reusable view above the embedded `AgentBoardView`.

This ensures the visual follows the selected Dock session rather than being visible only in the global Kanban control tab.

**Step 4: Keep Activity interactions read-only.**

- Refresh calls `control.refreshSessionKanban(for: model.sessionID)`.
- A row opens the existing Kanban tab/detail through a callback supplied by `WorkspaceActivitySidebar`; do not add task mutation buttons.
- The `Open full Kanban board` affordance switches to `.kanban`, applies an explicit session filter, and refreshes the global board only after user intent. It must not silently alter the global board when merely viewing Activity.

**Step 5: Write view tests.**

Test active/blocked/ready rendering, empty/loading/error states, accessibility labels, refresh callback, open-board callback, completed-card collapse, and no action controls for complete/block/archive/assign.

---

### Task 4: Add bounded Activity refresh behavior without global-board churn

**Objective:** Keep the visual current while the user is viewing Activity, without polling all Kanban data or leaking stale state across sessions.

**Files:**
- Modify: `Sources/HermesAgentDock/WorkspaceActivitySidebar.swift`
- Modify: `Sources/HermesAgentDock/SessionInspectorView.swift`
- Modify if lifecycle ownership proves cleaner: `Sources/HermesAgentDock/ControlCenterModel.swift`
- Modify: `Tests/HermesAgentDockTests/SessionKanbanProjectionTests.swift`

**Step 1: Refresh on meaningful transitions.**

Request the session projection when:

- `model.sessionID` changes and `control.focus(sessionID:)` runs;
- the user enters an Activity view with a valid session;
- the user explicitly taps refresh;
- the selected board changes, if the session view is board-scoped.

**Step 2: Poll only while visible.**

Use a cancellable Swift concurrency task keyed by `(visibleActivitySurface, sessionID, selectedKanbanBoardSlug)`. Refresh at a conservative interval (for example 10–15 seconds) only while the Activity view is selected/visible. Cancel on tab switch, session switch, view disappearance, or deinit.

Do not poll the global `refreshKanban()` loop from Activity, and do not issue concurrent requests if a session refresh is already in flight.

**Step 3: Enforce stale-result protection.**

Every async completion must verify the same generation, canonical session ID, and board slug that initiated the request before publishing. A cancelled or older request must have no visible effect.

**Step 4: Test lifecycle behavior.**

Use an injectable clock/task seam or testable refresh coordinator to prove no fetch runs after cancellation, only the current session is published, and Activity polling never mutates `kanbanTasks` or `kanbanFilter`.

---

### Task 5: Update the Development Team Orchestrator skill for deliberate Kanban use

**Objective:** Align worker orchestration policy with the Dock visual so the UI reflects genuine durable work, not cosmetic task generation.

**Files (outside the Dock repository but local to Christian’s active Hermes profile):**
- Modify: `/Users/christian/.hermes/skills/my-dev-team-orchestrator/SKILL.md`
- Modify: `/Users/christian/.hermes/skills/my-dev-team-orchestrator/references/team-config.yaml`
- Modify: `/Users/christian/.hermes/skills/my-dev-team-orchestrator/references/handoffs.md`
- Modify only if placement wording needs correction: `/Users/christian/.hermes/skills/my-dev-team-orchestrator/references/model-routing.md`

**Step 1: Add a backend-selection matrix.**

- Direct lead tools: deterministic inspection/small one-owner changes.
- `delegate_task`: bounded investigations and short independent reviews.
- Kanban DAG: multi-role implementation, dependency chains, formal review/remediation, long-running/interrupted work, or audit-sensitive delivery.

**Step 2: Add session-activity conventions.**

For Kanban-routed work originating from a user session, require cards to preserve the Hermes-provided origin session association and a board assignment. The lead reports the session projection as an observation, while the global Kanban board remains the canonical operational source of truth.

**Step 3: Keep runtime claims honest.**

The skill must not claim that a dispatcher, per-role profile, model placement, or durable Kanban worker fleet is configured unless live runtime telemetry confirms it. `team-config.yaml` remains declarative policy.

**Step 4: Retain the hybrid default.**

Do not convert every chat task into Kanban. The Dock’s session visual should normally be empty for direct/delegated short work; that is correct and must be described as such.

---

### Task 6: Validate the client feature on a frozen state

**Objective:** Verify the Dock-only implementation and visual behavior before any delivery action.

**Files:**
- Verify all changed Dock files and approved skill files.

**Step 1: Focused tests.**

```bash
swift test --filter HermesCLIAdapterTests
swift test --filter SessionKanbanProjectionTests
swift test --filter SessionKanbanActivityPresentationTests
swift test --filter SessionKanbanActivityViewTests
```

Use exact discovered test target names; if a filter is unsupported in the local SwiftPM version, run the test target and report that limitation honestly.

**Step 2: Broad local gates.**

```bash
swift test
swift build
```

Separate pre-existing failures caused by the current unrelated worktree from introduced failures. Do not reset the worktree to manufacture a clean result.

**Step 3: Manual UI evidence.**

With two real Hermes sessions and the same board:

1. Create or identify one Hermes-owned card associated with session A and one with session B.
2. Open Activity for session A and confirm only session A’s task appears.
3. Switch to session B and confirm the prior card clears before the new projection arrives; confirm session B’s task appears.
4. Change a task in Hermes, then verify the Dock updates via explicit refresh and visible-only polling.
5. Open the full board from the visual and verify it applies the session filter only after the user chooses the action.
6. Switch back to global Kanban and confirm its prior board/filter state was not altered by background activity polling.
7. Check no Active Activity control mutates a Kanban card.
8. Inspect console/log output for command or parsing failures and capture screenshots at loading, empty, active, blocked, stale/error, and completed-collapsed states.

**Step 4: Fresh exact-diff review.**

Freeze the Dock feature-branch state, record changed/untracked files, and perform an independent read-only review against DSKA-1 through DSKA-8. Route any accepted issue through a bounded remediation change, then rerun every affected test. Do not commit, push, or create a PR unless separately authorized.

---

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Session ID used by Dock does not match Hermes task `session_id`. | Verify using live existing `--session` results first; do not add a client mapping or fabricate ownership. Show empty/unavailable truthfully until the contract is confirmed. |
| Reusing `refreshKanban` overwrites the global board. | Maintain independent session projection state and generation token. |
| Session switch races display prior cards. | Clear on focus and gate every publish by session ID, board, and generation. |
| Activity polling creates unnecessary CLI load. | Poll only while an Activity surface is visible, with cancellation and a conservative interval. |
| Dock-created card lacks session attribution. | Keep session Activity read-only; do not claim manually created global cards belong to the current session. |
| Current worktree contains unrelated changes. | Isolate a new feature branch only after preserving the worktree; no destructive Git commands. |
| Skill overstates actual Kanban runtime capability. | Keep backend policy conditional on verified dispatcher/profile telemetry. |

## Follow-up candidates (not part of this plan)

1. A Hermes-provided cross-board session aggregate once a supported contract exists.
2. Read-only task detail drill-down embedded in the Session Inspector.
3. Board-level agent/worker telemetry overlays once Hermes exposes verified real-time placement data.
4. Optional session-card creation in the Dock only if Hermes exposes a supported command/API that explicitly accepts and persists session attribution.
