import json
import os
from pathlib import Path
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).parent))
import __init__ as herm  # noqa: E402

with tempfile.TemporaryDirectory() as root:
    path = Path(root) / 'agent-surfaces.json'
    os.environ['HERM_AGENT_SURFACES'] = str(path)
    assert herm.rules() == '' and herm.guard('terminal', {'command': 'open https://x'}) is None
    path.write_text(json.dumps(dict(version=1, sessions={'s1': {'herm.browser': 'loaded'}}, surfaces=[dict(
        id='herm.browser', rules='Use browser_navigate.', reference='Ref.',
        guards=[dict(tool='terminal', argument='command', pattern=r'(^|[;&|(]\s*)open\s[^;&|\n]*https?://', message='No.')])])))
    assert herm.rules() == 'Use browser_navigate.'
    assert herm.guard('terminal', {'command': 'cd x && OPEN https://x'}) == dict(action='block', message='No.')
    assert herm.guard('terminal', {'command': 'curl https://x'}) is None
    assert herm.guard('write_file', {'command': 'open https://x'}) is None
    assert json.loads(herm.reference({'surface': 'herm.browser'}, session_id='s1'))['reference'] == 'Ref.\n\nloaded'
    assert 'error' in json.loads(herm.reference({'surface': 'nope'}))
    assert json.loads(herm.inspector({'tab': 'files'}))['schema'] == 'herm.inspector.v1'
    assert 'error' in json.loads(herm.inspector({'tab': '../x'}))
    assert herm.rules({'session_id': 'new'}) == 'Use browser_navigate.' and herm.turn_context(session_id='new') is None
    assert 'supersede' in herm.turn_context(session_id='old')['context'] and herm.turn_context(session_id='old') is None
    path.write_text(json.dumps(dict(version=1, surfaces=[dict(id='herm.browser', rules='Open externally.')])))
    assert herm.turn_context(session_id='new')['context'].endswith('Open externally.')
    path.write_text(json.dumps(dict(version=1, surfaces=[])))
    assert 'no longer apply' in herm.turn_context(session_id='new')['context']

    # MCP Apps: a tool declaring a ui:// view gets a receipt; everything else passes through untouched.
    assert herm.ui_resource_uri({'ui': {'resourceUri': 'ui://s/view'}}) == 'ui://s/view'
    assert herm.ui_resource_uri({'ui/resourceUri': 'ui://s/old'}) == 'ui://s/old'
    assert herm.ui_resource_uri({'ui': {'resourceUri': 'https://x'}}) is None and herm.ui_resource_uri(None) is None
    tool = type('Tool', (), dict(name='show', title='Show', meta={'ui': {'resourceUri': 'ui://s/view'}}))()
    herm._mcp_tool = lambda name: ('srv', tool) if name == 'mcp__srv__show' else (None, None)
    herm._read_view = lambda server, uri: dict(html='<p>hi</p>', csp={'connectDomains': ['https://api.x']})
    result = json.dumps({'result': 'done', 'structuredContent': {'n': 1}})
    assert herm.mcp_app('mcp__srv__show', {'q': 1}, result) is None  # Generative UI off
    path.write_text(json.dumps(dict(version=1, surfaces=[dict(id='herm.generative-ui', rules='UI.')])))
    receipt = json.loads(herm.mcp_app('mcp__srv__show', {'q': 1}, result))['herm_app']
    assert receipt['schema'] == 'herm.mcp-app.v1' and json.loads(result)['result'] == 'done'
    call = json.loads((herm.app_dir() / f"{receipt['id']}.json").read_text())
    assert call['arguments'] == {'q': 1} and call['result']['structuredContent'] == {'n': 1}
    assert call['result']['content'] == [{'type': 'text', 'text': 'done'}] and call['tool']['name'] == 'show'
    assert (herm.app_dir() / f"{call['html']}.html").read_text() == '<p>hi</p>'
    assert call['csp'] == {'connectDomains': ['https://api.x']}
    assert herm.mcp_app('mcp__srv__show', {}, result, status='error') is None
    assert herm.mcp_app('mcp__srv__other', {}, result) is None and herm.mcp_app('terminal', {}, result) is None
print('ok')
