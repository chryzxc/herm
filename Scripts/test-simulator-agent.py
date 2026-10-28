"""Direct agent controls use fake devices: no simulator boot or live input."""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/Herm/Resources/SimulatorBridge'))
import agent


class AgentTests(unittest.TestCase):
    def request(self, **extra):
        return dict(action='capture', platform='ios', device_id='exact-device', **extra)

    def test_rejects_invalid_actions_before_connecting(self):
        cases = [
            None, {}, dict(action='delete', platform='ios', device_id='x'),
            dict(action='tap', platform='ios', device_id='x', x=True, y=0),
            dict(action='tap', platform='ios', device_id='x', x=float('nan'), y=0),
            dict(action='swipe', platform='android', device_id='x', x=0, y=0, to_x=1, to_y=2),
            dict(action='button', platform='ios', device_id='x', button='back'),
            dict(action='key', platform='ios', device_id='x', key='run'),
            self.request(duration=float('inf')), self.request(unknown='field'),
        ]
        for request in cases:
            with self.subTest(request=request), patch.object(agent.bridge, 'devices') as devices:
                with self.assertRaises((ValueError, TypeError)):
                    agent.execute(request, '/unused')
                devices.assert_not_called()

    def test_exact_running_device_required(self):
        with patch.object(agent.bridge, 'devices', return_value=[dict(id='other')]), patch.object(agent.bridge, 'IOS') as ios:
            with self.assertRaisesRegex(RuntimeError, 'exact device'):
                agent.execute(self.request(), '/unused')
            ios.assert_not_called()

    @patch.object(agent.time, 'sleep')
    def test_swipe_releases_at_destination(self, sleep):
        backend = MagicMock()
        agent.perform(backend, dict(action='swipe', platform='android', x=.2, y=.8, to_x=.2, to_y=.1, duration=.1))
        events = [call.args[0] for call in backend.input.call_args_list]
        self.assertEqual(events[0], dict(kind='touch', phase='down', x=.2, y=.8))
        self.assertEqual(events[-1], dict(kind='release'))
        self.assertEqual(events[-2]['phase'], 'up')
        self.assertAlmostEqual(events[-2]['y'], .1)

    @patch.object(agent.time, 'sleep')
    def test_failed_swipe_still_releases_touch(self, sleep):
        backend = MagicMock()
        def send(event):
            if event.get('phase') == 'move':
                raise RuntimeError('lost connection')
        backend.input.side_effect = send
        with self.assertRaises(RuntimeError):
            agent.perform(backend, dict(action='swipe', platform='android', x=0, y=0, to_x=1, to_y=1))
        self.assertEqual(backend.input.call_args_list[-1].args[0]['phase'], 'up')

    @patch.object(agent.time, 'sleep')
    def test_ios_input_is_acknowledged_before_capture(self, sleep):
        backend = MagicMock()
        agent.perform(backend, dict(action='key', platform='ios', key='enter'))
        self.assertEqual(backend.input.call_args_list[0].args[0]['code'], 36)
        backend.events.put.assert_called_once_with(None, timeout=1)
        backend.hid.result.assert_called_once_with(timeout=5)

    def test_capture_and_inspection_failure_preserve_image_and_close(self):
        backend = MagicMock()
        with tempfile.TemporaryDirectory() as directory, patch.object(agent.bridge, 'devices', return_value=[dict(id='exact-device')]), patch.object(agent.bridge, 'IOS', return_value=backend), patch.object(agent, 'screenshot', return_value=b'png'), patch.object(agent.diagnostics, 'inspect', side_effect=RuntimeError):
            output = Path(directory) / 'screen.png'
            result = agent.execute(self.request(), output)
            self.assertEqual(output.read_bytes(), b'png')
            self.assertFalse(result['input_delivered'])
            self.assertIn('inspection_error', result)
            backend.close.assert_called_once()
            backend.input.assert_not_called()

    @patch.object(agent.time, 'sleep')
    def test_post_action_failure_does_not_invite_duplicate_input(self, sleep):
        backend = MagicMock()
        with patch.object(agent.bridge, 'devices', return_value=[dict(id='exact-device')]), patch.object(agent.bridge, 'IOS', return_value=backend), patch.object(agent, 'screenshot', side_effect=[b'png', RuntimeError()]):
            with self.assertRaisesRegex(RuntimeError, 'Input was delivered'):
                agent.execute(dict(action='button', platform='ios', device_id='exact-device', button='home'), '/unused')
            backend.close.assert_called_once()

    def test_ios_rotated_capture_updates_touch_dimensions(self):
        backend = MagicMock()
        backend.density = 2
        backend.channel.unary_unary.return_value.return_value.image_data = (
            b'\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR' + (1600).to_bytes(4, 'big') + (800).to_bytes(4, 'big'))
        agent.screenshot(backend, 'ios')
        self.assertEqual((backend.width, backend.height), (800, 400))

    def test_android_capture_updates_dimensions_and_rejects_non_png(self):
        backend = MagicMock()
        backend.rpc.return_value.image = b'\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR' + (400).to_bytes(4, 'big') + (800).to_bytes(4, 'big')
        backend.rpc.return_value.format.width = 400
        backend.rpc.return_value.format.height = 800
        agent.screenshot(backend, 'android')
        self.assertEqual((backend.width, backend.height), (400, 800))
        backend.rpc.return_value.image = b'bad'
        with self.assertRaises(RuntimeError):
            agent.screenshot(backend, 'android')


if __name__ == '__main__':
    unittest.main()
