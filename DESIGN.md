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
| `dockInfo`, `dockMerged`, `dockReview` | Blue informational context, violet merged PR/closed issue outcomes, and teal reviewer/assignment context; appearance-aware, neutral in Monochrome/E-Ink |
| `dockSuccess`, `dockWarning`, `dockDestructive` | Health and outcome of non-task state, such as quota, verification, and mutation results |
| `dockOnAccentText` | Text on a filled accent control |

`DockAccentColor` in `DockAccentPalette.swift` owns the approved solid reference
palette: teal, amber, violet, coral, blue, orange, pink, green, cyan, indigo, and
tangerine. Solid artwork, avatars, dots, and data marks use `.fill`; those values
stay identical in Light and Dark. Small text and symbols use `.color`, which
adjusts only enough for 4.5:1 contrast. Never lighten the solid fills into pastels.
Monochrome and E-Ink keep neutral ink. Source identity colors remain authoritative.

Skin interaction is separate from semantic color. Clean and Glass use neutral gray
actions and selection. Character skins keep their authored interaction hue, such
as Dusk lavender, Terminal green, Classic brass, and Warm Light brown. Cool Blue
may use blue because it is that skin's identity. Never assign blue globally to
primary or secondary controls. Theme surfaces and selection live in `DockTheme.swift`;
shared components inherit them. `make color-contract`, included in `make check`,
rejects new feature-local color literals.

Interaction and task lifecycle keep separate meanings, using the same color
families. Lifecycle uses the status tones below.

### Status tones

`DockStatusTone` (`DockDesignSystem.swift`) is the only lifecycle palette for
work: sessions, bots, Kanban tasks, and background work. Office bubbles and
bot eyes always draw on dark sign ink and use `signageColor`. SwiftUI chrome
uses `color`, which follows the shared theme-aware accent palette.

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

`DockTypography` in `DesignSystem/DockDesignSystem.swift` is the source of truth
for standard point sizes, weights, font designs, and Markdown heading sizes.
Feature views use `.dockFont(.body)`, `.navigation`, `.conversation`, or another
semantic role. Native text uses `DockTypography.size(_:scale:)`; do not copy
standard point sizes into feature views or renderer defaults. The explicit-size
modifier is reserved for artwork and specialized presentation sizes.


Window mode uses `DockWorkspaceScale.window` (100%) as an inherited native
sizing value, matching the standard base typography. `dockFont` resolves fonts at their final size;
shared icons, action controls, and native Markdown use the same value. Floating
panels retain compact sizes. Never magnify the workspace with a render transform
or scaled AppKit bounds: drawing, pointer events, and text selection must share
native coordinates. Display resolution and pixel alignment remain system-owned.

Session and group-chat list titles use scaled 13pt text, previews use the 12pt
body role, and timestamps use 11pt metadata. Inline session renaming matches
the title font.

Markdown table headers and cells use the surrounding reply body size, including
the inherited window-mode sizing. Headings and fenced code derive their sizes
from that body size; native code measurement and its copy/language controls
must update when the presentation size changes. Workspace text, shared inputs,
inspector tabs, and chart labels use `dockFont` or explicitly resolve the inherited
scale when a drawing API requires `Text`.

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
- Expanded Bot dispatch replies use a neutral `dockSurface2` card with a light
  hairline, 10pt corners, and 12pt internal padding; no leading identity rule.
  Keep 12pt between the activity pill and reply, and 8pt above and below the
  expanded group so it stays clear of neighboring activity and message content.

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
`animates`. Glass matches macOS Liquid Glass: a 12% window tint over AppKit
`NSGlassEffectView` (macOS 26) (page canvases and the sidebar stay clear), frosted
cards, chips and inputs, native `glassEffect` buttons and floating panels (`dockFloatingSurface`), no outlines, and
`DockPaneBackground` under sheets and overlays.
The window uses one native glass layer, clipped to its panel silhouette; do not
stack a full-window SwiftUI glass effect over it, which adds broad reflections
across the reading surface.

Surfaces must be theme-aware. Never paint a box, field, chip or track with
`fill(Color.dockSurface…)` / `.background(Color.dockControlSurface)` directly:
use `shape.dockSurfaceFill(fallback)` (glass on Glass, `fallback` elsewhere),
`shape.dockSelectionFill(isSelected, fallback:)` for selected rows,
`.dockPaneTint(color)` for full-width header/column tints (clear on Glass), and
`dockFloatingSurface` for menus and popovers. Skeletons, avatars and status
pills keep plain tints. Only floating panels and buttons use elevated (native,
shadow-casting) glass; inline glass is shadowless, and no `.shadow` is stacked on
glass. E-Ink inverts selected tabs and disables all animation. Swiss drops
card fills and strokes (`chrome: .open`), marks selection with a 2pt accent
underline, and uses a single-rule composer (`DockSkinPresentation.Composer.line`).

Clay molds controls with paired light and dark shadows (`emboss`) and round
corners. Pixel (`geometry: .pixel`) steps its corners, uses 3pt outlines and
hard shadows, and disables animation. Notebook (`.sketch`) draws slightly
uneven pencil outlines on ruled paper (`backdrop: .ruled`) with highlighter
selection. HUD (`.chamfered`) cuts opposing corners, adds corner brackets to
cards, draws a faint grid, and marks selection with a leading accent bar. Storm
is a neon night city: slanted rain over a low skyline with lit windows and
horizon haze (`backdrop: .rain`), cards and the composer rimmed in a
blue-magenta-cyan gradient with a lit top edge, solid blue-to-magenta primary
buttons that glow on hover, and `.neon` selection (gradient wash plus a
glowing leading bar). Its brand hues live in `DockThemePalette.neonHues`.
Skins with `accentGradient` add a top-down sheen to primary buttons.

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
  the skin's `pressScale`.
- Each skin sets a `motion` personality that `dockEase` reads, so views never
  pick curves per skin: `glide` (default soft deceleration), `snap` (Hermes:
  0.6x pace, fast ease-out), `mechanical` (Monochrome, Cool Blue, Terminal,
  HUD, Ares, Brutalist, Swiss: 0.7x, no overshoot), `bouncy` (Cartoon, Clay:
  springy overshoot), and `float` (Glass, Dusk, Storm, Island: slower
  weightless settle). Hover and press feedback use `dockFeedback`; under
  `snap` the active state paints in the current frame and only the return
  eases, as in the Hermes desktop.
- Bubbles and cards appear with a short rise-and-fade (about 0.24s). A status
  or task change may pop once.
- Live loops are the status pulse and the shimmer sweep (1.6s). The running
  chat indicator draws a borderless 40pt Bot in a fixed 56pt slot. Real activity starts
  and completions trigger alternating reaches, tilts, and hops, with a short
  crouch, soft landing, and an echo of the current activity glyph. Rapid updates
  blend from the current pose. Activity row geometry uses a 0.38s damped spring;
  disclosures keep the short `dockEase` transition. Gestures stay within the
  reserved area and its vertical padding.
- Under Reduce Motion, every loop stops, disclosures are immediate, and
  geometry changes snap.
- In a Bot huddle each working Bot takes a 2.6s turn: a thought bubble pops
  above it, types the headline of its latest step (or shows thinking dots
  when none is known), then bursts into sparks that drift to the next Bot.
  Bubbles float at one height above the lead's head, so the row never shifts.
  While a crew is working, the row's names, timer and steps sit under the
  huddle, lined up with the lead, so the bubbles never cover them.
- Decorative Bot motion (working poses, busy faces, tool rings, huddle turns)
  pauses while Herm is neither the active app nor holding a key panel; every
  animated frame re-renders the whole window. Spinners and the notch work
  marker keep running because they carry status.

### Components

Use these before building anything new. They live in `DockDesignSystem.swift`
and `DockComponentStyles.swift`.

| Component | API | Use it for |
| --- | --- | --- |
| Page header | `DockPageHeader` | The one title row of a full workspace destination |
| Expanded page | `DockExpandedPage(title:subtitle:help:close:content:)` | Any full-window expanded layer; owns the title row, Close, and Esc (see `docs/expanded-pages.md`) |
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
| Buttons | `.dockCompact`, `.dockPress`, `.dockSecondary`, `.dockPrimary`, `.dockLink`, `DockActionLabel` | Compact actions, icon controls, standard actions, the local primary action, inline navigation, pending state |
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
title. Use the shared `DockPageHeader` treatment. In windows, Calendar is the
reference: one full-width 52pt title row above the page’s panes. Titles and
leading sidebar toggles use the same 16pt gutter after traffic-light clearance.
Keep the title row above split panes when a page's list collapses. Chat uses
three full-height panes with independent title rows: the session list owns the
traffic-light clearance and sidebar toggle, the conversation owns its session
identity and Chat/Talk actions, and the inspector's tabs reach the top of its
pane. When the chat list is collapsed, its restore toggle moves into the
conversation header with traffic-light clearance.

