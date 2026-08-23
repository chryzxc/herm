# Hermes Agent Dock Control-Tower Roadmap Implementation Plan

> **For Hermes:** Use `subagent-driven-development` to implement this plan one task packet at a time. For this roadmap, use Kanban as the durable control plane because the work has dependencies, review gates, durable evidence, and may be interrupted. Do **not** create a PR unless the user explicitly authorizes `CREATE_PR`.

**Goal:** Evolve Hermes Agent Dock into a local, read-mostly control tower that explains live Hermes work, surfaces decisions and evidence, and links to the authoritative Hermes runtime without duplicating the CLI, scheduler, gateway, or agent execution engine.

**Architecture:** Keep Hermes Agent Dock a projection client. Every new surface must consume an existing Dock model/CLI/RPC projection or an explicitly verified, read-only Hermes capability; it must not invent runtime state, persist secrets, or write directly to Hermes databases. Use pure Foundation presentation/builders for sorting, prioritization, health classification, and redaction, then keep SwiftUI views thin and bind them to `ControlCenterModel` refresh state.

**Tech Stack:** Swift 6, SwiftUI, Swift Package Manager, `Testing`, existing `HermesCLIAdapter`, existing `HermesControlRPC`, existing `ControlCenterModel`, existing Sci-Fi component styles.

---

## Scope and non-goals

### In scope

1. **Plan Artifacts** — a dedicated right-inspector artifact browser for `.hermes/plans/*.md`, with explicit comments and revision workflows.
2. **Mission Control** — an at-a-glance focused-session operational summary.
3. **Attention Inbox improvements** — prioritization, actionable context, snoozing/navigation, and high-signal notification integration.
4. **Verification Evidence** — a read-only proof/status surface for checks, review state, and repository freshness.
5. **Automation Health** — cron/MCP health and recent failure state.
6. **Agent Operations Radar** — observed live workers, active state, heartbeat/stall classification, and dependency context where Hermes exposes it.
7. **Session Flight Recorder** — a readable timeline assembled from existing events/tool calls/agent activity.
8. **Context & Provenance** — source/session/profile/repository/model/capability metadata for an item.
9. **Capacity Runway** — a visualization over existing quota data and `QuotaForecasting` estimates.
10. **Repository Change Intelligence** — relationship between the focused session, Kanban task, dirty state, review baseline, and verification freshness.
11. **High-signal macOS notifications** — only for attention, blockers, terminal completion/failure, automation failure, and quota threshold crossings.

### Explicit non-goals

- Do not modify `/Users/christian/.hermes/hermes-agent` or introduce Hermes CLI/core/database/API changes.
- Do not execute agent work, schedule jobs, mutate Kanban, change model routing, edit credentials, or make external calls from new dashboard views.
- Do not use Dock state as an authority when Hermes did not supply the underlying evidence.
- Do not add a generic duplicate chat screen, duplicate global Kanban board, or a second cron scheduler.
- Do not add a snapshot-testing dependency unless pure-presentation coverage cannot verify a concrete requirement.
- Do not claim per-agent provider/model placement unless observed from runtime data; configured aliases are not evidence.

## Current repository facts to preserve

- Workspace path: `/Users/christian/Projects/hermes-agent-dock`.
- The current worktree is heavily dirty on `main`; do not reset, stash, clean, stage, or modify unrelated work.
- Existing data/UI seams:
  - `Sources/HermesAgentDock/ControlCenterModel.swift` owns remote projection refresh, capabilities, attention, Kanban, cron, and verification state.
  - `Sources/HermesAgentDock/ControlModels.swift` contains transport-facing summary types and capability/attention models.
  - `Sources/HermesAgentDock/AgentActivityPresentation.swift` already derives activity phases and timeline-style pipeline rows.
  - `Sources/HermesAgentDock/CommandCenterModels.swift` already has `MissionControlSnapshotBuilder`, readiness logic, and command palette descriptors.
  - `Sources/HermesAgentDock/WorkspaceActivitySidebar.swift` already owns tabs for Today, Session, Inbox, Activity, Changes, Verification, Automations, Kanban, Core, and Quota.
  - `Sources/HermesAgentDock/SessionInspectorView.swift` owns focused session UI.
  - `Sources/HermesAgentDock/QuotaForecasting.swift` has pure quota runway functions.
  - Existing Testing conventions live in `Tests/HermesAgentDockTests/`.
- Baseline test concern: the current worktree contains an unrelated staged `ProviderQuotaTests.swift` syntax failure. Do not silently repair it under this roadmap. Capture and classify it at preflight; obtain explicit authorization before fixing unrelated baseline work.

## Product decisions frozen for this plan

