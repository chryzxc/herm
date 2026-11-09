"""Enforce shared text-button geometry. This is a focused source check, not a Swift parser."""
from pathlib import Path
import re
import sys

STYLE = re.compile(r'\.buttonStyle\s*\(\s*(?:\.dock(?:Primary|Secondary|Compact)|Dock(?:Primary|Secondary|Modal)ButtonStyle\s*\([^)]*\))\s*\)')
GEOMETRY = re.compile(r'\.(?:frame\s*\([^)]*\b(?:height|minHeight|maxHeight)\s*:|padding\s*\(\s*\.(?:vertical|all)\b|dockButtonSize\s*\()')
LARGE_SIZE = re.compile(r'\.dockButtonSize\s*\(\s*\.(?:standard|accessible)\b')
# Reviewed .standard/.accessible containers (form footers, substantial groups).
# Ordinary page actions inherit .compact; do not raise a count to pass the check.
LARGE_SIZE_ALLOWED = {
    'Sources/Herm/DesignSystem/DockModal.swift': 1,
    'Sources/Herm/ControlCenter/WorkspaceActivitySidebar+Kanban.swift': 1,
    'Sources/Herm/Extensions/WorkflowIntegrationView.swift': 1,
    'Sources/Herm/SessionWorkspace/SessionWorkspaceSurfaces.swift': 1,
    'Sources/Herm/Gateway/MessagingWorkspaceView.swift': 1,
    'Sources/Herm/Conversation/SessionNavQueue.swift': 1,
}
PRESS_STYLE = re.compile(r'\.buttonStyle\s*\(\s*(?:\.dockPress|DockPressButtonStyle\s*\(\s*\))\s*\)')


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
    result = [f'{path}:{source.count(chr(10), 0, offset) + 1}: error: text-button sizing belongs to the action container; use .dockButtonSize there, not label height/padding or a per-button override.'
              for offset in sorted(set(findings))]
    for style in PRESS_STYLE.finditer(code):
        cursor = style.start() - 1
        while cursor >= 0:
            while cursor >= 0 and code[cursor].isspace():
                cursor -= 1
            if cursor < 0 or code[cursor] != ')' or cursor not in mapping:
                break
            name = re.search(r'\.\w+\s*$', code[:mapping[cursor]])
            if not name:
                break
            cursor = name.start() - 1
        if cursor < 0 or code[cursor] != '}' or cursor not in mapping:
            continue
        opening = mapping[cursor]
        prefix, body = code[:opening], code[opening + 1:cursor]
        label = re.search(r'label\s*:\s*$', prefix)
        title = re.search(r'\b(?:Button|DockAsyncButton)\s*\(([^{}]*)\)\s*$', prefix)
        text_label = label and re.match(r'\s*(?:Text|DockActionLabel|DockIconLabel)\s*\(', body)
        title_action = title and not re.match(r'\s*action\s*:', title.group(1))
        # Container-inherited styles also caused the gateway's undersized actions.
        container_titles = not label and not title and re.search(
            r'\b(?:Button|DockAsyncButton)\s*\(\s*(?!\s|action\s*:)', body)
        if text_label or title_action or container_titles:
            line = source.count(chr(10), 0, style.start()) + 1
            result.append(f'{path}:{line}: error: text actions must use .dockPrimary or .dockSecondary, not .dockPress, which bypasses shared sizing.')
    large = list(LARGE_SIZE.finditer(code))
    if path.startswith("Sources/") and len(large) > LARGE_SIZE_ALLOWED.get(path, 0):
        for match in large:
            line = source.count(chr(10), 0, match.start()) + 1
            result.append(f'{path}:{line}: error: .standard/.accessible are for form footers and decisions only; ordinary page actions use the default .compact (docs/button-sizing.md).')
    return result


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