**Header bar anatomy.** Identity on the left, actions on the right, a hairline
divider below. Identity is a 28pt avatar and a two-line stack (13pt
semibold name, 11pt role). When the identity can be switched, the block is a
button with a trailing chevrons-up-down icon and the standard hover fill; a
fixed identity shows neither. Actions are 28pt `DockIconButton`s: quiet ones
first, then at most one `isProminent` action (the pane's create action) last.
Bot avatars add no surrounding outline in any theme.

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

**Navigation identity.** Chats keeps its speech bubbles; Messaging uses a paper plane
for external delivery, and Artifacts uses stacked files for saved outputs across
the rail, compact navigation, and inspector. Preserve the Bots ghost glyph.
The Chats rail button overlays a compact badge without changing its footprint:
the shared running spinner plus the unread completed-session count (capped at
99+), independently visible. Deduplicate pinned/index rows, omit hidden sessions,
and prioritize working over unread for each session. Keep the selected bot's
session index refreshed while the workspace is visible, including other pages.
Disconnected state stops the live spinner. The tooltip and accessibility value
explain both states; Reduce Motion and motion-free skins keep the spinner static.
The badge owns a cached aggregate from the filtered sidebar publisher, independent
of parent view rendering and transcript deltas. Publish only changed aggregates.
Keep spinner ticks within the badge's shared motion clock, and skip session
polls while the workspace is hidden or disconnected; do not refresh immediately
on every navigation remount.

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

- Every clickable text label must be distinguishable at rest. Use
  `.dockCompact` for small outlined actions (26pt minimum visible height),
  `.dockSecondary` for standard outlined actions, and `.dockPrimary` for the
  one primary action in a local section. Hosting roots default to
  `.dockCompact` so an unstyled action still looks interactive. Use
  `.dockPress` for compact icon controls. Native bordered styles are not used.
- Use `.dockLink` for inline navigation and Show more/Show less. Its persistent
  underline remains recognizable when a theme's accent is monochrome. Ordinary
  `Link` controls need the same treatment unless their label already has a
  button surface or a navigation icon. Linked `DockMetadataPill` values include
  an underline and `navigationIcon` (external arrow or internal chevron);
  static metadata has neither.
- `.dockHover` is only for labels that already communicate interaction: rows
  with navigation cues, tabs, icon actions, and chevron disclosures. Never use
  `.plain`, `.borderless`, or `.dockHover` for a standalone text action. A
  tooltip, pointer change, or hover-only color/outline is not a resting cue.
- Menu toggle labels use the normal leading row inset, with a visible checked
  or unchecked box at the trailing edge. Do not reserve a blank leading gutter
  for an invisible checkmark.
- Secondary and compact action outlines remain visible in every skin,
  including Glass and open chrome. Keep disabled outlines and labels visible
  with reduced emphasis. Text labels use at least 12pt; pending feedback stays
  in the same control. Preserve keyboard activation and native focus indication.
- Action labels use `DockTypography.control` (12pt medium) and themed text. Primary
  actions use `dockPrimaryText` over the canvas with a 14% accent tint,
  increasing to 24% on hover and 30% while pressed, with an accent contour. In
  Glass they are accent-tinted interactive glass (like `.glassProminent`) with
  `dockOnAccentText` labels; secondary actions are plain interactive glass.
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
text, no pills or icons that only decorate, underlined "show more" links, no
divider under title rows, and accent color reserved for links, focus, and live
status. A skin may change color, shape, outline, shadow, texture, type design,
and selection treatment through `DockThemeStyle` and the palette; it may not
add, remove, or reorder structure. The **Clean** skin is that skeleton with no
dressing: borderless soft-gray cards on white, tinted sidebar, neutral user
bubbles.

**Skin identities.** Each skin has a short material signature in the gallery.
Glass is native Liquid Glass with a neutral graphite tint (it absorbed the old macOS skin); Clean is porcelain.
Hermes mirrors the Hermes desktop: GitHub Default neutrals, Nous blue, 4pt
square controls, and its etched filler art as a whisper backdrop
(`backdrop: .etching`, inverted in light); Ares uses oxblood and bronze;
Monochrome is a graphite ledger; Cool Blue is a steel blueprint; Warm Light
is cream stationery. Cartoon uses inked stickers; Terminal uses phosphor
scanlines; Brutalist uses a dotted print grid; Origami uses folded ivory;
Dusk uses plum and lavender; Retro uses silver desktop bevels. E-Ink is
high-contrast print; Swiss is an open red-accent editorial layout; Clay is
soft terracotta; Pixel is an indigo arcade; Notebook is ruled cream paper;
HUD uses cyan crosshairs; Storm uses Tokyo Night indigo with neon rain. These are centralized skin treatments, the
exception to the default flat chrome rules: patterns stay faint and static,
surface shadows stay local, and semantic status hues retain their meaning.

Navigation and tabs honor the skin's selection treatment (inverted ink,
underline, marker, bar, or tonal fill). Composers use the skin's panel radius,
outline and material details without changing their footprint. Patterned skins
use distinct static scanline, dot, rule, grid or crosshair backdrops; Clean,
Glass, E-Ink and Swiss keep their canvas clear. No decorative loops.

**Adding a theme (standard).** A theme is one `DockThemeID` case in
`DockTheme.swift`. The `title`, `detail`, `appearance`, `style`, `hermesSkinID`
and palette `roles` switches are exhaustive (no `default`), so the compiler
lists every place to fill in. Then:

1. Pick `appearance` honestly: `.system` only for themes with distinct light and
   dark palettes (`roles(_, dark:)`); native-material themes (Glass) must be `.system`.
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
for the Glass skin), so AppKit text, nested hosting views, menus, and sheets
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
- Rows are quiet: no border or surface at rest, including the current session,
  in both the side preview and top island; hover and composing use a `dockSurface4` fill. A one-line 12pt semibold title
  uses the full row width until Reply slides left into view on hover. Its slot
  collapses when hidden; composing, keyboard navigation, and VoiceOver keep it visible.
  The reveal takes 0.18s and snaps under Reduce Motion or motion-free themes.
  The title sits beside the status dot and trailing metadata. The next line is the 11pt
  status label, colored only for attention, then " · detail" in metadata text.
  Current sessions carry a quiet "Current" chip.
  The status label is "Needs your approval", "Needs your answer", "Working", or "Finished", or a more specific label such
  as "New response" or "2 background tasks running". The detail line is the
  running tool, the latest response excerpt, or the session preview. Trailing
  metadata is the time since the last update. Working cards pulse and show the
  shimmer. No percentage is ever implied.
- The open session appears only while it has live activity or an unseen
  completion. It leads its group and shows
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
  the preview with a taller conversation panel. Entering Quick message starts a
  new session, even when another chat is selected or busy; acknowledged sends keep
  that destination for follow-ups until the user chooses another destination.
  Each session row also has Reply, which opens a composer beneath that row
  and captures the session identity and profile. Command-Return submits either
  composer. Neither action changes the workspace selection. Reply drafts stay
  with their target session; a composing row stays visible through refreshes.
  A failed new-session submission retains its created session for retry. The workspace draft and attachments remain untouched. Pending
  and rejected sends stay in place; rejected text remains available for retry.
  Busy chats and offline state explain why sending is unavailable.
