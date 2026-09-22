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

### Global Hermes themes

The Dock has one global theme preference stored under
`hermes.dock.theme.v1`. Native macOS is the default and follows the system
Light/Dark setting. Hermes palettes map stable skin IDs (`default`, `ares`,
`mono`, `slate`, `daylight`, `warm-lightmode`, `poseidon`, `sisyphus`, and
`charizard`) to semantic Dock roles. Daylight and Warm Light force light
appearance; the other Hermes palettes use dark appearance. Theme selection is
Dock-owned presentation state and never invokes Hermes skin commands or changes
Hermes configuration.

Theme palettes resolve canvas, layered surfaces, text, selection, controls,
dividers, accents, success, warning, destructive, and message fills. Every
Dock surface consumes these semantic tokens: navigation, workspace,
conversations, composer, inspectors, repository tools, settings, popovers,
menus, sheets, and confirmations. Unknown local or hub skins remain visible as
read-only inventory and are disabled until an explicit Dock palette mapping
exists.

Settings presents Dock palettes and Hermes skin status as one Skins gallery.
Each mapped skin appears once as its corresponding Dock skin, with a checkmark
for the selected Dock skin and a separate Hermes-active label when Hermes
reports that skin as active. Native macOS is the Dock default and has no Hermes
skin status. Selecting a tile changes Dock presentation only; it never invokes
Hermes skin commands. Unmapped skins appear in a compact unavailable list, and
installed companions remain in their own read-only section.

The Projects section uses one shared outline tree:
the section disclosure, label, count, and refresh action form a flat header;
each project row places disclosure and folder identity before its name, with
session count and new-chat action trailing. Sessions align under the project
name and use a title plus one compact relative-time/preview line. Show the ten
newest sessions by default, with an independent per-project expansion control
for the rest. Keep project and session rows cardless and preserve 44pt action
targets.

Session management follows a progressive action hierarchy: Pin is the only
direct session-management control and shares the profile-scoped pinned store
with the Pinned section. Rename, Hide/Show, and Delete live in the row’s More
menu and native context menu. Rename edits inline; visibility and deletion
remain Hermes-authoritative mutations, with a shared confirmation/error
surface. Runtime controls (steer, branch, compress, interrupt, and model
changes) stay with the active-session workspace rather than navigation.

Conversations uses the same outline language as Projects: one collapsible
header with count and refresh, ten newest sessions by default, and independent
Show more/Show recent expansion. Each session is a 50pt two-line row. The
second line may combine relative time, an inline repository identity, and a
single-line preview; missing values do not leave separators behind. Repository
identity is inline metadata rather than a capsule so the list remains calm at
narrow sidebar widths. The Pinned section remains a separate presentation.

Pinned is a saved-conversation outline with 8pt inner margins and a comfortable
72pt row. Title, project context, timestamp, and preview occupy separate visual
levels: project context uses a quiet folder icon, timestamps align
independently, and dot-separated metadata strings are avoided. Unpin remains a
direct trailing action while less frequent session actions stay in More. In the
Projects tree, the selected session owns the only selected fill; its parent
project remains neutral and uses only an accent folder to show containment.
Session selection is profile-scoped and owned by navigation state, so refreshes
may update projections but never clear a still-valid selection. Only explicit
navigation or authoritative removal can clear it.

### Settings workspace

Settings is a responsive, cardless workspace rather than one long accordion.
It keeps six stable categories in this order: General, Runtime, Integrations,
Session, Project, and Diagnostics. General is selected when the surface is
mounted; selection is local presentation state and is not persisted. At 760pt
and wider, a 208pt category rail scrolls independently from the detail page;
narrow layouts use a full-width category menu below the Settings header.

Each detail page begins directly with real content—there is no repeated
category detail header. Use a leading-aligned column (maximum 920pt), 48–56pt
preference rows, 12pt semibold section labels, and one subtle divider between
groups. Purpose-built sections, preference rows, status rows, action rows,
inventory lists, and inline notices keep the surface cardless and calm. Global
theme-resolved `dock*` tokens apply everywhere. Loading, unavailable, and empty
states stay inside their category without moving the header or removing
navigation. Badges are reserved for actionable state: an update dot on
General, setup-needed count on Integrations, and open-attention count on
Session. Long inventories may retain local disclosure, while disruptive
session actions keep their existing confirmations.

### Quota workspace

Quota is a centered, cardless operational ledger. The page starts with one
toolbar containing a compact connected/attention/available sentence, last
updated time, and refresh control. Connected providers are sorted by worst
health first and show all quota windows inline; window rows preserve remaining
capacity, daily-budget markers, forecasts, limits, and reset times. Disconnected
providers appear afterward in a compact Available providers section with
Connect and website actions. Healthy, warning, critical, and unknown states use
their semantic colors; missing numeric data is never rendered as a fabricated
meter or percentage. The existing provider-order preference is retained for
compatibility but does not control this presentation.

