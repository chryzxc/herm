# Shared app colors

The approved reference colors are centralized in
`Sources/Herm/DesignSystem/DockAccentPalette.swift`. There are eleven families:
teal, amber, violet, coral, blue, orange, pink, green, cyan, indigo, and tangerine.
The six reference fills are teal `#50B8A6`, orange `#FA9D29`, indigo `#6957E8`,
violet `#8955F5`, blue `#387FF2`, and tangerine `#F97029`. Other families extend
that solid, saturated treatment. These are the approved visual match, not
claimed pixel samples from the original image.

## Which token to use

- Solid avatars, lifecycle dots, and data marks: `DockAccentColor.teal.fill`,
  `palette.fill(.teal)`, or `Color.dockSuccessFill`. Fills do not change between
  Light and Dark, across all skins.
- Text and small symbols: `DockAccentColor.teal.color`, `palette.color(.teal)`,
  or `Color.dockSuccess`. These preserve hue while adjusting for readable contrast.
- Interaction: `Color.dockAccent` and shared Dock button styles. This belongs
  to the skin, not the semantic palette. Clean and Glass are gray; Dusk uses
  lavender, Terminal green, Classic brass, and Warm Light brown. Other character
  skins keep their authored hue. Do not use semantic blue for generic controls.
- Selection: `palette.selectedFill` and shared selection components. Clean and
  Glass stay neutral; character skins keep their selection treatment.
- Content and surfaces: `dockPrimaryText`, `dockSecondaryText`, `dockCanvas`,
  and shared Dock surface components. Do not use accent colors for all prose.

Use green for success, orange for warnings, coral for errors/destruction, violet
for review outcomes, and teal for assignments. All agent identity surfaces use
the same stable ID mapping. Changing the shared configuration updates existing
consumers; new features inherit it through Dock components and tokens.

## Future feature enforcement

Run `make color-contract`. It scans Swift and web resources under `Sources/Herm`
for new literal hues, RGB constructors, and system accent shortcuts outside the
two central palette files. `make check` runs this in CI. The scanner's own tests
verify that new files and extra copies of old exceptions are rejected.

`Scripts/color-exceptions.json` counts existing source colors, legacy avatar
compatibility, and scene material definitions by exact source expression. Layout,
semicolons, and trailing commas may change without consuming another exception;
string contents and other tokens must match. Multiline colors are checked too.
It is not a whole-file exemption. Remove entries as legacy code goes away; do not regenerate
or increase counts just to pass a new feature. An intentional new external
identity/material exception requires a reviewable explanation in this document.
The check catches common syntax, not every possible way to construct a color;
code review must also enforce this rule.

## Surface audit

| Area | Standard |
| --- | --- |
| App menu and Dock tile | Shared destructive unread badge and skin-colored activity ring; redraw on theme changes |
| Appearance | Theme specimens use the same palette as their actual theme |
| Conversation | Actions, selected sessions, bubbles, Markdown links, handoff markers, and image preview chrome use shared roles |
| Bots | Live faces, fallback identities, activity marks, and chat handoff markers share the same families |
| Agents | Agent board and session activity use the same ID-to-color mapping |
| Control Center | Navigation, settings, activity lists, summaries, and pending controls use Dock roles |
| Activity | Work calendar, charts, meters, and Spend heatmap retain their shared semantic category colors |
| Calendar | Shared category colors; connected Mac calendar/list colors retain source identity |
| Automation | Schedule, outcomes, and pending/error feedback use shared semantic roles |
| Kanban | Lifecycle follows `DockStatusTone`; assignee initials use shared identity ink and a quiet tinted fill |
| GitHub, Issues, Pull Requests | Lifecycle, assignments, checks, review, changes, and actions use shared roles; provider labels retain source colors |
| Repository | Explorer icons and syntax highlighting use shared families; editor selection/caret and blame use Dock roles |
| Review | Diff additions/removals, annotations, and controls use semantic roles |
| Session workspace | Files, activity, browser annotation chrome, and terminal base/ANSI colors use shared roles |
| Generated UI | Host controls use Dock roles; generated documents receive all eleven solid `--herm-<family>` and readable `--herm-<family>-ink` CSS variables |
| Edge dock | Previews, quota, session/task marks, and interaction controls resolve shared roles |
| Office | Lifecycle signals, interaction beacons, and room-label accents share the palette; physical materials and daylight retain their scene colors |
| Quota | Meters, warnings, errors, and provider controls use semantic roles |
| Gateway | Connection/health and setup controls use semantic roles; authentication QR codes retain white backing for scanning |
| Settings, Configuration | Native controls inherit the shared root tint; preference switches explicitly use it |
| Extensions, Knowledge, Operations | Cards, availability, outcomes, and actions use shared roles |
| Plans, Projects, Profiles | Artifact, project, profile, model, and command controls use shared roles |
| Intelligence, Voice | Supporting text, pending feedback, and actions use shared roles |

