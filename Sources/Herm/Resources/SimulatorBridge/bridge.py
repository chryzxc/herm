"""Local-only device bridge. stdout: length-prefixed JSON or encoded image packets."""
import json
import math
import os
from pathlib import Path
import queue
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time

MAX_PACKET = 32 * 1024 * 1024
WRITE_LOCK = threading.Lock()


def emit(kind, value):
    data = value if isinstance(value, bytes) else json.dumps(value).encode()
    if len(data) > MAX_PACKET:
        raise RuntimeError('Device frame exceeds the supported size.')
    with WRITE_LOCK:
        sys.stdout.buffer.write(kind.encode() + struct.pack('>I', len(data)) + data)
        sys.stdout.buffer.flush()


def run(words):
    result = subprocess.run(words, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=15)
    if result.returncode:
        raise RuntimeError('Device discovery failed. Check the selected Xcode or Android SDK and retry.')
    return result.stdout.decode()


def android_targets():
    root = Path.home() / 'Library/Caches/TemporaryItems/avd/running'
    targets = []
    for path in root.glob('pid_*.ini'):
        try:
            os.kill(int(path.stem[4:]), 0)
            values = dict(line.split('=', 1) for line in path.read_text().splitlines() if '=' in line)
            port = int(values['grpc.port'])
            serial = int(values['port.serial'])
            if not 0 < port < 65536 or not 0 < serial < 65536:
                continue
            targets.append((dict(id=f'emulator-{serial}', name=values.get('avd.name', f'Android {serial}')), values))
        except (OSError, ValueError, KeyError):
            continue
    return targets


def devices(platform):
    if platform == 'android':
        return [item for item, _ in android_targets()]
    rows = json.loads(run(['/usr/bin/xcrun', 'simctl', 'list', 'devices', 'booted', '--json']))
    return [dict(id=d['udid'], name=d['name']) for runtime, entries in rows['devices'].items()
            if '.iOS-' in runtime for d in entries if d.get('isAvailable') and d['state'] == 'Booted']


def coordinate(value, extent):
    value = float(value)
    if not math.isfinite(value) or extent <= 0:
        raise ValueError('Invalid coordinate')
    return min(extent - 1, max(0, round(value * extent)))


def jpeg_dimensions(data):
    """Read the encoded frame size so rotation changes input coordinates too."""
    offset = 2
    while offset + 4 <= len(data) and data[offset] == 255:
        marker = data[offset + 1]
        length = int.from_bytes(data[offset + 2:offset + 4], 'big')
        if length < 2 or offset + 2 + length > len(data):
            break
        if marker in (192, 193, 194) and length >= 7:
            return (int.from_bytes(data[offset + 7:offset + 9], 'big'),
                    int.from_bytes(data[offset + 5:offset + 7], 'big'))
        offset += 2 + length
    raise ValueError('Invalid JPEG dimensions')


class Android:
    def __init__(self, device):
        import grpc
        import emulator_controller_pb2 as pb
        self.pb = pb
        matches = [values for item, values in android_targets() if item['id'] == device]
        if len(matches) != 1:
            raise RuntimeError('The selected Android emulator is no longer running. Refresh devices.')
        values = matches[0]
        token = values.get('grpc.token')
        if not token:
            raise RuntimeError('This emulator has no local access token. Start it with -grpc-use-token and retry.')
        self.channel = grpc.insecure_channel('127.0.0.1:' + values['grpc.port'])
        self.metadata = [('authorization', 'Bearer ' + token)]
        self.width = self.height = 0
        self.point = None
        self.keys = set()

    def rpc(self, name, request, response=None):
        method = self.channel.unary_unary('/android.emulation.control.EmulatorController/' + name,
                                         request_serializer=lambda x: x.SerializeToString(),
                                         response_deserializer=response.FromString if response else lambda x: x)
        return method(request, metadata=self.metadata, timeout=5)

    def frames(self):
        method = self.channel.unary_stream('/android.emulation.control.EmulatorController/streamScreenshot',
                                          request_serializer=lambda x: x.SerializeToString(),
                                          response_deserializer=self.pb.Image.FromString)
        for frame in method(self.pb.ImageFormat(format=0), metadata=self.metadata):
            self.width, self.height = frame.format.width, frame.format.height
            if frame.image:
                yield frame.image

    def input(self, event):
        kind = event['kind']
        if kind == 'touch':
            x, y = coordinate(event['x'], self.width), coordinate(event['y'], self.height)
            up = event['phase'] == 'up'
            self.point = None if up else (x, y)
            self.rpc('sendTouch', self.pb.TouchEvent(touches=[self.pb.Touch(x=x, y=y, identifier=0, pressure=0 if up else 1)]))
        elif kind == 'key':
            code = int(event['code'])
            up = event['phase'] == 'up'
            self.keys.discard(code) if up else self.keys.add(code)
            self.rpc('sendKey', self.pb.KeyboardEvent(codeType=4, eventType=1 if up else 0, keyCode=code))
        elif kind == 'button':
            key = {'home': 'GoHome', 'back': 'GoBack', 'apps': 'AppSwitch', 'power': 'Power'}[event['name']]
            self.rpc('sendKey', self.pb.KeyboardEvent(eventType=2, key=key))
        elif kind == 'release':
            if self.point:
                x, y = self.point
                self.rpc('sendTouch', self.pb.TouchEvent(touches=[self.pb.Touch(x=x, y=y, identifier=0, pressure=0)]))
                self.point = None
            for code in list(self.keys):
                self.input(dict(kind='key', code=code, phase='up'))

    def close(self):
        try:
            self.input(dict(kind='release'))
        finally:
            self.channel.close()