The fullscreen Automation destination is a full-height operations index rather
than a dashboard. A quiet table is the primary surface: status, automation
name/request, cadence, next run, latest result, delivery, and progressive
actions. It preserves Hermes order, uses hairline dividers, and replaces vague
repeated UNKNOWN labels with Paused, No run yet, Succeeded, or Failed. Run now
is direct; Edit and Remove live in More and the native context menu.

Selecting a row opens a contextual inspector at wide widths and the same native
sheet at narrow widths. The inspector has Overview and Runs tabs. Overview
contains the complete schedule, request, delivery, identifiers, latest result,
and report action; Runs defaults to the selected job and can switch to the
authoritative All runs scope. Empty, stale, loading, and unavailable states stay
inside stable table or inspector regions. New automation uses a focused native
sheet, and no pause/resume control is shown without an authoritative Hermes
mutation path.

The session inspector uses one compact text switcher for Explorer, Terminal,
Activity, and Changes. All four share the canvas, 12pt typography, and 12pt
side insets. Explorer starts with the repository and filter, without a repeated
page label. Secondary tree actions live in its options menu. Changes prioritizes
branch and staged/unstaged files; GitHub account and PR management remain in the
full repository workspace. Missing projects use a compact top-aligned message.

Activity starts with a fixed refresh toolbar, followed by actual current work,
agents when present, and recent events. It has no summary dashboard or empty
agent/work sections. Agent scope and map selection live in a secondary menu.
The canonical session-attributed work and newest-first timeline retain their
stable IDs, disclosures, durations, results, and bounded pagination. One empty
state appears when there is no activity; refresh errors remain actionable.

The fullscreen Kanban page uses a compact native board. Its header subtitle
names the selected board and reports filtered results as “shown of total”. A
single persistent toolbar keeps board selection, Status, Assignee, Mine, Sort,
active-filter count/Clear, and Add Task available in loaded, loading, and empty
states; filter visibility is not gated by an optional capability when the
board adapter can apply the filters. Updated, Created, Priority, and Title
sorts are readable labels backed by stable adapter ordering.

Kanban lanes are flat columns in canonical order. Non-empty lanes use a compact
working width; empty lanes collapse to a discoverable icon/name/count rail and
expand locally on selection or automatically when work arrives. Cards prioritize
title, priority/assignee, model metadata, summary/current step, and relative
activity. Selecting a card opens the existing detail inspector. Details, Done,
Block, Unblock, and Archive are progressive actions in More and the native
context menu, appearing on hover, keyboard focus, or selection rather than as
permanent chips. Health diagnostics stay behind a compact disclosure above the
board. The board and its toolbar remain presentation-only and do not add Hermes
data contracts.

Kanban cards are essential-compact: priority and assignee, a two-line title,
one summary line, and relative activity with a subdued task ID. Provider/model
and execution diagnostics belong in the task inspector, not on every card.
Empty lanes collapse to horizontal icon/name/count rails; rotated lane labels
are not used. Selecting a card immediately opens a fallback-first inspector so
the authoritative board summary remains visible while Hermes enriches it. The
inspector is a flat contextual surface with Overview and Activity tabs for task
content, metadata, attachments, current state, and run history.

The Bots destination uses a responsive adaptive grid for profiles and a compact
schedule list for routines. The grid uses one column below 600pt, two columns
from 600pt, and three columns from 900pt, with flexible cards filling the
workspace width. Cards keep identity and live presence first, a bounded
latest-activity preview second, and relative activity time plus provider/model
metadata at the footer. Tabs, search, activity, and visibility filters share a
responsive toolbar that wraps at narrower widths. The full card opens the
canonical Bot Chat; profile editing, duplication, activity history, and
hide/unhide remain in More and the native context menu. Focus and hover use one
quiet surface treatment, and the 44pt More target does not change card layout.
Routines retain their own focused list with assigned Bot names, schedules,
disabled state, and confirmed removal. This page uses the global Dock tokens and
is independent of the sidebar brand-concept preference. Groups, sections,
profile deletion, cross-machine routing, and richer routine actions require
additional Hermes gateway contracts and are not presented as available Dock
controls yet.

