"""SDK inventory and explicit headless boot. Never opens or captures a desktop window."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


def run(words, timeout=20):
    result = subprocess.run(words, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
    if result.returncode:
        raise RuntimeError('Device command failed. Check the selected SDK and device configuration, then retry.')
    if len(result.stdout) > 4 * 1024 * 1024:
        raise RuntimeError('Device inventory exceeded the supported size.')
    return result.stdout.decode().strip()


def android_tool(name):
    sdk = Path(os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME') or Path.home() / 'Library/Android/sdk')
    relative = 'emulator/emulator' if name == 'emulator' else 'platform-tools/adb'
    path = shutil.which(name) or str(sdk / relative)
    if not os.access(path, os.X_OK):
        raise RuntimeError('Android SDK tools are missing. Install Emulator and Platform-Tools in Android Studio’s SDK Manager, then check again.')
    return path


def android_tools():
    return android_tool('emulator'), android_tool('adb')


def android_running(adb):
    found = {}
    for line in run([adb, 'devices']).splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[0].startswith('emulator-') and fields[1] == 'device':
            name = run([adb, '-s', fields[0], 'emu', 'avd', 'name']).splitlines()[0]
            found[name] = fields[0]
    return found


def ledger_path():
    root = os.environ.get('HERM_SIMULATOR_ENV') or Path.home() / 'Library/Application Support/Herm/simulator-bridge'
    return Path(root) / 'owned-devices.json'


def owned():
    try:
        rows = json.loads(ledger_path().read_text())
        return [r for r in rows if isinstance(r, dict) and r.get('platform') in ('ios', 'android') and isinstance(r.get('key'), str)]
    except (OSError, ValueError):
        return []


def save_owned(rows):
    path = ledger_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(rows))
    temporary.replace(path)


def own(platform, key):
    """Record a device Herm booted (iOS udid or AVD name) so Herm, and only Herm, shuts it down later."""
    rows = [r for r in owned() if (r['platform'], r['key']) != (platform, key)]
    save_owned(rows + [dict(platform=platform, key=key)])


def shutdown_owned(platform='all'):
    """Shut down Herm-booted devices; devices the user started elsewhere are never in the ledger."""
    rows = owned()
    kept = []
    for row in rows:
        if platform not in ('all', row['platform']):
            kept.append(row)
            continue
        try:
            if row['platform'] == 'ios':
                # Fails harmlessly when the simulator is already shut down.
                subprocess.run(['/usr/bin/xcrun', 'simctl', 'shutdown', row['key']], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=20)
            else:
                adb = android_tool('adb')
                serial = android_running(adb).get(row['key'])
                if serial:
                    run([adb, '-s', serial, 'emu', 'kill'])
        except (RuntimeError, OSError, subprocess.TimeoutExpired):
            pass
    save_owned(kept)


def inventory(platform):
    if platform == 'ios':
        try:
            rows = json.loads(run(['/usr/bin/xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
        except (RuntimeError, OSError):
            raise RuntimeError('iOS tools are unavailable. Install and select full Xcode, finish its first-launch setup, then check again.')
        return [dict(id=d['udid'], name=d['name'], running=d['state'] == 'Booted')
                for runtime, entries in rows['devices'].items() if '.iOS-' in runtime
                for d in entries if d.get('isAvailable') and d['state'] in ('Booted', 'Shutdown')]
    emulator, adb = android_tools()
    running = android_running(adb)
    return [dict(id=running.get(name, 'avd:' + name), name=name, running=name in running)
            for name in run([emulator, '-list-avds']).splitlines() if name]


def boot(platform, device_id):
    # Re-read inventory before launch: a device may have booted since the picker was populated.
    rows = inventory(platform)
    matches = [d for d in rows if d['id'] == device_id or
               (platform == 'android' and device_id == 'avd:' + d['name'])]
    if len(matches) != 1:
        raise RuntimeError('Device is no longer available. Check again and choose a device.')
    device = matches[0]
    if platform == 'ios':
        if not device['running']:
            run(['/usr/bin/xcrun', 'simctl', 'boot', device['id']])
            own('ios', device['id'])
        run(['/usr/bin/xcrun', 'simctl', 'bootstatus', device['id'], '-b'], timeout=120)
        return device['id']
    emulator, adb = android_tools()
    if device['running']:
        return device['id']
    child = subprocess.Popen([emulator, '-avd', device['name'], '-no-window', '-grpc-use-token'],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
    own('android', device['name'])
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        if child.poll() is not None:
            raise RuntimeError('Emulator exited during startup. Check this virtual device in Android Studio.')
        serial = android_running(adb).get(device['name'])
        if serial and run([adb, '-s', serial, 'shell', 'getprop', 'sys.boot_completed']) == '1':
            return serial
        time.sleep(2)
    raise RuntimeError('Device is still starting. Check again before trying to start another device.')
