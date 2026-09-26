# Kanban Page Performance Remediation

Date: 2026-09-20
Source audit: performance audit of the Kanban page (`WorkspaceActivitySidebar.swift`,
`ControlCenterModel.swift`, `HermesCLIAdapter.swift`), same session.

## Problem

The Kanban tab "lags sometimes". The audit found one systemic driver amplified by
rendering inefficiencies:

1. **Poll cascade.** While the tab is open, a loop refreshes every 5 s when live
   cards exist (`WorkspaceActivitySidebar.swift:1465-1475`). Every successful board
   refresh calls `refreshKanbanSupportingProjections()`
   (`ControlCenterModel.swift:1618-1623`), spawning stats, assignees, boards, and
   diagnostics — four extra `hermes` subprocesses per tick. With no board selected,
   the visible path falls through to the aggregate, which fetches each board
   serially (`HermesCLIAdapter.swift:87-109`).
2. **Guaranteed publish churn.** Background polls write `@Published` projection
   and action state even when data is unchanged
   (`beginProjectionRefresh` `:236-254`, `recordProjectionSuccess` `:256-260`,
   `beginAction`/`finishAction` `:326-333`), re-rendering the entire sidebar each
   tick. The unchanged-array guard (`:1591-1601`) cannot help because the state
   dicts still flip.
3. **O(lanes x tasks) main-thread recomputation.** 8 lane filters + 3 metric
   filters over all tasks per render (`WorkspaceActivitySidebar.swift:2908`,
   `:2580-2582`), per-task string allocation in `kanbanLane(for:)` (`:3345`),
   per-card linear bot searches (`:3076`, `:3095`), and per-render detail
   re-parsing (`:3155`).
4. **Secondary.** A single global `isLoadingKanbanDetail` flag re-renders and
   disables every card's Details chip (`:3035`); `.animation(value:)` wraps the
   whole `HSplitView` (`:2576`) so poll-driven diffs animate.

## Goals

- Background polling costs one board request per tick, not ~5 subprocesses.
- No `objectWillChange` from a background poll when board data is unchanged.
- Board body evaluation is single-pass per `kanbanTasks` change.
- Preserve every existing contract: fail-closed capability gating, generation
  guards against stale writes, unchanged-array publish guards, `kanban show`
  stale-recovery, and DESIGN.md layout stability (status stays in existing fixed
  slots; no new chrome; motion must not delay work).

## Non-goals

- No visual redesign or new controls.
- No changes to Hermes CLI commands or capability classification.
- No push/WebSocket transport for the board (separate roadmap item).

## Workstreams

### Phase 1 — Model: stop the per-tick cascade and silent polls

Files: `Sources/HermesAgentDock/ControlCenter/ControlCenterModel.swift`,
`Sources/HermesAgentDock/ControlCenter/WorkspaceActivitySidebar.swift`.

1. Give `refreshKanban(filter:scope:)` an explicit trigger kind
   (`.user` / `.background`):
   - Tab open (`WorkspaceActivitySidebar.swift:427-428`, `:454-458`), explicit
     filter changes via `applyKanbanFilters()` button/menu paths, board
     selection change, and mutation completions (around
     `ControlCenterModel.swift:2498-2560`) run with supporting projections.
   - The poll loop (`WorkspaceActivitySidebar.swift:1465-1475`) and
     `observedKanbanTaskRevision` refresh (`:471-476`) run background-only:
     board list refresh, no `refreshKanbanSupportingProjections()`.
   - `observedKanbanTaskRevision` is exact `kanban show` evidence — keep the
     stale-recovery append path (`:1573-1586`) for it.
2. Suppress published-state writes for background polls:
   - Background refreshes skip `beginProjectionRefresh`/`recordProjectionSuccess`
     writes when a previous projection state exists and content is unchanged.
     Failures still record (fail honest, per DESIGN.md). First load keeps the
     current LOADING path.
   - Replace `beginAction`/`finishAction` churn for poll reentrancy with a
     non-published in-flight guard; `pendingActionIDs` remains for
     user-initiated actions, so `isKanbanRefreshPending` stops flickering the
     filter chips every 5 s.