The conversation workspace uses a stable cool-navy canvas in both fullscreen
and compact layouts, independent of the sidebar concept selector. Its header
is a single flat row.
The session identity gets the flexible header width and may wrap to two lines.
A view menu replaces the fixed destination icon strip. Voice is directly
available from 520pt chat width; the inspector toggle remains direct from
340pt and moves into the view menu below that. All destinations remain available
at every width. Controls retain 44pt targets and resizing does not animate.
Assistant responses are open document content; user prompts use restrained
right-aligned navy bubbles; and completed assistant
responses keep a compact action rail permanently visible beneath the content.
The rail uses tightly grouped 28pt controls, a subtle divider, and subdued
monospaced metadata. Hover and keyboard focus strengthen the control surface but
never reveal or hide actions. The composer is one centered floating surface with
the editor, attachments, model, reasoning, and send controls kept together.
It is aligned to the reading column, stays at a compact two-row idle height,
and grows only for multiline drafts, attachments, suggestions, or actionable
errors. Attach is icon-only; model and reasoning context remain available at
normal widths, while the send/steer action retains the strongest emphasis.
Streaming, approvals, clarifications, voice state, and errors may use semantic
surfaces when they represent an active decision or recovery path.

Explorer is a dedicated, cardless source workspace. Its navigator starts at
280pt and remains between 220pt and 360pt, leaving the remaining width to the
selected file editor. The navigator uses a flat repository header, compact
30pt tree rows, neutral file icons, and one quiet selected-row fill. Top-level
folders are collapsed initially; filtering reveals matching ancestors without
discarding the user's disclosure state. Generated and dependency trees are
hidden by default, while `.git` remains excluded for safety. Compact layouts
drill into the editor and provide a 44pt Back action. The workspace continues
to use the global cool-navy Dock tokens and does not inherit sidebar brand
concept colors.

The fullscreen Artifacts destination is a two-pane output browser. Its fixed
header and toolbar keep search, type scope, counts, and refresh visible while a
lazy newest-first results list drives a selected detail pane. Images use an
aspect-fit preview; files and links use semantic previews with selectable
paths or URLs. Open, Copy, optional Reveal in Finder, and source-session
navigation are the only artifact actions. The compact conversation inspector
retains its existing grid/list and pagination presentation.

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
- Inputs and compact controls use an 8pt corner radius and the shared `.dockGlass` text-field style. Native `.roundedBorder` fields are not permitted because their appearance can introduce a warm/brown fill inconsistent with the Dock palette. Use `Color.dockControlSurface` for custom controls and keep all surfaces in the cool navy glass hierarchy.
- The menubar popover and embedded views share the same surface hierarchy; an
  embedded view must not introduce a second black window inside its parent.

### Typography

- Use the system font for primary labels and body text.
- Use monospaced system type for IDs, timestamps, command-like values, status
  labels, logs, and concise operational metadata.
- Standard body and metadata text: 12pt or larger.
- Section labels: uppercase, semibold monospaced, with restrained tracking.
- Page headers use 16pt semibold. Compact empty states use a 12pt semibold
  title and 12pt detail text; they are not secondary page headers.
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

### Layout stability

- Do not insert or remove transient loading, retry, or projection-status rows
  above a page header or primary content. When that row disappears, the entire
  page jumps and disrupts the user's visual position.
- Put short transient status into a footprint that already exists: a page-header
  subtitle, a fixed status slot, or an in-place control spinner. Longer errors
  belong inside the affected section with stable placement; they must not
  reflow unrelated content.

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

### Terminal and external workflow states

- Session Terminal is an interactive local PTY with a native SwiftTerm canvas.
  Typing occurs at the shell cursor; there is no separate command field.
  It starts in the session project or the user's home directory without
  requiring verification recipes. Tabs and directory context remain visible;
  the terminal owns selection, scrollback, completion, and keyboard history.
  Its grid resizes with the panel. Clear, interrupt, and
  restart live in its options menu. Failed and closed shells offer recovery.
  User-entered commands never create verification evidence.
- Verification recipes are presented only when repository facts produce an
  allow-listed command. A missing project root or unsupported command is shown
  as unavailable and cannot be executed.
- Change Review is genuinely read-only: it renders repository-relative paths and
  bounded diffs only. File editing and save callbacks belong exclusively to the
  explicit Project Files editing surface.
- GitHub is a read-mostly projection in the repository Changes context. Show
  no remote, not loaded, unavailable, stale, and available states with text as
  well as color. A stale refresh retains the last successful PR rows and
  displays the local failure beside them.
- PR rows show a deep link and at most the first normalized blocking reason;
  provider payloads, credentials, terminal output, and source diffs are never
  persisted as integration state.
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

### Runtime parity and control authority

- Hermes remains authoritative for the active model, reasoning settings, skills,
  plugins, MCP configuration, sessions, and agent execution. Core may render
  verified inventories and invoke only named, capability-gated controls.
- Session model/reasoning changes are explicit Hermes mutations. Disable them
  without an active session and while a prior change is pending; replace the
  displayed configuration only from Hermes' response.
- MCP reload is an explicit confirmed Hermes action when the installed runtime
  advertises it. It affects subsequent runtime work, not the active transcript;
  adding/removing/authenticating servers and third-party tool invocation remain
  unavailable without upstream typed contracts.
