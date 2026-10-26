# Button sizing contract

Button **priority** and **size** are independent. `.dockPrimary` selects the local
primary action; `.dockSecondary` selects an outlined companion. Neither selects a
height. `.dockCompact` is a compatibility alias for `.dockSecondary`, with the same
inherited metrics. Prefer `.dockSecondary` in new code.

All text actions use `DockButtonMetrics`: the same control font, vertical padding,
and workspace-scaled minimum height. Choose size once on the common container:

| Context | Size | Minimum height at 100% scale |
| --- | --- | --- |
| Toolbars, inspectors, inline recovery, ordinary page actions | Default `.compact` | 28 pt |
| Form footers and substantial action groups | `.standard` | 36 pt |
| Approval/clarification decisions and large-target groups | `.accessible` | 44 pt |

```swift
HStack(spacing: DockSpacing.control) {
    Button("Cancel", action: cancel).buttonStyle(.dockSecondary)
    Button("Save", action: save).buttonStyle(.dockPrimary)
}
.dockButtonSize(.standard)
```

Apply the size above `ViewThatFits` when it contains horizontal and vertical
alternatives. `DockModal` applies `.standard` to its footer automatically. Primary,
secondary, modal, destructive, disabled, and pending buttons inherit that size.
Native `.controlSize` affects native controls, not Herm text-button metrics.

Do not set a height/minHeight, vertical padding, or size override on an individual
text action or its outer label. Do not use font size or role to make a primary
button bigger. Use intrinsic widths for different labels; equal height does not
require equal width. Width-only constraints and outer layout spacing are allowed.
Wrapped labels may grow beyond the minimum height so content is not clipped. Use
short labels and adaptive stacking when a row is too narrow.

Icon-only buttons use `DockIconButton` and its established 24/28 pt contracts.
Inline navigation uses `.dockLink`. Rows, tabs, and content tiles use `.dockHover`
or their shared component. These are separate interaction types; do not put a
large content tile inside a standard text-button style merely to obtain a border.

## Enforcement

`make button-contract` runs source checks and their self-tests; it is part of
`make guard` and therefore `make check`/CI. It rejects outer label heights,
vertical padding, and per-button size overrides on shared text actions, and
requires concrete primary/secondary/modal styles to use the common metrics.
There is no exception baseline to expand.

`DockButtonSizingTests` measures actual SwiftUI/AppKit fitting heights across
priorities, pending/disabled states, native control sizes, and workspace scales.
It renders a comparison sheet for Light, Dark, Glass, and Monochrome to
`/tmp/herm-button-sizing`. Run the focused suite after changing shared metrics.

The source gate is deliberately scoped: it is not a complete Swift semantic or
layout analyzer. It does not prove every arbitrary custom view, hover state, or
nested helper has matching geometry. Visual review still checks new action groups
at narrow widths, keyboard focus, and relevant themes. Do not claim a compiler
check alone is visual verification.

## Audit — 2026-10-26

Source inventory covered every Swift file under `Sources/Herm`, spanning 30
subsystems with styled buttons. It found 382 shorthand text-action uses: 225
compact, 99 secondary, and 58 primary, plus direct style constructors. Thirty-seven
files used compact alongside primary/secondary; that is an exposure count, not a
claim that every group in those files was broken. Existing compact buttons were
26 pt despite a documented 28 pt token; primary/secondary defaulted to 36 pt.
Modal buttons had a third independent font/padding implementation.

The shared fix covers all these call sites without rewriting their behaviors.
The audit also inspected label geometry and corrected these concrete paths:

- **All modal footers:** group-level 36 pt sizing; modal and ordinary styles share metrics.
- **Chat approvals, clarifications, and value prompts:** retain 44 pt targets via container sizing.
- **Office status filters:** remove label-owned 44 pt height and duplicate padding; group owns the target size.
- **Kanban creation:** the row owns 36 pt sizing; the icon label no longer adds its own 36 pt box.
- **Quota connection actions:** remove redundant label height; keep the intentional width.
- **Markdown code copy:** remove manual padding/height from the action wrapper.
- **Generated image gallery:** classify the 120 pt preview as a content tile, not a text action.
- **Both simulator tabs and all other ordinary text actions:** share the 28 pt default regardless of visual priority.

This is an app-wide source audit with rendered design-system checks, not a live
click-through of every page. The running Herm app is not relaunched by these checks.
Light, Dark, and Monochrome reference sheets were visually checked. The offscreen
Glass capture was incomplete; Glass appearance still needs live visual review.
