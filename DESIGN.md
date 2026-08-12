# Hermes Agent Dock — Design Specification

## Purpose

Hermes Agent Dock is a native macOS menu-bar control surface for a local Hermes
Agent session. It is an operational workspace, not a decorative dashboard or a
second task manager. The interface must make live Hermes state easy to scan,
safe actions obvious, and missing capability honest.

This document is the source of truth for UI decisions. When implementing or
reviewing a view, prefer the rules here over generic macOS defaults or a visual
reference from another project.

## Product principles

1. Hermes owns operational data. The Dock renders canonical sessions, agents,
   tasks, tools, and runtime state; it only owns presentation state.
2. Scan first, inspect second. Dense lists show status and a short summary;
   full payloads are disclosed after explicit selection.
3. Show real state or an honest empty/unavailable state. Never use sample
   activity, invented counts, placeholder output, or guessed capability state.
4. Actions are narrow and visible. Mutating controls need a clear label,
   confirmation where appropriate, and an in-place pending state.
5. Compact does not mean tiny. The menu-bar surface keeps labels and metadata
   legible at a 12pt minimum.
6. Motion supports state change; it must never delay work or obscure a status.

## Visual language

The app uses a dark, precise sci-fi glass treatment. The intended feeling is a
calm operational instrument: low-noise, high-contrast, and technical without
being theatrical.

### Color tokens

Use the SwiftUI color names below rather than introducing ad hoc colors.
Definitions live in `Views.swift`.

| Token | Purpose |
| --- | --- |
| `scifiBg` | Main near-black background |
| `scifiSurface`, `scifiSurface2`, `scifiSurface4` | Layered translucent glass surfaces |
| `scifiFg` | Primary readable text |
| `scifiMuted`, `scifiTertiary` | Secondary metadata and inactive detail |
| `scifiBorder`, `scifiBorderLight`, `scifiBorderStrong` | Hairline boundaries and dividers |
| `scifiAccent` | Primary interactive emphasis and active work |
| `scifiSuccess` | Completed or healthy state |
| `scifiWarning` | Attention, blocked, destructive confirmation, or caution |
| `scifiDestructive` | Failure or destructive result |

The accent is cyan-blue. Status colors communicate state; they must not be
repurposed as identity colors. Avoid broad gradient fills. Ambient glow is
subtle and reserved for the app background, voice orb, or focused state.

### Surfaces and borders

- Use `scifiGlassPane()` for a focused interactive unit of work.
- Use `scifiListRow()` for dense operational rows. Prefer divider-led lists to
  a grid of unrelated cards.
- Glass surfaces use 0.5pt borders and modest opacity. Do not add thick colored
  borders or a left-accent stripe to ordinary cards.
- Inputs and compact controls use an 8pt corner radius. Larger panes use 14pt.
- The menubar popover and embedded views share the same surface hierarchy; an
  embedded view must not introduce a second black window inside its parent.

### Typography

- Use the system font for primary labels and body text.
- Use monospaced system type for IDs, timestamps, command-like values, status
  labels, logs, and concise operational metadata.
- Standard body and metadata text: 12pt or larger.
- Section labels: uppercase, semibold monospaced, with restrained tracking.
- Use sentence case for action labels; use uppercase only for compact status or
  section labels.
- Truncate only the compact summary. Expanded details must wrap or remain
  selectable when they contain useful Hermes output.

## Layout and information hierarchy

The Dock has two primary work areas:

| Area | Responsibility |
| --- | --- |
| Ask | Conversation, voice, attachments, active session, and immediate controls |
| Control | Today, Inbox, Kanban, and Activity are primary. Review, workspace, and tool views live in the grouped More menu. |

On narrow displays, switch between Ask and Control rather than compressing both
into an unreadable split pane. Never require horizontal scrolling for primary
content.

The Control navigation strip is ordered by daily decision frequency: Today,
Inbox, Kanban, then Activity. The More menu groups Changes and Verification
under Review; Projects and Repositories under Workspace; and Automations,
Search, and Core under Tools. Secondary views remain directly accessible from
the command palette. Keep the overflow trigger label stable so long view names
cannot resize or truncate the strip.

