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
print('ok')