| Decision | Contract |
| --- | --- |
| Authority | Hermes remains authoritative. Dock only displays verified projections and invokes existing, explicitly user-triggered actions. |
| Refresh | Refresh only while the relevant view is visible, use model-owned cancellation/generation protection, preserve known-good cached state, and distinguish loading, unavailable, stale, empty, and error. |
| Privacy | Never store raw tool inputs/outputs, prompt text, secrets, tokens, or unbounded logs in defaults/notification payloads. Bound and redact display previews. |
| Session isolation | Every focused-session projection validates the session ID at publication time and clears when focus is absent or changes. |
| Notifications | Notifications contain generic titles and a source reference only; detailed content stays behind Dock unlock/app foreground. |
| UI model | Use pure, deterministic presentation builders. SwiftUI views must not invent status or perform broad polling independently. |
| Plan artifacts | Treat `.hermes/plans/*.md` as canonical Markdown artifacts. Render safely, save only on explicit user action, store review comments as transparent sidecar artifacts, and create revisions as new Markdown files linked to their parent hash rather than silently overwriting the source plan. |
| Delivery | Build each phase independently. Do not begin a dependent phase until the previous phase has targeted tests, current review, and an accepted handoff. |

---

# Execution graph

```text
P0 Baseline + contracts
 ├─ P1 Plan Artifacts viewer, comments, and revisions
 ├─ P2 Mission control composition
 ├─ P3 Attention/inbox + notification policy
 ├─ P4 Verification evidence + repository freshness
 └─ P5 Automation health
       ↓
P6 Agent operations radar + flight recorder
       ↓
P7 Provenance inspector + capacity runway
       ↓
P8 Cross-surface integration, accessibility, performance, and final evidence
```

P1 establishes the shared artifact boundary and right-inspector navigation, so complete and review it first. After P1, parallelize only pure-model work in P2–P5; serialize any SwiftUI composition changes to `Views.swift`, `WorkspaceActivitySidebar.swift`, or `SessionInspectorView.swift`. P6–P8 are serialized because they consume cross-surface contracts. Give each implementer an isolated worktree and exclusive file ownership.

## Acceptance ledger

| ID | Criterion | Owner | Evidence |
| --- | --- | --- | --- |
| AC-01 | Dock does not create a second Hermes runtime, database, scheduler, or task authority. | Lead/reviewer | Exact diff and capability-path review. |
| AC-02 | Every new focused-session projection is session-safe and rejects late data after focus changes. | Implementer/verifier | Unit race tests + manual switching check. |
| AC-03 | Dashboard state differentiates loading, unavailable, stale, empty, success, and failure where applicable. | Implementer/verifier | Presentation tests and UI state walkthrough. |
| AC-04 | Attention/notifications expose only high-signal, safe summaries and deep-link to the correct Dock context. | Implementer/security reviewer | Unit tests + notification payload review. |
| AC-05 | Verification UI never reports readiness without current evidence for the current repository state. | Implementer/reviewer | Builder tests + stale-baseline regression tests. |
| AC-06 | Automation/agent status is derived only from observed Hermes data; absent telemetry is shown as unavailable/unknown. | Implementer/reviewer | Parsing/presentation tests. |
| AC-07 | New UI is keyboard-accessible, respects VoiceOver labels, reduced motion, and does not continuously refresh hidden tabs. | Verifier | Manual macOS QA checklist. |
| AC-08 | `swift build` passes and all currently runnable relevant tests pass; unrelated baseline failures are separately documented. | Verifier | Commands/output linked to frozen diff. |
| AC-09 | Plan artifacts are path-confined, safely rendered, explicitly saved, revision-linked, and commentable without silently modifying the canonical plan. | Implementer/reviewer | File-service and presentation tests + manual artifact workflow. |

---

# Phase P0 — Freeze the baseline and define shared contracts

### Task P0.1: Create an isolated feature worktree

**Objective:** Protect the current dirty `main` worktree and establish a reproducible implementation baseline.

**Files:**
- Create: a new feature worktree/branch only; no source changes.
- Read: repository instructions, `Package.swift`, current status, current diff.

**Steps:**
1. Read repository instructions (`AGENTS.md`, `.hermes.md`, `CLAUDE.md`, etc.) if present.
2. Record `git status --short --branch`, `git diff --check`, staged and unstaged file lists, and `git rev-parse HEAD`.
3. Create a new branch/worktree from the repository’s designated clean base only after confirming the base with the user/repository convention. Do not derive a branch from the dirty worktree.
4. Confirm the isolated worktree is clean before the first source change.

**Verification:**
```bash
git status --short --branch
git diff --check
git rev-parse HEAD
```

