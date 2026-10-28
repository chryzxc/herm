import sys
from pathlib import Path
import unittest
from unittest.mock import patch
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/Herm/Resources/SimulatorBridge'))
import diagnostics as d


class DiagnosticsTests(unittest.TestCase):
    def test_diagnostics_use_the_inventory_resolver_for_path_only_sdk(self):
        with patch.object(d.devices.shutil, 'which', return_value='/custom/sdk/adb'), \
             patch.object(d.devices.os, 'access', return_value=True), \
             patch.object(d, 'command', return_value='hierarchy') as command:
            self.assertEqual(d.adb('emulator-5554', 'devices'), 'hierarchy')
            command.assert_called_once_with(['/custom/sdk/adb', '-s', 'emulator-5554', 'devices'])

    def test_android_bounds_password_and_labels(self):
        xml = '<hierarchy><node bounds="[10,20][50,60]" resource-id="app:id/ok" content-desc="OK" text="secret" password="true"/><node bounds="[0,0][0,0]"/></hierarchy>'
        elements = d.android_elements(xml, 100, 200)
        self.assertEqual(len(elements), 1)
        self.assertEqual(elements[0]['identifier'], 'app:id/ok')
        self.assertEqual(elements[0]['value'], '')
        self.assertEqual(elements[0]['x'], .1)
        self.assertAlmostEqual(elements[0]['height'], .2)
        with self.assertRaises(ValueError):
            d.android_elements('<!DOCTYPE x><hierarchy/>', 100, 200)

    def test_ios_nested_point_bounds_and_missing_frames(self):
        tree = dict(children=[dict(frame=dict(x=10,y=20,width=30,height=40), AXLabel='Continue', AXUniqueId='next', type='Button'), dict(frame=dict(x=0,y=0,width=float('nan'),height=20))])
        elements = d.ios_elements(tree, 100, 200)
        self.assertEqual(len(elements), 1)
        self.assertEqual(elements[0]['label'], 'Continue')
        self.assertEqual(elements[0]['identifier'], 'next')
        self.assertAlmostEqual(elements[0]['height'], .2)

    def test_log_filter_is_scoped_and_arguments_are_literal(self):
        with patch.object(d, 'adb', side_effect=['123\n', 'E test']) as adb:
            result = d.logs('android', 'emulator-5554', 'com.example.app', 'errors')
            self.assertEqual(result['text'], 'E test')
            self.assertIn('--pid=123', adb.call_args.args)
            self.assertIn('*:E', adb.call_args.args)
        with patch.object(d, 'command', return_value='') as command:
            d.logs('ios', 'device', 'MyApp', 'errors')
            words = command.call_args.args[0]
            self.assertEqual(words[3], 'device')
            self.assertIn('process == "MyApp" AND (messageType == error OR messageType == fault)', words)
        for value in ['', 'x" OR TRUE', '$(echo bad)', '../app']:
            with self.assertRaises(RuntimeError):
                d.logs('ios', 'device', value, 'all')

    def test_missing_process_never_returns_whole_device_logs(self):
        with patch.object(d, 'adb', return_value='') as adb:
            with self.assertRaises(RuntimeError):
                d.logs('android', 'device', 'com.example.app', 'all')
            self.assertEqual(adb.call_count, 1)


if __name__ == '__main__':
    unittest.main()
