"""Catch client branding regressions without renaming Hermes backend contracts."""
from pathlib import Path
import re
import sys


def violations(source, path='Fixture.swift'):
    findings = []
    for number, line in enumerate(source.splitlines(), 1):
        if line.lstrip().startswith('//'):
            continue
        for match in re.finditer(r'"(?:\\.|[^"\\])*"', line):
            value = match.group()[1:-1]
            if not re.search(r'\bhermes\b', value, re.I):
                continue
            # Backend NSError domains are wire-facing identifiers, not app labels.
            prefix = line[:match.start()]
            if value == 'Hermes' and re.search(r'\bdomain\s*(?::|==)\s*$', prefix):
                continue
            # This named skin deliberately matches the official Hermes Desktop look.
            if path == 'Sources/Herm/DesignSystem/DockTheme.swift' and 'case .hermesClassic:' in prefix:
                continue
            if value in {'Hermes', 'HERMES'} or re.search(
                r"\bHermes (?:navigation|control queue|companion|can't browse)\b"
                r'|\b(?:review with|prepare(?: resolution)? in|open linked) Hermes\b'
                r'|\bHermes is (?:thinking|reasoning|listening)\b', value, re.I
            ):
                findings.append(f'{path}:{number}: error: client labels use Herm; reserve Hermes for the backend agent.')
    return findings


if __name__ == '__main__':
    findings = [finding for path in sorted(Path('Sources/Herm').rglob('*.swift'))
                for finding in violations(path.read_text(), path.as_posix())]
    print('\n'.join(findings) if findings else 'Naming contract passed: client labels use Herm.')
    sys.exit(bool(findings))
