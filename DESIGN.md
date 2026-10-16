# Herm — Design Specification

This document is the source of truth for Herm UI behavior and styling. It has
five parts, and each has a different job:

1. **Purpose and principles:** why Herm looks and behaves the way it does.
2. **Design system:** the foundations (color, status, type, spacing,
   elevation, motion) and shared components that every surface is built from.
3. **Layout and interaction rules:** hierarchy, stability, states, and
   mutations. These apply to every surface.
4. **Surface specifications:** one section per surface, describing only what
   is specific to it.
5. **Engineering rules and review checklist.**

When a surface spec and the design system disagree, fix the spec. New surface
specs follow the template in Surface specifications.

## Purpose

Herm is a native macOS menu-bar control surface for a local Hermes
Agent session. It is an operational workspace, not a decorative dashboard or a
second task manager. The interface must make live Hermes state easy to scan,
safe actions obvious, and missing capability honest.

This document is the source of truth for UI decisions. When implementing or
reviewing a view, prefer the rules here over generic macOS defaults or a visual
reference from another project.

## Product principles

1. Hermes owns operational data. Herm renders canonical sessions, agents,
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

## Design system

Every Herm surface is assembled from the foundations and components in this
part. A surface spec may choose layout and content. It may not invent a new
color, type size, radius, status hue, or panel treatment. If a need is not
covered here, extend this part first, then use the new entry.

### Visual direction: the lamp-lit office

The 3D office sets Herm's identity. It is a calm workplace in open
countryside whose sky follows the local clock: blue days, amber dusks, starry
nights, warm lamps, and small signs that say who is doing what. The 2D chrome carries the same feeling:

- **Night canvas.** Surfaces sit on the theme's base canvas. Chrome stays flat
  and quiet so status light reads clearly.
- **Signage, not dashboards.** Raised content looks like the office's task
  bubbles: a small solid card, a 10pt radius, and a hairline border tinted by
  the status it reports. Name first, status second, one detail line. The full
  story is one click away.
- **Light means state.** Warmth and color come from status dots with a soft
  glow, like the office lamps and bot eyes. Decorative gradients, textures,
  illustrations, and ambient glows are not used in chrome.
- **One vocabulary.** A bot's eyes, its bubble border, a HUD chip, and a notch
  card for the same state all use the same hue and the same label.
- **Live but calm.** Live work breathes (a pulsing dot or a sweeping shimmer)
  and never shows a fabricated percentage. Settled states hold still.

### Color roles

Theme-resolved tokens live in `DockComponentStyles.swift`. They are backed by
`DockThemePalette` in `DockTheme.swift`. Views never use system label,
separator, or window colors, or ad hoc literals.

| Token | Role |
| --- | --- |
| `dockCanvas` | Base canvas for windows, the notch, and HUD panels |
| `dockSurface`, `dockSurface2` | Raised content, such as signage cards and inspector groups |
| `dockSurface4`, `dockControlSurface` | Controls, hovered cards, and segmented tracks |
| `dockPrimaryText` | Titles and body text |
| `dockMarkdownText` | Long-form Markdown reading text, slightly softened from primary chrome text |
| `dockSecondaryText`, `dockSectionText` | Supporting text and section labels |
| `dockMetadataText` | Timestamps, counts, and IDs |
| `dockBorderLight`, `dockBorder`, `dockBorderStrong` | Dividers, panel hairlines, and contours |
| `dockDiscord` | Appearance-aware Discord identity tint for the source pill and logo |
| `dockAccent`, `dockAccentMuted` | Interactive emphasis, the selected tab, and selected fills |
| `dockSuccess`, `dockWarning`, `dockDestructive` | Health and outcome of non-task state, such as quota, verification, and mutation results |
| `dockOnAccentText` | Text on a filled accent control |

The accent marks interaction. It does not mark task lifecycle, which uses the
status tones below.

### Status tones

`DockStatusTone` (`DockDesignSystem.swift`) is the only lifecycle palette for
work: sessions, bots, Kanban tasks, and background work. Office bubbles and
bot eyes always draw on dark sign ink and use `signageColor`. SwiftUI chrome
uses `color`, which switches to deeper variants in light appearances.

| Tone | Meaning | Office status | Motion |
| --- | --- | --- | --- |
| `attention` | Blocked or waiting on the user | Blocked | Fast pulse (0.7s) |
| `working` | Running now | Working | Pulse (1.1s) and shimmer |
| `review` | Waiting for review | Review | Still |
| `queued` | Ready but not started | Queued | Still |
| `complete` | Finished, or idle with nothing pending | Idle | Still |
| `inactive` | Status is not current (stale or offline) | Not current | Still |

- Always pair a tone with a text label. Color alone never carries state.
- Tone hues color the dot, the card border, the shimmer, and the short status
  label. Titles and detail text stay in text tokens.
- Stale or offline data keeps its last content but switches live tones to
  `inactive`, labelled "Status not current". A finished result stays
  `complete`.
- Per-agent identity colors are separate from status. They never replace a
  tone.

### Typography

System font for prose and labels. Monospaced for IDs, timestamps, durations,
command-like values, and section labels. Roles live in `DockTypography`.

| Role | Spec | Use |
| --- | --- | --- |
| `pageTitle` | 16pt semibold | Page headers only |
| Card / row title | 12pt semibold | Signage-card titles, compact empty-state titles |
| `body` | 12pt regular | Body text, empty-state detail |
| `control` | 12pt medium | Buttons, tabs, and footer actions |
| `metadata` | 11pt regular | Dense metadata beside an established 11pt component |
| Status label | 11pt semibold, tone hue | The short state on a card or pill |
| `machineMetadata` | 11pt monospaced | Relative time, durations, IDs |
| `metric` | 20pt semibold rounded, monospaced digits | Measured figures on monitoring surfaces, such as remaining quota |
| `sectionLabel` | 10pt semibold monospaced, uppercase, 0.6 tracking | Section labels via `DockSectionLabel` and `DockSectionHeader` |
| Navigation label | 13pt regular; semibold when selected | `DockNavRow` labels |
| Identity name / role | 13pt semibold / 11pt regular `metadataText` | Two-line identity in a header bar (Bot name over its role) |
| Count pill | 10pt semibold, monospaced digits | The count beside an uppercase section label |

- Body text and interactive labels are never smaller than 12pt. 11pt is only
  for metadata and status labels. 10pt is only for uppercase section labels
  and their count pills. Navigation labels use 13pt.
- Use sentence case for actions and uppercase only for section labels.
- Truncate only compact summaries. Expanded content wraps and stays selectable.

### Spacing, size, and shape

| Token | Value | Use |
| --- | --- | --- |
| `DockSpacing.micro` / `tight` | 4 / 6pt | Inside a card, and between dot and label |
| `DockSpacing.control` | 8pt | Between controls, and card padding (vertical) |
| `DockSpacing.group` | 12pt | Compact insets, between sections in a list |
| `DockSpacing.section` / `page` | 16 / 20pt | Page gutters |
| `DockControlMetrics.compactHeight` | 28pt | Icon controls, header-bar actions, and HUD chips |
| Inline header action | 24pt | `DockIconButton(size: 24)` inside a `DockSectionHeader` |
| Section header | 30pt | `DockSectionHeader` row height |
| Navigation row | 32pt | `DockNavRow` height; 18pt icon column, 10pt gap, 10pt horizontal padding |
| Header bar | 56pt | The identity-and-actions bar at the top of a pane; 8pt horizontal padding, 4pt between actions |
| `DockControlMetrics.standardHeight` | 36pt | Text controls and footers |
| `DockControlMetrics.hitTarget` | 44pt | Minimum hit target (`dockHitTarget()`) |
| `DockControlMetrics.cornerRadius` | 8pt | Inputs and compact controls |
| `DockControlMetrics.paneRadius` | 10pt | Signage cards and inspector groups |
| HUD radius | 12pt | Floating HUD panels only |
| Capsule | — | Status pills, chips, tab indicators |
| `DockLayout.hairline` | 0.5pt | Dividers and panel borders. Signage cards use 1pt (1.5pt emphasized) |

Shared controls and surfaces resolve their silhouette through
`DockThemeShape`. The default silhouette is the continuous rounded rectangle
defined by the radius tokens above. Custom themes may replace that silhouette
without changing layout or hit targets. Origami uses clipped opposing corners
on controls and panels, plus one quiet crease in the top trailing corner of
larger surfaces. Status pills and other semantic capsules remain capsules so
their meaning stays consistent across themes.

Themes also set `DockThemeStyle.material`, `selection`, `chrome`, and
`animates`. Glass uses blurred material panels with pill controls and a light
top edge. E-Ink inverts selected tabs and disables all animation. Swiss drops
card fills and strokes (`chrome: .open`), marks selection with a 2pt accent
underline, and uses a single-rule composer (`DockSkinPresentation.Composer.line`).

Clay molds controls with paired light and dark shadows (`emboss`) and round
corners. Pixel (`geometry: .pixel`) steps its corners, uses 3pt outlines and
hard shadows, and disables animation. Notebook (`.sketch`) draws slightly
uneven pencil outlines on ruled paper (`backdrop: .ruled`) with highlighter
selection. HUD (`.chamfered`) cuts opposing corners, adds corner brackets to
cards, draws a faint grid, and marks selection with a leading accent bar.

### Elevation

There are three levels. Do not add others.

