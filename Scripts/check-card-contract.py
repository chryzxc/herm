"""Cards come from `.dockCard`; a hand-built fill+stroke box elsewhere drifts from the theme.

A file is flagged when it builds a rounded shape, fills it with a Color.dockSurface* and strokes it
within a few lines. Existing offenders are counted in Scripts/card-contract-allowlist.txt, which may
only shrink. This is a focused source check, not a Swift parser."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
ALLOWLIST = Path(__file__).with_name('card-contract-allowlist.txt')
SHAPE = re.compile(r'(?:RoundedRectangle|DockThemeShape)\s*\(')
FILL = re.compile(r'\.(?:dockSurfaceFill|fill)\s*\(\s*(?:Color\.)?dockSurface\d?\b')
STROKE = re.compile(r'\.stroke\s*\(|stroke\s*:')
# A surface-filled box without a stroke is still a hand-built well; skeleton bars (.frame) are exempt.
FILLED_BOX = re.compile(r'(?:RoundedRectangle|DockThemeShape)\s*\([^\n]*?\)\s*\.(?:dockSurfaceFill|fill)\s*\(\s*(?:Color\.)?dockSurface\d?\b(?![^\n]*\.frame\()')
# Label capsules and meters have shared components (.dockPill, DockProgressBar); a hand-built one drifts.
CAPSULE = re.compile(r'\.background\(\s*Capsule\(\)\s*\.fill\(|^\s*Capsule\(\)\s*\.fill\(.*\)\s*$')
WINDOW = 6


def violations(source):
    """Line numbers of shapes that are both filled with a surface color and stroked nearby."""
    lines = source.splitlines()
    found = []
    for i, line in enumerate(lines):
        if CAPSULE.search(line):
            found.append(i + 1)
            continue
        if not SHAPE.search(line):
            continue
        block = '\n'.join(lines[i:i + WINDOW])
        if (FILL.search(block) and STROKE.search(block)) or FILLED_BOX.search(line):
            found.append(i + 1)
    return found


def counts():
    result = {}
    for path in sorted((ROOT / 'Sources/Herm').rglob('*.swift')):
        relative = path.relative_to(ROOT).as_posix()
        if relative.startswith('Sources/Herm/DesignSystem/'):
            continue
        n = len(violations(path.read_text()))
        if n:
            result[relative] = n
    return result


def main():
    allowed = dict(line.rsplit(' ', 1) for line in ALLOWLIST.read_text().split('\n') if line.strip()) \
        if ALLOWLIST.exists() else {}
    current = counts()
    if '--update' in sys.argv:
        ALLOWLIST.write_text(''.join(f'{p} {n}\n' for p, n in current.items()))
        return 0
    failed = False
    for path, n in current.items():
        limit = int(allowed.get(path, 0))
        if n > limit:
            failed = True
            print(f'{path}:1: error: {n} hand-built surface(s), allowed {limit}; use .dockCard / .dockWell / .dockPill / DockProgressBar (docs/cards.md).')
    if failed:
        return 1
    print(f'Card contract passed: {sum(current.values())} legacy surfaces remain.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
