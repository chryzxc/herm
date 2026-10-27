import sys
import unittest
from pathlib import Path
from unittest.mock import patch, Mock

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/Herm/Resources/SimulatorBridge'))
import devices


class DeviceTests(unittest.TestCase):
    def test_ios_inventory_includes_stopped_and_filters_other_platforms(self):
        payload = '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26":[{"udid":"a","name":"Phone","state":"Shutdown","isAvailable":true},{"udid":"b","name":"Phone 2","state":"Booted","isAvailable":true}],"watchOS-26":[{"udid":"c","name":"Watch","state":"Booted","isAvailable":true}]}}'
        with patch.object(devices, 'run', return_value=payload):
            self.assertEqual([d['running'] for d in devices.inventory('ios')], [False, True])

    def test_android_inventory_distinguishes_launch_id_from_live_serial(self):
        with patch.object(devices, 'android_tools', return_value=['emulator', 'adb']), \
             patch.object(devices, 'android_running', return_value={'Pixel': 'emulator-5554'}), \
             patch.object(devices, 'run', return_value='Pixel\nTablet'):
            self.assertEqual(devices.inventory('android'), [
                dict(id='emulator-5554', name='Pixel', running=True),
                dict(id='avd:Tablet', name='Tablet', running=False)])

    def test_boot_reuses_device_started_since_inventory(self):
        with patch.object(devices, 'inventory', return_value=[dict(id='emulator-5554', name='Pixel', running=True)]), \
             patch.object(devices, 'android_tools', return_value=['emulator', 'adb']), \
             patch.object(devices.subprocess, 'Popen') as launch:
            self.assertEqual(devices.boot('android', 'avd:Pixel'), 'emulator-5554')
            launch.assert_not_called()

    def test_android_boot_is_headless_and_authenticated(self):
        child = Mock()
        child.poll.return_value = None
        with patch.object(devices, 'inventory', return_value=[dict(id='avd:Pixel', name='Pixel', running=False)]), \
             patch.object(devices, 'android_tools', return_value=['emulator', 'adb']), \
             patch.object(devices, 'android_running', return_value={'Pixel': 'emulator-5554'}), \
             patch.object(devices, 'run', return_value='1'), \
             patch.object(devices.subprocess, 'Popen', return_value=child) as launch:
            self.assertEqual(devices.boot('android', 'avd:Pixel'), 'emulator-5554')
            self.assertEqual(launch.call_args.args[0], ['emulator', '-avd', 'Pixel', '-no-window', '-grpc-use-token'])

    def test_missing_device_never_launches(self):
        with patch.object(devices, 'inventory', return_value=[]), patch.object(devices.subprocess, 'Popen') as launch:
            with self.assertRaises(RuntimeError):
                devices.boot('ios', 'missing')
            launch.assert_not_called()


if __name__ == '__main__':
    unittest.main()
