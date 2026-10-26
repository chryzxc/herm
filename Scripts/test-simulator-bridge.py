import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1] / 'Sources/Herm/Resources/SimulatorBridge'
sys.path.insert(0, str(ROOT))
import bridge
import emulator_controller_pb2 as android
import idb_pb2 as ios


class BridgeTests(unittest.TestCase):
    def test_coordinates_are_clamped_and_finite(self):
        self.assertEqual(bridge.coordinate(1, 100), 99)
        self.assertEqual(bridge.coordinate(-1, 100), 0)
        for value in [float('nan'), float('inf')]:
            with self.assertRaises(ValueError):
                bridge.coordinate(value, 100)

    def test_jpeg_dimensions_follow_rotation(self):
        for width, height in [(1206, 2622), (2622, 1206)]:
            jpeg = b'\xff\xd8\xff\xc0\x00\x0b\x08' + height.to_bytes(2, 'big') + width.to_bytes(2, 'big') + b'\x01\x01\x11\x00'
            self.assertEqual(bridge.jpeg_dimensions(jpeg), (width, height))
        with self.assertRaises(ValueError):
            bridge.jpeg_dimensions(b'invalid')

    def test_android_touch_release_and_key_up(self):
        backend = bridge.Android.__new__(bridge.Android)
        backend.pb, backend.width, backend.height = android, 100, 200
        backend.point, backend.keys = None, set()
        events = []
        backend.rpc = lambda name, request: events.append((name, request))
        backend.input(dict(kind='touch', phase='down', x=.5, y=1))
        self.assertEqual(events[-1][1].touches[0].y, 199)
        backend.input(dict(kind='key', phase='down', code=0))
        backend.input(dict(kind='release'))
        self.assertEqual(events[-2][1].touches[0].pressure, 0)
        self.assertEqual(events[-1][1].eventType, android.KeyboardEvent.keyup)
        self.assertEqual(backend.keys, set())
        self.assertIsNone(backend.point)

    def test_no_unauthenticated_android_connection(self):
        with patch.object(bridge, 'android_targets', return_value=[(dict(id='emulator-5554'), {'grpc.port': '8554'})]):
            with self.assertRaisesRegex(RuntimeError, 'access token'):
                bridge.Android('emulator-5554')
        with patch.object(bridge, 'android_targets', return_value=[]):
            with self.assertRaisesRegex(RuntimeError, 'no longer running'):
                bridge.Android('emulator-5554')

    def test_ios_input_uses_device_points_and_releases(self):
        from concurrent.futures import Future
        backend = bridge.IOS.__new__(bridge.IOS)
        backend.pb, backend.width, backend.height = ios, 400, 800
        backend.point, backend.keys, backend.hid = None, set(), Future()
        events = []
        backend.press = lambda action, up: events.append((action, up))
        backend.input(dict(kind='touch', phase='down', x=.5, y=.25))
        self.assertEqual(events[-1][0].touch.point.x, 200)
        self.assertEqual(events[-1][0].touch.point.y, 200)
        backend.input(dict(kind='key', phase='down', code=0))
        self.assertEqual(events[-1][0].key.keycode, 4)
        backend.input(dict(kind='release'))
        self.assertTrue(all(up for _, up in events[-2:]))
        self.assertIsNone(backend.point)
        self.assertEqual(backend.keys, set())
        backend.input(dict(kind='button', name='home'))
        self.assertEqual(events[-1][0].button.button, ios.HIDEvent.HOME)
        self.assertTrue(events[-1][1])

    def test_ios_inventory_excludes_shutdown_and_other_platforms(self):
        with patch.object(bridge, 'run', return_value='{"devices":{"runtime.iOS-26":[{"udid":"a","name":"Phone","state":"Booted","isAvailable":true},{"udid":"b","name":"Other","state":"Shutdown","isAvailable":true}],"runtime.watchOS-26":[]}}'):
            self.assertEqual(bridge.devices('ios'), [dict(id='a', name='Phone')])


if __name__ == '__main__':
    unittest.main()
