#!/usr/bin/env python3
"""Pages must use dockShellPane()/dockShellChrome(), not the raw chrome tint."""
import pathlib, re, sys

ALLOWED = {"DesignSystem/DockWorkspaceShell.swift", "DesignSystem/DockTheme.swift",
           "DesignSystem/DockComponentStyles.swift", "Conversation/DockPopover+Layout.swift",
           "Conversation/DockPopover+Context.swift", "Conversation/ChatRailActivityModel.swift"}
root = pathlib.Path("Sources/Herm")
bad = []
for path in root.rglob("*.swift"):
    rel = path.relative_to(root).as_posix()
    if rel in ALLOWED:
        continue
    for n, line in enumerate(path.read_text().splitlines(), 1):
        if re.search(r"\bdockSidebar\b|sidebarBackground", line):
            bad.append(f"{path}:{n}: use dockShellPane()/dockShellChrome() instead of the raw chrome tint")
print("\n".join(bad))
sys.exit(1 if bad else 0)
