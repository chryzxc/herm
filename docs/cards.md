# Cards

Every boxed surface comes from `.dockCard(padding:isActive:)`
(`DesignSystem/DockComponentStyles.swift`). It owns fill, outline, shadow, glass and
open-chrome behavior per skin, so a card never needs its own `RoundedRectangle` + stroke.

- Static group: `.dockCard(padding: 12)`.
- Hovered, focused or selected card: `.dockCard(padding: 16, isActive: hovered)`.
- Content that supplies its own padding: `.dockCard(padding: 0)`.
- Selection that carries a hue (canvas nodes): `.dockCard(isActive: selected, tint: Color.dockAccent)`.
- Card drawn over other content (canvas nodes over wires, panels floating over a scroll view):
  add `isSolid: true`. Typographic skins otherwise draw cards boxless; solid cards keep a canvas
  fill and rule there so what is beneath does not show through.
- Inset boxes inside a card or row: `.dockWell(.raised | .sunken)` (`radius:`, `role:`, `stroke:` to tune).
- Floating HUD surface: `.dockHUDSurface(tint:)`.
- Tinted label capsule: `.dockPill(tint:)`; neutral chip: `DockMetadataPill`.
- Thin meters: `DockProgressBar(fraction:tint:)`.
- Compact empty state: `DockEmptyState(title:detail:icon:actions:)` (12pt semibold title, 12pt detail).

`make card-contract` fails when a file outside `DesignSystem/` fills a rounded shape with a
`dockSurface*` color (stroked or not), uses `.background(dockSurface*, in: RoundedRectangle/DockThemeShape)`, or hand-builds a `Capsule().fill` pill or meter. Legacy
capsules (selected/stroked/shadowed variants, slider tracks, ghost-fill meters) are counted per
file in `Scripts/card-contract-allowlist.txt`; counts may only go down. When you convert one, run
`python3 Scripts/check-card-contract.py --update`. New work must use the shared components, and a
variant the components cannot express means extending the component, not styling at the call site.