1. **Canvas.** Flat. It holds divider-led lists and page content.
2. **Signage card.** A raised surface with a status-tinted hairline and no
   shadow. It is used for one unit of work in a list.
3. **HUD panel.** 92% canvas, a hairline border, a 12pt radius, and a soft
   shadow. It is used only for panels floating over the office scene. The
   notch's attached contour is its own shape and is not a HUD panel.

Borders are hairlines. Do not add thick colored borders, left-accent stripes,
or broad gradient fills to cards. The one permitted leading bar is the
selection indicator on a `DockNavRow` (see Interaction states); it marks
navigation selection, never status. An embedded view shares its parent's canvas
and must not introduce a second black window inside it.

### Motion

- Use `dockEase` for state transitions (0.16–0.22s). Pressed controls scale to
  0.96.
- Bubbles and cards appear with a short rise-and-fade (about 0.24s). A status
  or task change may pop once.
- Live loops are only the status pulse and the shimmer sweep (1.6s).
- Under Reduce Motion, every loop stops, disclosures are immediate, and
  geometry changes snap.

### Components

Use these before building anything new. They live in `DockDesignSystem.swift`
and `DockComponentStyles.swift`.

| Component | API | Use it for |
| --- | --- | --- |
| Page header | `DockPageHeader` | The one title row of a full workspace destination |
| Section label | `DockSectionLabel(title:count:)` | A static in-page label with no disclosure or actions |
| Section header | `DockSectionHeader(title:count:isExpanded:style:actions:)` | Any group label that has a count pill, a disclosure, or trailing actions |
| Navigation row | `DockNavRow(title:icon:isSelected:showsUpdateBadge:style:action:)` | One destination in a navigation list or page-local nav (tabs down a pane, settings categories) |
| Icon button | `DockIconButton(icon:label:isProminent:isBusy:size:style:action:)` | Icon-only actions in header bars (28pt) and section headers (24pt) |
| Copy button | `DockCopyButton(_:label:accessibilityLabel:presentation:iconSize:color:confirmationColor:)` | Copy actions that confirm in place with a temporary check; use icon, text, or icon-and-text presentation to preserve the surrounding control treatment |
| Status dot | `DockStatusDot(tone:size:pulses:)` | State beside a title; `pulses` only on live rows |
| Status pill | `DockStatusPill(tone:text:symbol:)` | A standalone state, such as an inspector status or an offline marker |
| Signage card | `.dockSignageCard(tone:emphasized:highlighted:)` | One unit of work in a list: a session, task, or bot |
| Shimmer track | `DockShimmerTrack(tone:)` | Indeterminate progress under a working card |
| HUD panel | `.dockHUDPanel()` | Panels floating over the office scene |
| List row | `.dockListRow(isHighlighted:)` | Dense divider-led operational rows |
| Inspector group | `.dockCard(padding:)` | Grouped detail inside an inspector |
| Buttons | `.dockPress`, `.dockSecondary`, `.dockPrimary`, `DockActionLabel` | Compact controls, the one primary action, pending state |
| Inputs | `.dockGlass`, `.dockSwitch`, `DockTabBar` / `DockTabButton` | Text fields, toggles, local scopes (never native `.segmented`) |

**Signage card anatomy.** Row 1 has the status dot, a one-line 12pt semibold
title, and trailing monospaced metadata such as relative time or "Current".
Row 2 is indented to the title and has the status label in the tone hue plus
` · ` and one detail line in secondary text. A working card adds a shimmer
track below. Padding is 10pt horizontal and 8pt vertical. The border is the
tone at 35% opacity. It rises to 90% for `attention` or an emphasized card,
and to 60% on hover. Hover raises the fill to `dockSurface4`. The whole card
is the button.

**Navigation row anatomy.** An 18pt icon column with a 15pt Lucide icon, a
10pt gap, the 13pt label, a flexible spacer, then at most one trailing
element: a count badge or an "Update"-style pill (10pt semibold, tone hue on
a 16% capsule of the same hue). Rows sit in a 2pt-spaced stack with an 8pt
radius. The whole row is the button.

**Section header anatomy.** The uppercase `sectionLabel` in `metadataText`,
an optional count pill (secondary text on a `surface4` capsule at 80%,
minimum 18×16pt), then, for a collapsible group, a 10pt chevron-right that
rotates 90° when expanded. Trailing actions are 24pt `DockIconButton`s; a
refresh action passes `isBusy` so its spinner replaces the icon in place. One
header style serves every group; do not mix title-case disclosure rows with
uppercase labels in the same pane.

**Page header anatomy.** Full workspace destinations start with a text title
and subtitle aligned to the page gutter, with actions on the right and a
hairline divider below. Do not add a decorative destination icon beside the
title. Use the shared `DockPageHeader` treatment.

**Header bar anatomy.** Identity on the left, actions on the right, a hairline
divider below. Identity is a 28pt avatar and a two-line stack (13pt
semibold name, 11pt role). When the identity can be switched, the block is a
button with a trailing chevrons-up-down icon and the standard hover fill; a
fixed identity shows neither. Actions are 28pt `DockIconButton`s: quiet ones
first, then at most one `isProminent` action (the pane's create action) last.

**Interaction states.** Every row, header, and icon button uses the same
four states:

| State | Treatment |
| --- | --- |
| Rest | No fill. Icon and label in `secondaryText`; section labels in `metadataText` |
| Hover | `surface4` at 60% (rows) or 70% (icon buttons); icon and label lift to `primaryText`; collapsible headers lift the label to `secondaryText` and the chevron to full opacity |
| Selected | Theme `selectedFill`, accent icon, semibold label, and a 3×14pt accent capsule on the leading edge |
| Busy | A mini `ProgressView` replaces the icon in the same frame; the control is disabled |

A prominent icon button sits on accent at 14% (24% on hover) with an accent
icon. Hover transitions use `dockEase(0.16)` and are disabled under Reduce
Motion. Hover is never the only way to find an action: trailing actions stay
visible at rest in their quiet color.

**Iconography.** Chrome uses only the vendored Lucide catalog
(`LucideIconName` and `LucideIcon` in `PullRequestCenter.swift`) at a 1.8pt
stroke. Sizes are fixed per slot: 15pt in a navigation row, half the frame
in an icon button (14pt in 28pt, 12pt in 24pt), 12pt for a switcher chevron,
and 10pt for a disclosure chevron. Views may pass SF Symbol-style names
through `LucideIconName.from(systemName:)`, but an unmapped name falls back
to a document icon. When a destination needs a new meaning (for example
Issues → `circleDot`), add the glyph and its mapping to the catalog rather
than reusing an unrelated icon.

**Empty state.** Use a 12pt semibold title and 12pt secondary detail,
top-leading, inside the same container the content would occupy. It says what
will appear or what to do next.

**Buttons and inputs.**

- Use `.dockPress` for compact controls, `.dockSecondary` for outlined actions,
  and `.dockPrimary` for the one primary action in a local section. Hosting roots
  default to `.dockHover` for unstyled actions; native bordered styles are not used.
- Action labels use `DockTypography.control` (12pt medium) and themed text. Primary
  actions use `dockPrimaryText` over the canvas (neutral glass in Glass) with a 14% accent tint,
  increasing to 24% on hover and 30% while pressed, with an accent contour.
  All shared action styles show hover/press feedback and suppress hover emphasis
  when disabled. Keep theme geometry, material, and reduced-motion behavior.
- Keep icon controls visually compact but give them a 44pt minimum hit target.
  The exception is `DockIconButton` inside a header bar or section header:
  its hit area is its 28pt or 24pt frame, and neighbouring actions keep at
  least 2pt between frames so pointer targets never overlap.
- Use `.dockGlass` for text input. Native `.roundedBorder` fields are not
  permitted, because their warm fill breaks the palette. Inputs and compact
  controls use an 8pt radius and `Color.dockControlSurface`.
- Disabled controls stay legible and explain why they are unavailable through
  nearby text or capability guidance.
- An action that calls Hermes keeps its footprint while pending. Use
  `DockActionLabel` rather than replacing nearby content or allowing duplicate
  submission.

### Tooltips

SwiftUI controls use the shared `.help` / `.dockHoverTip` renderer. After a
450ms hover, show one non-activating, mouse-transparent child panel above the
host content; never draw a tooltip inside a row or scroll container. Nested
controls show the smaller control's help. Empty help shows nothing. Use 12pt
control text, a fully opaque native window with a solid themed canvas, and a
hairline border. Wrap long text at 320pt with at most 12 lines. Prefer the
requested edge with a 6pt gap, flip
at the display edge, and try the other sides if clamping would cover the hovered
control. Keep a visible gap beside the control and stay inside the display bounds.
Dismiss on pointer exit, click, typing, scrolling, host movement/resizing/hiding,
or source removal.
Informational tooltip windows never prevent normal notch/workspace dismissal.

### Themes

**The skeleton is clean; skins dress it.** Layout and component structure are
the same under every skin and follow the Clean reference: a native unified
title row (52pt, traffic lights centered, sidebar header and centered chat
title in that row), sentence-case section labels with counts as plain gray
text, no pills or icons that only decorate, quiet gray "show more" links, no
divider under title rows, and accent color reserved for links, focus, and live
status. A skin may change color, shape, outline, shadow, texture, type design,
and selection treatment through `DockThemeStyle` and the palette; it may not
add, remove, or reorder structure. The **Clean** skin is that skeleton with no
dressing: borderless soft-gray cards on white, tinted sidebar, neutral user
bubbles.

**Skin identities.** Each skin has a short material signature in the gallery.
Glass is frosted crystal; System is native graphite; Clean is porcelain.
Classic Hermes pairs midnight ink with brass; Ares uses oxblood and bronze;
Monochrome is a graphite ledger; Cool Blue is a steel blueprint; Warm Light
is cream stationery. Cartoon uses inked stickers; Terminal uses phosphor
scanlines; Brutalist uses a dotted print grid; Origami uses folded ivory;
Dusk uses plum and lavender; Retro uses silver desktop bevels. E-Ink is
high-contrast print; Swiss is an open red-accent editorial layout; Clay is
soft terracotta; Pixel is an indigo arcade; Notebook is ruled cream paper;
HUD uses cyan crosshairs. These are centralized skin treatments, the
exception to the default flat chrome rules: patterns stay faint and static,
surface shadows stay local, and semantic status hues retain their meaning.

Navigation and tabs honor the skin's selection treatment (inverted ink,
underline, marker, bar, or tonal fill). Composers use the skin's panel radius,
outline and material details without changing their footprint. Patterned skins
use distinct static scanline, dot, rule, grid or crosshair backdrops; Clean,
System, Glass, E-Ink and Swiss keep their canvas clear. No decorative loops.