**Stop condition:** If a clean base cannot be identified without discarding user work, return `NEEDS_ASSISTANCE`; do not reset/stash/clean.

---

### Task P0.2: Inventory authoritative data paths

**Objective:** Produce a small contract table before adding any dashboard models.

**Files:**
- Read: `Sources/HermesAgentDock/HermesCLIAdapter.swift`
- Read: `Sources/HermesAgentDock/HermesControlTransport.swift`
- Read: `Sources/HermesAgentDock/ControlCenterModel.swift`
- Read: `Sources/HermesAgentDock/ControlModels.swift`
- Create: `.hermes/plans/evidence/control-tower-capability-inventory.md` (in the isolated feature worktree only)

**Steps:**
1. List each planned surface and its candidate source: existing RPC event, existing CLI query, existing local repository read, or unavailable.
2. For each candidate source, record payload fields actually parsed today, refresh owner, session linkage, mutation capability, and privacy concerns.
3. Mark any field not currently supplied by Dock/Hermes as **unavailable**. Do not plan UI that implies it exists.
4. Freeze a compact `ControlTower` domain vocabulary: `observed`, `unknown`, `unavailable`, `stale`, `blocked`, `attentionRequired`, `healthy`, `degraded`.

**Verification:**
- Reviewer confirms every planned displayed field is either mapped to an existing parsed source or explicitly marked unavailable.

---

### Task P0.3: Add a shared presentation-state contract

**Objective:** Prevent each view from inventing incompatible loading/error/staleness rules.

**Files:**
- Modify: `Sources/HermesAgentDock/ControlModels.swift`
- Create: `Sources/HermesAgentDock/ControlTowerPresentation.swift`
- Test: `Tests/HermesAgentDockTests/ControlTowerPresentationTests.swift`

**Step 1: Write failing tests**
- Test that a projection with no success and `isRefreshing == true` presents loading.
- Test that cached data plus an error presents stale, not empty.
- Test that unsupported capability presents unavailable with no retry mutation.
- Test that unknown telemetry does not become healthy.

**Step 2: Run focused test**
```bash
swift test --filter ControlTowerPresentationTests
```
Expected: fail because the presentation type does not exist.

**Step 3: Implement minimal pure types**
- Add a closed `ControlTowerDataState` enum to the new presentation file.
- Map existing `ProjectionRefreshState` plus capability availability and item count into that enum.
- Keep the type Foundation-only and deterministic.

**Step 4: Re-run focused test**
```bash
swift test --filter ControlTowerPresentationTests
```
Expected: pass, unless an unrelated baseline test compilation failure prevents test-target construction; record that separately.

**Acceptance:** AC-03 foundation exists and is not tied to a specific SwiftUI screen.

---

# Phase P1 — Plan Artifacts viewer, comments, and revisions

### Task P1.1: Define a confined plan-artifact file service

**Objective:** Safely discover and load canonical plan Markdown below the active project’s `.hermes/plans/` directory without exposing arbitrary files.

**Files:**
- Create: `Sources/HermesAgentDock/PlanArtifactService.swift`
- Create: `Sources/HermesAgentDock/PlanArtifactModels.swift`
- Test: `Tests/HermesAgentDockTests/PlanArtifactServiceTests.swift`

**Step 1: Write failing tests**
- Only immediate/nested Markdown files under `<project>/.hermes/plans` are listed; `.md` and `.markdown` are accepted.
- Paths containing traversal (`..`), absolute paths, symlink escapes, or files outside the canonical root are rejected.
- Listings are deterministically sorted newest-first by parsed timestamp/name, then stable path.
- A missing plans directory presents an empty artifact state, not an error or a fabricated plan.
- Plan text and metadata are bounded before display; binary/non-UTF-8 files are unavailable.

**Step 2: Run focused test**
```bash
swift test --filter PlanArtifactServiceTests
```
Expected: fail because plan artifact types/service do not exist.

**Step 3: Implement minimal data model/service**
- `PlanArtifactSummary`: relative path, display title, modification date, byte count, SHA-256, and `ArtifactDataState`.
- `PlanArtifactDocument`: summary plus bounded UTF-8 Markdown source.
- Resolve paths with `URL.standardizedFileURL`, verify containment below the standardized plans root, reject unsafe inputs, and do not follow a symlink outside the root.
- Keep all filesystem reads local to the resolved project path. Do not read the global `~/.hermes` plans directory in v1.
- Compute SHA-256 from the canonical on-disk bytes; do not treat an in-memory draft as canonical.

**Step 4: Re-run focused test**
```bash
swift test --filter PlanArtifactServiceTests
```

