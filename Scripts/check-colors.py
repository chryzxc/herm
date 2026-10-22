#!/usr/bin/env python3
"""Reject new feature-local colors; reviewed legacy/source colors are counted exactly."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys

CENTRAL = {
    "Sources/Herm/DesignSystem/DockAccentPalette.swift",
    "Sources/Herm/DesignSystem/DockTheme.swift",
}
PATTERN = re.compile(
    r"\b(?:NSColor|Color)\s*\(\s*(?:red:|srgbRed:|calibratedRed:|hue:|hex:|\.sRGB)"
    r"|#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?\b"
    r"|\b(?:Color|NSColor)\.(?:system)?(?:[Bb]lue|[Gg]reen|[Rr]ed|[Oo]range|[Yy]ellow|[Pp]urple|[Tt]eal|[Pp]ink|[Cc]yan|[Ii]ndigo|[Mm]int)\b"
    r"|\.(?:fill|stroke|foregroundStyle|foregroundColor|tint|background)\(\.(?:blue|green|red|orange|yellow|purple|teal|pink|cyan|indigo|mint)\b"
    r"|\b0x[0-9a-fA-F]{6}\b"
)


def occurrences(root):
    result = {}
    for path in sorted((root / "Sources/Herm").rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.suffix not in {".swift", ".js", ".css", ".html"} or relative in CENTRAL:
            continue
        counts = Counter()
        for line in path.read_text().splitlines():
            # Comments are not rendering instructions.
            if line.lstrip().startswith(("//", "/*", "*")):
                continue
            if PATTERN.search(line):
                counts[line.strip()] += 1
        if counts:
            result[relative] = dict(counts)
    return result


def violations(actual, allowed):
    return [f"{path}: {line} (allowed {allowed.get(path, {}).get(line, 0)}, found {count})"
            for path, lines in actual.items() for line, count in lines.items()
            if count > allowed.get(path, {}).get(line, 0)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    baseline = json.loads((args.root / "Scripts/color-exceptions.json").read_text())
    failures = violations(occurrences(args.root), baseline["occurrences"])
    if failures:
        print("Use DockAccentColor fill/ink or Color.dock* roles. See docs/color-system.md.")
        print("\n".join(failures))
        return 1
    print("Color contract passed: no new feature-local color literals.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
