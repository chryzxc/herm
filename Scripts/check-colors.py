#!/usr/bin/env python3
"""Reject new feature-local colors; reviewed legacy/source colors are counted exactly."""
import argparse
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
    r"|\b(?:Color|NSColor)\s*\.\s*(?:system)?(?:[Bb]lue|[Gg]reen|[Rr]ed|[Oo]range|[Yy]ellow|[Pp]urple|[Tt]eal|[Pp]ink|[Cc]yan|[Ii]ndigo|[Mm]int)\b"
    r"|\.\s*(?:fill|stroke|foregroundStyle|foregroundColor|tint|background)\s*\(\s*\.(?:blue|green|red|orange|yellow|purple|teal|pink|cyan|indigo|mint)\b"
    r"|\b0x[0-9a-fA-F]{6}\b"
)


def sources(root):
    result = {}
    for path in sorted((root / "Sources/Herm").rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.suffix not in {".swift", ".js", ".css", ".html"} or relative in CENTRAL:
            continue
        # Vendored third-party code ships with a sibling LICENSE (for example Resources/Mermaid.LICENSE).
        if path.with_suffix(".LICENSE").exists():
            continue
        # Preserve line numbers while ignoring standalone comments.
        text = "\n".join("" if line.lstrip().startswith(("//", "/*", "*")) else line
                         for line in path.read_text().splitlines())
        if PATTERN.search(text):
            result[relative] = text
    return result


def exception_pattern(source):
    # Keep string contents exact; tolerate only layout, semicolons and trailing commas.
    tokens = re.findall(r'"(?:\\.|[^"\\])*"|\w+|[^\s]', source)
    parts = []
    for index, token in enumerate(tokens):
        if token == ";":
            parts.append(";?")
        elif token == "," and index + 1 < len(tokens) and tokens[index + 1] in (")", "]"):
            continue
        elif token in (")", "]"):
            parts.append(r",?\s*" + re.escape(token))
        else:
            parts.append(re.escape(token))
    return re.compile(r"\s*".join(parts))


def violations(actual, allowed):
    failures = []
    for path, text in actual.items():
        approved = []
        for source, count in allowed.get(path, {}).items():
            matches = exception_pattern(source).finditer(text)
            approved.extend(match.span() for _, match in zip(range(count), matches))
        for match in PATTERN.finditer(text):
            if not any(start <= match.start() and match.end() <= end for start, end in approved):
                line = text.count("\n", 0, match.start()) + 1
                failures.append(f"{path}:{line}: error: unapproved color; use DockAccentColor or Color.dock* roles")
    return list(dict.fromkeys(failures))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    baseline = json.loads((args.root / "Scripts/color-exceptions.json").read_text())
    failures = violations(sources(args.root), baseline["occurrences"])
    if failures:
        print("Use DockAccentColor fill/ink or Color.dock* roles. See docs/color-system.md.")
        print("\n".join(failures))
        return 1
    print("Color contract passed: no new feature-local color literals.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
