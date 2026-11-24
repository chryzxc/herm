#!/usr/bin/env python3
"""Performance contract for Herm sources.

Rejects patterns that have caused frame drops, idle CPU, or battery drain:

* `repeatForever` animations and cyclic `.phaseAnimator` (no `trigger:`):
  both render at the display's full refresh rate (120 Hz on ProMotion).
  Use `TimelineView(.dockMotion(rate:paused:))` to share tick instants or
  use a native layer animation for compositing-only effects.
* `TimelineView(.animation...)`: same per-frame cost; use `.dockMotion`.
* `TimelineView(.periodic(... by: <1s))`: use `.dockMotion` to share tick
  instants and reduce updates off screen.
* Indeterminate `ProgressView`: use `DockLoadingIndicator` so indeterminate
  states share the theme and visibility rules.
* Allocate-and-use formatters (`ISO8601DateFormatter().date(...)`): building
  a formatter loads ICU state and costs several times the parse. Use
  `ISO8601Parsing` or a stored static formatter.
* Repeating timers without tolerance: they pin the CPU's wake schedule.
  Set `tolerance` on the timer (or pass it to `Timer.publish`).

A line can opt out with `// perf-contract: allow <reason>` on the same line
or the line above. The reason is required.

It also ratchets the observation fan-out of the two god models: their
`@Published` property count and the number of view sites observing them
whole may not grow. Lower the caps in BUDGET when a change reduces them.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Sources' / 'Herm'

ALLOW = re.compile(r'//\s*perf-contract:\s*allow\s+\S')
FORMATTERS = (
    'ISO8601DateFormatter|DateFormatter|NumberFormatter|RelativeDateTimeFormatter|'
    'DateComponentsFormatter|DateIntervalFormatter|ByteCountFormatter|MeasurementFormatter|ListFormatter'
)
LINE_RULES: list[tuple[re.Pattern[str], str]] = [
    (
        re.compile(r'\.repeatForever\s*\('),
        'repeatForever renders at full refresh rate and never stops; use TimelineView(.dockMotion(rate:paused:))',
    ),
    (
        re.compile(r'TimelineView\s*\(\s*\.animation\b'),
        'TimelineView(.animation) renders every display frame; use .dockMotion(rate:paused:)',
    ),
    (
        re.compile(r'\b(?:' + FORMATTERS + r')\(\)\s*\.'),
        'formatter allocated per call; use ISO8601Parsing or a stored static formatter',
    ),
    (
        re.compile(r'\bProgressView\s*\(\s*(?:"(?:[^"\\]|\\.)*"\s*)?\)'),
        'use DockLoadingIndicator for indeterminate progress',
    ),
]
PERIODIC = re.compile(r'\.periodic\s*\(\s*from:[^)]*\bby:\s*([0-9]*\.?[0-9]+)')
PHASE_ANIMATOR = re.compile(r'\.phaseAnimator\s*\(')
REPEATING_TIMER = re.compile(
    r'Timer\.scheduledTimer\s*\([^)]*repeats:\s*true|Timer\s*\(\s*timeInterval:[^)]*repeats:\s*true|Timer\.publish\s*\('
)
TIMER_WINDOW = 8

# Ceilings measured on 20 November 2026. Only ever lower them.
BUDGET = {
    'DockModel @Published': 118,
    'ControlCenterModel @Published': 93,
    'DockModel whole-model observers': 35,
    'ControlCenterModel whole-model observers': 26,
}


def code(line: str) -> str:
    """The line without its trailing `//` comment (string-unaware, good enough)."""
    index = line.find('//')
    return line if index < 0 else line[:index]


def allowed(lines: list[str], index: int) -> bool:
    return bool(ALLOW.search(lines[index]) or (index > 0 and ALLOW.search(lines[index - 1])))


def violations(source: str) -> list[tuple[int, str]]:
    lines = source.splitlines()
    found: list[tuple[int, str]] = []
    for index, raw in enumerate(lines):
        line = code(raw)
        if not line.strip() or allowed(lines, index):
            continue
        for pattern, message in LINE_RULES:
            if pattern.search(line):
                found.append((index + 1, message))
        periodic = PERIODIC.search(line)
        if periodic and float(periodic.group(1)) < 1:
            found.append((index + 1, 'sub-second TimelineView(.periodic) is motion; use .dockMotion(rate:paused:)'))
        if PHASE_ANIMATOR.search(line):
            call = ' '.join(code(item) for item in lines[index : index + 3])
            if 'trigger:' not in call:
                found.append((index + 1, 'cyclic phaseAnimator loops forever at full refresh rate; pass trigger: or use .dockMotion'))
        if REPEATING_TIMER.search(line):
            window = ' '.join(code(item) for item in lines[index : index + TIMER_WINDOW])
            if 'tolerance' not in window:
                found.append((index + 1, 'repeating timer without tolerance; set timer.tolerance or pass tolerance:'))
    return found


def observer_pattern(model: str) -> re.Pattern[str]:
    return re.compile(r'@(?:ObservedObject|EnvironmentObject|StateObject)\b[^\n]*:\s*' + model + r'\b')


def measure(files: dict[Path, str]) -> dict[str, int]:
    def published(name: str) -> int:
        return sum(text.count('@Published') for path, text in files.items() if path.name == f'{name}.swift')

    def observers(name: str) -> int:
        pattern = observer_pattern(name)
        return sum(len(pattern.findall(text)) for text in files.values())

    return {
        'DockModel @Published': published('DockModel'),
        'ControlCenterModel @Published': published('ControlCenterModel'),
        'DockModel whole-model observers': observers('DockModel'),
        'ControlCenterModel whole-model observers': observers('ControlCenterModel'),
    }


def main() -> int:
    files = {path: path.read_text(encoding='utf-8') for path in sorted(SOURCES.rglob('*.swift'))}
    failures = 0
    for path, text in files.items():
        for line, message in violations(text):
            print(f'{path.relative_to(ROOT)}:{line}: {message}')
            failures += 1
    for name, value in measure(files).items():
        cap = BUDGET[name]
        if value > cap:
            print(f'perf budget: {name} is {value}, cap is {cap}. Observe a narrower model or publisher instead.')
            failures += 1
        elif value < cap:
            print(f'perf budget: {name} dropped to {value}; lower its cap in Scripts/check-perf-contract.py.')
    if failures:
        print(f'perf-contract: {failures} violation(s). See docs/chat-performance.md.')
        return 1
    print('perf-contract: ok')
    return 0


if __name__ == '__main__':
    sys.exit(main())