**Adding a theme (standard).** A theme is one `DockThemeID` case in
`DockTheme.swift`. The `title`, `detail`, `appearance`, `style`, `hermesSkinID`
and palette `roles` switches are exhaustive (no `default`), so the compiler
lists every place to fill in. Then:

1. Pick `appearance` honestly: `.system` only for themes with distinct light and
   dark palettes (`roles(_, dark:)`); native-material themes (System, Glass) must be `.system`.
2. Set `style.material = .glass` for Liquid Glass; `usesNativeMaterial` derives
   from it. Never special-case a theme id in views; add a `DockThemeStyle` knob.
3. Read colors only through `Color.dock*` tokens and `DockThemeStyle.current`.
4. Run `DockThemeContrastTests` (text/icon contrast) and
   `everyThemeSatisfiesTheThemeStandard`; both iterate `allCases`.
5. Switch to it from a light skin and from a dark skin without relaunching;
   window appearance is reset per window in `applyToApplication`.

Herm has one global theme preference stored under
`hermes.dock.theme.v1`. Glass is the default and follows the system
Light/Dark setting. It composites translucent graphite role colors over
AppKit's popover material and uses macOS label, accent, and status hues; the
other themes keep opaque authored canvases. Hermes palettes map stable skin IDs (`default`, `ares`,
`mono`, `slate`, `daylight`, `warm-lightmode`, `poseidon`, `sisyphus`, and
`charizard`) to semantic Herm roles. Daylight and Warm Light force light
appearance; the other Hermes palettes use dark appearance. Theme selection is
Herm-owned presentation state and never invokes Hermes skin commands or changes
Hermes configuration.

Skins own semantic component styling roles in `DockSkinPresentation`. Views
consume these roles rather than theme IDs. Skins must preserve the sidebar,
navigation destinations, control order, message alignment, and workspace layout.
**Retro** is a Herm-only skin with square gray panels and Win95-style bevels
(`bevel`): cards and buttons are raised with light top-left and dark
bottom-right edges, pressed buttons and text fields are sunken, selection is
inverted, and nothing animates.

New skins extend the centralized styling contract and reuse shared components
rather than forking feature views. Native text updates both fonts and colors
when the theme revision changes.

Theme palettes resolve canvas, layered surfaces, text, selection, controls,
dividers, accents, success, warning, destructive, and message fills. Every
Herm surface consumes these semantic tokens: navigation, workspace,
conversations, composer, inspectors, repository tools, settings, popovers,
menus, sheets, and confirmations. One shared theme store drives every window.
The selected theme also sets the application appearance (Light, Dark, or system
for System), so AppKit text, nested hosting views, menus, and sheets
resolve colors under the same theme. Every hosting root, including split-view
panes, applies the themed default text color and control tint. Views must not
use system label, separator, or window colors in themed surfaces, and content
that bakes colors into attributed text must re-render when the theme revision
changes, even if its text is unchanged. Unknown local or hub skins remain visible as
read-only inventory and are disabled until an explicit Herm palette mapping
exists.

## Layout and interaction rules

### Layout and information hierarchy

Herm has two primary work areas:

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

### Motion and accessibility

- Use `dockEase` for short state transitions (roughly 0.16–0.22
  seconds). Pressed controls scale to 0.96.
- Respect `accessibilityReduceMotion`: disclosure and pressed-state changes
  become immediate; continuous decorative animation is disabled.
- Do not rely on hover, color, animation, or an icon alone to convey state.
- Use accessible labels that include control purpose and disclosure state, for
  example “Agent A, running. Click to expand activity.”
- Preserve keyboard focus through refreshes and disclosures where SwiftUI
  permits. Textual output that may be copied should use text selection.

## Surface specifications

Each surface section states what is specific to that surface and builds on
the design system rather than restating it. New or rewritten sections follow
this template, using bold run-in labels:

- **Purpose:** the question the surface answers, in one or two sentences.
- **Structure:** layout from top to bottom, fixed slots, and sizes.
- **Content and states:** loaded, loading, empty, unavailable or offline, and
  stale.
- **Actions:** direct actions compared with those in More and the context
  menu, plus where each action routes.
- **Motion and accessibility:** only where the surface differs from the
  shared rules.

Older sections are migrated to the template when they are next changed.

### Side activity notch

**Hermes companion.** When the selected Hermes profile has an enabled pet, its
sprite sits outside and below the rail with a 4pt gap, in its own sized window.
The status marker stays inside the same 22 × 72pt contour; the 44pt hit target
still opens Herm. The pet has a separate minimum-44pt hit target: hover greets, click
plays a short petting reaction, and neither opens the notch or sends a message.
It remains below the expanded preview, never duplicated in its header. The
window reserves an extra 48pt for the companion; the contour and preview content
keep their original sizes. The pet follows work and approval poses, with a brief
error reaction; the notch remains the authoritative status display. Hover/click
reactions briefly override the live pose, then return to it. Successful work triggers a brief celebration
through the common notch announcement path. Quota announcements use review,
attention uses waiting, working uses run, and other updates use wave; failures
use failed. `HermesPetReaction` owns this mapping, with exhaustive cases and tests.
Unsupported poses fall back
to idle. Reactions use Hermes' spritesheet, not locally invented assets. This opt-in sprite is an
exception to the chrome illustration and motion rules; Reduce Motion uses a
static frame, and offline/stale sprites are dimmed and static. No passive
lifecycle label is added to the rail.

General → Appearance shows the searchable pet list directly, without a disclosure
button. Its fixed-height list keeps loading, unavailable and loaded states stable.
Installed pets load first; the remote catalog enriches that list. A bad community
label is skipped without discarding the catalog; remote failures retain local pets.
It also offers an enabled switch and
Hermes size slider. Changes are staged and confirmed with Apply to Hermes;
Hermes owns adoption, downloads, selection, and persistence for the selected
profile. The settings explain that changes also affect Desktop/TUI and that
the floating pet uses native frame dimensions multiplied by the saved scale,
clamped proportionally to fit its display. Its panel, home placement and roaming
bounds use that same size; the Settings thumbnail stays compact. Failed reads retain the previous
sprite with stale presentation and show recovery guidance in this settings
section. Generation, export, rename, and deletion are outside this UI.

Roaming is an opt-in Herm-only preference. A separate transparent, non-activating
A pet-sized window (minimum 44pt hit target) starts at the notch and strolls across the current display's
bottom edge with directional walking sprites, pauses, and returns home after
several strolls. Like Desktop, live activity pauses roaming to show its reaction.
Hover pauses movement; dragging repositions
within that display. The notch and pet context menus offer Call pet home. Moving
the notch or changing screens resets home; opening the workspace hides the pet
along with the notch. Reduce Motion, offline state, and stale assets keep it home.
Only the small pet window intercepts input; no screen-sized input overlay is used.

**Purpose.** The notch is the primary launcher; the menu-bar item is
temporarily hidden. At a glance it answers three questions: what is running,
what needs me, and what finished that I have not opened?

**Rail.** Idle is a quiet, theme-colored 22 × 72pt silhouette with a 44pt-wide
hit target and no passive lifecycle label. It keeps this contour in every
activity state. Settings → Appearance offers three persisted status displays:
Dots (default), Vertical line, and Ring, with working-animation previews.
Dots breathe during work; the line sweeps vertically and the ring rotates.
Settled states hold still. Attention and updates retain a separate dot above
ongoing work, so neither hides it. Idle is subdued, offline is hollow, updates
use the success tone, and attention pulses in the warning tone. Hover reveals
the full text, and the button's accessibility label always names the status.
Reduce Motion holds every work marker still. Changing style never changes the
rail geometry or its interactions.

The generated workstation-and-side-dock icon is shared by the notch and the app
bundle. Sparkles are not used as app identity. The compact, preview, and
workspace states share the theme's canvas and text colors, with a 1pt
`dockBorderStrong` border around the contour.

**Preview.** Hover or new work morphs the rail into an attached preview. It is
a fixed 368 × 360pt panel with stable inset content. The size never changes
with content, so arriving tasks and refreshes do not resize it. The preview
has three parts:

