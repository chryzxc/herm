"""Hermes user plugin. Serves the manifest Herm writes; never modifies the Hermes engine."""
import hashlib
import json
import logging
import os
from pathlib import Path
import re
import uuid

DEFAULT_PATH = Path.home() / 'Library/Application Support/Herm/agent-surfaces.json'
GENERATIVE_UI = 'herm.generative-ui'
APP_SCHEMA = 'herm.mcp-app.v1'
APP_HTML_LIMIT = 4 * 1_048_576
APP_CACHE_LIMIT = 200
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


def app_dir():
    return Path(os.environ.get('HERM_AGENT_SURFACES') or DEFAULT_PATH).parent / 'mcp-apps'


def ui_resource_uri(meta):
    """MCP Apps `_meta.ui.resourceUri` (or the older flat `ui/resourceUri`) when it names a `ui://` view."""
    meta = meta if isinstance(meta, dict) else {}
    ui = meta.get('ui')
    uri = ui.get('resourceUri') if isinstance(ui, dict) else meta.get('ui/resourceUri')
    return uri if isinstance(uri, str) and uri.startswith('ui://') else None


def _mcp_tool(tool_name):
    """(server name, MCP Tool) behind a registered Hermes tool name. Hermes has no public API for a tool's `_meta`,
    so this reads its live MCP client; any change there only means no app views."""
    from tools import mcp_tool
    from tools.mcp_tool_schema import mcp_prefixed_tool_name
    for server in list(mcp_tool._servers.values()):
        for tool in list(server._tools):
            if mcp_prefixed_tool_name(server.name, tool.name) == tool_name:
                return server.name, tool
    return None, None


def _read_view(server, uri):
    """`resources/read` through Hermes' own connection, keeping the HTML's mimeType and `_meta.ui`."""
    from tools.mcp_tool_handlers import _make_utility_handler

    def render(result, _server):
        for content in getattr(result, 'contents', []):
            text, mime = getattr(content, 'text', None), str(getattr(content, 'mimeType', '') or '')
            if isinstance(text, str) and mime.startswith('text/html'):
                ui = (getattr(content, 'meta', None) or {}).get('ui')
                ui = ui if isinstance(ui, dict) else {}
                return dict(html=text, csp=ui.get('csp'), prefersBorder=ui.get('prefersBorder'))
        return dict(error='The view is not text/html.')
    read = _make_utility_handler('resources/read', 'read_ui_resource',
                                 lambda session, args, _sn: session.read_resource(args['uri']), render, required='uri')
    return json.loads(read(server, 30)({'uri': uri}))


def _write(path, text):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(text, encoding='utf-8')
    os.replace(temporary, path)


def _prune(directory):
    for pattern in ('*.json', '*.html'):
        files = sorted(directory.glob(pattern), key=lambda p: p.stat().st_mtime, reverse=True)
        for stale in files[APP_CACHE_LIMIT:]:
            stale.unlink(missing_ok=True)


def mcp_app(tool_name='', args=None, result=None, status='', **_):
    """MCP Apps: when a tool declares a `ui://` view, cache the view and this call's input/result for Herm and add a
    short receipt to the result. The model sees only the receipt; Herm renders the view beside the tool step."""
    if (not tool_name.startswith('mcp__') or status == 'error' or not isinstance(result, str)
            or not any(s['id'] == GENERATIVE_UI for s in surfaces())):
        return None
    try:
        payload = json.loads(result)
        server, tool = _mcp_tool(tool_name)
        uri = ui_resource_uri(getattr(tool, 'meta', None))
        if not isinstance(payload, dict) or 'result' not in payload or uri is None:
            return None
        view = _read_view(server, uri)
        html = view.get('html')
        if not isinstance(html, str) or len(html.encode('utf-8')) > APP_HTML_LIMIT:
            return None
        text = payload['result']
        call_result = dict(content=[dict(type='text', text=text if isinstance(text, str) else json.dumps(text))])
        if 'structuredContent' in payload:
            call_result['structuredContent'] = payload['structuredContent']
        if isinstance(payload.get('_meta'), dict):
            call_result['_meta'] = payload['_meta']
        directory = app_dir()
        directory.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha256(html.encode('utf-8')).hexdigest()
        page = directory / f'{digest}.html'
        if page.exists():
            os.utime(page)
        else:
            _write(page, html)
        call_id = uuid.uuid4().hex
        _write(directory / f'{call_id}.json', json.dumps(dict(
            server=server, tool=dict(name=tool.name, title=getattr(tool, 'title', None)), uri=uri, html=digest,
            csp=view.get('csp'), prefersBorder=view.get('prefersBorder'), arguments=args or {}, result=call_result,
        ), ensure_ascii=False, default=str))
        _prune(directory)
        payload['herm_app'] = dict(schema=APP_SCHEMA, id=call_id)
        return json.dumps(payload, ensure_ascii=False)
    except Exception as error:  # Fail open: the tool result reaches the model unchanged.
        logging.getLogger(__name__).debug('herm mcp app view unavailable: %s', error)
        return None


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
    ctx.register_hook('transform_tool_result', mcp_app)
    ctx.register_tool(name='herm_reference', toolset='herm', schema=REFERENCE_SCHEMA, handler=reference,
                      description=REFERENCE_SCHEMA['description'])
    ctx.register_tool(name='herm_inspector', toolset='herm', schema=INSPECTOR_SCHEMA, handler=inspector,
                      description=INSPECTOR_SCHEMA['description'])
