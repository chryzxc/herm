#!/usr/bin/env python3
"""Notch views and shared components read their theme through the surface.

`dockThemedRoot(surface:)` puts the chrome theme in the environment (Onyx on the
camera notch, the skin elsewhere). Reading the skin directly for style, shape,
material or appearance bypasses it and repaints the black notch in the skin's
chrome. Use `@DockChromeTheme` or `dockChrome { view, theme in ... }` instead.
Skin color tokens (`Color.dock*`) are fine: they resolve per window appearance.
"""
import pathlib, re, sys

root = pathlib.Path("Sources/Herm")
SHARED = {"DesignSystem/DockComponentStyles.swift", "DesignSystem/DockDesignSystem.swift"}
STYLE_READ = re.compile(
    r"DockThemeRuntime\.current\)?\.(style|usesNativeMaterial|appearance)\b"
    r"|DockThemeShape\(cornerRadius:\s*DockThemeRuntime")
ANY_READ = re.compile(r"DockThemeRuntime\.current\b")
# A fallback behind an explicit or surface theme is the sanctioned resolution.
FALLBACK = re.compile(r"\?\?\s*DockThemeRuntime\.current")

bad = []
for path in sorted(root.rglob("*.swift")):
    rel = path.relative_to(root).as_posix()
    notch = rel.startswith("EdgeDock/")
    if not notch and rel not in SHARED:
        continue
    for n, line in enumerate(path.read_text().splitlines(), 1):
        if FALLBACK.search(line):
            continue
        if (notch and ANY_READ.search(line)) or STYLE_READ.search(line):
            bad.append(f"{path}:{n}: read the theme with @DockChromeTheme / dockChrome, not DockThemeRuntime.current")
if bad:
    print("\n".join(bad))
    sys.exit(1)
print("Theme surface contract passed.")