- A 40pt tab row with a Tasks / Quota segmented pill (selected segment on
  `surface`, track on `surface4`), and a trailing fixed slot.
- A scrolling body.
- A fixed footer holding `EdgePreviewFooterButton` actions: quiet icon rows
  that lift on hover, never accent text links.

The tab selection survives collapse and reopening. Automatic announcements
show Tasks without changing the stored selection. The preview has no close
button, upward arrow, or duplicate icon rail; pointer exit handles dismissal.

**Tasks tab.** Activity is selected by default. The header's trailing slot
holds a quiet "Activity" / "Kanban" text filter: no container or pill, the
selected word is just brighter and semibold so Tasks/Quota stays the only tab
bar (list/grid glyphs would read as a layout switch), followed by refresh for the selected source. Tooltips and accessibility labels
name both choices. The choice survives collapse and reopening. An automatic
announcement temporarily shows its source without changing that choice.

Activity lists every session that is working, waiting on the user, or finished
with a result the user has not opened. The list has no cap; the body scrolls.

- It has three sections, each with a `DockSectionLabel` and a live count:
  - **Needs your attention:** unresolved approvals and clarification questions.
  - **In progress:** working sessions.
  - **Finished, not opened:** newest first.

  An empty section is omitted. Pending requests include other sessions, use a
  bounded request summary, and remain visible until answered or expired. Select
  the row to review the full request and respond in the workspace.
  One-tap answers capture the original profile, session and request ID. Only
  that request is disabled while submitting; a received refusal exposes Retry
  in the same card. An unacknowledged response remains unavailable for another
  quick submission and directs the user to review the session. Answers never
  retry automatically. Check request uses an authoritative pending-request
  read before enabling another answer. If the runtime cannot provide that read,
  the request stays uncertain. Answers never consume the workspace draft or
  attachments. Missing request IDs require the
  workspace rather than an unscoped quick answer. File-delivered questions are
  removed only after acknowledged submission and only while their contents
  still match the answered question.
  A finished session row opens Result Peek inside the same fixed preview.
  Result Peek reads the latest saved reply on demand, with files from that
  reply's user turn. It never uses the index preview as output or asks Hermes
  to generate a summary. Reading does not switch the workspace session. A
  deliberate selection marks a matching completion reviewed after its content
  loads; hovering does not acknowledge it. Copy copies a bounded excerpt; Reply deliberately
  enters the targeted quick composer; Open session selects the captured session.
  Missing files show File not found, and relative paths require the session
  rather than resolving against Herm's process directory. Loading, unavailable,
  empty and loaded states keep the same header and footer.
  The fallback label is Latest completed reply. The excerpt is limited to
  12,000 characters and 12 actual outputs. At most eight snapshots are held
  in memory. New activity invalidates cached reads while the displayed result
  stays frozen; Update explicitly requests new content.
- Rows are quiet: no border or surface at rest, a `dockSurface4` fill on hover
  and a fainter one for the current session. A one-line 12pt semibold title
  sits beside the status dot and trailing metadata. The next line is the 11pt
  status label, colored only for attention, then " · detail" in metadata text.
  Current sessions carry a quiet "Current" chip.
  The status label is "Needs your approval", "Needs your answer", "Working", or "Finished", or a more specific label such
  as "New response" or "2 background tasks running". The detail line is the
  running tool, the latest response excerpt, or the session preview. Trailing
  metadata is the time since the last update. Working cards pulse and show the
  shimmer. No percentage is ever implied.
- The open session appears only while it has live activity or an unseen
  completion. It leads its group, uses the faint current fill, and shows
  "Current" instead of a time.
- Background tasks roll up into their parent session rather than appearing as
  separate rows.
- Selecting a card resumes that session in the workspace, which clears its
  unread state. The current session's card opens the workspace.
- While Hermes is offline, the refresh slot shows a warning icon with an
  accessible unavailable label. The last list stays. Working and needs-you cards switch to the `inactive` tone,
  labelled "Status not current". Finished results keep their tone.
- The empty state reads "No activity in progress", "No Kanban activity", or
  "Hermes is offline", with one line saying what will appear. A failed Kanban
  read explicitly shows "Kanban is unavailable" when no cards are cached.
- The footer holds Quick message and Open Herm actions. Quick message replaces
  the scrolling body with a compact text composer inside the same fixed panel.
  It always starts a new session, even when another chat is selected or busy.
  Each session row also has Reply, which opens a composer beneath that row
  and captures the session identity and profile. Command-Return submits either
  composer. Neither action changes the workspace selection. Reply drafts stay
  with their target session; a composing row stays visible through refreshes.
  A failed new-session submission retains its created session for retry. The workspace draft and attachments remain untouched. Pending
  and rejected sends stay in place; rejected text remains available for retry.
  Busy chats and offline state explain why sending is unavailable.
- Explicitly entering the composer gives the panel keyboard focus and prevents
  pointer-exit dismissal and automatic announcements from interrupting typing.
  Back, Escape, tab changes, or Open Herm leave composition. The separate draft
  survives preview collapse and restart in a dedicated QuickDraftStore file.
  To, Add, Paste, Drafts and More operate within the existing composer. The
  destination names the captured profile and session; a chosen project is
  explicit. Workspace navigation never retargets a nonempty quick draft.
  Captured URLs are references, not browser or agent actions. Files use
  bookmarks; pasted images live in draft-owned storage. One PDF up to 25 MB
  and image/generic files up to 50 MB are supported. Folders are rejected.
  Generic files use file.attach and its actual returned reference.
  Missing, changed and inaccessible files remain visible for repair. Preparing,
  rejected and uncertain submissions use the existing status slot. Protected
  attachment submission requires the runtime's advertised exclusive-submit
  capability. An interrupted operation restores as needing review, never as
  an in-flight send. Known uploads are retained for safe retry or scoped image
  cleanup. Only acknowledged sends or confirmed discard clean up owned files.

**Keyboard preview and saved actions.** Hover keeps the preview passive. The notch shortcut
enters an interactive preview, preserving a scoped row selection through updates. Arrow keys
move among rows; Return inspects the selected row and never answers a decision. Typing fields
and menus retain their own navigation. Escape leaves a comparison first, then detail/composition,
then the preview. Outside clicks save the quick draft and dismiss without activating another app.
Dismissal returns focus only when Herm still owns focus; it never overrides a later app switch.

More exposes four editable starter actions and custom instructions. An action only prepares a
quick draft; Send remains explicit. Unbound actions retain the captured recipient and material.
A bound action that changes destination requires confirmation and preserves the original draft;
the new draft contains instructions alone. Actions and working-set checkpoint notes belong in a
separate versioned WorkflowContent store, using atomic writes and restrictive file permissions.
Corrupt content remains intact and disables saving rather than being overwritten.

**Working-set checkpoints and watching.** A checkpoint records a user note, a member destination
and, when present, the exact quick draft ID. Opening the editor and autosaving note edits retain
the existing draft association. Save checkpoint explicitly associates a matching current draft,
only while capture/submission is inactive. Restore affects notch context only. Missing drafts
never substitute another draft with the same recipient; the note survives and the destination
opens as an empty draft. Checkpoint clearing and set removal use confirmation. Choosing Watch
filters ordinary activity to concrete sessions in one saved set without changing the recipient
or workspace. Decisions and blocking failures remain global. Activity scope stays visible in the
fixed header. Watch metadata reads are scoped to each profile, bounded to two concurrent reads,
and triggered by selection, opening, refresh, reconnect or existing events, with no new timer.
Saved session metadata does not prove current execution state. Unknown or disconnected state
is marked stale; references absent from the bounded recent inventory remain repairable.

**Result comparison.** An explicit successful update retains the previous read in memory.
Compare shows added/removed text and output references from these two reads. It does not claim
an exact historical turn match when reply identity is absent, or unchanged file contents from
an unchanged path. Failed updates retain the displayed result and its recovery action. At most
two bounded reads belong to the open result; closing it clears comparison history. Longer text
uses separate snapshots rather than an expensive line diff. Comparison never changes source
pins, drafts, or workspace selection.

**Routine recovery.** Activity includes failed execution, blocked configuration, delivery errors,
and explicitly pinned routines. Routine detail replaces the body, names its owner profile,
and separates execution from delivery. View report reads its captured report session. Pause,
Resume and Run now confirm the affected profile/job and refresh authoritative state. Run now
starts a new execution; it does not retry delivery. Repeat triggers remain disabled until a
new run is recorded or the user explicitly reviews history and authorizes a fresh attempt.
Skills & MCP repair opens the existing workspace modal with the captured profile. Lifecycle
operations keep Hermes' installation checks; credentials use secure fields and never enter
preview/draft persistence. OAuth polling and skill-removal outcome checks run only during
an explicit action. A live MCP reload warns that it affects all connected runtime sessions.
The Capabilities page (rail and compact sidebar) covers what Hermes Desktop's Capabilities
route does in Herm's own idiom: `DockTabBar` tabs with counts (Skills / Tools / Connectors /
Plugins / MCP), a profile menu, and a filterable list (`dockListRow`, status dot, `dockSwitch`)
beside a `dockCard` inspector (SKILL.md preview, toolset tools, connector accounts, plugin
settings). Skills, Plugins and MCP add an Installed / Discover scope (Skills Hub search, the
plugin catalog, unadded and custom MCP servers) instead of an embedded hub page. Only theme
tokens are used, so every skin restyles it. Tools reads `GET /api/tools/toolsets` and toggles via
`PUT /api/tools/toolsets/{name}`, hiding the same internal toolsets Desktop hides. Plugin
Discover groups the whole catalog by its `category` (chips narrow to one) and ranks each group
by GitHub stars or A–Z; Hermes has no popularity data, so stars come from one batched GitHub
GraphQL read using the launch `GH_TOKEN`/`GITHUB_TOKEN` and are simply absent without one. Load
errors show only on their own tab.
The same Integrations modal lists Hermes plugins (`plugins.manage`: enable, disable, remove
user installs) and hosted connectors (`connectors.*`, account owner: connect via the browser
link Hermes mints, disconnect per account). Plugins that ship a Hermes Desktop UI half say so;
Herm cannot host that panel, but the plugin's agent tools still load. Plugin settings save
plain fields through `plugins.manage settings` and secret fields through `PUT /api/env`;
secrets are never read back, only shown as saved. The catalog installer (from
`/api/dashboard/plugins/catalog`) hides non-macOS entries and Desktop-only packages (category
`desktop` with no tools, hooks or middleware). Connector rules toggle a connector through
the member policy layer, guarded by its revision; without a member layer they are read-only.
Accounts can be renamed to a Hermes alias (`[a-z0-9][a-z0-9-]{0,31}`).