- Skills and plugins are inventory/readiness surfaces only in the current Dock.
  Installation, enablement, disablement, removal, and configuration are
  unavailable until Hermes supplies a verified contract. Do not imply that a
  displayed inventory grants mutation authority.
- `hermes update` is explicit and confirmed. It streams progress, never starts
  automatically, and requires a Hermes restart before new sessions use the
  updated agent. Recovery commands are copy-only unless a separately verified
  action is exposed.
- Any missing, malformed, denied, or unsupported capability is rendered as
  unavailable; a previous valid projection may instead remain visible with a
  stale marker. Never infer support from a Hermes version string alone.

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

### Office simulation and exterior

The 3D office projects canonical bot identities and Kanban activity. Each bot
starts at a distinct home position; shared leisure destinations are reserved
before travel. Refreshes and desk changes preserve walking continuity. Ambient
breaks do not claim task progress. Planning/review interactions require a shared
reported board and phase, and begin only after both participants arrive.

The exterior is a connected campus forecourt: stone promenade, timber pergola,
seating terrace, fountain court, planting beds, and bicycle parking. Outdoor
seats are reachable activities, while solid furniture and landscaping contribute
to the same obstacle map as the interior. Reuse cached geometry and materials;
static scenery does not introduce animation timers or additional dynamic lights.

### Side activity notch

The side notch is the primary launcher; the menu-bar item is temporarily hidden.
Idle is a quiet theme-colored 22 × 72pt silhouette with a 44pt-wide hit target and no
passive lifecycle label. Hover or new work morphs it into an attached activity
surface. The preview leads with the current session title, then current tool
activity or the latest response, with one Open session action. Running tools
and background-task changes update real progress text;
new responses, completions, and requests for attention expand automatically for
six seconds. Rapid tool chains are bounded to one automatic announcement every
four seconds. Indeterminate progress never implies a measured percentage.

The generated workstation-and-side-dock icon is shared by the notch and app
bundle. Circular indicators accompany meaningful work and updates, with semantic
colors and text; sparkles are not used as app identity. Compact, preview, and
workspace states share the selected theme’s canvas and
text colors, with a 1pt semantic border around the contour. The workspace
reserves a 12pt horizontal and 32pt vertical safe inset for the notch contour.
The entire workspace, including its header and bottom controls, fits inside this rectangle.
Native panel dimensions include these insets; responsive content dimensions
exclude them and clamp to the selected display.

Drag the notch along either side of any connected display. It snaps to the
nearest side and persists that side, display, and relative vertical position.
The native context menu also offers left/right placement and Quit. Screen
changes clamp the surface to an available display.

Click or double-tap Command expands the same native window into the workspace
at the notch's location. Closing, leaving the window with the pointer, or clicking outside returns
that window to the notch. There is one conversation host, retained across these transitions, and
hover never activates the app, mounts the conversation, or marks responses read.
The workspace and preview share the screen-attached contour.
Shortcut reveal coordinates a 460ms edge expansion with a restrained inward
spring slide and staged content fade. Collapse takes 260ms. Repeated toggles
cancel content animations, and focus is available immediately. Reduced Motion
makes geometry changes immediate and replaces the work animation with a static
symbol. Only bounded response excerpts and tool names appear in automatic
previews; full results and decisions remain in the workspace.

The expanded notch also offers a clickable Quota tab. It shares the existing
selection across collapse/reopen and remembers the chosen provider. Automatic
session announcements temporarily show activity without changing that selection.
Cached quota remains visible during refresh and after failed reads, with stale
status shown instead of clearing the last successful values. It shares the
ControlCenterModel provider inventory with the workspace, reads quota only on
explicit selection or refresh, and presents at most two windows for the chosen
provider. Bars show `100 - remainingPercent`; missing values stay unavailable.
Reset times and last-updated time remain visible. Leaving either preview or the expanded workspace collapses it after a 350–400ms
grace period; returning cancels dismissal. Attached sheets and popovers remain
usable, and fullscreen stays open. Quota menus can be used before collapse;
The preview has no close button, upward arrow, or duplicate icon rail; pointer
exit handles dismissal. Open Quota routes
to the full quota workspace in the same native window.

The quota preview fits two complete rows without an inner scroll view. Each
row places window name and used percentage on one line, a 4pt meter beneath,
and a short reset countdown below it. Last-updated text and Open Quota share
one compact footer. Full provider windows remain available in the workspace.

The minimized notch retains its slim 22 × 72pt contour in every activity state.
A subdued grip marks idle; an indeterminate accent travels vertically while
work runs, a small dot/check marks updates, and an exclamation mark signals
attention. Work and attention can coexist. Hover reveals the full text, and the
button accessibility label always names the status. Reduce Motion holds the
work marker still. These indicators replace the large compact icon rail.