Within a control tab, use this hierarchy:

1. Section label and a compact count or live-state label.
2. Current status and actionable exceptions.
3. Dense list or projection rows.
4. On-demand detail, forms, and confirmations.

The most urgent or active information belongs near the top. Secondary
diagnostics, history, and setup guidance follow it.

## Component rules

### Buttons and inputs

- Use `.scifiPress` for compact controls and `.scifiPrimary` for the one primary
  action in a local section.
- Keep primary icon controls visually compact but give them a 44pt minimum hit
  target.
- Use `.scifiGlass` for text input. Disabled controls must remain legible and
  explain why they are unavailable through nearby text or capability guidance.
- An action that calls Hermes retains its footprint while pending. Use a spinner
  and pending label rather than replacing nearby content or allowing duplicate
  submission.

### Lists, statuses, and empty states

- Every row needs a stable semantic ID from Hermes or a locally owned
  presentation identity. Do not key state by a mutable title.
- Show status with both text and color. Color alone is insufficient.
- Empty states explain what Hermes must provide or what the user can do next.
- Refresh failures retain the last successful projection, mark it stale, and
  show the error locally to the affected section.

### Confirmations and mutations

- Confirm persistent or externally visible Hermes mutations before sending them.
- State exactly what the action affects; do not use vague labels such as
  “Continue.”
- In-turn steering is an exception: it is explicitly presented as an ephemeral
  correction and does not need a confirmation dialog.
- After a mutation, refresh or apply Hermes’ authoritative result. Do not
  optimistically fabricate a final state.

## Agent Board and activity disclosure

The Agent Board is a live operational projection of Hermes subagents, agent
events, and main-agent tool activity.

### Identity and status

- Give every displayed subagent a stable accent color derived from its stable
  agent ID. The color must survive reorder and status updates.
- Identity color differentiates agents only. Status color remains responsible
  for Pending, Running, Completed, Failed, Interrupted, and other lifecycle
  meaning.
- Render one row/card per Hermes worker for batch delegation. Do not merge
  workers just because their display names match.

### Disclosure behavior

- Agent cards and pipeline rows are collapsed by default.
- Selecting an agent expands the available live event history, grouped as
  Pending, Running, and Completed.
- Selecting an individual activity expands only that event’s available content:
  event text, tool name, handoff target, input, result, and diff preview.
- Diff previews never appear by default and never cause an activity to expand.
- Expanded content must come from the same canonical Hermes event payload as
  the compact row. Do not synthesize output, summaries, or metrics.
- The bounded activity window is retained locally per Hermes session so session
  switches and app relaunches preserve the agent graph and pipeline. It remains
  operational context rather than durable audit storage.

## Developer workflow surfaces

### Mission Control, changes, and verification

- Today answers needs-me, running-now, changed, and readiness using only live
  Hermes projections plus an explicitly attached local repository snapshot.
- A targeted verification result is never a ship-ready result. A clean tree and
  repository-wide passed evidence are required for a green readiness state.
- Change Review reads Git state only. It renders repository-relative paths and
  bounded diffs after explicit disclosure. Agent attribution requires an exact
  Hermes-reported written-file match; otherwise the change is unattributed.
- Repository watchlists and last-seen state may persist only stable references
  and presentation preferences, never prompts, diffs, tool output, or copied
  Hermes records.
- Repository-wide local review is bounded, added-line-only, and honest about
  partial coverage. A complete saved review baseline additionally requires all
  covered files to be explicitly marked reviewed. Partial coverage may be
  acknowledged after its covered files are reviewed, but remains partial and
  cannot become a green readiness signal. A baseline contains only stable repository
  identity, revision/fingerprint, time, and acknowledged finding IDs; it never
  stores source or diff content. Hermes review is a separate explicit no-edit
  background request.
- Repository watching is opt-in and passive. One managed service owns retained
  FSEvent registrations for every explicitly watched repository and debounces
  each repository independently. It may refresh local Git state,
  invalidate stale presentation, and suggest Hermes actions, but it never
  submits prompts, verification, or mutations automatically. System notices
  contain only a repository display name and aggregate count.