**Destinations and Recall.** Named working sets store profile/session/project references, not
transcripts or runtime aliases. Choosing a destination never navigates the workspace. Missing
references remain visible, disabled, and repairable. Search replaces the scrolling body from
an existing footer/menu action and deliberately takes keyboard focus. It searches the chosen
profile on Hermes with a 300ms debounce and at most 20 results. Open conversation makes no
exact-message jump claim. Insert preserves the quick draft recipient and adds its source.

**Session capacity.** A user-selected session may expose configured model choices and Stop
this turn after an owned resume. Changes require acknowledged session scope and idle state.
Quota figures come exclusively from `ControlCenterModel.providerQuotas`, the same inventory
as the Quota page and chat composer. Session model responses supply model choices and provider
identity, never a second quota reading. Compact summaries use the page's limiting window.
Provider/account selection is an aggregate advisory, not a claim about the session's active
credential. The provider reading time is explicit. Remaining allowance of 20% or less adds a
nonblocking quick Send advisory; it does not switch models or predict completion.
Capacity reads occur when the user opens the relevant composer/detail, without another idle
polling loop.

**Source and coding review.** Result Peek has Sources and Coding review disclosures. Links
actually present in the saved excerpt are candidates, pinned only explicitly. User-added URLs,
labels, origin and supplied reply references remain references; they do not verify particular claims. Selected
sources and quoted corrections target the original session. Markdown export names the bounded
reviewed excerpt and its pins. Coding reads the originating session directory only when expanded.
A clean captured HEAD plus acknowledged and observed turn ownership enables Changes since turn started, with a warning about other writers;
missing/dirty baselines show current repository scope. Verification requires matching repository
and revision provenance. Refresh is explicit and external changes invalidate known evidence.
New task in worktree confirms the repository/profile, creates a native Git worktree from HEAD,
then verifies Hermes' explicit directory before presenting the unsent task. Partial setup retains
the worktree and recoverable draft. Live-subagent steering selects a child from its owned parent
session; Queued remains distinct from delivery. Memory correction loads the actual fingerprinted
entry/profile and confirms edit/delete. No memory graph or pending-write approval is recreated.

**Quiet periods.** Quiet is explicitly started from the existing Tasks header;
60 minutes is the default, with 30 minutes and Until I end it alternatives.
One app-boundary coordinator classifies existing notices. Approval, clarification
and authoritative stopping failures may interrupt; ordinary completion, quota
and informational notices enter a digest. This policy applies before notch
expansion, pet announcement reactions and opted-in system notifications. The rail
keeps meaningful attention and unread indicators. No new polling loop is added.

The digest replaces the preview body and keeps its surrounding slots. It holds
at most 50 origin/event references and an overflow count, persisted with quiet
expiry; it does not save response bodies. Restored card and other unavailable
source references wait for their owner inventory to reconcile. Selecting a
completion opens Result Peek, and only a successful deliberate read reviews it.
A completion retains its original profile and session even outside the visible
inventory. Restored completions permit an explicit scoped read with the existing
retry state; this does not restore expired questions as actionable decisions.
Other entries open their actual source. At period end, one announcement waits
for composition, dragging and result-reading guards to permit it. Clear requires
confirmation and removes only Herm's saved references.

**Kanban activity.** The Kanban selection shows all running, blocked, and
review cards across boards,
plus up to 30 recently changed cards until opened. Rows reuse the session row
layout, with the canonical card status, board and assignee, and a short
observed transition such as “Running → Review”. Assigned rows show the bot's
stored avatar (or shared bot fallback), with a small status dot; unknown
assignees use the existing initial avatar. Clicking a row opens its board
and card inspector. Recent changes lead the list so the announced move is
visible immediately. Queued and review rows never imply running work.

The first successful all-board read is a silent baseline. Subsequent confirmed
card additions, edits, and status moves use the same six-second automatic
announcement as session activity. The notch refreshes the shared unfiltered
Kanban projection every five seconds, including while the workspace is closed.
Unchanged reads, visible-board filters, optimistic moves, and failed reads do
not announce. Failures retain the last cards with inactive live status; refresh
in flight does not flicker the rows. Snapshot comparison can miss intermediate
moves between reads. The rail includes running and blocked Kanban work even
when no conversation is active.

New responses, completions, and requests for attention expand the preview
automatically for six seconds. Rapid tool chains are limited to one automatic
announcement every four seconds. Tool progress updates the current card in
place without expanding the preview. Only bounded response excerpts and tool
names appear; full results and decisions stay in the workspace.

**Quota tab.** While Quota is selected, the trailing slot holds a List/Grid
segmented toggle and the refresh control (a small spinner while reading). The
tab shares the ControlCenterModel provider inventory with the workspace. It
reads quota only on explicit selection or refresh. It presents every connected
provider with its reported allowance windows: the 5-hour window (`Session`, shown as
`5h`) and weekly window (`7d`) appear first, followed by other reported windows
under their own names. Balance providers show balance and runway when available. Meters and rings show remaining
capacity (`remainingPercent`) in the Quota page's health hues, so both
surfaces read the same way; missing values stay unavailable. Cached quota stays visible during refresh and
after failed reads, with stale status shown instead of clearing the last
successful values.

- **List rows** show the provider mark and name, then one line per window: a
  short label, a 4pt meter with the daily-budget tick, the remaining
  percentage, and a reset countdown.
- **Grid** uses two columns of surface tiles. Each tile has the provider mark,
  the name, and a 3pt ring per window holding the remaining percentage and
  a radial daily-budget tick, with the short label and reset countdown
  beneath.
- **Provider marks** are vector Simple Icons paths (CC0) on a themed tile.
  Claude keeps its coral. OpenAI/Codex and OpenCode use primary text.
  Providers without a mark use a monogram.

The footer shows the last-updated time and an Open Quota footer button, which routes to the
full quota workspace in the same native window. Quota menus can be used
before collapse.

**Workspace transition.** A click or a double-tap of Command expands the same
native window into the workspace at the notch's location. Closing it, moving
the pointer out of the window, or clicking outside returns that window to the
notch. There is one conversation host, retained across these transitions.
Hover never activates the app, mounts the conversation, or marks responses
read. The workspace reserves a 12pt horizontal and 32pt vertical safe inset
for the contour, and the entire workspace, including its header and bottom
controls, fits inside it. Native panel dimensions include these insets.
Responsive content dimensions exclude them and clamp to the selected display.

Revealing the workspace with the shortcut coordinates a 460ms edge expansion
with a restrained inward spring slide and a staged content fade. Collapse
takes 260ms. Repeated toggles cancel content animations, and focus is
available immediately. Leaving either the preview or the expanded workspace
collapses it after a 350–400ms grace period; returning cancels the dismissal.
Attached sheets and popovers stay usable, and fullscreen stays open. Reduce
Motion makes geometry changes immediate and replaces the work animation with a
static symbol.

**Placement.** Drag the notch along either side of any connected display. It
snaps to the nearest side and persists that side, the display, and the
relative vertical position. The native context menu also offers left/right
placement and Quit. Screen changes clamp the surface to an available display.

### Office simulation and exterior

The 3D office projects canonical bot identities and Kanban activity. Each bot
starts at a distinct home position; shared leisure destinations are reserved
before travel. Refreshes and desk changes preserve walking continuity. Ambient
breaks do not claim task progress. Planning/review interactions require a shared
reported board and phase, and begin only after both participants arrive.

Bots persist. Hiding bots only hides them; the simulation keeps running and
showing them resumes where each bot stands. Placements also survive closing and
reopening the office. Working bots go to the computer their reported location
calls for. Idle bots spread across the whole office. Solo activities are ranked
against crowding and repeat visits, so every room gets used. Activities include
coffee, reading, strolling, arcade games, charging bays, workbenches and parts
shelves. Idle
colleagues sometimes pair up at facing chat spots for a short scripted chat:
wave hello, take turns talking (a speech bubble marks the speaker), share a
laugh, high-five, and wave goodbye. A reported task always takes priority and
ends a chat.

