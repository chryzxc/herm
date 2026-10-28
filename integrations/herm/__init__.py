"""Hermes user plugin. Serves the manifest Herm writes; never modifies the Hermes engine."""
import json
import os
from pathlib import Path
import re

DEFAULT_PATH = Path.home() / 'Library/Application Support/Herm/agent-surfaces.json'
RULE_BUDGET = 4000
TABS = ('timeline', 'artifacts', 'files', 'changes', 'diff', 'terminal', 'browser', 'github')
_cache = {}
# ponytail: in-memory; after a Hermes restart each session gets the current rules once more.
_sent = {}  # session ID -> rules the session last received (system prompt or turn context)


def manifest():
    """Re-reads only when Herm rewrote the file; missing or malformed means no surfaces."""
    path = Path(os.environ.get('HERM_AGENT_SURFACES') or DEFAULT_PATH)
    try:
        stamp = path.stat().st_mtime_ns
        if _cache.get('stamp') != stamp:
            data = json.loads(path.read_bytes()[:1_048_576])
            _cache.update(stamp=stamp, data=data if isinstance(data, dict) else {})
    except (OSError, ValueError):
        _cache.clear()
        return {}
    return _cache['data']


def surfaces():
    return [s for s in manifest().get('surfaces') or [] if isinstance(s, dict) and isinstance(s.get('id'), str)]


def rules(session_info=None):
    text = '\n\n'.join(s['rules'].strip() for s in surfaces() if isinstance(s.get('rules'), str))[:RULE_BUDGET]
    if session_id := (session_info or {}).get('session_id'):
        _sent[session_id] = text
    return text


def turn_context(session_id='', **_):
    """System-prompt rules freeze at session start. When Herm settings changed since (or the session
    predates the plugin), the current rules ride this turn's context once; the transcript stays clean."""
    current = rules()
    if not session_id or _sent.get(session_id) == current:
        return None
    _sent[session_id] = current
    if not current:
        return dict(context='[Herm settings changed] Earlier Herm rules no longer apply.')
    return dict(context='[Herm settings changed] These Herm rules supersede earlier ones:\n' + current)


def guard(tool_name='', args=None, **_):
    """Guards are live: a setting change in Herm applies to running sessions on the next tool call."""
    for surface in surfaces():
        for rule in surface.get('guards') or []:
            value = (args or {}).get(rule.get('argument')) if isinstance(rule, dict) else None
            if rule.get('tool') != tool_name or not isinstance(value, str):
                continue
            try:
                if re.search(rule.get('pattern', ''), value, re.IGNORECASE):
                    return dict(action='block', message=rule.get('message') or 'Blocked by Herm.')
            except re.error:
                continue
    return None


def reference(args, session_id='', **_):
    surface = (args or {}).get('surface')
    match = next((s for s in surfaces() if s['id'] == surface), None)
    if match is None:
        return json.dumps(dict(error='Unknown surface. Available: ' + ', '.join(s['id'] for s in surfaces())))
    extra = (manifest().get('sessions') or {}).get(session_id, {}).get(surface)
    text = '\n\n'.join(t for t in (match.get('reference'), extra) if isinstance(t, str) and t)
    return json.dumps(dict(surface=surface, reference=text or 'No reference beyond the session rules.'))


def inspector(args, **_):
    tab = (args or {}).get('tab')
    if tab not in TABS:
        return json.dumps(dict(error='Tab must be one of: ' + ', '.join(TABS) + '.'))
    # Herm reads this receipt from the tool result and opens the tab in the owning chat.
    return json.dumps(dict(schema='herm.inspector.v1', tab=tab,
                           message='Herm opens this tab in the chat when it is running; it does not change the tab contents.'))


REFERENCE_SCHEMA = {
    'name': 'herm_reference',
    'description': 'Fetch the full Herm reference for a surface named in the session rules (for example herm.generative-ui).',
    'parameters': {'type': 'object', 'properties': {'surface': {'type': 'string'}},
                   'required': ['surface'], 'additionalProperties': False},
}

INSPECTOR_SCHEMA = {
    'name': 'herm_inspector',
    'description': ('Show a tab in the Herm inspector beside this chat when the user asks to see it or when pointing them at '
                    'your work helps: files (explorer), changes (source control), diff, terminal, browser, timeline, '
                    'artifacts, github. Opening a tab only shows it; use normal tools to change files, run commands or browse.'),
    'parameters': {'type': 'object', 'properties': {'tab': {'type': 'string', 'enum': list(TABS)}},
                   'required': ['tab'], 'additionalProperties': False},
}


def register(ctx):
    ctx.register_system_prompt_section('herm', rules)
    ctx.register_hook('pre_tool_call', guard)
    ctx.register_hook('pre_llm_call', turn_context)
    ctx.register_tool(name='herm_reference', toolset='herm', schema=REFERENCE_SCHEMA, handler=reference,
                      description=REFERENCE_SCHEMA['description'])
    ctx.register_tool(name='herm_inspector', toolset='herm', schema=INSPECTOR_SCHEMA, handler=inspector,
                      description=INSPECTOR_SCHEMA['description'])