- Quick message hides the Tasks/Quota tabs, Quiet, refresh, activity banners, and
  Open Herm footer while its standalone composer is visible. A quiet destination
  picker and icon-only Close action are the only header controls. The composer
  anchors to the bottom of a 560pt panel (plus the top island's camera clearance).
  Above it, `ConversationTranscriptView` renders Hermes-owned sent messages,
  streamed replies, activity, approval/clarification controls, and message actions.
  A disposable `DockModel` shares the gateway's event router and existing session
  resume/history path; workspace selection and drafts remain separate. Changing
  destinations or closing detaches the projection. Failed history reads show the
  existing chat error and a Reload conversation action without resending.
- Quick message and inline reply reuse the session composer's native growing
  editor, input surface, attachment control, and circular send treatment, including
  theme-specific line and shaped variants. Return and Command-Return send;
  Shift-Return inserts a newline. Attachments scroll inside the input surface.
  The + menu contains files, paste, capture, saved drafts when available, and
  discard; interrupted sends also expose review and retry. Project choices appear
  only for a new session, with a directory reset only when a project has been chosen.
- Inline quick reply uses the task row as its only title. Destination stays tied
  to that row's captured session. Low quota uses one quiet provider/allowance line,
  with sending availability and freshness in its tooltip and accessibility hint.
  Actual preparation, errors, and unavailable states use the feedback area; the
  send shortcut stays in the Send tooltip. Draft errors remain visible and prevent
  sending. The replying task row yields keyboard focus and its selection outline
  to the composer.
- Explicitly entering the composer gives the panel keyboard focus and prevents
  pointer-exit dismissal and automatic announcements from interrupting typing.
  Close or Escape leaves standalone composition; the row reply toggle closes inline
  replies. The separate draft survives preview collapse and restart in a dedicated
  QuickDraftStore file. Destination, attachments, paste, and draft recovery stay in
  the existing composer. The
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
errors show only on their own tab. Capabilities loads inventories on first visiting each tab; successful inventories are reused until explicit Refresh or a profile change. Counts remain absent until their inventory has loaded. Page Refresh reads only its selected tab, and plugin mutations refresh only the plugin inventory (and an already-open catalog after install/remove). Plugin changes invalidate the other tab inventories so the next visit reloads their authoritative state. The profile picker uses the profile-only roster without plugin or live-session probes. Catalog sorting and normalized search text are indexed only when catalog, installed plugins or star counts change. Empty catalogs are valid loaded results, concurrent catalog reads coalesce, and cancellation discards responses. Optional GitHub stars do not keep the catalog loading and are attempted once per page; catalogs without GitHub repositories skip that work. Quick-view details show installed plugin version, source, runtime status, catalog version and pinned revision when supplied; toolset configuration and counts; connector policy, connection and account count; MCP enabled state, transport and required key names; and skill identity and profile alongside its preview. Missing version fields are omitted.
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

The footer shows the last-updated time and a compact Open Quota button (`.dockCompact`), which routes to the
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
reopening the office and app relaunch. New idle bots randomly choose among
uncrowded activity spots. Coordinates are checkpointed every ten seconds and
on leaving Office; no task content is persisted. Working bots go to the computer their reported location
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
in both appearances. The Glass skin follows the system appearance. Changing the theme
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
- **Toolbar (bottom center):** show bots, show roster, the task board and
  camera reset, with 44pt targets and a selected state for the open board.

The HUD shows only projected Kanban and session state. It has no
fabricated stats, percentages or resource meters. Narrow containers hide the
roster. Status chips scroll horizontally when needed; opening an inspector
hides the roster when both panels would crowd the scene.

### Navigation sidebar

The bottom connection indicator opens a quick-action popover in every connection
state. Show Herm's backend connection separately from the local default-profile
messaging gateway. Reuse General's gateway status, refresh, confirmed restart,
pending, and unavailable states; offer Reconnect when the backend is offline.
Keep the indicator's dot tied to backend connectivity.

The sidebar is the reference implementation of the navigation patterns in
the design system; other panes copy it rather than restyle it.

The desktop panes default to 25% conversation list, 40% conversation, and 35%
inspector, excluding the fixed navigation rail. Minimum readable widths take
priority in smaller windows; dividers remain adjustable.
The desktop conversation list keeps its 300pt minimum while resizing; the
workspace takes the remaining width when both pane minimums cannot fit.
Section headings stay on one line and truncate rather than wrapping vertically.
The floating desktop shell keeps the conversation and inspector side by side
when the inspector opens, using a 360pt conversation minimum (520pt in
fullscreen). Expanding the inspector must not replace the conversation.
Only the narrow single-workspace layout switches between those panes.

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
Show more/Show recent expansion. Right-click the Recents header for Mark all as read,
which updates seen timestamps and clears unread flags for all loaded conversations in that
bot’s Recents, including rows under Show more. Disable it when no completed
conversation is unread; preserve working, approval, clarification, and failure states.
Each session is a 50pt two-line row. The
second line may combine relative time, an inline repository identity, and a
single-line preview; missing values do not leave separators behind. Repository
identity is inline metadata rather than a capsule so the list remains calm at
narrow sidebar widths. The Pinned section remains a separate presentation.

Session activity uses `session.active_list`, not the REST index’s recent-write
flag. The visible sidebar refreshes activity every ten seconds for the selected
profile, including unopened Bot sessions and pins. Successful live snapshots
replace prior working flags so missed completion events cannot leave a spinner
running indefinitely. Stream events arriving during a read take precedence;
unavailable live reads retain the last observed activity.

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
Startup restoration selects from the shared session index and awaits any in-flight
list load. It never publishes a partial list over the sidebar's loaded snapshot.
An explicit refresh can supersede an older background poll after a session mutation.

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
state and is not persisted. Skin changes preserve the mounted surface and its
selected category, including Appearance, while updating colors and native controls.
At 760pt and wider, a 184pt rail of `DockNavRow`s
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
  The theme gallery uses adaptive columns with a 224pt minimum card width;
  specimen avatar spacing compresses to keep previews within their cards.
  Notifications contains completion and repository alerts. Updates contains
  both app and agent updates, plus Hermes update behavior. Files & terminal
  keeps the working directory, execution backend, shell, and file access together.
  Panel and window share one agent updater. Its owner-scoped phase affects only
  ambient rail and companion activity, never session tasks or announcements.
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
  invented activity or metrics. Each specimen also shows four sample Herm
  Faces (idle, tool, needs approval, done) drawn in that skin, so tone,
  outline and badge colors are previewed before switching. The selected tile gets an accent stroke and
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

The Automation destination uses a full-height schedule list, a selected schedule
workspace, and a resizable run inspector at wide widths. The list collapses to a
picker when the workspace beside the inspector is narrow or through the sidebar toggle. Inset rows show the name,
humanized cadence, labelled last outcome, and next run. Selection uses the theme's
accent fill and leading marker; two-line titles remain readable and rows are keyboard-accessible buttons. Search filters by
name or job ID and shows an explicit no-matches state.

The selected schedule header carries Active, Overdue, or Paused, cadence and
the name, and one compact action row for Edit, Run now, and More. The labelled
Run output control belongs beside History and Details, where it opens or hides
the inspector; it never floats among schedule mutations. Operation
feedback occupies a fixed single-line slot with the full error in its tooltip.
A flat, hairline-separated summary band shows Next run, Last run, and success among confirmed
outcomes. Summary values use 12pt medium text, with sentence-case metadata labels.
Violet `DockCategoryTone.automation` identifies scheduling context; green, amber, and red
retain their success, warning, and failure meanings. Unconfirmed outcomes stay
neutral and are excluded from success percentages. These colors resolve through
the existing palette, including neutral variants in Monochrome and E-Ink.

History and Details tabs sit below the summary. History has a loaded-run count,
labelled outcomes, and rows that open the run inspector; a finished run
without a reported outcome stays neutral. Details includes the request, cadence,
configuration, identifiers, and reported errors. At narrow widths the run
inspector replaces the workspace and offers a back action. Loading, empty,
unavailable, and stale states remain within their content regions. Inventory
errors and overdue counts use the existing page subtitle so updates do not move
the content.

The schedule title leads the detail pane, with cadence and actions on separate rows.
Run output precedes a collapsed technical-details disclosure. The inspector uses a
12pt semibold title, a quiet timestamp, and compact Copy/Close actions. Script
previews use selectable 12pt regular text so log separators cannot become oversized
Markdown headings; full agent reports retain the shared Markdown renderer at a
12pt body size. History freshness stays in its header slot. List and history titles
use 12pt medium; selection is conveyed by the surface and leading marker.

Creation and editing use matching native sheets with schedule explanations, delivery, working directory, and
model/provider overrides. Editing loads the complete Hermes job before saving.
Run now, Pause, Resume, and Remove preserve their confirmation and capability
gates. Pause and Resume use the authoritative profile-scoped mutation path.
Per-job history uses Hermes-returned session identities and script-output
previews; reports stay attached to their owning job and profile.

### Session inspector

Chat attachment **Open diff** opens a dedicated, closable Diff tab in the session
inspector with read-only staged and working-tree changes from the attachment's own
worktree. Source Control keeps its inline file previews. Both reuse `SharedDiffView`;
long lines wrap by default in unified and split layouts without horizontal scrolling.
Keep **Open preview** available for the file itself. Opening a diff does not rebind
the session's project; closing the tab clears its transient attachment selection.
These are current Git changes, not a response-specific patch.

The session inspector uses one compact text switcher for Timeline, Terminal,
Explorer, Source Control, and Browser. They share the canvas, 12pt typography, and 12pt
side insets. Explorer starts with the repository and filter, without a repeated
page label. Secondary tree actions live in its options menu. Changes prioritizes
branch and staged/unstaged files; GitHub account and PR management remain in the
full repository workspace. Missing projects use a compact top-aligned message.

Timeline (formerly Trace) replaces the session Activity Overview / History interface. It opens a native
execution waterfall on All activity (loaded requests stacked, idle gaps collapsed to
2s); the request menu selects one request or Follow current turn. The page header holds
only that menu and Expand. Subagents and Steps are collapsible `DockSectionHeader`
sections, each in a shared `dockCard` with 8pt padding and 12pt between sections
(content style, with 14pt semibold titles and 12pt counts); the Steps header carries the step controls:
search (⌘F focuses, Esc clears), Fit, and a Live toggle (compact button
with a success-colored dot when on). Live defaults on, keeps the last waterfall
row (bottom-anchored) and the playhead in view, and turns off on any user wheel or trackpad
scroll inside the list (momentum ignored). In the inspector the step list is capped at 360pt and the selected step's detail docks below it, filling the
remaining height instead of floating; an Expand icon button presents the uncapped
timeline in a `DockExpandedPage` through the expanded-review router (sheet fallback
below 800pt), whose Close button and Esc return. Both views read the same projection. A fixed metrics
strip follows: Duration, Model calls, Tool calls, Delegates and Tokens when reported,
and Errors (destructive tint only when nonzero). Step labels stay fixed beside a
horizontally scrolling timeline with a shared ruler; one vertical scroll keeps the
tree and bars aligned. Ruler ticks use readable minute-and-second labels (for example,
`2 mins 43 secs`), omitting zero seconds at whole minutes and leaving room between labels.
Delegates disclose their tool calls.
Bars outside the horizontal viewport show a compact directional timing button at
the corresponding edge. Selecting a step pauses Live and reveals its bar without
changing the time scale; Fit resets the native horizontal offset. Row drawing is
clipped to the visible plot, and horizontal navigation updates nearby bars without
rebuilding labels.
The longest finished step carries an amber Slowest badge when there is more than one. Selecting a label or bar
reveals a lower detail area in compact panes and a 380×340 floating card in wide, tall
panes: icon, title with owner/context subtitle, status pill, a metric grid (duration,
start, tokens, model calls, timing quality), then Input/Goal, Result/Summary, and Diff
rendered through `MarkdownMessageView`. Tool payloads are fenced (patches as diff);
delegate prose renders as Markdown. The footer holds replay play/pause, restart,
speed (0.5–4×), the coverage slot, and the legend. Unnamed delegates are titled by
their goal's first line. A Subagents section sits between the metrics strip and the steps, with the
replay footer directly under the waterfall (header with disclosure caret and count, collapsible, hairline dividers, up to 240pt then scrolling). With no delegates it
shows a 12pt "No subagents" empty state; otherwise one card per delegate (Agent 1,
Agent 2, … unless Hermes names it): model, step count, live duration, status, its task,
and either its latest reported activity with a spinner while running or the first line
of its summary. Selecting a card opens the same detail card, which adds a "Now"
section while the delegate runs. Delegates
without a reported start are placed by their start event, then completion. Rows
show an open-conversation icon when the child session is available. Restored tool
steps carry only Hermes' result timestamp, so they sit at that instant and read
"Finished"; live thinking and compaction rows are timed as observed.

Performance: Timeline subscribes only to execution-relevant publishers and coalesces
updates at 250ms. Its parent equality boundary excludes unrelated workspace refreshes.
Completed history is projected once per message revision; live tool updates reuse
that projection. Fixed-height labels and bars share one native vertical viewport
and mount nearby rows with a viewport of buffer, preserving the full scroll extent.
VoiceOver, Switch Control, and full keyboard access retain the complete row hierarchy.
The grid and ruler draw only the visible region. Clock bounds are prepared once per
projection; the 10Hz clock updates duration, ruler, nearby bars, and a running step's
detail metrics, never step labels, static counts, or Markdown. Native horizontal
scroll keeps the ruler and grid aligned. Hidden timelines cancel their subscriptions
and scheduled projection work; returning reads the current canonical state.

Step icons reuse `TurnActivityView.icon(for:)` and file-type icons from the chat.
Tool bars and icon tiles take a DockAccentColor per chat icon family (terminal teal,
edits orange, reads blue, search cyan, and so on); unknown tools use a stable identity
hue, never coral, which is reserved for failures. Derived model spans use the owner's
hue, delegates their identity hue, and the request root a neutral hatch.
The trace uses stable worker colors from DockAccentColor, hatched parent intervals,
34pt rows, and shared 12pt text roles. Failed steps carry an explicit failure mark;
finished tools do not imply success. Live bars grow with measured elapsed time,
disclosures and details use 200ms Herm easing, and Live scrolls with 350ms
easing. Reduce Motion and motion-free skins disable interpolation and transitions;
time readings still update. Timers stop when the trace is unmounted or settled.

Execution projection coalesces at 250ms, ignores reply-text changes, and merges live
and loaded calls by ID. Search waits 150ms and preserves matching ancestors. Timeline
stays scoped to backend/profile/session; saved Activity and Trace tab references
migrate to Timeline, including closed and recently closed tabs. The removed inspector's Kanban
polling and Bot refresh tasks are not retained.

Closing an inspector tab stops its work, not just its view: Terminal closes its shells
(confirming a running command), Browser stops the agent's Chrome and blanks its page,
and Timeline, Files, Source Control and GitHub unmount and cancel their tasks. Timeline
also pauses while the inspector is collapsed or covered by another tab.

Measured tool duration takes priority over receive-time subtraction. Positions from
local event receipt are labelled observed; restored/replayed records without usable
timestamps remain inspectable with timing unavailable. The footer identifies partial
coverage or disconnected state within a fixed slot. No exact LLM-call spans, per-step
billing, inferred success, or durable trace archive is claimed. Chat and global
Activity retain their existing presentation and controls.

Chat retains the established `TurnActivityView`: live tool steps, `SignalTrace`,
stable duration text with separate animated live-work decoration, and a compact expandable completed summary. Running and completed tool durations align at the trailing end of their rows. Generated
reply content must not replace or restyle this activity presentation.

### Generated replies

Generative UI is included in normal builds and tests. Settings → Appearance has one
Generative UI toggle, on by default. Changes apply immediately: disabling closes any
active HTML view, requests ordinary replies, and projects saved visual replies as
readable text. Canonical Hermes records remain unchanged. All host hooks continue
through `GenerativeUIIntegration`; the feature owns parsing, form state, and HTML
lifecycle. Legacy rendering instructions remain hidden only in presentation.

When enabled, prompt context directs Hermes to use visual replies whenever interaction
or structure helps, without requiring the user to name Herm UI or HTML. Calculators,
simulations, and interactive graphics request complete offline HTML with inputs wired
to update results immediately. Simple answers remain Markdown, and explicit requests
for plain text, source code, or project/file changes retain their requested deliverable.

Hermes owns execution and transcripts; there is no additional workflow engine
or operational store. Rendering instructions travel through
existing prompt submissions and remain hidden from the visible conversation.
Protocol-owned answers and runtime-owned voice keep their existing contracts.
Generated forms use existing destination-validated submission handling without
adding rendering context or replacing the workspace composer.

Generated surfaces use one themed container with a wrapping 12pt semibold title,
16pt insets, restrained separators, and visible Expand. A compact actions menu owns
source inspection, readable copying, Export, Save/Unsave, Reset inputs, Revise, and
composer-context actions. Source opens expanded within its existing padded panel.
Native expansion uses DockExpandedPage and the shared expanded router/sheet fallback.
Sections stack below 640pt; explicitly paired sections use columns at wider sizes.
Tables retain source order until sorted and expose filters above ten rows. Numbers
align trailing. Dataset charts share row selection with their table and show exact
selected values. Source, assumptions, fictional labels, and observation times come
only from supplied metadata. Graph nodes remain keyboard-selectable; tree expansion
and image-comparison position/zoom use the shared native presentation state.

Session Artifacts is a closable/reopenable inspector tab beside Explorer and Terminal,
not a new top-level session mode. It scopes the existing Artifacts browser to one
profile/session; the global library spans accessible sessions. Interactive and Saved
filters join the existing resource filters. Latest explicitly linked revisions occupy
one list entry, with prior versions and comparison in detail. Missing saved sources
retain an unavailable entry and removable reference. Refresh remains in the header;
new outputs never steal the selected tab or move transcript content.

Connected record cards resolve existing PR/issue, Kanban, Calendar automation/task,
usage, and session-trace projections. Their navigation opens established Herm pages,
where permissions, confirmations, mutations, and pending state remain authoritative.
Unavailable records are labelled unavailable. Generated labels never establish live
status or an action permission. Mac calendar items remain owned by the Calendar page;
CI reruns, deployment control, and network capture are not advertised integrations.

Native surfaces use the current Dock canvas, surface, typography, border and
action tokens. Tables scroll within bounded containers; charts use Apple Charts
and the theme accent; gallery images do not fetch arbitrary remote resources
on display. Forms reuse native Dock controls and destination-validated drafts.
Generated content cannot declare verified Herm records, approvals, credentials,
or direct tool actions. Source inspection is explicit. Expanded source uses a
bounded, padded panel with a theme-aware surface and border; its top-right Copy
source action stays above the scrollable, selectable monospaced content. Plain-text projections
serve copy, search, speech, and Result Peek. Existing runtime-owned export
contracts remain unchanged; host text projections use `GenerativeUIIntegration`.

Version-1 replies remain supported. Version-2 payloads use typed components, shared
datasets, stable item IDs, and optional explicit revision references. The feature
registry supplies the generation catalog; unavailable connected features are omitted.
Only complete, validated surfaces render. Limits are 1 MiB per surface, 100
blocks, and 1,000 table rows or chart points per block. Unsupported or malformed
content retains a readable fallback. Partial streamed JSON and HTML never run.
Table cells accept JSON strings and numbers; numbers become display text only in
the presentation decoder. Invalid surfaces show “Visual reply unavailable” above
their readable fallback and source disclosure. Canonical reply source is preserved.

HTML uses a native fallback card and explicit “Open interactive view” action.
Its separate nonpersistent WebKit host embeds the document in an opaque-origin
sandbox with scripts enabled, restrictive CSP, blocked resources and navigation,
and no action bridge. It exposes no tools, credentials, session browser state,
network, filesystem, downloads, popups or device permission access. Native Close
and Reload remain outside authored content; process failure retains recovery
and fallback. Only one preview may run. The same WebKit host transfers between inline, artifact,
and expanded containers and returns to the previous container on close. Explicit
Close, disabling Generative UI, and session/profile changes destroy that host.
Native drafts and selection are bounded local presentation preferences keyed by
source reference and digest; they do not duplicate transcripts or provider records.
Saving a tool stores its original reply reference. Export is an explicit user file.
HTML DOM/input state is never persisted.
Theme variables and reduced-motion defaults are injected into the saved document;
changing themes reloads an open HTML preview. Authored styles may customize the
interactive content itself. See `docs/generative-ui.md` for isolation and removal.

#### Generated card motion

A generated card is one stable interactive surface. Its main visual, selection,
details, and actions belong to the same state. A map may coordinate its camera,
selected marker, route, and place detail; a PR card may coordinate its graph,
checks, and recovery action. Keep explanatory assistant prose outside the card.

Use the existing `dockEase` curve. Small control and detail transitions take
0.16–0.22s. Spatial transitions such as moving a map camera or tracing a route
may take 0.35–0.5s so the relationship remains legible. Respond to input at once;
animation must never gate a control, an authoritative update, or a result.
Preserve stable identities and animate changes in place. Avoid rebuilding or
replaying an entire card when one value changes.

Coordinate related motion from one selected item or confirmed revision. Rapid
input interrupts the current transition and moves toward the newest state;
do not queue transitions or use artificial waiting and staggered step reveals.
Keep the card's surrounding layout and transcript anchor stable. No continuous
camera drift, attention pulses, or entrance replay on unrelated streamed tokens.

Reduce Motion and motion-free themes make camera, route, and layout changes
immediate and stop decorative loops. Keep selection, focus, loading feedback,
and all actions readable in that state. Keyboard selection must use the same
state transition as pointer selection, with focus retained on the initiating
control. Colors and materials follow the active Dock theme.

Review a short interaction recording before enabling a new card: first display,
place/item switching, rapid reversal, pending/error recovery, keyboard focus,
and Reduce Motion. Check narrow/wide layouts and Light/Dark, Glass, and
monochrome themes. Map cards require a supported source for actual places,
routes, images, and locations; the offline HTML host does not gain network or
device privileges for them. The map motion study in `docs/previews/` is an
illustrative design fixture, not a connected map implementation.

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

Description formatting belongs inside the lazy card view so opening or refreshing
a large board does not process offscreen task bodies. Card comparisons include
only their own selection, pending actions, drag state, and displayed activity age;
updates to another card must not rebuild unchanged card content or menus.

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
hide/unhide remain in More and the native context menu. Delete Bot… is a
destructive, capability-gated action in both menus, with explicit confirmation
listing the profile data and active sessions affected. The default profile is
protected. Pending deletion uses the existing More slot; failures show a safe
diagnostic and the roster refreshes from Hermes. Focus and hover use one
quiet surface treatment, and the 44pt More target does not change card layout.
Routines retain their own focused list with assigned Bot names, schedules,
disabled state, and confirmed removal. This page uses the global Herm tokens and
is independent of the sidebar brand-concept preference. Groups, sections,
cross-machine routing and richer routine actions require
additional Hermes gateway contracts and are not presented as available Herm
controls yet.

The composer’s bot picker shows display names, such as Nexus, while retaining
canonical profile IDs for selection and delivery.

Recognized bot mentions show their pill and body inside the sent bubble on the
first layout, whether selected from the picker or typed manually. History uses
the current bot roster to recognize mentions. Unknown handles and mentions inside
code or links stay plain. Draft restoration and queue editing retain explicit
selections; deleting a handle clears its selection. Native text measurement must
preserve the displayed wrapping width and leave frame sizing to SwiftUI.

Single-bot mentions eligible for direct delivery, including mentions after words
such as “hey”, submit a user turn to the recipient’s profile-scoped canonical Bot
Chat. Confirm its session and profile before sending; a busy or unconfirmed
recipient fails visibly. Only the confirmed recipient’s stream supplies its reply
in the originating conversation, without navigating away from it. Queued mentions
retain the recipient selected at submission and cannot steer the current bot.
Unsupported selected-bot payloads keep the draft and explain the text-only,
single-recipient requirement, including in Bot Chats.

Native typing supersedes queued completion caret moves in the shared composer,
including Forward to Bot. Redraws must not restore a selection from before the edit.

**Herm Faces.** Bots without uploaded art draw a seeded face (`HermFace.swift`)
in a 100-unit box: one of five bodies, ten hue palettes, four eye styles and a
±7° lean, all from the profile ID. Each `BotMood` maps to something Hermes or
Herm actually knows: tool (busy or `working`), clarify (`waiting`), queued,
done, failed, stopped (canceled), voice listening/thinking/replying, sleepy
(hidden) and happy (hover). Live session asks override the busy face through
`BotMood(ask:compacting:)`: approval, then clarify (sidebar Bot rows, notch
rows, the streaming reply), then compressing while Hermes compacts the open
session. Effects use theme tokens only: accent rings, dots
and waves for activity; warning, destructive, success and metadata badges for
outcomes. Badge glyphs drop below 24pt. Live face canvases observe the shared theme store and redraw on skin changes;
gallery faces retain their explicit preview skin. Skins set the tone (hue; gray on E-Ink
and Monochrome; accent on Terminal and HUD) and ink outlines (Cartoon,
Brutalist, E-Ink). Gloss (sheen, rim light, highlight, sparkle) is drawn
only on Glass and Clay; every other skin, and the saved PNG, is matte. Only moving states run a clock, gated by Reduce Motion,
`animates`, and app focus. The PNG saved to Hermes is the still, skin-neutral
idle face; Regenerate All re-renders it for every Bot. Glossy Herm faces saved by older builds are recognized alongside the matte
PNG. The legacy blob renderer stays only to recognize older saves. Group chat stacks place faces
side by side with no cut-out border.

### Conversation workspace

The conversation workspace uses a stable cool-navy canvas in both fullscreen
and compact layouts, independent of the sidebar concept selector. Its header
is a single flat row.
The session identity gets the flexible header width and may wrap to two lines.
Chat, Talk, and repository PRs use visible 12pt text labels in one compact
32pt outlined track. The selected segment is 28pt high inside a 44pt click
target; hit-target size must not inflate the visible tab. Unselected tabs have
no individual button surfaces. Selection uses the skin’s treatment, a semibold
label, and a persistent underline, including in monochrome and without hover.
The actions menu holds session actions. Voice is directly
available from 520pt chat width; the inspector toggle remains direct from
340pt and moves into the view menu below that. All destinations remain available
at every width. Controls retain 44pt targets and resizing does not animate.
The transcript mounts a bounded window of messages and pages earlier or later
history automatically as the reader scrolls within one viewport of either edge.
History pages reveal eight messages in either direction. The initial window stays
at 12 messages and the normal mounting backstop stays at 36; a larger visible span
is protected from eviction.
There are no show-more buttons, and the reader's position is held while a page
mounts. Page anchors track reader movement during layout and repair native origin clamps;
programmatic corrections and resize events do not trigger edge paging. One session-scoped
coordinator owns mounting, anchors, navigation, and deferred scroll work. A page remains
pending until its session, generation, range, and anchor match the measured row batch;
settling alone never completes it. Session changes and explicit navigation cancel stale work. Each message owns one geometry container around its activity and body; hidden messages still report a zero-height row, so complete page batches remain measurable.
Scrolling upward immediately suspends streaming follow until the reader
returns to the bottom or chooses Jump to latest. Streamed output, new blocking
prompts, and same-session transcript refreshes preserve the reader's position
above the bottom. While following, content-height changes target the measured
footer after layout without a second streaming timer. Jump to latest animates
only when Reduce Motion is off.

Transcript snapshots include live activity only while its streaming row is mounted,
and bot-step inputs are scoped to the selected conversation’s dispatches and mentions.
The canonical stream and activity continue accumulating while browsing history;
returning to the live reply presents the current state without replaying UI updates.
The jump-to-message rail sits on the left edge of wide conversations, with hover
previews opening inward to its right. Find opens at the same left edge.
The message navigator reuses its immutable history projection across activity and
scroll refreshes; offscreen edits and stored-history changes still update search
and navigation. Ordinary Markdown chunks do not restart visual-reply parsing tasks.
Find matches full message text away from the main thread. Query edits, history
changes, closing Find, and session changes cancel obsolete matching; stale results
cannot be selected. Return reuses matching results or waits for the current query,
and the existing result slot shows progress while matching is pending.

Completed assistant replies use the section renderer at every length, including
replies over 8 KB. Long native Markdown documents retain their full measured height while mounting
only visible sections and one viewport of buffer. Adjacent completed pages prefetch pure
Markdown sections away from the main actor, with immediate synchronous rendering on a miss.
A bounded 4,000-entry memory cache reuses numeric completed-section heights by exact
source, kind, width, body style, theme identity/revision, and mention revision. Streaming
measurements remain local. Reusable text and code views
measure sections before their display views are created, so cold history pages
do not construct a text view for every offscreen paragraph. Scrolling remounts the same
section views without reparsing their content. Focused text remains mounted so
selection and Copy survive scrolling; VoiceOver, Switch Control, and full
keyboard access retain the complete section hierarchy.
Text selection stays within a Markdown section; the message's Copy action copies
the entire reply.

Long live Markdown replies retain the stable prefix of their section projection
and classify only changed chunks. Native rendering uses the existing canonical
stream text rather than joining the full chunk history for each update. Exact
source/context checks invalidate reused chunk identities across stream replacement;
theme changes restyle sections without reclassifying unchanged source. Activity rows
receive only their own dispatches and bot steps, so another message’s bot updates
do not rebuild completed activity. Centered bot dispatch rows keep 8pt of outer
vertical padding in both collapsed and expanded states, separating their pills
from adjacent activity data.

While the reader manually scrolls, a long live reply keeps its current Markdown
layout. Incoming chunks continue accumulating in the existing streaming state;
the native renderer applies the latest chunks once the clip view has been still
for 80ms. Programmatic following and history-anchor corrections do not start
this pause. A newly mounted live reply always renders its first snapshot.

Website links in native Markdown keep their underlined accent labels and a
fixed-size inline site icon. GitHub uses the bundled theme-aware mark; other
public websites load their HTTPS origin's `/favicon.ico` without cookies or
redirects and retain a theme-aware globe when unavailable. Custom labels are
preserved; bare GitHub PR and issue URLs may use `PR #123` and `Issue #123`.
Icon loading changes neither the text layout nor the link destination.

Assistant responses are open document content; user prompts use
restrained right-aligned navy bubbles with a tighter sender-side corner, and a
steering prompt's status sits in sentence case beside its timestamp. Fenced
code blocks carry a quiet header with the lowercase language and a Copy action.
Completed assistant
responses keep a compact action rail permanently visible beneath the content.
The rail uses tightly grouped 28pt controls and subdued monospaced metadata,
without a divider before the hover-revealed timestamp. Hover and keyboard focus strengthen the control surface but
never reveal or hide actions. The composer is one centered floating surface with
the editor, attachments, model, reasoning, and send controls kept together.
Attach, model, and reasoning are 28pt control-surface chips inside 44pt
targets. It is aligned to the reading column, stays at a compact two-row idle height,
and grows only for multiline drafts, attachments, suggestions, or actionable
errors. Files, Images, and Folder share one native picker presentation, configured for
the selected action. Files and composer drops accept generic files up to 8 MB as
removable context chips, using the existing protected file upload on send.
Context attachments use one removable tray chip per source. Attaching or refreshing
context never inserts a second chip into the text editor. Restored inline context
references move into the tray while preserving their payload and the surrounding
draft text; repeated sources keep the latest context.
Pasted file URLs take precedence over clipboard icon bitmaps and use the same
attachment path as picked or dropped files; ordinary image pastes keep thumbnails.
Folder selection inserts its path into the draft.
Unsent text, images, PDFs, context chips, reply quotes, and attachment errors stay
with their profile and session while Herm is open. Navigation restores that
session's draft without sending it or deleting temporary images. New-chat drafts
are scoped to the profile and chosen project until Hermes creates the session.
Sending, queueing, or removing content updates the active draft; returning later
must never resurrect consumed input. Drafts are in memory and clear on quit.
Draft snapshots are taken only during navigation, without per-keystroke archive
work or file reads. Restore publishes the final editor text once and leaves
unchanged attachment fields alone; snapshots reuse existing text and image storage.
When the current conversation has queued input, subsequent composer sends join
the queue in order; plain text must not redirect the live turn past queued messages.
Attach is icon-only; model and reasoning context remain available at
normal widths, while the send/steer action retains the strongest emphasis.
Streaming, approvals, clarifications, voice state, and errors may use semantic
surfaces when they represent an active decision or recovery path.
Voice submissions use the active session's profile. Pending replies and playback
retain ownership of the voice state until completion or interruption; late
recorder transcripts cannot reopen capture. A failed request pauses voice
with a transcript error and the existing tap-to-resume action.
Voice activation is bound to one session and ends on conversation changes or
leaving the voice stage. Local recognition starts after permission without
backend recorder checks. Hermes synthesizes the owning profile's reply audio;
Herm plays it locally and cancels pending synthesis/playback on exit. Backend
recording uses session-scoped controls. Process-wide speech toggles are never
used. Recognized words cannot be held indefinitely by background noise.
Voice keeps captions and labeled controls in a centered column, without floating
activity cards overlapping the conversation. Microphone startup and permission
errors occupy the existing status slot with Retry microphone. Muting releases
capture in every phase and rejects late speech callbacks. Speech that interrupts
local playback retains the same recognition request so opening words are kept;
a completed agent turn is not interrupted again just to stop its local audio.
Normal phrases settle after 0.8 seconds (1.2 without confirmed quiet); unfinished
phrases retain their longer hold. Quiet follow-ups wait 30 seconds before sleep.
Spoken captions use the exact plain-text segment sent to synthesis and change
only when that segment's audio starts. Show a preparation status while audio
loads. Center caption text without Markdown list indents or timer-based advance.
Dictation replaces its live partial transcript in the composer without sending,
duplicating words, or overwriting manual edits. Real recognition failures keep
recognized text and offer visible Retry and Dismiss actions. Clear old warnings
on retry or session change.
The welcome and voice orbs share the responding profile's live Herm face,
falling back to the selected or default Bot. Faces require an explicit enabled
`hermes-bots` status from `plugins.manage` and a ready roster. Disabled or
unconfirmed plugin status, uploaded art, and generated art keep the plain orb.
The welcome orb retains the same footprint and pointer reactions as voice,
including Reduce Motion support.
The running indicator uses the responding Bot's stored avatar or generated
face, falling back to the session profile and selected Bot for ordinary chats.
Its gentle hop and activity-driven gestures stop under Reduce Motion and motion-free themes.
Activity rows appear immediately; their insertion and the Bot's movement share
one short spring transition. Disclosure and completion transitions use the same
motion preference, with no delayed or queued row reveals.
Unavailable bot rosters use the ordinary activity glyph. An explicit disabled
`hermes-bots` runtime plugin status prevents roster loading. Desktop-only plugin
preferences require a gateway contract before Herm can mirror them. Custom avatar
assets take precedence over generated-face recognition and are never overwritten
by bulk avatar population.

The composer input sits in one tray (`dockSurface4`, composer radius, light
border) that also holds the task plan, background tasks, queued prompts and
reply quote above the input, and the session's folder and branch below it.
With none of these showing the input covers the tray; line skins draw no tray.
The folder bar is a 28pt metadata row; with more than one Git worktree it opens
the worktree chooser, which changes only what Explorer and Source Control show.
Session Explorer and Source Control therefore show no branch or worktree header.

The task plan above the composer keeps a compact progress ring, resolved-step
count, and current-step summary in a 44pt disclosure target. Expanded steps use
12pt wrapping text, a quiet fill on the current step, and distinct completed
and cancelled marks. Long plans scroll within a bounded area. Progress, count,
status marks, and disclosure use short `dockEase` transitions; Reduce Motion and
motion-free themes disable them. Only an active turn animates the current-step
indicator. Plan updates preserve disclosure; changing sessions resets it.

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
retains its existing grid/list and pagination presentation. Both read a paginated,
profile-aware index of unarchived sessions independently of the sidebar window, including
pre-compaction messages, assistant links, and producer/terminal outputs. Transcript
extraction runs off the main actor in bounded pages, with at most four concurrent
session reads. Completed sessions appear progressively; sidebar updates do not
cancel indexing. Opening the page or using Refresh starts a scan. Partial profile/index
failures keep readable results and prior outputs for unreadable sessions, with a warning
in the existing header subtitle. An in-memory cache reuses artifacts only while Hermes session
recency, message count, and display title agree; raw transcripts are not cached. Refresh
failures stay in the fixed header subtitle and preserve the last loaded output.

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
  It has a commit message input, Commit staged changes action,
  collapsible Staged Changes and Changes groups, and a commit Graph for that branch.
- Group titles carry a tinted lead icon, primary-text semibold title, and a count
  capsule (`DockSectionHeader` `icon:`/`tint:`): Staged uses success, Changes the
  modified tone, Graph the first lane accent.
- Staged Changes, Changes, and Graph contents have an additional 12pt leading
  inset beneath their headings, including empty, loading, and error states.
- File rows are single-line, 30pt rows with a file icon, name, secondary directory,
  a 20pt stage/unstage toggle shown on hover or keyboard focus (its slot stays
  reserved so rows never shift), and textual Git status.
- Rows and group headers carry VS Code–ordered context menus. Discard is
  working-tree only, always confirms, restores tracked files from the index,
  and moves untracked files to the Trash; conflicted and staged rows offer none.
- A collapsible Stash section uses the same header and 12pt content inset. Its
  add action opens a message field and Include untracked files toggle (on by
  default; ignored files stay untouched). Rows disclose a read-only diff and
  Apply, Pop, and Delete actions. Apply/Pop restore the index and worktree; Pop
  removes the selected stash only after successful restoration. Failures retain
  the stash and show an actionable error. All three actions confirm their scope;
  Delete warns that it cannot be undone in Herm. Git owns the list, shared across
  repository worktrees, and refresh failures show unavailable rather than empty.
- The Graph draws lanes from `RepositoryCommitGraphPalette` (approved
  `DockAccentColor` fills) in single-line 24pt rows. Each row's text starts right
  after its own lanes, so it nests with the branch structure. HEAD is a ring,
  merges a ring with a center dot; author, date, and hash live in the tooltip
  and expanded card. Ref pills are
  static (no underline) and tinted with their lane. An expanded commit shows a
  surface card with message body, email, parents, changed files with +/− counts,
  Copy hash, and Open on GitHub when a GitHub remote exists. Header icon actions
  fetch, pull (fast-forward only), and push; pull/push appear only with an upstream. Selecting a row opens its bounded,
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
  Global session tool labels use a dedicated publisher consumed by the edge dock;
  label changes must not invalidate the open conversation or workspace.
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
- Clickable text is recognizable before hover in light, dark, Glass, and
  monochrome skins; links are underlined, actions have a visible surface or
  outline, and static metadata cannot be mistaken for linked metadata.
- Every `TextField` uses `.textFieldStyle(.dockGlass)`; `grep -rn roundedBorder
  Sources` returns nothing.
- Navigation, group headers, and icon actions use `DockNavRow`,
  `DockSectionHeader`, and `DockIconButton` rather than one-off rows.
- Icons come from the Lucide catalog at their slot size, with no unmapped
  fallbacks.
- The README is updated when user-visible behavior changes.


### Pull requests and Issues metadata

Wide PR Summary layouts place a `dockBorderLight` vertical hairline midway through
the existing gap between the reading column and details sidebar. Stacked layouts omit it.

The PR detail panel follows the ChatGPT pull request reference: an open reading
canvas, a compact capsule tab strip (Summary, Changes with line totals, Reviews),
and a quiet action toolbar. Before wrapping, the header drops tab line totals and
uses compact icon actions. At phone-like widths, compact tabs and actions
form left-aligned rows, with actions wrapping further when needed. Watch, GitHub,
Refresh, More, and Merge remain
available. Line totals remain in the summary. Repository/number, status, title, author/freshness,
and base ← head branch direction sit above the content without an overview card.
At 840pt and wider, description and Activity occupy the reading column while a
280pt right column holds Changes, reviewers, checks, readiness, and metadata,
separated by hairlines. Narrow panes stack these sections. File categories are
available through the Changes disclosure. The shared metadata and breakdown views
support an embedded presentation; Issues retains its existing card treatment.
The Merge toolbar dropdown opens the shared landing controls in a popover,
retaining requirements, permissions, confirmations, expected-head checks, queue
state, and merged-branch cleanup. More contains Generate review guide, using the
existing separate-conversation flow with the default profile. A current guide
exposes Read review guide beside Reviews. Generation tooltips identify Hermes
Agent's bundled `github` skill and its code-review workflow. The request tells
Hermes to load the skill and `references/code-review.md`, report unavailability
instead of silently substituting a review, and keep analysis private without
checkout, file edits, or GitHub writes. Activity uses the shared individual event
surfaces. The comment editor and submit action occupy separate rows.

On the standalone Pull Requests page, a floating bottom-right panel is titled “Chat” and reuses `ConversationTranscriptView`
and `ChatComposerView` from session chat, including message bubbles, Markdown,
activity, reply actions, approvals, clarification, attachments, and send/stop controls.
Minimized chat is a compact Chat · #PR button, at most 200pt wide, with the transcript
and composer hidden. Clicking it opens the transcript and composer and focuses the
input. The header minimizes the entire panel; drafts and attachments stay in the
PR conversation model. Typing or sending expands it.
Minimized chat floats over the page without reserving a bottom strip; the page's
content viewport continues to the bottom edge. Only expanded chat reserves its
measured height plus outer gutters in Summary, Changes, and Reviews, keeping
content and scroll controls above the composer at every pane width.
Expansion respects Reduce Motion. Each PR has an independent presentation model over
Hermes-owned history. Herm saves only the PR-to-session reference (profile and stable
session ID), so reopening the PR after navigation or an app restart resumes the same
conversation rather than creating another one. A new conversation uses the explicit
`default` profile and the PR’s local project path when available. Every composer
submission includes current PR context. The selected workspace conversation and its
draft and attachments remain untouched. Open conversation navigates to the linked
session. Missing or unavailable history uses the standard session recovery behavior;
a failed resume never silently replaces the linked session.

Session PR inspector tabs, including expanded code review, omit the floating chat
and its reserved space. Their toolbar offers Attach to chat, staging current PR
context in the existing session composer without sending or replacing the draft.
Reattaching updates the existing chip. Compact toolbars use a labelled icon action.
The standalone Pull Requests page hides Attach to chat.

The Changes group classifies current loaded file paths, with mocks/fixtures
preceding tests, then docs/configuration/code/other. Totals lead the group, followed by compact rows with category, file count,
additions, and deletions. Binary files count even with zero line changes; renames
count once at the destination path. The totals explicitly label loaded files for incomplete/unknown coverage, with a
coverage explanation below the rows. Unverified revisions show unavailable or
loading text instead of presenting stale totals. Review files opens the Changes tab.
Blue denotes informational context, violet merged outcomes, amber pending or
blocked work; green/red remain line additions/deletions and success/failure.
Color always accompanies text. All skins resolve the shared semantic colors;
Monochrome and E-Ink preserve neutral tones.

Both modules use the existing Dock canvas, cards, disclosures, modal editor,
button styles, color tokens, and 12pt body typography. Metadata uses the same
Labels, Projects, Milestone, Assignees, and Development presentation in each
feature. An empty assignment, restricted access, loading, and a failed refresh
must be distinguishable. Provider permission failures retain the edit draft.

Readiness presents independent state/check/review/conflict facts. Successful
checks never conceal a draft or conflict. Conflict-file analysis is explicit and
labels the analyzed revisions. Landing controls confirm the item/head and show
requested, waiting, queued, failed, and merged results honestly. Description,
comment, review, and edit-preview Markdown use the chat's canonical native
rendering pipeline and follow the active theme.

Pull request filter labels stay on one line at their intrinsic width. When tabs
show merged history, the label is “Merged”. Session lists include repository-scoped
merged PRs from the last 14 days, independent of the signed-in user's involvement.
Merged-history failures keep open PRs visible with an unavailable message. When tabs
cannot fit, use the shared menu picker showing the selected filter. Session pull
request toolbars follow the Issues list layout: full-width search first, filters
and refresh below, 14pt horizontal gutters, 8pt row spacing, and a canvas background
with a bottom hairline. Use unmodified shared tab/menu controls without extra tracks
or outlines.

Pull request and issue headers expose Open on GitHub through their dedicated
external-link button only. The item actions menu keeps editing and Copy link
without duplicating the open action.

The Code toolbar exposes review actions through a 28pt ellipsis icon using
`DockMenu`, with “Review actions” help and accessibility text.

The Reviews tab separates thread browsing from the review composer with a quiet
divider. Thread filters wrap below the title in narrow panes. Loading, unavailable,
and empty thread messages share a stable content slot; empty threads explain where
to add line comments. The review type sits beside “Your review”. Write and Preview
share one bordered input surface, with a visible editor prompt, character limit,
and a trailing primary submit action. Empty preview explains that no text is present.

Assigned GitHub metadata uses `DockMetadataPill` and the shared `DockChipFlow`
layout. Pills wrap within the detail pane; empty, loading, and unavailable
messages remain plain text. Linked pills preserve their navigation actions.

The PR landing card lists known merge blockers beside the disabled action.
Use provider review decisions and named check results; when GitHub only reports
a generic blocked rule, say the exact requirement is unavailable and link to
GitHub. Do not send users to another card to explain a disabled merge action.

Pull request readiness, metadata, and count pills use regular-weight text.
Conflict emphasis comes from its warning color and wording, with regular body
weight. Keep the established emphasis for page, section, and PR titles.

GitHub activity and discussion rows show a 24pt circular provider avatar beside
the author when its URL is supplied. Reserve its size while loading, use the
existing user-icon fallback on failure, and keep the author name visible.

GitHub Details uses the same content-section header typography and leading alignment as Description, Checks, and Activity.

GitHub Details uses aligned label/value rows with a 104pt section-label column,
wrapping values, and trailing edit actions. Recovery text stays beside the
affected value. Landing method/actions wrap together; blockers use warning icons and regular-weight text
below the shared readiness divider. Header refresh uses the
shared 24pt icon control with its pending state in place.

Readiness uses a compact aligned 64pt label column. Freshness
occupies the header action slot. Show conflicts once in the Merge fact with a
warning icon and regular-weight text; recovery actions wrap below a divider.

`DockIconButton.size` is the final control footprint, including its surface.
Do not apply a padding-bearing button style around an already sized icon.
GitHub header icons and Attach to chat use 28pt height; section actions use
24pt. Match their neutral resting surfaces as well as glyph sizes.

GitHub state switches keep a reserved spinner slot beside Open/Closed/History.
Issues uses loading rows while a changed scope is fetching and a loading label
in the existing count/status slot. Keep prior results for recovery, and disable
the state selector during the active request.

PR actions must be supported by the current item state. Conflict analysis and
resolution belong only to open PRs with provider-confirmed conflicts; failed
checks and unknown mergeability are not conflicts. Omit the Readiness recovery
action row when it has no work to do. Closed PRs offer Reopen. Merged PRs show a compact success/remote-branch cleanup
card instead of merge controls. Status mutation requires provider-confirmed edit permission.
Empty check data is “No checks” only when coverage is available. Activity counts
come from the rendered timeline items, including reviews.

GitHub asynchronous actions show pending feedback inside their existing control:
28pt item-action menus, 24pt section refresh icons, and compact save/reply/resolve
buttons. Show the spinner only on the active action and disable conflicting
submissions until it finishes. Failed choice loads replace loading with Retry;
never leave a spinner running after an error. Preserve staged edits on failure.
Capture the confirmed request before dismissing a dialog. Apply provider write
results before background refreshes, and reject older reads that would undo them.

PR diff file rows contain the disclosure, file path/status, and change counts.
Do not add local Viewed switches or repeat a page-wide progress count per file.

Landing uses GitHub's merge state to enable merging. `UNSTABLE` is mergeable
with non-passing checks; show those checks as warnings, not inferred required
blockers. Keep provider-reported blocks, permissions, reviews, drafts, queues,
and expected-head checks. Use the compact method menu and a small primary merge
button; recovery links name checks or requirements according to the situation.

A confirmed merge updates shared PR state directly from the mutation response;
stale REST/search results cannot undo this terminal state. Keep the selected PR
detail visible after its open-list row disappears so branch cleanup is reachable.
Offer Delete branch only for a merged PR with an unchanged, non-default,
unprotected remote head and provider-confirmed deletion permission. Confirm the
repository, branch, and revision; compare-and-delete the remote ref, preserve
local worktrees, and keep a failed deletion separate from the successful merge.

PR Summary shows the description directly beneath the title/author using the
canonical Markdown view, without a card or a redundant Description heading. Optional Projects failures occupy one quiet value/Retry row;
keep diagnostic detail in help/accessibility text instead of a repeated orange
provider-error paragraph. Retain previously loaded memberships on refresh errors.

GitHub label pills use the repository-provided six-digit RGB color as their fill
in both item details and label editors. Keep the shared pill geometry and regular
text weight; choose black or white ink for maximum contrast. Invalid/missing
provider colors retain the neutral theme treatment. Other metadata stays neutral.


### Native review and local workflows

Shared diffs use the existing Dock canvas and code tokenizer. Newly opened files start at horizontal offset zero after the line-number gutter is laid out. File navigation remains
flat, with a 220–360pt expanded navigator and a compact picker in narrow contexts.
Split presentation falls back to unified below 680pt without changing the preference.
Full-width expanded review headers reserve the navigation rail plus traffic-light
clearance. File titles show the filename with its parent path as supporting text.
Diff toolbars use the standard Unified/Split tab treatment and 28pt shared
icon controls for wrapping, Find, context loading, and expansion. Wrap retains
an active tint and an accessible On/Off value; context loading uses an in-place
spinner. Every icon has a descriptive tooltip and accessibility label.
Long-line wrapping defaults to on in shared diffs, pull request reviews, and the
repository code editor. Keep the wrap controls available and honor saved preferences.
Unified/Split choices reflect the visible layout. Panes under 680pt and one-sided
diffs disable Split and
render a single full-width source pane. Escape closes the expanded file review.

Expanded review uses the existing workspace/modal treatment and restores the source
conversation. Read-only code has native selection, Find, and line-number gutters;
private revision notes are distinct from provider review comments. PR diffs expose
keyboard-accessible + actions in the line gutter. Selecting a line opens an in-file
review editor with captured source and an old/new line label; it stays available
in expanded file review. Saved comments remain private, editable drafts beside the
file and in Reviews until confirmed batch submission. Reviews leads with the
summary and Comment/Approve/Request changes choices, explains disabled submission,
and places thread history below authoring. Narrow PR headers wrap actions beneath
the tabs so navigation labels remain readable. Expanding local
context validates the captured comparison and never combines stale source silently.

Review guides are the single AI-review entry point. The PR header has no separate
Prepare review action; Attach to chat supports general conversation context, and
the guide provides Open review conversation for follow-up. Review guides are
explicit requests in a separate Hermes conversation. Generation
offers the visible reviewer roster only when Bots is enabled and current, with a
default-bot fallback. The guide opens immediately in a stable reading container;
its waiting state explains automatic refresh and provides conversation access.
Saved replies refresh while visible, retain prior content during empty/error
refreshes, and reset on profile/session changes. Body copy uses regular-weight
Markdown in a bounded reading column. Generated
explanations never become verification evidence. Source changes invalidate their
references. All review and comparison source stays bounded in memory; durable stores
hold only user drafts or presentation references.

Terminals are owned by the session-scoped terminal workspace store, not SwiftUI view
lifetime. Switching sections or conversations preserves shells. At most four split
panes are visible per group. Closing an active foreground job requires confirmation.
App termination stops all owned shells; restored tabs start fresh shells. Terminal
excerpts are user context and never count as verification evidence.

Project commands run only after Run, in validated project-relative directories. No
repository-discovered setup executes automatically. Preview discovery is limited to
Herm terminal process descendants and never opens a server automatically. Desktop
capture stages one explicit window in a draft, with optional app text off by default.
Capture failures retain the draft. Saved prompts restore for editing without sending.

PR watching stores stable references, respects notification preferences and quiet
mode, and performs provider reads only. Model comparison launches are explicit,
use existing Hermes sessions/background tasks, and never rank or merge results.

New preference switches use `SettingsPreferenceRow` with the same small, accent-tinted
native switch as adjacent settings, aligned to the trailing edge. The label and
explanation occupy the leading column. Appearance → Replies contains Generative UI;
optional capture text belongs to General → Window capture. Do not place capture
permissions in the reply-presentation group. Compact diff controls wrap using the
shared flow layout, and long revision notes put editing actions below their text.
Terminal panes retain their preferred split axis but stack vertically when a horizontal
split would make them unreadable. Pending model-comparison launches disable sheet dismissal, including Escape.
Visual acceptance includes inspecting the exported native fixtures, not only checking
that export succeeded. Check compact and workspace widths across light, dark, Glass,
monochrome, and motion-free themes. Settings fixtures include an established preference
row beside the new controls so alignment and control treatment can be compared directly.

Private revision-note editors use a compact, content-sized Dock modal: file and
line metadata, a flat numbered source excerpt, a labeled note input, then trailing
Cancel and Add/Save actions. Changed-source notices use a warning icon with quiet
supporting text. Review trays place the count and Send revision in their header;
file metadata and Edit/Remove share a wrapping row, followed by readable-width note
text and stale-source status. Explain why sending is unavailable beside the tray.

Terminal Previews uses a compact, surfaced globe/label/chevron control
and a shared 320pt themed popover. Its header owns refresh feedback; rows separate
process names from monospaced loopback addresses and include an open arrow. Empty,
checking, and failed discovery occupy one stable slot. Failed refreshes retain
previous rows with an explicit stale subtitle. Discovery pauses under hidden surfaces
and rejects results from a previous terminal scope. Opening remains an explicit click.

Browser uses the session composer exclusively. Attach Page stays visible in the
responsive toolbar and stages a removable context chip without sending or changing
the chat draft. It captures the title, URL, shared Chromium tab ID when available,
and selected text as untrusted page context. Reattaching the same page refreshes
its chip; navigation does not silently change attached context. Async selection
capture is discarded if the session, page, or tab changes. The action shows pending
feedback and is disabled on blank pages. More retains New Agent Tab and the
annotation and console-context actions.

The Browser toolbar uses 28pt controls and a compact themed address field. It
first collapses viewport labels and moves annotation into More; phone-width
panels give the address a full-width row above navigation and viewport actions.
Browser has no Local Previews control or discovery polling. Auto follows native
page bounds on every resize without reloading; device presets retain their CSS
width and scale to fit. WebKit sizing belongs to its native page container;
Chromium’s canvas reports frame changes directly rather than waiting for a
subview layout pass. Headless Chromium uses a 2x compositor and lossless PNG
screencast frames, bounded to the viewing display’s pixel density. Auto rounds
CSS viewport dimensions down to whole pixels and aligns the page origin to the
backing pixel grid, preserving 1:1 text rendering in fractional panel bounds.
Device previews scale down only when needed to fit. Screencasting stays paused
while the pane is hidden. The viewport menu stays visible and names the
selected CSS width; its accessible label includes the device preset. Page loading
uses a reserved address-field spinner and a slim indeterminate track over the
toolbar’s bottom edge; Reload becomes Stop in the same footprint. Navigation
failures and the agent-offline notice overlay the page rather than inserting rows
above it. Retry and dismissal stay local to the failure. Empty tabs offer address
entry. Back/Forward availability follows each engine’s live history, including
same-document changes. Copy Address and Open in Default Browser live in More.

PR list rows separate repository/number, title, branch, and readiness into a clear
reading order. State icons use green for open work, neutral ink for drafts,
violet for merged work, and red for closed work. Leading marks describe lifecycle
only. A separate readiness badge uses amber for conflicts, red for failed checks,
pink for requested changes, violet for required review, and neutral ink for missing
checks. Terminal lifecycle takes precedence over old readiness results. Selection has an accent leading marker as
well as the shared selected surface. Status controls pair a state icon and
readable semantic ink with a quiet tinted surface. Reviewer assignments use
`dockReview` teal, which resolves to deep ink in light themes, bright ink in dark
themes, and neutral ink in Monochrome/E-Ink. Description prose stays within an
820pt reading measure while its surrounding card fills the pane.


### Calendar workspace

Week and Month share a search row with Agenda, a weekly list grouped by date.
Search matches titles, source names, and locations within the displayed range;
a type menu narrows the projection and Clear resets both filters. The month heading
opens a date picker. Agenda rows select the day and expand the item in the inspector.
The inspector separates all-day items from the schedule and labels overlapping timed
events using all enabled sources before search/type filtering. Touching event boundaries
do not conflict. Plan in chat includes the complete selected day from enabled sources.

Calendar uses the shared semantic palette for item identity: `DockCategoryTone.event` blue for events,
`.reminder` amber for reminders, `.automation` violet for scheduled agent runs,
and `.task` teal for Kanban. These are category accents, not lifecycle status.
EventKit calendar/list colors take precedence for Mac items; Monochrome and
E-Ink use neutral ink, with icons and source labels preserving identity.

Keep the month/week grid dominant beside a 340pt daily agenda. Weekends have a
quiet surface tint; today has a filled date circle and selection has a tinted
cell with a top rule. Day cells are keyboard-focusable buttons. Event chips show time above title with a quiet category tint. The daily agenda is a divider-led list with an aligned time column, category icons, and expandable details/actions. Selection uses the skin accent; category identity stays in icons. The compact category legend sits below the grid without adding controls.

Date navigation keeps Today in a fixed slot, disabled on today. The toolbar
wraps into two rows when needed. Narrow windows stack the grid and agenda in a
scrollable workspace. Very narrow grids show category icons and item counts
instead of truncated event titles; full titles remain in the daily agenda. Agenda headers show the selected date and actual item
count; the read-only Mac connection prompt follows the schedule.

### Activity usage heatmap

Activity → Spend shows the yearly usage heatmap above the fixed 30-day spend report.
Tokens, Cost, and API calls select the measured intensity; hovering a day shows
its reported usage. The year loads independently of the spend report
and reloads with Refresh. No date-range picker is shown. Missing reports show an unavailable state; failed
refreshes retain the last successful heatmap with a stale diagnostic.

Issues follows the PR overview hierarchy: repository/number and a labeled state,
16pt page title, author, then assignment/freshness separated by a hairline. Open
issue state uses `dockInfo`; closed uses `dockMerged`, without implying a merge;
unknown state remains neutral with a question icon. Assignments use `dockReview`.
List rows use an unfilled lifecycle icon and show number/freshness, a 12pt semibold title,
then plain neutral state text and assignment; omit repeated colored icon discs and state pills. The
detail overview retains one tinted state badge. List selection has the shared surface plus a leading accent marker. Repository scope
moves below intrinsic-width filter tabs when horizontal space runs out.

Issue Description precedes Details in a shared Dock card, starts expanded, and
uses the canonical Markdown renderer within an 820pt reading measure. Conversation
uses one grouped timeline card, with loading/empty/unavailable in a stable content
slot and refresh feedback inside its 24pt control. Leave a comment is a separate
card: Write/Preview share an input surface, with a visible prompt and empty-preview
message. Character count and Post comment sit below the editor. Preserve drafts,
confirmation, posting feedback, and provider-authoritative metadata editing.


### Activity workspace

Activity navigation uses the shared pulse waveform icon.

Work retains its pinned calendar and scrollable detail pane. The calendar starts
with a labelled month overview of shipped work, sessions, and active days. Its
heat cells and shipped meters use `dockReview` teal; sessions and hourly rhythm
use `dockInfo` blue; automation uses `dockMerged` violet. Failed runs keep
`dockWarning` amber. Legends, row icons, and counts preserve meaning without
color. These category accents reuse the shared appearance-aware palette and
resolve to neutral ink in Monochrome and E-Ink. Refresh errors occupy the existing
toolbar status slot; initial unavailable content retains a stable content area.

A summary card sits below the Activity calendar in the left scrolling column on
wide windows, and before the detail sections in the narrow scrolling pane.
The wide calendar column retains 16pt of bottom content padding so the summary
card clears the viewport edge when scrolled to the end. It
summarizes the selected Day, Week, or Month using Apple's on-device model, with
bounded metadata samples and full recorded counts. A week crossing a month edge
uses only the loaded month's records. Changing period cancels the previous request;
empty, loading, stale, unavailable, and retry states retain the same card container.
Summaries use the shared `MarkdownMessageView` at body size, preserving paragraph
and list breaks. Generation requests a short overview and 2–3 bullets with bold
labels, up to 90 words, focusing on concrete changes rather than repeating totals.
Apple Intelligence attribution uses the shared `OnDeviceAssistNotice`: a small
neutral inset surface, an orange info icon from `DockAccentColor.orange.color`,
and unchanged `dockMetadataText` body text. Reuse it for Activity and notch
summaries, automatic title information, and Apple Intelligence settings.
Generated summaries show “Generated by Apple Intelligence” with help explaining
local generation and possible inaccuracies. Existing reply summaries retain that
attribution in notch detail, approval notifications include an accuracy notice,
and session title / Writing Tools help explains their generation behavior.

Today uses a 24pt filled date badge with `dockOnAccentText`, a 2.5pt skin-accent
cell outline, and a light accent tint in every scope. Other selected days retain
the thinner selection outline; today's marker remains visible independently of
selection and activity. Date rows keep the same height, and VoiceOver names today.

Day, Week, and Month use the same detail sections for merged PRs, finished tasks,
commits, sessions, automations, and usage, projected from the selected daily buckets.
Range totals retain their underlying records, repository counts, and navigation
actions. Rows in Week and Month include a date as well as a time; every capped list
offers Show more. Usage-only periods remain visible even with no event records.
The hourly chart sums the selected days; longest stretch is the longest within one
day, never a continuous stretch across midnight. Range-specific day bars, weekday
patterns, and assignee summaries remain available below the shared details.

Pull requests merged keeps its total and individual PR links in every scope, with
per-repository counts above the list. Reuse the commits section's repository labels
and count bars, sorted by count descending and repository name ascending.

The 30-day report loads before yearly analytics; both loads belong to the model
and survive tab changes. Reopening within one minute reuses successful reports;
explicit Refresh reloads both, sharing any in-flight request. The refresh control
stays pending through the yearly load. Failed loads settle to unavailable or stale
content, without showing old errors alongside active loading messages.

Spend leads with the yearly heatmap, followed by estimated cost, total tokens,
cache reads, and sessions for the past 30 days. API
calls, reasoning, background share, and model count form a compact supporting
row with detail in help text. The daily chart follows the spend summary. Input is blue, output and cost teal, cache reads and background work
violet. Tools and skills occupy two equal columns when space permits and stack
in compact panes. Selection continues to use the interaction accent; charts
and meters keep their category colors across metric and theme changes.

Neutral skins use neutral interaction and selection. Character skins use their
own hue. Semantic status and identity colors use the shared solid palette.

Disclosure groups use `DockDisclosureGroupStyle`: the caret, label, and remaining header width form one keyboard-focusable button. Expanded content keeps its own interactions; the header reports expanded/collapsed state and respects Reduce Motion.

### Component color semantics

`DockCategoryTone` in `DockAccentPalette.swift` supplies category identity without
implying health or urgency. Calendar reminders are amber rather than warning
orange; task categories are teal; automation and review categories are violet;
modified files and integrations are cyan; renamed files are violet. Staged file
selection uses the skin accent. Additions are green and deletions red across all
diff viewers. Charts use solid fill roles and keep legends mapped to their data.

Ordinary IDs, branches, repository metadata, drafts, paused automations, unknown
readiness, and triage are neutral. Actual links and actions use the skin's
interaction accent. Never turn an ordinary identifier blue just to imply a link.
Global navigation and page titles remain neutral; put category color in the
content's meaningful marks. Never add color to fill space or imply a status
that the runtime/provider did not report.

The expanded floating workspace fills the panel vertically without extra top or bottom shell padding.

PR Summary branch-route icons use the shared violet `dockMerged` ink. Reviewer and
merge-warning icons use text-sized Dock glyphs to align with the first text baseline,
including wrapped warnings.

The Merge toolbar button uses a live Dock glyph that inherits the primary button's
foreground with its label, including on Storm's gradient and Glass's filled surface.
Keep icon and text at the same contrast in every skin and interaction state.
PR toolbar actions inherit small control sizing, keeping Attach to chat and Merge close
to the adjacent 28pt icon controls while retaining 12pt labels and themed feedback.

PR Summary content cards use 20pt insets. Their section headers omit sidebar-only
leading padding and use 12pt semibold primary ink so titles and body share an edge.

PR Activity commit entries show a monospaced short hash as a visible link below
the message. Selecting it opens a read-only commit diff sheet using `DockExpandedPage`
and `SharedDiffView`, with a changed-file picker and addition/deletion counts.
The sheet loads that exact commit from GitHub, retains partial-coverage notices,
and offers retry on failure. Missing patches show an unavailable message.

Review actions group pull-request watching and guide actions in a compact menu. Raw submission diagnostics stay in the guide; startup shows a loading indicator. New review sessions wait briefly for project-directory confirmation, and active first turns wait for saved history.

Markdown GitHub pull request and issue overview links open the shared PR or issue detail view in chat’s Pull Request or Issue inspector tab
when that page is enabled in Settings and GitHub resolves the item. Each chat keeps
its own GitHub selection; opening a link leaves the conversation visible. Disabled pages,
unavailable items, and links to anchors or subpages retain the browser fallback.

Chat’s Pull Request and Issue tabs use the standard 12pt inspector side gutters.

Open pull requests offer Edit beside Reviewers to select people with repository write access.
Changes require confirmation, preserve team requests, and refresh from GitHub.

PR merging uses `PullRequestMergeButton` in both toolbar and landing panel, hosted
by `PullRequestLandingView` so selection, requirements, confirmation, pending state,
and GitHub writes follow one path. The primary segment names the selected method;
the chevron shows repository-supported methods with descriptions and a checkmark.
Selection stays available when checks block immediate merging, including for
auto-merge. Unavailable requirements and blocked or queued merges disable the
main action; the dropdown opens requirements. Successful eligibility requires explicit confirmation
and provider revalidation. All segments share primary-button ink across skins.

### Async action feedback

Failed explicit actions use the shared `DockActionErrorCenter` and
`DockActionErrorPopup`. A nonactivating child panel places the error above the
active window or sheet without reflowing content or stealing keyboard focus.
Use a destructive-tinted background and border, a warning icon, readable title
and sanitized detail, and a labelled dismiss button. Errors remain until dismissed
or replaced by a newer action error; an old dismissal cannot clear a newer error.
Monochrome skins retain their semantic palette and the warning icon. Background
polls keep their existing inline stale/unavailable states and do not open popups.
Pin actions retain their footprint with a spinner until acknowledgement and refresh;
late index reads cannot undo a confirmed pin or publish it into another profile.

User-triggered asynchronous actions acknowledge the click immediately, keep progress
visible until their awaited work settles, and disable repeat submission while pending.
Use `DockAsyncButton` for persistent controls without model-owned pending state; its
spinner slot preserves the control's width. Existing model-owned `DockActionLabel`,
`DockIconButton`, and modal pending states remain the preferred treatments when available.
Menu and confirmation actions show progress on the persistent parent, since their
invoking control dismisses. Errors and drafts stay owned by the existing action.

Markdown GitHub overview links show a non-interactive “Opening…” progress overlay in
the current conversation while resolving, without moving transcript content. Progress
is scoped to that conversation and clears on success, failure, or cancellation. Repeated
clicks during resolution do not start another lookup. Browser fallbacks remain available.
Group sends, approval responses, rename, retry, stop, and disband expose room-scoped
request progress, separate from the runtime's working status.

Merge eligibility and its tooltip share `GitHubLandingSnapshot.mergeDisabledReason`
in toolbar and landing controls. Drafts disable immediately from the PR record,
even before requirements load. Missing requirements fail closed. GitHub merge
state controls required-check and branch-protection gating; optional failing
checks remain warnings when GitHub reports the PR mergeable. Disabled Merge
keeps an active hover-tip anchor and the separate requirements dropdown.

The empty chat welcome shows the orb and introductory text without suggested-prompt pills.
