"""Hermes user plugin. Uses supported tools/events; never modifies the Hermes engine."""
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import threading
import time

_LOCK = threading.Lock()


def run(words, timeout=20):
    result = subprocess.run(words, capture_output=True, text=True, timeout=timeout, check=False)
    if result.returncode:
        # CLI output may contain local paths or credentials; return an actionable bounded error instead.
        raise RuntimeError(f"{Path(words[0]).name} {words[1] if len(words) > 1 else ''} failed (exit {result.returncode}). Check the device in Xcode or Android Studio, then retry.")
    return result.stdout.strip()


def executable(name, fallback=None):
    path = shutil.which(name)
    if not path and fallback and fallback.is_file() and os.access(fallback, os.X_OK):
        path = str(fallback)
    if not path:
        raise RuntimeError(f"{name} is unavailable. Install/select Xcode for iOS or install Android SDK tools for Android.")
    return path


def resolve_platform(requested, project):
    if requested in ('ios', 'android'):
        return requested
    if requested != 'auto':
        raise RuntimeError('Platform must be auto, ios, or android.')
    if not project:
        raise RuntimeError('Platform is ambiguous. Use the conversation context or ask the user iOS or Android.')
    root = Path(project).expanduser().resolve(strict=True)
    if not root.is_dir():
        raise RuntimeError('Project path must be a directory.')
    names = {p.name for p in root.iterdir()}
    ios = 'ios' in names or any(n.endswith(('.xcodeproj', '.xcworkspace')) for n in names)
    android = 'android' in names or 'build.gradle' in names or 'build.gradle.kts' in names
    if ios == android:
        raise RuntimeError('Project does not identify one platform. Use the conversation context or ask iOS or Android.')
    return 'ios' if ios else 'android'


def choose(devices, requested):
    if requested:
        matches = [d for d in devices if requested.casefold() in (d['id'].casefold(), d['name'].casefold())]
    else:
        running = [d for d in devices if d['running']]
        matches = running if running else devices
    if len(matches) != 1:
        return None
    return matches[0]


def ios_inventory():
    xcrun = executable('xcrun')
    rows = json.loads(run([xcrun, 'simctl', 'list', 'devices', 'available', '--json']))['devices']
    devices = []
    for runtime, entries in rows.items():
        if '.iOS-' not in runtime:
            continue
        for item in entries:
            if item.get('isAvailable') and item.get('state') in ('Booted', 'Shutdown'):
                devices.append(dict(id=item['udid'], name=item['name'], running=item['state'] == 'Booted'))
    return devices


def android_tools():
    sdk = Path(os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME') or Path.home() / 'Library/Android/sdk')
    return executable('emulator', sdk / 'emulator/emulator'), executable('adb', sdk / 'platform-tools/adb')


def android_running(adb):
    result = {}
    for line in run([adb, 'devices']).splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[0].startswith('emulator-') and fields[1] == 'device':
            name = run([adb, '-s', fields[0], 'emu', 'avd', 'name']).splitlines()[0]
            result[name] = fields[0]
    return result


def android_inventory():
    emulator, adb = android_tools()
    running = android_running(adb)
    return [dict(id=name, name=name, running=name in running) for name in run([emulator, '-list-avds']).splitlines() if name]


def launch_ios(device):
    xcrun = executable('xcrun')
    if not device['running']:
        run([xcrun, 'simctl', 'boot', device['id']])
    run([xcrun, 'simctl', 'bootstatus', device['id'], '-b'], timeout=120)
    return device['id']


def launch_android(device):
    emulator, adb = android_tools()
    child = None
    if not device['running']:
        # Direct display/input uses the authenticated local emulator controller.
        child = subprocess.Popen([emulator, '-avd', device['id'], '-no-window', '-grpc-use-token'], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        if child and child.poll() is not None:
            raise RuntimeError('Android emulator exited during startup. Open the AVD in Android Studio to diagnose, then retry.')
        serial = android_running(adb).get(device['id'])
        if serial and run([adb, '-s', serial, 'shell', 'getprop', 'sys.boot_completed']) == '1':
            return serial
        time.sleep(2)
    raise RuntimeError('Android device did not finish booting within two minutes. It may still be booting; inspect Android Studio and retry. The device was not terminated.')


def handle(args, **kwargs):
    try:
        if not isinstance(args, dict):
            raise RuntimeError('Expected structured simulator arguments.')
        if any(not isinstance(value, str) for value in args.values()):
            raise RuntimeError('Simulator arguments must be strings.')
        action = args.get('action', 'launch')
        if action not in ('launch', 'list'):
            raise RuntimeError('Action must be launch or list.')
        target = resolve_platform(args.get('platform', 'auto'), args.get('project_path'))
        if not _LOCK.acquire(blocking=False):
            raise RuntimeError('Another simulator launch is in progress. Wait for it to finish, then retry.')
        try:
            devices = ios_inventory() if target == 'ios' else android_inventory()
            if not devices:
                raise RuntimeError('No installed devices. Create/download a device in Xcode or Android Studio, then retry.')
            selected = choose(devices, args.get('device'))
            if action == 'list' or selected is None:
                return json.dumps(dict(status='devices' if action == 'list' else 'selection_required', platform=target,
                                       devices=devices, message='Choose an exact device id using the user’s context; ask if still ambiguous.'))
            device_id = launch_ios(selected) if target == 'ios' else launch_android(selected)
            return json.dumps(dict(schema='herm.simulator.v1', status='ready', platform=target,
                                   device_id=device_id, device_name=selected['name'], host=platform.node(),
                                   message='Device booted. Herm connects directly to its display and input in this chat. The local simulator bridge must be installed. Do not claim the display is connected until the user can see it.'))
        finally:
            _LOCK.release()
    except subprocess.TimeoutExpired:
        return json.dumps(dict(error='Device command timed out. It may still be starting. Inspect the simulator and retry; do not start a duplicate device.'))
    except (OSError, ValueError, KeyError, TypeError, IndexError, RuntimeError):
        # Known operational diagnostics are safe; unexpected malformed tool/CLI data is generic.
        import sys
        error = sys.exc_info()[1]
        message = str(error) if isinstance(error, RuntimeError) else 'Invalid request or device inventory. Specify ios/android, list devices, and use an exact device id.'
        return json.dumps(dict(error=message))


SCHEMA = {
    'name': 'herm_simulator',
    'description': ('Use when the user asks to launch/open an iOS simulator or Android emulator in Herm, or needs a device to run a mobile app. '
                    'Infer platform from conversation/project context, reuse a matching running device, and prefer a device the user named. '
                    'Use auto with project_path for unambiguous projects. If selection_required, use context or ask; never guess between platforms. '
                    'After launch, build/install/run the app with existing project tools using the returned device_id when requested. '
                    'Launch returns a structured receipt that opens the simulator tab in the owning Herm chat. This runs on the gateway Mac; no remote display forwarding.'),
    'parameters': {'type': 'object', 'properties': {
        'action': {'type': 'string', 'enum': ['list', 'launch']},
        'platform': {'type': 'string', 'enum': ['auto', 'ios', 'android']},
        'project_path': {'type': 'string', 'description': 'Absolute directory of the current session project.'},
        'device': {'type': 'string', 'description': 'Exact device id or name from inventory; omit to reuse the sole running or sole installed device.'}
    }, 'required': ['action', 'platform'], 'additionalProperties': False}
}


def register(ctx):
    ctx.register_tool(name='herm_simulator', toolset='terminal', schema=SCHEMA, handler=handle,
                      check_fn=lambda: platform.system() == 'Darwin', description=SCHEMA['description'])