Bot animation uses jointed pivots (hips, waist, shoulders, neck) and one
per-frame pose driver that blends toward each target. Sitting, standing,
walking and gesturing never pop. Walking eases in and out across corners on
smoothed routes. The gait has counter-swinging arms, a forward lean, torso
twist and a speed-scaled stride. Bots yield to a colleague just ahead and
replan if blocked. Reduce Motion snaps bots to their destination pose and
disables leisure and chats.

Workstations are real cubicles. Floor-standing panels with trim caps, end
panels that stay clear of seat approaches, and a cork tackboard frame each desk.
Six desk personas rotate so neighbouring cubicles never match: plant lover,
gamer, organizer, traveler, maker and reader. Their static props include
succulents, a robot figurine, an inbox tray, sticky notes, a calendar, a globe,
postcards, a backpack, a desk fan, a puzzle cube, a blueprint and a desk lamp.
Every room has its own floor finish and signature furniture, so no two rooms
share a table set. The café, beside the entrance hall, has checker tiles, a
slatted-oak coffee bar with an espresso machine and pastry case, bar stools,
bistro tables and booths under pendant lamps. An open library nook sits south of
the café, with bookcases and two reading armchairs. The planning room in the east
wing holds the kanban wall with two stand-up rows, a sticky-note wall, a roadmap
strip, a standing table and a round huddle table. Mission Control has two
tiered console rows facing a display wall. The Parts Depot has warehouse racking,
aisle lines, a pallet and a packing bench. The Game Room has ping-pong and two
arcade cabinets. Maintenance has a robot service lift and a tool chest. The Design
Studio has plank floors, an easel and a slatted accent wall, and the QA Lab has an
ESD mat. Rooms also carry everyday fixtures: water coolers, extinguishers,
charging-pad caution stripes, an Assembly Bay safety line, a QA parts-bin rail
and a server-room cable spool. The office shows no clocks or other displays that
would need to state real time or data.

The exterior is a connected campus forecourt: stone promenade, timber pergola,
seating terrace, fountain court, planting beds, and bicycle parking. Outdoor
seats are reachable activities, while solid furniture and landscaping contribute
to the same obstacle map as the interior. Reuse cached geometry and materials;
static scenery does not introduce animation timers.

The campus sits in countryside that runs to the horizon, so it never floats:
a meadow just below the site slab, a hedge around the back and sides, an
access road to a country road, a car park with parked cars, striped farm
fields, a pond, tree clumps, and rolling hills hazed toward the horizon. It is
static scenery merged by the batcher and lies outside the walkable site.

Time of day follows the local clock (`OfficeDaylight`). The sun's position is
computed from the date and time at a fixed mid latitude, so sunrise and sunset
move with the seasons; +x is east and the midday sun sits over the forecourt.
The coordinator re-reads the clock every 30 seconds. Sun elevation sets the
sky colors, light, stars, and night bloom. Lighting (`OfficeSceneLighting`) is a
key light that is the sun by day (clamped to a low elevation at dawn and
dusk) and the moon at night, a sky-tinted fill from the opposite side, and the
sky gradient as image-based light, cached per two degrees of sun elevation.
Night is moonlit, not black: the moon key, the fill, and a lifted blue-grey
copy of the sky used as ambient light keep the countryside readable while the
lamp pools still read as night.
`OfficeSky` draws a gradient dome, sun and moon discs, a merged star field, and
low-poly clouds held beyond the site so they never hide the office. The clouds
drift slowly (one transform per frame), and the drift stops under Reduce Motion.
Sky geometry casts no shadows (macOS 15 and later). macOS 14 keeps a flat
horizon-coloured background, RealityKit's default image light, and clouds
only. Shadow reach follows camera distance. Street lamps ring the
site (sidewalk, both sides, the back and the forecourt), and rooms without
their own pendants have slim linear ceiling lights, so the office reads as lit
at night. Lamps, sconces, ceiling lights and bollards do not add dynamic
lights; each one lays an unlit, transparent glow pool on the floor, which the
static mesh batcher leaves unmerged (merged meshes carry no UVs) and which
never registers as an obstacle. A screen-space finish (`OfficePostProcess`)
applies a light warm grade, bloom on near-white lamps, signs and screens, a
soft vignette, and a tilt-shift blur at the top and bottom of wide views. The
tilt-shift fades out as the camera moves in, so close views of a bot stay
sharp. Apart from cloud drift and the clock-driven sky, none of it animates.

The office palette is derived from the selected Herm theme (`OfficeScenePalette`).
Only the shell follows the theme: plaster, floors, trim, paving and ground take
the hue of the theme's base surface at fixed lightness, with saturation capped
so strong themes tint rather than flood the scene. Furniture stays one
honey-oak studio set with low-poly potted trees in every theme. Dark themes
dim the same materials; light and sky follow the clock in every theme. The theme accent tints glass, signage and screens only. Room floor finishes blend toward the base floor so they stay calm
in both appearances. System follows the system appearance. Changing the theme
rebuilds the room materials, lights and background in place. Rooms are
identified by numbered hanging signs with a title and a short subtitle that
names the room's work (for example, QA Lab: Tests & verification). Bots stay small white robots in every theme, with a dark
visor, glowing eyes and accent-colored headphones. The main session wears gold
with a compass badge. A single status vocabulary (`OfficeAgentStatus`, mapped onto `DockStatusTone`: Blocked,
Working, Review, Queued, Idle, Not current) drives eye color, bubble tint, HUD
dots and roster order. Selecting a bot shows a floor selection ring. Head motion
and blinking follow the reported phase and stop under Reduce Motion.

Each bot carries an AppKit task bubble instead of an icon. The full tier shows
a status dot, bot name, reported status with time elapsed since the task
started, task title, and the latest reported step. Running work shows an
indeterminate shimmer, never a percentage. Wide views show name pills, and
crowded bubbles step down to a dot instead of overlapping. Bubbles rise in when
they appear and pop when status or task changes. Those animations stop under
Reduce Motion.

The office container is a game-style HUD over the scene. All panels share one
floating treatment: canvas at 92% opacity, a hairline border, a 12pt radius and
a shadow. It has four parts:
- **Status bar (top left):** a chip for each status with its live count. The
  Not current chip appears only when data is stale. A chip cycles the camera and
  selection through the bots in that status, and it is disabled at zero.
- **Crew roster (left, toggleable):** bots sorted by status priority. Rows show
  the name and current task title. The selected row uses the muted accent.
  Selecting a row focuses the camera on that bot.
- **Inspector (right):** replaces the modal sheet. It shows the bot's avatar
  with a status dot, a status pill, the current task (with the reported step and
  running time), task fields and the "Assign existing task…" menu. Main sessions
  get Open conversation and recent activity. The task board inspector lists
  lanes with count badges.
- **Toolbar (bottom center):** the Workspace / Whole office segment, show bots,
  show roster, the task board and camera reset.

The HUD shows only projected Kanban and session state. It has no
fabricated stats, percentages or resource meters. Narrow containers hide the
roster.

### Navigation sidebar

The sidebar is the reference implementation of the navigation patterns in
the design system; other panes copy it rather than restyle it.

The desktop conversation list keeps its 300pt minimum while resizing; the
workspace takes the remaining width when both pane minimums cannot fit.
Section headings stay on one line and truncate rather than wrapping vertically.
When the conversation and inspector cannot fit side by side, the inspector
uses the workspace pane with a Back to conversation action.

The 56pt header bar holds the Bot switcher (avatar, name over role,
chevrons-up-down when more than one Bot is visible) and two `DockIconButton`s:
fullscreen, then new conversation as the prominent action. Top-level
destinations (Today, Inbox, Kanban, the Tools group, and the Quota and
Settings footer) are `DockNavRow`s. Settings shows the "Update" pill when a
Hermes update is available. Tools, Pinned, Conversations, and Projects all use
`DockSectionHeader`; Tools is static, the others are collapsible, and
Conversations and Projects carry a 24pt refresh action.

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

### Pinned messages

Message pins are Hermes-owned bookmarks, separate from conversation pins and
model context. Completed user and assistant messages with verified stored row
identities offer Pin/Unpin in their existing action row. An unpersisted or
streaming row never guesses its durable identity from text or position.

The conversation header's pin action opens a fixed-size popover with 12pt
titles and previews. Selecting a pin pages in older history if necessary and
jumps to the exact original message; it never falls back to a nearby message.
Refresh, loading, empty, unavailable, stale, and mutation errors stay inside
this popover. A failed refresh retains existing pins with an error and disables
mutations until a successful refresh. Mutations display pending state and
change the pin projection only after Hermes confirms and is reread.

Pins follow the compression lineage's stable message identities. Explicit
branches have independent pin sets. Profile or conversation changes discard
the local projection and fence late responses from the previous selection.
Older Hermes runtimes must show support as unavailable, never local-only pins.

### Settings workspace

Settings groups destinations by purpose:

- **App:** General, Gateway, Appearance, Notifications.
- **Agent:** Models & tools, Chat, Memory & Context, Voice, Advanced.
- **Tools & access:** Files & terminal, Browser, Privacy & safety, Integrations.
- **Activity & maintenance:** Active session, Project checks, Diagnostics, Updates.

General is selected when the surface is mounted; selection is local presentation
state and is not persisted. At 760pt and wider, a 184pt rail of `DockNavRow`s
scrolls independently from the detail page. Group labels separate destinations;
narrow layouts use the same groups in a category menu below the Settings header.
Each detail page starts with its category title and a short description, and
opens at the top when the category changes.

