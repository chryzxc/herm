"""On-demand, bounded device diagnostics; no desktop capture or persistent logs."""
import json
import math
import os
from pathlib import Path
import re
import subprocess
import tempfile
import uuid
import xml.etree.ElementTree as ET

LIMIT = 1024 * 1024


def command(words):
    # Spool outside memory and never expose raw subprocess errors or environment.
    with tempfile.TemporaryFile() as output:
        result = subprocess.run(words, stdout=output, stderr=subprocess.DEVNULL, timeout=20)
        if result.returncode:
            raise RuntimeError('Device command failed. Check the app, SDK, and device connection.')
        output.seek(0)
        data = output.read(LIMIT + 1)
        if len(data) > LIMIT:
            raise RuntimeError('Diagnostic output is too large. Narrow the app filter and retry.')
        return data.decode('utf-8', errors='replace')


def adb(device, *words):
    roots = [os.environ.get('ANDROID_SDK_ROOT', ''), os.environ.get('ANDROID_HOME', ''),
             str(Path.home() / 'Library/Android/sdk')]
    executable = next((str(Path(root) / 'platform-tools/adb') for root in roots
                       if root and os.access(Path(root) / 'platform-tools/adb', os.X_OK)), None)
    if not executable:
        raise RuntimeError('Android diagnostics require SDK platform-tools (adb).')
    return command([executable, '-s', device, *words])


def element(rect, width, height, label='', identifier='', role='', value=''):
    x, y, w, h = map(float, rect)
    if not all(math.isfinite(v) for v in (x, y, w, h, width, height)) or min(w, h, width, height) <= 0:
        return None
    left, top = max(0, x / width), max(0, y / height)
    right, bottom = min(1, (x + w) / width), min(1, (y + h) / height)
    if right <= left or bottom <= top:
        return None
    return dict(x=left, y=top, width=right-left, height=bottom-top,
                label=str(label or '')[:500], identifier=str(identifier or '')[:500],
                role=str(role or '')[:200], value=str(value or '')[:500])


def android_elements(xml, width, height):
    if '<!DOCTYPE' in xml or '<!ENTITY' in xml:
        raise ValueError('Unsupported XML')
    root = ET.fromstring(xml)
    result = []
    for node in root.iter('node'):
        match = re.fullmatch(r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]', node.get('bounds', ''))
        if not match:
            continue
        x, y, right, bottom = map(int, match.groups())
        item = element((x, y, right-x, bottom-y), width, height,
                       node.get('content-desc'), node.get('resource-id'), node.get('class'),
                       '' if node.get('password') == 'true' else node.get('text'))
        if item:
            result.append(item)
        if len(result) >= 2000:
            break
    return result


def ios_elements(document, width, height):
    pending = list(document) if isinstance(document, list) else [document]
    result = []
    visited = 0
    while pending and visited < 10000:
        node = pending.pop()
        visited += 1
        if not isinstance(node, dict):
            continue
        pending.extend(node.get('children', []))
        frame = node.get('frame', {})
        if not isinstance(frame, dict):
            continue
        item = element([frame.get(key, 0) for key in ('x', 'y', 'width', 'height')], width, height,
                       node.get('AXLabel', node.get('label', '')),
                       node.get('AXUniqueId', node.get('identifier', '')),
                       node.get('type', node.get('role', '')),
                       node.get('AXValue', node.get('value', '')))
        if item:
            result.append(item)
        if len(result) >= 2000:
            break
    return result


def inspect(backend, platform, device):
    if platform == 'android':
        path = '/data/local/tmp/herm-ui-' + uuid.uuid4().hex + '.xml'
        try:
            adb(device, 'shell', 'uiautomator', 'dump', path)
            xml = adb(device, 'exec-out', 'cat', path)
            elements = android_elements(xml, backend.width, backend.height)
        finally:
            try:
                adb(device, 'shell', 'rm', '-f', path)
            except Exception:
                pass
        return dict(elements=elements, detail='Android UI hierarchy snapshot')
    method = backend.channel.unary_unary('/idb.CompanionService/accessibility_info',
        request_serializer=lambda x: x.SerializeToString(),
        response_deserializer=backend.pb.AccessibilityInfoResponse.FromString)
    response = method(backend.pb.AccessibilityInfoRequest(format=1), timeout=15)
    if len(response.json) > LIMIT:
        raise RuntimeError('Accessibility hierarchy is too large. Select a screenshot region instead.')
    return dict(elements=ios_elements(json.loads(response.json), backend.width, backend.height),
                detail='iOS accessibility hierarchy snapshot')


def logs(platform, device, app, severity):
    if not re.fullmatch(r'[A-Za-z0-9_.:-]{1,200}', app):
        raise RuntimeError('Enter an Android package ID or iOS process name using letters, digits, dots, underscores, colons, or hyphens.')
    if severity not in ('errors', 'all'):
        raise ValueError('Invalid severity')
    if platform == 'android':
        pids = adb(device, 'shell', 'pidof', app).strip().split()
        if not pids or not all(pid.isdecimal() for pid in pids):
            raise RuntimeError('App process was not found. Open the app and check its package ID.')
        text = adb(device, 'logcat', '-d', '-t', '500', '--pid=' + pids[0], '-v', 'threadtime',
                   '*:E' if severity == 'errors' else '*:V')
        scope = 'Android Logcat · main process ' + pids[0] + ' · last 500 buffered entries'
    else:
        predicate = 'process == "' + app + '"'
        if severity == 'errors':
            predicate += ' AND (messageType == error OR messageType == fault)'
        text = command(['/usr/bin/xcrun', 'simctl', 'spawn', device, 'log', 'show', '--last', '2m',
                        '--style', 'compact', '--predicate', predicate])
        scope = 'iOS unified log · last 2 minutes'
    return dict(text=text[-24000:], detail=scope + (' · excerpt truncated' if len(text) > 24000 else ''))
