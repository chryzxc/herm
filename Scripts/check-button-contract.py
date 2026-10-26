"""Enforce shared text-button geometry. This is a focused source check, not a Swift parser."""
from pathlib import Path
import re
import sys

STYLE = re.compile(r'\.buttonStyle\s*\(\s*(?:\.dock(?:Primary|Secondary|Compact)|Dock(?:Primary|Secondary|Modal)ButtonStyle\s*\([^)]*\))\s*\)')
GEOMETRY = re.compile(r'\.(?:frame\s*\([^)]*\b(?:height|minHeight|maxHeight)\s*:|padding\s*\(\s*\.(?:vertical|all)\b|dockButtonSize\s*\()')


def masked(source):
    # Preserve offsets/lines while excluding comments and string bodies (including raw strings).
    pattern = r'//[^\n]*|/\*[\s\S]*?\*/|\#*"""[\s\S]*?"""\#*|\#*"(?:\\.|[^"\\])*"\#*'
    return re.sub(pattern, lambda m: re.sub(r'[^\n]', ' ', m.group()), source)


def pairs(code):
    stack, result = [], {}
    for i, char in enumerate(code):
        if char in '({[':
            stack.append(i)
        elif char in ')}]' and stack:
            start = stack.pop()
            result[i] = start
    return result


def root_geometry(code, offset):
    findings = []
    for match in GEOMETRY.finditer(code):
        # Child icons/spinners may size themselves; only the whole label controls button chrome.
        prefix = code[:match.start()]
        if prefix.count('{') == prefix.count('}'):
            findings.append(offset + match.start())
    return findings


def violations(source, path='Fixture.swift'):
    code = masked(source)
    mapping = pairs(code)
    findings = []
    for style in STYLE.finditer(code):
        end = style.start()
        cursor = end - 1
        # Walk modifiers immediately preceding the style, without crossing a view boundary.
        while cursor >= 0:
            while cursor >= 0 and code[cursor].isspace():
                cursor -= 1
            if cursor < 0 or code[cursor] != ')' or cursor not in mapping:
                break
            opening = mapping[cursor]
            name = re.search(r'\.\w+\s*$', code[:opening])
            if not name:
                break
            cursor = name.start() - 1
        findings += root_geometry(code[cursor + 1:end], cursor + 1)
        if cursor >= 0 and code[cursor] == '}' and cursor in mapping:
            opening = mapping[cursor]
            if re.search(r'label\s*:\s*$', code[:opening]):
                findings += root_geometry(code[opening + 1:cursor], opening + 1)
        # A size applied directly after the style affects only this one action.
        cursor = style.end()
        forward = {start: end for end, start in mapping.items()}
        while modifier := re.match(r'\s*\.(\w+)\s*\(', code[cursor:]):
            opening = cursor + modifier.end() - 1
            if modifier.group(1) == 'dockButtonSize':
                findings.append(cursor + modifier.start())
            if opening not in forward:
                break
            cursor = forward[opening] + 1
    for match in re.finditer(r'DockSecondaryButtonStyle\s*\(\s*compact\s*:', code):
        findings.append(match.start())
    return [f'{path}:{source.count(chr(10), 0, offset) + 1}: error: text-button sizing belongs to the action container; use .dockButtonSize there, not label height/padding or a per-button override.'
            for offset in sorted(set(findings))]


def main():
    root = Path(__file__).resolve().parents[1]
    failures = []
    for path in sorted((root / 'Sources/Herm').rglob('*.swift')):
        failures += violations(path.read_text(), str(path.relative_to(root)))
    # All concrete text styles must use the one metrics implementation.
    for filename, names in {
        'DockComponentStyles.swift': ['DockPrimaryButtonStyle', 'DockSecondaryButtonStyle'],
        'DockModal.swift': ['DockModalButtonStyle'],
    }.items():
        path = root / 'Sources/Herm/DesignSystem' / filename
        source = path.read_text()
        for name in names:
            block = source.split('struct ' + name + ':', 1)[1].split('\n}\n', 1)[0]
            if '.dockButtonMetrics()' not in block or 'controlSize' in block or 'minHeight:' in block:
                failures.append(f'{path}: error: {name} must use shared DockButtonMetrics without local size rules.')
    if failures:
        print('\n'.join(failures))
        return 1
    print('Button contract passed: shared text-action metrics, no label height overrides.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