- Worktree fleet views are read-only local Git projections. Selecting a
  worktree changes only the Dock's session-to-repository presentation reference.

### Verification Center

- Consume `project.facts` and `verification.status` from Hermes; do not
  re-detect package managers or invent verification commands in the Dock.
- Show manifests, package managers, context filenames, and Hermes-provided
  verification commands as read-only facts.
- Copying a command is always available when a command exists.
- Running a verification command requires an explicit user action and is
  submitted through Hermes background execution with a no-file-edit request.
- Preserve Hermes evidence scope. `targeted` evidence must never be labelled
  as a repository-wide pass.
- Do not display prompt contents, credentials, raw environment data, or private
  filesystem details.

### Background tasks

- `DockModel` owns the in-memory background-task lifecycle.
- Register a task only after Hermes returns a valid `task_id`.
- Match `background.complete` by task ID and update the existing row.
- Background rows are collapsed by default and show prompt/output only after
  selection.
- Keep a bounded recent window; background tasks are not durable audit history.

### Session and runtime controls

- Control actions call named Hermes RPCs and use Hermes responses as truth.
- Rename and in-turn steering are direct actions; branch, compress, undo,
  global delegation pause, agent interrupt, and process stop require
  confirmation.
- Rejected text remains in its input field for retry.
- Never optimistically mark an agent interrupted or a process stopped before
  Hermes confirms the transition.
- Delegation pause is global and must be labelled as such.

## State ownership

- `HermesGateway` owns the authenticated loopback connection and raw RPC.
- `HermesControlRPC` owns named gateway method wrappers.
- `HermesCLIAdapter` owns allow-listed Hermes CLI command construction.
- `DockModel` owns the active conversation, event stream, subagents, tool
  calls, agent activity, and background tasks.
- `ControlCenterModel` owns read-only projections, refresh generations, stale
  state, and user-triggered control actions.
- `DeveloperWorkflowModel` owns the single active local repository projection,
  bounded review/baseline state, watch coordination, worktree inventory, and
  local notices. It does
  not own Hermes records or retain prompts, diffs, or Hermes output.
- SwiftUI views own only disclosure, selection, form, and confirmation state.
- `WorkspaceStore` persists local task/reference presentation metadata. It must
  not create a second Hermes gateway or execute background agents.

## Motion and accessibility

- Use the project’s `scifiEase` for short state transitions (roughly 0.16–0.22
  seconds). Pressed controls scale to 0.96.
- Respect `accessibilityReduceMotion`: disclosure and pressed-state changes
  become immediate; continuous decorative animation is disabled.
- Do not rely on hover, color, animation, or an icon alone to convey state.
- Use accessible labels that include control purpose and disclosure state, for
  example “Agent A, running. Click to expand activity.”
- Preserve keyboard focus through refreshes and disclosures where SwiftUI
  permits. Textual output that may be copied should use text selection.

## Implementation boundaries

- Keep shared styles in `ScifiComponentStyles.swift` and color tokens in
  `Views.swift`; do not duplicate control styling in every view.
- Views render typed models. Transport dictionaries, shell command assembly, and
  JSON parsing belong in transport/adapters/models, not in a SwiftUI body.
- A view may own local disclosure, selection, form, and confirmation state. It
  must not create another source of truth for Hermes data.
- Do not render private filesystem paths, credentials, raw environment data, or
  unredacted provider output.
- Context pressure is derived only from Hermes session context breakdown: below
  80% is normal, 80–89.99% is warning, and 90% or higher is critical. It guides
  handoff, branch, and confirmed compression; it is not verification evidence.

## Review checklist

Before considering a UI change complete, verify:

- The new state has a canonical owner and stable identity.
- The compact view is useful without expanding every row.
- Expanded content is real, bounded, and safe to render.
- Pending, error, unavailable, empty, and stale states are intentional.
- Controls meet hit-target, contrast, and reduced-motion rules.
- The README is updated when user-visible behavior changes.