3. Keep: generation checks (`:1613-1616`), unchanged-array guards
   (`:1591-1601`).

Expected result: while idle-viewing a board with running cards, subprocess spawn
rate drops from ~5 per 5 s to 1 per 5 s and `objectWillChange` fires ~0 times per
unchanged tick.

### Phase 2 — Presentation: single-pass board projection

Files: new `Sources/HermesAgentDock/ControlCenter/KanbanBoardPresentation.swift`,
`WorkspaceActivitySidebar.swift`, new
`Tests/HermesAgentDockTests/KanbanBoardPresentationTests.swift`.

1. Mirror the existing `SessionKanbanActivityPresentation` pattern (pure,
   testable, `Equatable` rows):
   - Normalize status once per task (move logic from
     `WorkspaceActivitySidebar.swift:3344-3357`).
   - One pass producing ordered lane rows (`[KanbanLane: [Row]]` + per-lane
     counts + overview counts), mirroring `KanbanLane.allCases` order.
   - Bot lookups as `Dictionary` keyed by id and case-insensitive name (replace
     `first(where:)` scans at `:3076`, `:3095`).
   - Precompute normalized card detail (move `kanbanCardDetail` `:3155-3168`).
2. Rework `kanbanLane(_:)`, `kanbanOverviewMetrics`, `kanbanTaskCard`,
   `kanbanAssigneePill`, `kanbanBot(for:)` to consume the projection.
3. Tests: lane mapping (`in-progress`, `inprogress`, unknown → todo, archived →
   done), counts, case-insensitive bot match, detail normalization
   (TASK_ID/OBJECTIVE stripping), unknown-status pass-through.

### Phase 3 — Adapter + view polish

1. `HermesRuntime/HermesCLIAdapter.swift:87-109`: fetch boards concurrently with
   `withTaskGroup`, preserving board order and `board_slug` stamping; failure
   semantics unchanged (any throw fails the aggregate).
2. Scope detail loading: `loadKanbanTask` tracks a pending task ID instead of the
   global `isLoadingKanbanDetail`; only the selected card's Details chip shows
   pending/disabled.
3. Replace the whole-`HSplitView` `.animation(.dockEase(duration: 0.2),
   value: selectedKanbanTask?.id)` (`:2576`) with an animation/transition scoped
   to the detail panel container, per DESIGN.md "motion supports state change".

## Sequencing

| Phase | Scope | Est. | Lands independently |
| --- | --- | --- | --- |
| 1 | Model refresh triggers + publish suppression | ~0.5 day | yes — `swift build && swift test` green |
| 2 | Single-pass presentation + tests | ~0.5 day | yes |
| 3 | Concurrent aggregate, per-task pending, scoped animation | ~0.25 day | yes |

## Verification

- `swift build` and `swift test` after each phase (CI parity per README).
- New unit tests for Phase 2 presentation and Phase 1 "background poll does not
  publish when unchanged" (inject tasks via `setKanbanTasksForTesting`, drive a
  background refresh, assert `projectionStates` stability).
- Manual: open Kanban with running cards; confirm no filter-chip flicker, no
  whole-board re-animation during scroll; Activity Monitor shows one `hermes`
  spawn per 5 s tick; diagnostics/stats still refresh on tab open, board change,
  and after mutations.

## Documentation

User-visible behavior is unchanged (same data, same controls). If Phase 1 makes
the reduced diagnostics cadence observable (stale Health section timing), add one
line to the README Kanban section in the same change set; otherwise no README
edit. No DESIGN.md change needed — this work enforces its existing rules.

## Risks

- Publish suppression must not hide first-load LOADING or genuine failure
  transitions: only suppress when a prior state exists and content is unchanged;
  errors always record.
- TaskGroup must preserve board ordering for deterministic list order.
- `observedKanbanTaskRevision` path is correctness-sensitive (stale-card
  recovery); keep it inside the visible scope with recovery intact and covered by
  existing tests.