- **Grouped cards.** Each detail page is a short stack of `SettingsSection`
  groups: a 13pt semibold title and an optional inline 11pt subtitle above one
  quiet card (`surface` at 0.34, `borderLight` hairline, radius 10, 14pt
  padding). Never nest a card inside a card; subgroups inside a card use a
  divider and an 11pt semibold `settingsSubheading`.
- **Predictable locations.** General contains Hermes gateway, Startup, and Keyboard shortcuts.
  Appearance exposes Theme, Sidebar, Notch, and Hermes companion directly.
  Notifications contains completion and repository alerts. Updates contains
  both app and agent updates, plus Hermes update behavior. Files & terminal
  keeps the working directory, execution backend, shell, and file access together.
  Checkpoint limits live beside the checkpoint switch in Privacy & safety.
  Preference rows keep the 52pt minimum with a small switch trailing.
- **Gateway service.** General shows the default-profile messaging gateway's
  running, stopped, or unavailable status with a dot and text. Refresh every
  15 seconds while visible and on demand. Keep progress and failures in fixed
  slots. Confirm Restart gateway because messaging and scheduled work may be
  interrupted; run the local, allow-listed Hermes CLI command outside the chat
  transport, then read status again. Restart requires a verified launchd service
  because unmanaged CLI restarts may run in the foreground. Unknown CLI output
  and failed reads show unavailable, never an inferred running state.
- **Gateway connection.** Gateway configures Herm's machine-level backend:
  Local, Remote URL, SSH, or Hermes Cloud. Use the existing preference controls
  and keep test progress and errors in a fixed slot beneath the actions. Remote
  URLs preserve proxy path prefixes and require HTTPS outside loopback. Tokens and native OAuth credentials use
  Keychain; browser sessions use Herm's dedicated WebKit store. Native OAuth
  uses PKCE and a loopback callback when advertised, with the gateway's browser
  sign-in for password providers and older runtimes. Cloud uses portal sign-in,
  organization selection, agent discovery, and a separate per-agent session.
  SSH reuses Desktop's ownership-checked lifecycle for Linux, macOS, and Windows.
  Test both HTTP and WebSocket access without changing the active backend.
  Save applies after restart; Save and restart Herm requires confirmation
  because draft text and the current session view are cleared. Startup remote
  environment overrides are read-only. General's messaging service and local
  repository/terminal maintenance continue to target this Mac.
- **Skins gallery.** Compact tiles show a miniature material/type/selection
  specimen, the Herm skin name, a short material signature, and one line for
  the mode plus "Active in Hermes" when it applies. Specimens use the target
  palette and geometry independently of the active skin; they contain no
  invented activity or metrics. The selected tile gets an accent stroke and
  checkmark in a fixed slot; the description is a tooltip. Selecting a
  tile changes Herm presentation only and never invokes Hermes skin commands.
  Unmapped skins and installed companions are quiet lists below the grid.
- **Color and copy.** The Quota rule applies: healthy and ready states stay
  neutral, and warning or destructive hues mark only states that need action.
  Row labels and buttons use sentence case, not monospaced capitals. At most
  one accent-tinted `.dockPrimary` button per card, used for the committing action
  (for example Update Hermes).
- **Badges** are reserved for actionable state: the update indicator on Updates,
  the setup-needed count on Integrations, and the open-attention count on
  Session. Loading, unavailable, and empty states stay inside their category.
  Disruptive session actions keep their existing confirmations.

### Quota workspace

Quota is a centered monitoring page (maximum 960pt). A fixed toolbar holds the
connected/attention/available sentence, a Custom/Health order toggle, an
auto-refresh menu (Off, 1, 5, or 15 minutes; it runs only while the page is
open), the last-updated time (warning hue when stale), and refresh.

- **Overview.** One `dockCard` row with three measured figures: Most headroom
  (the provider whose tightest window has the most left), Needs attention
  (count and names), and Next recovery (soonest reset of a low or exhausted
  window, else Next reset). Figures use `DockTypography.metric`. A figure with
  no reported data shows an em dash and says why.
- **Provider cards.** One signage card per connected provider: drag handle,
  provider mark, name, a metadata line (reported name when renamed, model,
  plan detail), a health pill only for Low, Critical, or Exhausted, and an
  actions menu (Rename, Restore reported name, Move up/down, website, and
  Remove from Hermes for pooled accounts). Borders stay neutral; the pill
  (colored dot on `surface4`) carries health. Windows
  sit in an adaptive grid: label and `Resets in` countdown, remaining percent
  in the metric role, a 6pt meter with the daily-budget marker, and up to two
  insight lines (exhausted-until, run-out forecast, today's budget, or pace
  against even use). Countdowns re-render each minute.
- **Color discipline.** Healthy is neutral: figures in `primaryText`, meters
  in `secondaryText`, the budget marker and forecasts in neutral text. Warning
  and destructive hues appear only on a window or figure that is low or
  exhausted, so the page is calm until something needs attention. The refresh
  control is a 28pt `DockIconButton`.
- **Rename.** Double-click the name or choose Rename. The field edits inline;
  Return or losing focus saves, Escape cancels, and an empty name restores the
  reported one. Nicknames persist per reported provider id and also appear in
  the notch Quota tab.
- **Order.** In Custom order, drag a card by its handle to reorder live; Move
  up/down is the accessible equivalent. The order persists per reported
  provider id, so individual accounts can be arranged, and it is shared with
  the notch Quota tab. Health order shows worst health first and keeps the
  custom order within each tier; drag is hidden in that mode.
- **Hermes pooled accounts.** Codex via Hermes shows one card per entry in
  Hermes' `openai-codex` credential pool, numbered as `hermes auth list`
  numbers them and keyed by pool entry id, so nicknames and order survive
  another account being removed. The singleton Hermes login appears only when
  Hermes has no pool yet. The metadata line leads with `Hermes pool · <label>`.
  An account whose usage read fails still gets a card, with the failure as its
  detail, so it can be removed.
- **Remove from Hermes.** Only pooled accounts offer this destructive action.
  A confirmation names the account and pool position and states that Hermes
  stops using it everywhere. It runs `hermes auth remove <provider> <id>`
  through Hermes, so Hermes also does its own cleanup. While it runs, a
  spinner replaces the actions menu; a failure replaces the metadata line in
  the warning hue. Herm forgets that card's nickname and position only
  after Hermes succeeds. Other providers have no remove action, because the
  Herm does not own their logins.
- Disconnected providers appear afterward under Available to connect with
  Connect and website actions.

Healthy, warning, critical, and unknown states use `dockSuccess`,
`dockWarning`, `dockDestructive`, and `dockMetadataText`. Missing numeric data
is never rendered as a fabricated meter or percentage.

### Automation