## Deliberate source colors

Provider logos, uploaded art, GitHub labels, connected calendar colors, images,
and explicit RGB terminal output belong to their source. Masks, shadows,
material highlights, QR backing, and 3D furniture/daylight are not interface
accent palettes. Legacy bot renderers and unskinned bot exports retain their
old colors so previously saved avatars remain recognizable; live faces use
the current palette.

Contrast checks cover every family across all shipped themes and supported
appearances. Native palette fixtures can be exported with
`HERM_ACCENT_REVIEW_DIR=/tmp/herm-accent-review` when running
`DockThemeContrastTests`.

## Component semantics audit — 2026-10-22

The source pass covered all 37 directories under `Sources/Herm`, including
shared components and native/web hosts. The table above records the surface
rules; these corrections apply to existing components and their future callers:

- **Pull requests and Issues:** ordinary IDs and branch routes use neutral ink.
  PR lifecycle is green open, neutral draft, violet merged, red closed. Readiness
  has its own color: orange conflict, red failed check, pink changes requested,
  violet review required, blue actively running checks, neutral missing/no checks.
  A conflict no longer repaints the leading lifecycle mark. Issues use green open
  and violet closed. Assignments stay teal; provider labels keep source colors.
- **Repository and session files:** modified cyan, renamed violet, added green,
  deleted/conflicted red, staged selection skin-accented, unknown neutral. Local
  excerpt and result-comparison diffs now use the same green/red convention.
- **Calendar:** event blue, reminder amber, automation violet, task teal. These
  use `DockCategoryTone`, not warning tokens. Mac source colors remain intact.
- **Automation:** schedule identity violet; paused/disabled metadata neutral;
  overdue state keeps warnings. Success/failure outcomes remain separate.
- **Kanban:** the detail pane reuses the board's lane palette; triage and ordinary
  priority metadata are neutral. Actual high-priority/blocker indications remain
  actionable warnings, with review violet and queued work indigo.
- **Activity and Spend:** solid marks keep the approved palette; chart series
  retain their corresponding legend/category colors instead of using text ink.
- **Integrations and gateway:** available integration identity is cyan, distinct
  from connected/failed state; confirmed healthy gateway state is green.
- **Plans:** exhausted capacity uses the error role, matching quota exhaustion.
- **Other areas:** App, Appearance, Agents, Bots, Configuration, ControlCenter,
  Conversation, DesignSystem, EdgeDock, Features, GitHub, HermesRuntime,
  Intelligence, Intents, Knowledge, Markdown, Office, Operations, Profiles,
  Projects, Resources, Review, Settings, Voice, and Workspace retain their shared
  skin/identity/status roles. Errors, stale data, recovery and permission notices
  retain meaningful warning/error colors. Prose, page headings, settings,
  navigation, and controls do not acquire arbitrary category decoration.

New categories start in `DockCategoryTone`; new lifecycle semantics start in
`DockStatusTone` or the subsystem's tested presentation helper. Do not use blue
for ordinary metadata or orange for an unfinished/draft/paused state.