**Acceptance:** AC-09 path safety and truthful empty/unavailable states.

---

### Task P1.2: Add transparent comments and revision metadata

**Objective:** Support review discussion and revisions without silently changing the selected plan’s canonical Markdown.

**Files:**
- Modify: `Sources/HermesAgentDock/PlanArtifactModels.swift`
- Modify: `Sources/HermesAgentDock/PlanArtifactService.swift`
- Test: `Tests/HermesAgentDockTests/PlanArtifactServiceTests.swift`

**Persistence contract:**
- Comments are review artifacts saved only by explicit user action to `.hermes/plans/reviews/<canonical-plan-sha256>.md`.
- Each comment record contains comment ID, created timestamp, canonical plan relative path, canonical SHA-256, optional section anchor, and plain-text comment body.
- A revision is a **new** file in `.hermes/plans/` with a timestamped name and Markdown frontmatter containing `parent_plan` and `parent_sha256`.
- Never rewrite the selected canonical plan as part of “Add comment” or “Create revision.” Editing an original plan is a separate, explicitly confirmed workflow and remains out of v1.

**Tests:**
- Comment file is written only after an explicit save call.
- Comment body is bounded; control characters are rejected/normalized.
- Comments are marked stale if their stored parent SHA does not match the selected canonical plan.
- Revision filename cannot escape plans root, collision handling is deterministic, and frontmatter records the correct parent path/hash.
- Saving a comment/revision failure leaves the prior document and comment list intact.

**Acceptance:** AC-09 comments/revisions are transparent, reversible, and safely local.

---

### Task P1.3: Create pure plan-artifact presentation

**Objective:** Parse plan Markdown into a compact artifact outline and comment anchors without treating rendered Markdown as executable content.

**Files:**
- Create: `Sources/HermesAgentDock/PlanArtifactPresentation.swift`
- Test: `Tests/HermesAgentDockTests/PlanArtifactPresentationTests.swift`

**Requirements:**
- Extract title, `##`/`###` heading outline, task labels, acceptance IDs, and dependency code block summaries when present.
- Preserve source offsets/line ranges for navigation; never inject raw HTML or execute Markdown links/actions.
- Expose current SHA, last modified time, comment count, revision relation, and stale-comment count.
- Use `MarkdownMessageView` only for safe visual rendering; parsing/navigation state must remain pure Foundation data.

**Tests:** heading hierarchy/order, duplicate heading anchors, malformed Markdown, very long lines, no title fallback, stale comments, and plan files with no task structure.

---

### Task P1.4: Add the right-inspector Artifacts scope and plan browser

**Objective:** Give plans a dedicated, persistent right-section surface rather than burying them in repository files or chat output.

**Files:**
- Modify: `Sources/HermesAgentDock/Views.swift`
- Create: `Sources/HermesAgentDock/PlanArtifactsInspectorView.swift`
- Reuse: `Sources/HermesAgentDock/ConversationComponents.swift` (`MarkdownMessageView`)
- Reuse where appropriate: `Sources/HermesAgentDock/RepositoryCodeWorkspaceView.swift` visual shell conventions.

**UI contract:**
- Add `InspectorScope.artifacts = "Artifacts"` to the existing right-panel scope picker. Keep Global and Session behavior unchanged.
- Left column: plan list with title/path, modified date, checksum prefix, comment/revision badges, and state (current/stale/unavailable).
- Main artifact view: rendered Markdown with an outline rail, source path and SHA header, modified date, and a clear “canonical file” label.
- Review drawer: anchored comments, stale-comment indication, add-comment field, explicit **Save comment** action, and no automatic persistence.
- Revision action: **Create revision** opens a draft for a new plan artifact, pre-populates parent provenance, and requires explicit save. It must not overwrite the selected plan.
- Use the screenshot’s visual language: deep graphite canvas, rounded low-contrast card border, large pale heading, monospaced muted path/checksum metadata, restrained cyan accent for bullets/actions, generous vertical spacing. Preserve existing `Color.scifi*` tokens rather than hard-coding new colors.
- Accessibility: all metadata must have textual labels; checksum/path copy uses a deliberate button and announces success; status never depends on color alone.

**Manual verification:**
1. Existing `.hermes/plans/*.md` appears under Artifacts.
2. A project with no plans shows “No plan artifacts” and a path explanation.
3. Select a plan, add a comment, cancel, and confirm no file is written.
4. Save a comment, restart/reload, and confirm it appears with parent hash.
5. Modify the selected plan outside Dock, reload, and confirm existing comments appear stale.
6. Create a revision, verify parent frontmatter/hash, and confirm the source plan bytes remain unchanged.
7. Attempt a crafted traversal path through any internal test seam; it is rejected.