The fullscreen Automation destination is a full-height operations index rather
than a dashboard. A quiet three-column table is the primary surface: status
dot plus name with a single metadata line (humanized cadence such as "Every
day", and non-local delivery), Next run, and Last run. Times read relative
first ("in 3 hr", "2 days ago") with the absolute date beneath. Enabled jobs
whose next run is in the past show "Overdue" in `dockWarning`, and a single
banner under the header counts them. Last run falls back to the job's own
last status when run history is unavailable, so Paused, No run yet, Succeeded,
and Failed stay truthful. It preserves Hermes order and uses hairline dividers.
Run now is direct; Edit and Remove live in More and the native context menu.

Selecting a row opens a contextual inspector at wide widths and the same native
sheet at narrow widths. The inspector header carries a state pill (Active, Overdue,
Paused), cadence, name, Run now, Edit, More, and a close button in the sheet.
It has Overview and Runs tabs. Overview leads with four tiles (Next run, Last
run, Cadence, Repeats), then run and delivery error callouts when Hermes
reports them, the request (script and prompt preview), Configuration (model and
provider, skills, toolsets, workdir, delivery), Identifiers, and the report
action; Runs defaults to the selected job and can switch to the
authoritative All runs scope. Empty, stale, loading, and unavailable states stay
inside stable table or inspector regions. New automation uses a focused native
sheet, and no pause/resume control is shown without an authoritative Hermes
mutation path.

### Session inspector

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

### Kanban

The fullscreen Kanban page uses a compact native board. Its header subtitle
names the selected board and reports filtered results as “shown of total”. A
single persistent toolbar keeps board selection, Status, Assignee, Mine, Sort,
active-filter count/Clear, and Add Task available in loaded, loading, and empty
states; filter visibility is not gated by an optional capability when the
board adapter can apply the filters. Updated, Created, Priority, and Title
sorts are readable labels backed by stable adapter ordering.

Kanban lanes are flat columns in canonical order. The page header and toolbar
stay fixed; the board fills the remaining height, scrolls horizontally, and
each expanded lane scrolls its own cards vertically. Non-empty lanes use a
compact working width; empty lanes collapse to a narrow full-height rail with
icon, count, and the lane name stacked one letter per line, and expand locally
on selection or automatically when work arrives. Any expanded lane can be
collapsed from its header chevron. Cards prioritize
title, priority/assignee, model metadata, summary/current step, and relative
activity. Selecting a card opens the existing detail inspector. Details, Done,
Block, Unblock, and Archive are progressive actions in More and the native
context menu. The More control stays visible at rest, and Details always opens
the available board summary even when CLI detail enrichment is unavailable. Health diagnostics stay behind a compact disclosure above the
board. Apart from the lane-drop move described below, the board and its
toolbar are presentation-only.

Kanban cards are essential-compact: a two-line 13pt title first, one summary
line, then a single footer with priority, assignee avatar/name, compact
relative activity (minute resolution), and a subdued task ID. Cards use a
hairline border that strengthens on hover and an accent border when selected;
More stays in a top-trailing overlay without changing card layout; its icon
becomes a spinner while a card mutation is pending. Provider/model and execution diagnostics belong in the task
inspector, not on every card. Collapsed lane labels stack upright letters;
rotated lane labels are not used. Selecting a card immediately opens a fallback-first inspector so
the authoritative board summary remains visible while Hermes enriches it. The
inspector is a flat contextual surface with Overview and Activity tabs for task
content, metadata, attachments, current state, and run history.

Cards drag between lanes, matching the Hermes desktop board. Expanded lanes and
collapsed rails are both drop targets and highlight in the lane color while a
droppable card is over them. Running, Review, and Scheduled are system-owned:
cards can leave them but never enter, and those lanes show the forbidden cursor
instead of a highlight. Triage, Todo, and Ready drops use the Kanban plugin's
task route, enabled by a current successful HTTP board projection rather than
the separate CLI probe. The Move to submenu exposes the same destinations.
Done and Blocked drops require their CLI capabilities and use the same
confirmation as the card menu because they release a worker claim. Cards stay
in their current lane until Hermes confirms the change and the board refreshes.
A refused transition surfaces Hermes' reason in the error banner.
Assignment is one step from the card's More and context menus ("Assign to"),
listing Bot profiles with the current assignee checked plus Unassign. Like the
desktop assignee menu, it reassigns and reclaims a live worker first, so a
running card can change hands.

### Bots

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
disabled state, and confirmed removal. This page uses the global Herm tokens and
is independent of the sidebar brand-concept preference. Groups, sections,
profile deletion, cross-machine routing, and richer routine actions require
additional Hermes gateway contracts and are not presented as available Herm
controls yet.

### Conversation workspace

The conversation workspace uses a stable cool-navy canvas in both fullscreen
and compact layouts, independent of the sidebar concept selector. Its header
is a single flat row.
The session identity gets the flexible header width and may wrap to two lines.
A view menu replaces the fixed destination icon strip. Voice is directly
available from 520pt chat width; the inspector toggle remains direct from
340pt and moves into the view menu below that. All destinations remain available
at every width. Controls retain 44pt targets and resizing does not animate.
The transcript mounts a bounded window of messages and pages earlier or later
history automatically as the reader scrolls within one viewport of either edge;
there are no show-more buttons, and the reader's position is held while a page
mounts. Scrolling upward immediately suspends streaming follow until the reader
returns to the bottom. Jump to latest animates only when Reduce Motion is off.
Assistant responses are open document content; user prompts use
restrained right-aligned navy bubbles with a tighter sender-side corner, and a
steering prompt's status sits in sentence case beside its timestamp. Fenced
code blocks carry a quiet header with the lowercase language and a Copy action.
Completed assistant
responses keep a compact action rail permanently visible beneath the content.
The rail uses tightly grouped 28pt controls, a subtle divider, and subdued
monospaced metadata. Hover and keyboard focus strengthen the control surface but
never reveal or hide actions. The composer is one centered floating surface with
the editor, attachments, model, reasoning, and send controls kept together.
Attach, model, and reasoning are 28pt control-surface chips inside 44pt
targets. It is aligned to the reading column, stays at a compact two-row idle height,
and grows only for multiline drafts, attachments, suggestions, or actionable
errors. Attach is icon-only; model and reasoning context remain available at
normal widths, while the send/steer action retains the strongest emphasis.
Streaming, approvals, clarifications, voice state, and errors may use semantic
surfaces when they represent an active decision or recovery path.

### Explorer

Explorer is a dedicated, cardless source workspace. Its navigator starts at
280pt and remains between 220pt and 360pt, leaving the remaining width to the
selected file editor. The navigator uses a flat repository header, compact
30pt tree rows, neutral file icons, and one quiet selected-row fill. Top-level
folders are collapsed initially; filtering reveals matching ancestors without
discarding the user's disclosure state. Generated and dependency trees are
hidden by default, while `.git` remains excluded for safety. Compact layouts
drill into the editor and provide a 44pt Back action. The workspace continues
to use the global cool-navy Herm tokens and does not inherit sidebar brand
concept colors.

### Artifacts

The fullscreen Artifacts destination is a two-pane output browser. Its fixed
header and toolbar keep search, type scope, counts, and refresh visible while a
lazy newest-first results list drives a selected detail pane. Images use an
aspect-fit preview; files and links use semantic previews with selectable
paths or URLs. Open, Copy, optional Reveal in Finder, and source-session
navigation are the only artifact actions. The compact conversation inspector
retains its existing grid/list and pagination presentation.

### Agent Board and activity disclosure

The Agent Board is a live operational projection of Hermes subagents, agent
events, and main-agent tool activity.

#### Identity and status

- Give every displayed subagent a stable accent color derived from its stable
  agent ID. The color must survive reorder and status updates.
- Identity color differentiates agents only. Status color remains responsible
  for Pending, Running, Completed, Failed, Interrupted, and other lifecycle
  meaning.
- Render one row/card per Hermes worker for batch delegation. Do not merge
  workers just because their display names match.

#### Disclosure behavior

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

### Developer workflow surfaces

#### Mission Control, changes, and verification

- Today answers needs-me, running-now, changed, and readiness using only live
  Hermes projections plus an explicitly attached local repository snapshot.
- A targeted verification result is never a ship-ready result. A clean tree and
  repository-wide passed evidence are required for a green readiness state.
- Change Review reads Git state only. It renders repository-relative paths and
  bounded diffs after explicit disclosure. Agent attribution requires an exact
  Hermes-reported written-file match; otherwise the change is unattributed.

#### Source control in the session inspector

- The Changes tab is a compact source control surface for the selected worktree.
  It has a branch header, commit message input, Commit staged changes action,
  collapsible Staged Changes and Changes groups, and recent Commits on that branch.
- File rows are single-line, 30pt rows with a file icon, name, secondary directory,
  stage/unstage action, and textual Git status. Selecting a row opens its bounded,
  read-only diff. Group actions stage or unstage the displayed files.
- Staging and unstaging update only the Git index. Commit includes staged changes
  only, requires a message, and is disabled for unresolved conflicts. Pending
  actions disable duplicate mutations. Errors occupy the existing helper slot;
  failed commits retain the message. Each worktree keeps its own in-memory draft.
- Commits shows the latest 50 commits reachable from the selected worktree's HEAD.
  Disclosure reveals author, date, local references, and Copy commit hash. Upstream
  counts describe the last fetched local state, never live remote synchronization.
  Repository switches and refreshes update this history; no automatic fetch occurs.
- These explicit local Git actions belong to Source Control. Change Review and
  diff previews remain read-only.

#### Terminal and external workflow states

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
  worktree changes only Herm's session-to-repository presentation reference.

#### Verification Center

- Consume `project.facts` and `verification.status` from Hermes; do not
  re-detect package managers or invent verification commands in Herm.
- Show manifests, package managers, context filenames, and Hermes-provided
  verification commands as read-only facts.
- Copying a command is always available when a command exists.
- Running a verification command requires an explicit user action and is
  submitted through Hermes background execution with a no-file-edit request.
- Preserve Hermes evidence scope. `targeted` evidence must never be labelled
  as a repository-wide pass.
- Do not display prompt contents, credentials, raw environment data, or private
  filesystem details.

#### Background tasks

- `DockModel` owns the in-memory background-task lifecycle.
- Register a task only after Hermes returns a valid `task_id`.
- Match `background.complete` by task ID and update the existing row.
- Background rows are collapsed by default and show prompt/output only after
  selection.
- Keep a bounded recent window; background tasks are not durable audit history.

#### Session and runtime controls

- Control actions call named Hermes RPCs and use Hermes responses as truth.
- Rename and in-turn steering are direct actions; branch, compress, undo,
  global delegation pause, agent interrupt, and process stop require
  confirmation.
- Rejected text remains in its input field for retry.
- Never optimistically mark an agent interrupted or a process stopped before
  Hermes confirms the transition.
- Delegation pause is global and must be labelled as such.

#### Runtime parity and control authority

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
- Skills and plugins are inventory/readiness surfaces only in the current Herm.
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

## Engineering rules

### State ownership

- `HermesGateway` owns the authenticated loopback connection and raw RPC.
- `HermesControlRPC` owns named gateway method wrappers.
- `HermesCLIAdapter` owns allow-listed Hermes CLI command construction.
- `HermesGatewayLifecycleModel` owns the default-profile messaging gateway's
  local status checks and confirmed CLI restart, independently of the chat transport.
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

### Implementation boundaries

- Keep shared components in `DockDesignSystem.swift`, shared styles and color
  tokens in `DockComponentStyles.swift`, and theme palettes in `DockTheme.swift`;
  do not duplicate control styling in every view.
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
- Every `TextField` uses `.textFieldStyle(.dockGlass)`; `grep -rn roundedBorder
  Sources` returns nothing.
- Navigation, group headers, and icon actions use `DockNavRow`,
  `DockSectionHeader`, and `DockIconButton` rather than one-off rows.
- Icons come from the Lucide catalog at their slot size, with no unmapped
  fallbacks.
- The README is updated when user-visible behavior changes.
