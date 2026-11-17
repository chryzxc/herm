import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch, Mock

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/Herm/Resources/SimulatorBridge'))
import devices

# Boot tests record ownership; keep them out of the real Herm ledger.
os.environ['HERM_SIMULATOR_ENV'] = tempfile.mkdtemp(prefix='herm-ledger-test-')


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

    def test_boot_records_only_devices_it_started(self):
        devices.save_owned([])
        with patch.object(devices, 'inventory', return_value=[dict(id='emulator-5554', name='Pixel', running=True)]), \
             patch.object(devices, 'android_tools', return_value=['emulator', 'adb']):
            devices.boot('android', 'emulator-5554')
        self.assertEqual(devices.owned(), [])
        with patch.object(devices, 'inventory', return_value=[dict(id='u1', name='Phone', running=False)]), \
             patch.object(devices, 'run', return_value=''):
            devices.boot('ios', 'u1')
            devices.boot('ios', 'u1')
        self.assertEqual(devices.owned(), [dict(platform='ios', key='u1')])

    def test_shutdown_owned_stops_only_ledger_devices_of_that_platform(self):
        devices.save_owned([dict(platform='android', key='Pixel'), dict(platform='ios', key='u1')])
        with patch.object(devices, 'android_tool', return_value='adb'), \
             patch.object(devices, 'android_running', return_value={'Pixel': 'emulator-5554', 'Mine': 'emulator-5556'}), \
             patch.object(devices, 'run', return_value='') as run, \
             patch.object(devices.subprocess, 'run') as simctl:
            devices.shutdown_owned('android')
            self.assertEqual([c.args[0] for c in run.call_args_list], [['adb', '-s', 'emulator-5554', 'emu', 'kill']])
            simctl.assert_not_called()
            self.assertEqual(devices.owned(), [dict(platform='ios', key='u1')])
            devices.shutdown_owned('all')
            self.assertEqual(simctl.call_args.args[0], ['/usr/bin/xcrun', 'simctl', 'shutdown', 'u1'])
        self.assertEqual(devices.owned(), [])

    def test_corrupt_ledger_is_empty(self):
        devices.ledger_path().write_text('{not json')
        self.assertEqual(devices.owned(), [])

    def test_missing_device_never_launches(self):
        with patch.object(devices, 'inventory', return_value=[]), patch.object(devices.subprocess, 'Popen') as launch:
            with self.assertRaises(RuntimeError):
                devices.boot('ios', 'missing')
            launch.assert_not_called()


if __name__ == '__main__':
    unittest.main()