**Acceptance:** AC-07, AC-09.

---

### Task P1.5: Integrate plan artifacts with the existing plan handoff workflow

**Objective:** Make it easy to hand an approved plan to Hermes without making the Dock an execution engine.

**Files:**
- Modify: `Sources/HermesAgentDock/CommandCenterModels.swift`
- Modify: `Sources/HermesAgentDock/WorkspaceActivitySidebar.swift` only if the command palette/action callback is owned there.
- Test: `Tests/HermesAgentDockTests/CommandCenterModelsTests.swift`

**Behavior:**
- Add a read-only command-palette action to open Artifacts.
- Add a **Copy plan reference** action that copies only relative path + canonical SHA-256 in a compact handoff format.
- Optional v1.1, only after explicit confirmation design: “Ask Hermes to review this plan” creates a normal user prompt containing path and hash—not raw contents—and never auto-starts execution.

**Tests:** action registry exposes the artifact action; unavailable/no-plan state is disabled with reason; generated handoff contains path/hash but no comment bodies or plan content.

---

# Phase P2 — Mission Control composition

### Task P2.1: Extend the pure mission snapshot without duplicating existing work

**Objective:** Make `MissionControlSnapshotBuilder` describe the focused session’s current work, attention, readiness, and session Kanban summary from observed projections.

**Files:**
- Modify: `Sources/HermesAgentDock/CommandCenterModels.swift`
- Test: `Tests/HermesAgentDockTests/CommandCenterModelsTests.swift`

**Step 1: Write failing tests**
- A focused session with running agent activity surfaces the latest observed work item.
- A session Kanban blocked task outranks generic running work in the summary.
- A missing session Kanban capability produces `unavailable`, not “no tasks.”
- A stale verification record produces `needsReview`, never `ready`.

**Step 2: Implement minimal model changes**
- Add a narrowly scoped `MissionControlSessionStatus` value with session ID, current activity summary, attention counts, session Kanban counts, verification state, and data state.
- Reuse `AgentActivityPresentation.pipeline`, `ControlCenterModel.openAttention(for:)`, session Kanban projection, and `VerificationSummary`; do not copy parsing logic.
- Preserve the existing global `MissionControlSnapshot` behavior for non-session overview.

**Step 3: Run tests**
```bash
swift test --filter CommandCenterModelsTests
```

**Acceptance:** AC-01, AC-02, AC-03, AC-05.

---

### Task P2.2: Build a thin focused-session Mission Control card

**Objective:** Add a compact, read-only card to the existing Session and Today/Activity surfaces.

**Files:**
- Create: `Sources/HermesAgentDock/SessionMissionControlView.swift`
- Modify: `Sources/HermesAgentDock/SessionInspectorView.swift`
- Modify: `Sources/HermesAgentDock/WorkspaceActivitySidebar.swift`

**Steps:**
1. Render from the pure snapshot only.
2. Show: current phase, current task, active count, selected board/task summary if present, attention count, verification readiness, and data-state text.
3. Provide navigation callbacks only: Open Inbox, Open Activity, Open Verification, Open Kanban. Do not create/edit tasks from this card.
4. Add VoiceOver labels for status, state, and navigation controls.
5. Use existing Sci-Fi styles; do not create a new competing visual system.

**Manual verification:**
- Select a running session, a completed session, and no session.
- Switch session rapidly while a refresh is in flight.
- Confirm the old session never remains visible.
- Confirm hidden tabs do not start a second refresh loop.

**Acceptance:** AC-02, AC-03, AC-07.

---

# Phase P3 — Attention Inbox and notifications

### Task P3.1: Add a pure attention priority and grouping model

**Objective:** Make inbox urgency explainable and stable across surfaces.

**Files:**
- Create: `Sources/HermesAgentDock/AttentionPresentation.swift`
- Modify: `Sources/HermesAgentDock/ControlModels.swift` only if a small presentation-safe field is genuinely missing.
- Test: `Tests/HermesAgentDockTests/AttentionPresentationTests.swift`

**Required ordering:** approval → clarification → failure → blocked Kanban → automation failure → reminder → completed/history.

**Tests:**
- Different sessions do not coalesce into one item.
- Resolved/dismissed items do not appear in Needs Me.
- A generic failure never outranks an approval.
- Items with unavailable session linkage remain visible but do not offer a broken deep link.

**Acceptance:** AC-02, AC-04.

---

### Task P3.2: Upgrade the Inbox UI with source context and safe actions

