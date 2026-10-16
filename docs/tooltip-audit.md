# Tooltip audit

What this repo does: Herm is a native macOS workspace for one user's local
Hermes agent. This audit covers tooltip presentation throughout the app,
including the floating notch, workspace, sheets, menus, and scrollable views.

## Must fix (addressed)

1. **Tooltips can be covered by neighboring views.** The shared `DockHoverTip`
   rendered an overlay inside each control. Its local `zIndex` could not escape
   an ancestor's stacking order or a scroll view's clipping. The shared renderer
   now shows a mouse-transparent, non-activating child panel above the host.
   The existing `.help` and `.dockHoverTip` call sites use it without per-view fixes.
2. **Nested help can show multiple tips.** A session row and its child controls,
   and some repository toolbar buttons and their labels, both attach help.
   One presenter now chooses the smallest hovered control and shows one panel.
3. **Edge placement can lose help text.** The old renderer placed unbounded text
   at a fixed edge without checking the display. Help now wraps at 320pt and
   placement flips and clamps within the display containing the control. The native tooltip window is fully opaque; after clamping, placement checks
   all four sides for a gap beside the hovered control. Large
   payloads are bounded to 12 preview lines so they cannot cover the display.
4. **Chart help can escape into its header.** The daily usage chart disabled
   vertical annotation overflow resolution. It now fits annotations to the chart
   on both axes and uses an opaque tooltip background.

## Integration checks

- Inventoried 209 `.help` / `.dockHoverTip` matches across the SwiftUI app,
  including the shared API definitions/comments, and inspected all call sites.
- Checked the separate Swift Charts annotation and AppKit `toolTip` properties
  on the code-copy button, office bubbles, and menu-bar button. Native AppKit
  tips use the platform's floating presentation.
- Updated both native child-window dismissal guards so informational tips do
  not keep the notch/workspace open. Interactive popovers still block dismissal.
- Added native regression tests for nested help, scroll clipping, wrapping,
  screen-edge placement, negative display coordinates, cancellation, empty
  help, keyboard focus, and resize dismissal.

Validation: The complete app built from a stable source snapshot. All six
`DockHoverTipTests` passed against the real app module with macOS display access.
The rendered tooltip was visually inspected. New Swift files pass swift-format
lint, and the working diff passes `git diff --check`. Unrelated test sources were
excluded from the temporary validation target; the repository test target is
unchanged.

Verdict: The shared presentation layer is fixed; individual screens continue
using the same help API.

Not checked: Every live screen with a real Hermes runtime; physical multiple
monitors. This is a tooltip audit, not a security or backend audit.