class IOS:
    def __init__(self, device):
        import grpc
        import idb_pb2 as pb
        self.pb = pb
        self.child = None
        self.channel = None
        self.events = queue.Queue(maxsize=256)
        self.video_stop = threading.Event()
        self.point = None
        self.keys = set()
        self.directory = tempfile.TemporaryDirectory(prefix='herm-idb-')
        companion = next((p for p in ['/opt/homebrew/bin/idb_companion', '/usr/local/bin/idb_companion'] if os.access(p, os.X_OK)), None)
        if not companion:
            self.directory.cleanup()
            raise RuntimeError('Install the iOS bridge with brew install facebook/fb/idb-companion, then retry.')
        socket = str(Path(self.directory.name) / 'companion.sock')
        try:
            self.child = subprocess.Popen([companion, '--udid', device, '--grpc-domain-sock', socket],
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.channel = grpc.insecure_channel('unix:' + socket)
            grpc.channel_ready_future(self.channel).result(timeout=20)
            method = self.channel.unary_unary('/idb.CompanionService/describe',
                                             request_serializer=lambda x: x.SerializeToString(),
                                             response_deserializer=pb.TargetDescriptionResponse.FromString)
            target = method(pb.TargetDescriptionRequest(), timeout=5).target_description
            if target.udid != device or target.target_type.lower() != 'simulator':
                raise RuntimeError('The iOS companion connected to an unexpected target.')
            size = target.screen_dimensions
            self.density = size.width / size.width_points if size.width_points else size.density or 1
            self.width = size.width_points or size.width / self.density
            self.height = size.height_points or size.height / (size.density or 1)
            if self.width <= 0 or self.height <= 0:
                raise RuntimeError('The iOS companion did not report display dimensions.')
            method = self.channel.stream_unary('/idb.CompanionService/hid',
                                              request_serializer=lambda x: x.SerializeToString(),
                                              response_deserializer=lambda x: x)
            self.hid = method.future(iter(self.events.get, None))
        except BaseException:
            # Cancellation during startup must also remove the owned companion.
            self.close()
            raise

    def frames(self):
        pb = self.pb
        method = self.channel.stream_stream('/idb.CompanionService/video_stream',
                                            request_serializer=lambda x: x.SerializeToString(),
                                            response_deserializer=pb.VideoStreamResponse.FromString)
        stop = self.video_stop
        def requests():
            yield pb.VideoStreamRequest(start=pb.VideoStreamRequest.Start(fps=30, format=2, compression_quality=0.8))
            stop.wait()
        buffer = bytearray()
        try:
            for response in method(requests()):
                buffer.extend(response.payload.data)
                if len(buffer) > MAX_PACKET:
                    raise RuntimeError('Invalid iOS video frame.')
                while True:
                    start = buffer.find(b'\xff\xd8')
                    end = buffer.find(b'\xff\xd9', max(0, start))
                    if start < 0 or end < 0:
                        break
                    frame = bytes(buffer[start:end + 2])
                    width, height = jpeg_dimensions(frame)
                    self.width, self.height = width / self.density, height / self.density
                    yield frame
                    del buffer[:end + 2]
        finally:
            stop.set()

    def press(self, action, up):
        self.events.put(self.pb.HIDEvent(press=self.pb.HIDEvent.HIDPress(action=action, direction=1 if up else 0)), timeout=2)

    def input(self, event):
        pb = self.pb
        if self.hid.done():
            self.hid.result()
            raise RuntimeError('iOS input connection ended. Reconnect to continue.')
        kind = event['kind']
        if kind == 'touch':
            x, y = coordinate(event['x'], self.width), coordinate(event['y'], self.height)
            self.point = (x, y)
            action = pb.HIDEvent.HIDPressAction(touch=pb.HIDEvent.HIDTouch(point=pb.Point(x=x, y=y)))
            self.press(action, event['phase'] == 'up')
            if event['phase'] == 'up':
                self.point = None
        elif kind == 'key':
            # macOS virtual key codes -> USB HID usage codes used by idb.
            keys = {0:4, 1:22, 2:7, 3:9, 4:11, 5:10, 6:29, 7:27, 8:6, 9:25, 11:5,
                    12:20, 13:26, 14:8, 15:21, 16:28, 17:23, 18:30, 19:31, 20:32, 21:33,
                    22:35, 23:34, 24:46, 25:38, 26:36, 27:45, 28:37, 29:39, 30:48, 31:18,
                    32:24, 33:47, 34:12, 35:19, 36:40, 37:15, 38:13, 39:52, 40:14, 41:51,
                    42:49, 43:54, 44:56, 45:17, 46:16, 47:55, 48:43, 49:44, 50:53, 51:42,
                    53:41, 56:225, 60:229, 123:80, 124:79, 125:81, 126:82}
            code = keys.get(int(event['code']))
            if code is None:
                return
            up = event['phase'] == 'up'
            self.keys.discard(code) if up else self.keys.add(code)
            self.press(pb.HIDEvent.HIDPressAction(key=pb.HIDEvent.HIDKey(keycode=code)), up)
        elif kind == 'button':
            code = {'home': 1, 'power': 2}[event['name']]
            action = pb.HIDEvent.HIDPressAction(button=pb.HIDEvent.HIDButton(button=code))
            self.press(action, False)
            self.press(action, True)
        elif kind == 'release':
            if self.point:
                x, y = self.point
                self.press(pb.HIDEvent.HIDPressAction(touch=pb.HIDEvent.HIDTouch(point=pb.Point(x=x, y=y))), True)
                self.point = None
            for code in self.keys:
                self.press(pb.HIDEvent.HIDPressAction(key=pb.HIDEvent.HIDKey(keycode=code)), True)
            self.keys.clear()

    def close(self):
        self.video_stop.set()
        if hasattr(self, 'hid'):
            try:
                self.input(dict(kind='release'))
                self.events.put(None, timeout=1)
                self.hid.result(timeout=2)
            except Exception:
                self.hid.cancel()
        if self.channel:
            self.channel.close()
        if self.child:
            self.child.terminate()
            try:
                self.child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.wait()
        self.directory.cleanup()


def main():
    backend = None
    done = threading.Event()
    try:
        platform, device = sys.argv[1:3]
        import devices as device_manager
        if len(sys.argv) > 3 and sys.argv[3] == 'boot':
            emit('J', dict(booted=device_manager.boot(platform, device)))
            return
        try:
            inventory = device_manager.inventory(platform)
        except RuntimeError as error:
            emit('J', dict(devices=[], setup=str(error)))
            return
        import importlib.util
        setup = None
        if importlib.util.find_spec('grpc') is None or (importlib.util.find_spec('google') is None or importlib.util.find_spec('google.protobuf') is None):
            setup = 'Install the Herm simulator bridge dependencies, then check again.'
        elif platform == 'ios' and not any(os.access(p, os.X_OK) for p in ['/opt/homebrew/bin/idb_companion', '/usr/local/bin/idb_companion']):
            setup = 'Install the iOS companion with brew install facebook/fb/idb-companion, then check again.'
        emit('J', dict(devices=inventory, setup=setup))
        if setup:
            return
        if not device:
            return
        if any(d['id'] == device and not d['running'] for d in inventory):
            return
        backend = Android(device) if platform == 'android' else IOS(device)
        def frames():
            try:
                for frame in backend.frames():
                    emit('I', frame)
                if not done.is_set():
                    emit('J', dict(error='Device stream ended. Reconnect to continue.'))
            except Exception:
                if not done.is_set():
                    emit('J', dict(error='Device stream failed. Check the device and bridge version, then reconnect.'))
        threading.Thread(target=frames, daemon=True).start()
        diagnostic_busy = threading.Lock()
        def diagnostic(event):
            request = event.get('request', '')
            try:
                import diagnostics
                result = (diagnostics.inspect(backend, platform, device) if event['kind'] == 'inspect'
                          else diagnostics.logs(platform, device, event.get('app', ''), event.get('severity', 'errors')))
                emit('J', dict(diagnostic=dict(request=request, **result)))
            except Exception:
                emit('J', dict(diagnostic=dict(request=request, error=(
                    'Inspection unavailable. Open the app and retry, or drag a screenshot region.' if event['kind'] == 'inspect'
                    else 'Logs unavailable. Check the app filter, running process, and SDK tools, then retry.'))))
            finally:
                diagnostic_busy.release()
        for line in sys.stdin:
            if len(line) > 8192:
                raise ValueError('Input too large')
            event = json.loads(line)
            if event.get('kind') in ('inspect', 'logs'):
                if diagnostic_busy.acquire(blocking=False):
                    threading.Thread(target=diagnostic, args=(event,), daemon=True).start()
                else:
                    emit('J', dict(diagnostic=dict(request=event.get('request', ''), error='Another diagnostic request is still running. Retry shortly.')))
            else:
                backend.input(event)
    except (KeyboardInterrupt, SystemExit):
        pass
    except ImportError:
        emit('J', dict(error='Install the Herm simulator bridge dependencies, then retry.'))
    except RuntimeError as error:
        emit('J', dict(error=str(error)))
    except Exception:
        emit('J', dict(error='Direct device connection failed. Check the local bridge installation and retry.'))
    finally:
        done.set()
        if backend:
            backend.close()


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    main()