**Files:**
- Modify: `Sources/HermesAgentDock/WorkspaceActivitySidebar.swift`
- Modify: `Sources/HermesAgentDock/SessionInspectorView.swift` if it owns an inbox subsection.
- Reuse: existing `AttentionItem`, `AttentionAction`, and confirmed mutation callbacks in `ControlCenterModel`.

**Steps:**
1. Render grouped sections: Requires Decision, Blocked/Failed, Waiting, History.
2. Include source chip (session, Kanban, cron, reminder) and time.
3. Show only actions Hermes already exposes; retain confirmations for consequential actions.
4. Add “Open source” navigation and safe snooze/dismiss where the underlying action exists.
5. Never show raw command/tool output in a macOS notification preview.

**Acceptance:** AC-04, AC-07.

---

### Task P3.3: Implement a notification policy, not broad notifications

**Files:**
- Read/modify only after inspecting ownership: `Sources/HermesAgentDock/HermesAgentDockDelegate.swift`, `Sources/HermesAgentDock/DockNotification*` code.
- Create: `Sources/HermesAgentDock/ControlTowerNotificationPolicy.swift`
- Test: `Tests/HermesAgentDockTests/ControlTowerNotificationPolicyTests.swift`

**Policy:** notify on a newly observed approval, clarification, failure/blocker, terminal background result, cron failure, MCP health degradation, or quota threshold crossing. De-duplicate by stable item ID + terminal state. Notifications must include no prompt, output, secret, raw command, repository contents, or provider token values.

**Tests:**
- Duplicate event is suppressed.
- State transition to failure notifies once.
- Notification payload contains only generic title/body and Dock reference.
- An unavailable capability cannot trigger a false health notification.

**Acceptance:** AC-04, AC-07.

---

# Phase P4 — Verification Evidence and repository freshness

### Task P4.1: Add a pure delivery-evidence snapshot

**Files:**
- Create: `Sources/HermesAgentDock/VerificationEvidencePresentation.swift`
- Modify: `Sources/HermesAgentDock/CommandCenterModels.swift` only to expose existing inputs.
- Test: `Tests/HermesAgentDockTests/VerificationEvidencePresentationTests.swift`

**Inputs:** existing `VerificationSummary`, repository fingerprint/baseline state from `DeveloperWorkflowModel`, open attention failures, and bounded current diff metadata.

**Outputs:** explicit `blocked`, `stale`, `partial`, `targetedOnly`, `current`, or `unavailable` evidence state plus user-readable next action.

**Tests:**
- Passed targeted evidence is not presented as repository-ready.
- Any fingerprint mismatch marks evidence stale.
- Failed verification blocks readiness.
- Missing evidence is unavailable, not passed.

**Acceptance:** AC-05.

---

### Task P4.2: Add the Verification Evidence panel

**Files:**
- Modify: `Sources/HermesAgentDock/WorkspaceActivitySidebar.swift` (`verificationContent`)
- Modify: `Sources/HermesAgentDock/SessionInspectorView.swift` only if it has a verification tab.

**UI requirements:**
- Current evidence scope and timestamp.
- Current repository fingerprint/baseline freshness.
- Passed/failed/unavailable checks from existing projections.
- Exact navigation to Change Review and relevant session/activity; no claim that a local panel ran a check.
- Accessible summary with a single clear readiness outcome.

**Manual verification:** dirty repository, clean repository, targeted-only result, failure result, unavailable result, and session switch.

---

# Phase P5 — Automation Health

### Task P5.1: Build automation health classifiers

**Files:**
- Create: `Sources/HermesAgentDock/AutomationHealthPresentation.swift`
- Modify: `Sources/HermesAgentDock/ControlModels.swift` only for existing parsed fields.
- Test: `Tests/HermesAgentDockTests/AutomationHealthPresentationTests.swift`

**Classification contract:**
- `healthy`: observed last run succeeded and next schedule is valid/known.
- `degraded`: latest observed run failed or MCP error observed.
- `unknown`: runtime does not provide enough data.
- `unavailable`: capability not available.

**Tests:** cron history with success/failure, missing timestamps, unknown schedule, MCP unavailable; never infer health from absence of an error.

---

### Task P5.2: Add Automation Health summary and detail links

**Files:**
- Modify: `Sources/HermesAgentDock/WorkspaceActivitySidebar.swift` (`automationsContent`)
- Modify: `Sources/HermesAgentDock/ControlCenterModel.swift` only if a currently supported refresh is not exposed to the visible view.

**Rules:**
- Reuse existing cron/MCP refresh paths and existing user-confirmed mutation actions.
- Do not poll hidden tabs.
- Show recent run status, failure streak only if calculated from bounded known history, next run if Hermes supplies it, source session when supplied, and “open latest report.”

