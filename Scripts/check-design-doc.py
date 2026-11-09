"""Keep DESIGN.md in its documented order so agents can find the rule they need."""
from pathlib import Path
import re
import sys

PARTS = ['Purpose', 'Product principles', 'Design system', 'Layout and interaction rules',
         'Surface specifications', 'Engineering rules', 'Review checklist']


def violations(text, path='DESIGN.md'):
    findings = []
    paragraphs = [p for p in text.split('\n\n') if p.strip()]
    if len(paragraphs) < 2 or not paragraphs[1].startswith('This document is the source of truth'):
        findings.append(f'{path}:1: error: nothing goes between the title and the introduction; '
                        'put new specs in their surface section.')
    parts = re.findall(r'(?m)^## (.+)$', text)
    if parts != PARTS:
        findings.append(f'{path}:1: error: top-level sections must be exactly {PARTS}; found {parts}.')
    checklist = text.find('\n## Review checklist\n')
    if checklist >= 0:
        for match in re.finditer(r'(?m)^###+ .+$', text[checklist:]):
            number = text[:checklist + match.start()].count('\n') + 1
            findings.append(f'{path}:{number}: error: "{match.group()}" is after the review checklist; '
                            'move it into Design system, Layout and interaction rules, or Surface specifications.')
    return findings


if __name__ == '__main__':
    found = violations(Path('DESIGN.md').read_text())
    print('\n'.join(found) if found else 'Design doc structure passed.')
    sys.exit(1 if found else 0)