**Acceptance:** AC-03, AC-06, AC-07.

---

# Phase P6 — Agent Operations Radar and Flight Recorder

### Task P6.1: Build a pure operations-radar snapshot

**Files:**
- Create: `Sources/HermesAgentDock/AgentOperationsPresentation.swift`
- Modify: `Sources/HermesAgentDock/AgentActivityPresentation.swift` only if a reusable observed-state helper is missing.
- Test: `Tests/HermesAgentDockTests/AgentOperationsPresentationTests.swift`

**Data inputs:** existing `HermesSubagent`, `AgentSummary`, `ProcessSummary`, `AgentActivity`, `ActiveToolCall`, session Kanban status.

**Rules:**
- “Running” only when the observed current state is active.
- “Stalled” requires an observed heartbeat/timestamp older than a documented threshold *and* active status; without a timestamp display `unknown`, not stalled.
- Provider/model display must be `unverified` unless runtime telemetry gives actual values.
- Parent/child/session links are optional and must not be guessed.

**Tests:** terminal status supersedes old start event; stale heartbeat gives stalled only with evidence; completed agent does not animate; missing model remains unverified.

---

### Task P6.2: Add Agent Operations Radar UI

**Files:**
- Create: `Sources/HermesAgentDock/AgentOperationsRadarView.swift`
- Modify: `Sources/HermesAgentDock/WorkspaceActivitySidebar.swift`
- Optionally compose existing: `Sources/HermesAgentDock/AgentMapView.swift`, `Sources/HermesAgentDock/RunningAgentPulse.swift`

**UI requirements:**
- Filter by focused session/global workspace.
- Present current task, observed state, duration, latest activity, source session, and dependency/board link only when available.
- Use reduced-motion safe indicators; `RunningAgentPulse` must not be the only status signal.
- A click navigates to the existing session/activity/board view; it does not mutate worker execution.

---

### Task P6.3: Build Flight Recorder presentation and UI

**Files:**
- Create: `Sources/HermesAgentDock/SessionFlightRecorderPresentation.swift`
- Create: `Sources/HermesAgentDock/SessionFlightRecorderView.swift`
- Test: `Tests/HermesAgentDockTests/SessionFlightRecorderPresentationTests.swift`
- Modify: `Sources/HermesAgentDock/SessionInspectorView.swift`

**Rules:**
- Use `AgentActivityPresentation.pipeline` as the canonical raw projection.
- Group contiguous low-level tool events into bounded milestones; do not retain/display unbounded raw output.
- Preserve timestamp, source, status, and session linkage.
- Redact sensitive-looking values using existing redaction utilities or a dedicated bounded presentation helper; do not log raw data to defaults.

**Tests:** chronological ordering, grouping stability, output bounds, session filtering, terminal state override, and redaction.

---

# Phase P7 — Provenance and Capacity Runway

### Task P7.1: Build a reusable provenance model

**Files:**
- Create: `Sources/HermesAgentDock/ProvenancePresentation.swift`
- Test: `Tests/HermesAgentDockTests/ProvenancePresentationTests.swift`
- Modify: `Sources/HermesAgentDock/ControlModels.swift` only for genuinely existing source IDs.

**Provenance fields:** source type, Hermes session ID, project/repository context, board/task ID, timestamp, observed model/provider, capability/data-state. Each field is optional and must render `Unavailable`/`Unverified` rather than a placeholder fact.

**Tests:** no session leakage, missing provider remains unverified, no raw token/prompt content, stable deep-link references.

---

### Task P7.2: Add an inspector sheet

**Files:**
- Create: `Sources/HermesAgentDock/ProvenanceInspectorView.swift`
- Modify: `Sources/HermesAgentDock/WorkspaceActivitySidebar.swift`
- Modify: relevant card views only after P1–P5 establish common callback conventions.

**UI requirements:** a read-only sheet/popover with source, session, repository, capability, and observed runtime details; copy only non-sensitive IDs if already visible; navigation links to existing Dock views.

---

### Task P7.3: Add quota runway visualization from existing data

**Files:**
- Modify: `Sources/HermesAgentDock/QuotaForecasting.swift`
- Modify: existing quota view in `Sources/HermesAgentDock/WorkspaceActivitySidebar.swift`
- Test: `Tests/HermesAgentDockTests/QuotaForecastingTests.swift`

**Rules:**
- Reuse `limitForecast`, `dailyAllowance`, and `expectedRemainingMarker`.
- Label all estimates as estimates, not actual token/cost forecasting.
- Only display warnings if reported balance/reset times support the calculation.
- Do not implement provider switching/routing controls in Dock.

**Tests:** reset-before-forecast yields no exhaustion prediction; missing/invalid window remains unavailable; threshold crossings are stable; no provider credentials appear in UI data.

---

# Phase P8 — Cross-surface integration and final gates

### Task P8.1: Add navigation/deep-link contract tests

**Files:**
- Modify: `Sources/HermesAgentDock/CommandCenterModels.swift`
- Test: `Tests/HermesAgentDockTests/CommandCenterModelsTests.swift`

**Tests:** every Mission/Inbox/Radar/Automation action maps to an existing `ControlTab` or existing safe callback; unavailable source disables navigation with explanation; no action invokes a mutation without confirmation.

---

### Task P8.2: Run accessibility, motion, and refresh lifecycle QA

**Files:** no new production file by default.

**Manual checklist:**
1. VoiceOver announces every status state and navigation control.
2. Keyboard focus reaches all actionable controls in logical order.
3. Reduced Motion does not rely on pulse animation for meaning.
4. Switch Activity/Session/Inbox/Automations tabs while requests are in flight; only the visible projection refreshes.
5. Switch sessions rapidly; old session data never appears after a newer focus.
6. Network/CLI/RPC failure retains cached state as stale and shows the error without an infinite spinner.
7. Empty and unavailable are visually/textually distinct.
8. Notification payloads contain no command, prompt, tool output, key, token, repository content, or private file path.

---

### Task P8.3: Freeze, review, and verify the exact final state

**Files:** all changed files; no scope expansion.

**Commands:**
```bash
git status --short --branch
git diff --check
swift build
swift test
```

**Expected outcomes:**
- `swift build` succeeds.
- `swift test` succeeds, or any failure is classified with proof as baseline/environment/provider-related and not represented as a pass.
- A fresh read-only reviewer checks the final exact diff against AC-01 through AC-08.
- Trigger a security review if notifications, persistence, redaction, credentials, or external transport surfaces changed.

**Delivery gate:** no commit/push/PR unless separately authorized. If authorized later, create/update a PR only after final gates pass on the frozen exact diff.

---

# Low-model execution instructions

For every packet, the low-capability implementer must:

1. Read only the specified files and current focused test before editing.
2. Confirm the feature branch/worktree and preserve unrelated changes.
3. Write the named failing test first; record the actual failure.
4. Make the smallest production change that makes that one test pass.
5. Run the focused test, then `swift build` when a shared model/view changes.
6. Return `NEEDS_ASSISTANCE` for missing Hermes telemetry, unclear parser contracts, conflicts, or an unavailable capability—never infer data or extend Hermes upstream.
7. Stop after the owned packet; do not start a later phase or adjacent cleanup.
8. Hand off: changed paths, exact test/build output, data assumptions, capability gaps, and any UI state not manually validated.

## Review checkpoints

- **After P0:** plan/contract review before implementation waves.
- **After P1–P5:** independent code review on each frozen wave; do not integrate UI composition until model tests pass.
- **After P6/P7:** privacy and stale-data review, especially redaction, session isolation, and unverified telemetry.
- **After P8:** final integration review on the exact frozen diff.

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Hermes does not expose a requested field | Render unavailable/unknown; do not synthesize it or modify upstream. |
| Late async response crosses a session switch | Model-owned task cancellation plus session/generation checks at publication. |
| Hidden views poll unnecessarily | Centralize polling in `ControlCenterModel` and key it to visible demand. |
| UI becomes a second control plane | Keep new panels read-only and link to existing confirmed actions. |
| Sensitive content leaks through timelines/notifications | Bound previews, redact, avoid persistence, and use generic notification text. |
| Existing dirty work contaminates validation | Isolated clean worktree; record baseline failures rather than fixing unrelated work. |
| Large SwiftUI files become more fragile | Prefer new focused component files and pure presentation builders; keep `WorkspaceActivitySidebar.swift` composition-only. |

## Open questions to resolve during P0 (before their dependent phase)

1. Which telemetry fields are genuinely emitted for agent heartbeats, provider/model placement, task dependencies, and MCP health?
2. Does the Dock already have a safe notification authorization/persistence boundary, and what deep-link format is supported?
3. Which current tabs remain mounted when hidden, and where is visibility ownership best expressed?
4. What is the designated clean base branch for this repository, given the current dirty `main` worktree?
5. Should the first delivery include all roadmap phases, or should P1–P5 ship as a separately reviewed control-tower MVP?

**Recommended delivery slicing:** Ship P1–P5 first (Plan Artifacts, Mission Control, Inbox, Verification, Automation Health). Only begin P6–P8 after real runtime telemetry confirms the requested agent/provenance data can be represented truthfully.
