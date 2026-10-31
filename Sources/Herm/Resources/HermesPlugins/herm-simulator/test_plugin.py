import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch

spec = importlib.util.spec_from_file_location('herm_simulator_plugin', Path(__file__).with_name('__init__.py'))
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class SimulatorTests(unittest.TestCase):
    def test_registers_launch_and_direct_navigation_tools(self):
        context = MagicMock()
        p.register(context)
        calls = context.register_tool.call_args_list
        self.assertEqual([call.kwargs['name'] for call in calls], ['herm_simulator', 'herm_simulator_interact'])
        self.assertEqual(calls[1].kwargs['schema']['parameters']['required'], ['action', 'platform', 'device_id'])

    @patch.object(p.Path, 'is_file', return_value=True)
    @patch.object(p.subprocess, 'Popen')
    def test_interaction_uses_stdin_and_private_capture_path(self, popen, is_file):
        child = popen.return_value
        child.returncode = 0
        def start(*args, **kwargs):
            kwargs['stdout'].write(b'{"status":"captured","device_id":"exact"}')
            return child
        popen.side_effect = start
        request = dict(action='tap', platform='ios', device_id='exact', x=.2, y=.3)
        self.assertEqual(json.loads(p.interact(request))['status'], 'captured')
        words = popen.call_args.args[0]
        self.assertEqual(words[1], '-B')
        self.assertTrue(words[2].endswith('/resources/agent.py'))
        self.assertTrue(words[3].startswith(p._CAPTURES.name))
        self.assertNotIn('shell', popen.call_args.kwargs)
        child.communicate.assert_called_once_with(json.dumps(request).encode(), timeout=60)

    @patch.object(p.Path, 'is_file', return_value=True)
    @patch.object(p.subprocess, 'Popen')
    def test_timeout_terminates_action_and_requires_capture(self, popen, is_file):
        popen.return_value.communicate.side_effect = p.subprocess.TimeoutExpired('bridge', 60)
        result = json.loads(p.interact(dict(action='capture', platform='ios', device_id='exact')))
        self.assertIn('may have been delivered', result['error'])
        popen.return_value.terminate.assert_called_once()
        popen.return_value.wait.assert_called_once_with(timeout=8)
        self.assertFalse(p._LOCK.locked())

    @patch.object(p.Path, 'is_file', return_value=False)
    def test_missing_bridge_reports_setup(self, is_file):
        result = json.loads(p.interact(dict(action='capture', platform='ios', device_id='exact')))
        self.assertIn('setting up simulator controls', result['error'])

    def test_project_detection_and_ambiguity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'ios').mkdir()
            self.assertEqual(p.resolve_platform('auto', directory), 'ios')
            (root / 'android').mkdir()
            with self.assertRaises(RuntimeError):
                p.resolve_platform('auto', directory)
            self.assertEqual(p.resolve_platform('android', directory), 'android')

    def test_running_reuse_and_no_guessing(self):
        a = dict(id='a', name='Phone', running=False)
        b = dict(id='b', name='Tablet', running=True)
        self.assertEqual(p.choose([a, b], None), b)
        self.assertEqual(p.choose([a, b], 'a'), a)
        self.assertIsNone(p.choose([a, b], 'unknown'))
        self.assertEqual(p.choose([a, dict(b, running=False)], None), a)
        self.assertIsNone(p.choose([], None))
        self.assertIsNone(p.choose([a, dict(a, id='duplicate')], 'Phone'))

    @patch.object(p, 'ios_inventory')
    @patch.object(p, 'launch_ios')
    def test_structured_receipt_only_after_confirmed_launch(self, launch, inventory):
        inventory.return_value = [dict(id='uuid', name='Phone', running=True)]
        launch.return_value = 'uuid'
        result = json.loads(p.handle(dict(action='launch', platform='ios')))
        self.assertEqual(result['schema'], 'herm.simulator.v1')
        self.assertEqual(result['device_id'], 'uuid')
        self.assertEqual(result['status'], 'ready')
        launch.side_effect = RuntimeError('Device failed to boot.')
        result = json.loads(p.handle(dict(action='launch', platform='ios')))
        self.assertIn('error', result)
        self.assertNotIn('schema', result)

    @patch.object(p, 'ios_inventory')
    @patch.object(p, 'launch_ios')
    def test_unknown_device_and_list_never_launch(self, launch, inventory):
        inventory.return_value = [dict(id=str(i), name=str(i), running=False) for i in range(2)]
        self.assertEqual(json.loads(p.handle(dict(action='launch', platform='ios', device='x')))['status'], 'selection_required')
        self.assertEqual(json.loads(p.handle(dict(action='list', platform='ios')))['status'], 'devices')
        launch.assert_not_called()

    @patch.object(p, 'ios_inventory')
    @patch.object(p, 'launch_ios', return_value='0')
    def test_nothing_booted_boots_preferred_device(self, launch, inventory):
        inventory.return_value = [dict(id=str(i), name=str(i), running=False) for i in range(2)]
        self.assertEqual(json.loads(p.handle(dict(action='launch', platform='ios')))['device_id'], '0')
        launch.assert_called_once_with(inventory.return_value[0])

    @patch.object(p, 'run')
    @patch.object(p, 'executable', return_value='/usr/bin/xcrun')
    def test_inventory_prefers_newest_iphone(self, executable, run):
        run.return_value = json.dumps({'devices': {
            'com.apple.CoreSimulator.SimRuntime.iOS-26-5': [dict(udid='pad', name='iPad Air', state='Shutdown', isAvailable=True)],
            'com.apple.CoreSimulator.SimRuntime.iOS-18-0': [dict(udid='old', name='iPhone 15', state='Shutdown', isAvailable=True)],
            'com.apple.CoreSimulator.SimRuntime.iOS-26-4': [dict(udid='new', name='iPhone 17', state='Shutdown', isAvailable=True)]}})
        self.assertEqual([d['id'] for d in p.ios_inventory()], ['new', 'old', 'pad'])

    @patch.object(p, 'run')
    @patch.object(p, 'executable', return_value='/usr/bin/xcrun')
    def test_inventory_excludes_unavailable_and_other_platforms(self, executable, run):
        run.return_value = json.dumps({'devices': {
            'com.apple.CoreSimulator.SimRuntime.iOS-18-0': [
                dict(udid='ok', name='Phone', state='Booted', isAvailable=True),
                dict(udid='bad', name='Other', state='Shutdown', isAvailable=False)],
            'com.apple.CoreSimulator.SimRuntime.watchOS-11-0': [
                dict(udid='watch', name='Watch', state='Booted', isAvailable=True)]}})
        self.assertEqual(p.ios_inventory(), [dict(id='ok', name='Phone', running=True)])

    def test_invalid_arguments_fail_without_launch(self):
        for args in [None, {'platform': []}, {'platform': 'windows'}, {'platform': 'ios', 'action': 'delete'}]:
            self.assertIn('error', json.loads(p.handle(args)))

    @patch.object(p, 'android_tools', return_value=('/sdk/emulator', '/sdk/adb'))
    @patch.object(p, 'android_running', return_value={'Phone': 'emulator-5554'})
    @patch.object(p, 'run', return_value='1')
    @patch.object(p.subprocess, 'Popen')
    def test_android_running_device_is_reused(self, popen, run, running, tools):
        self.assertEqual(p.launch_android(dict(id='Phone', running=True)), 'emulator-5554')
        popen.assert_not_called()
        run.assert_called_once_with(['/sdk/adb', '-s', 'emulator-5554', 'shell', 'getprop', 'sys.boot_completed'])

    @patch.object(p, 'android_tools', return_value=('/sdk/emulator', '/sdk/adb'))
    @patch.object(p, 'android_running', return_value={'Phone': 'emulator-5554'})
    @patch.object(p, 'run', return_value='1')
    @patch.object(p.subprocess, 'Popen')
    def test_new_android_device_has_no_window_and_requires_token(self, popen, run, running, tools):
        popen.return_value.poll.return_value = None
        p.launch_android(dict(id='Phone', running=False))
        self.assertEqual(popen.call_args.args[0], ['/sdk/emulator', '-avd', 'Phone', '-no-window', '-grpc-use-token'])

    @patch.object(p, 'executable', return_value='/usr/bin/xcrun')
    @patch.object(p, 'run', return_value='')
    def test_ios_boot_never_opens_simulator_app(self, run, executable):
        self.assertEqual(p.launch_ios(dict(id='uuid', running=False)), 'uuid')
        self.assertEqual([call.args[0] for call in run.call_args_list], [
            ['/usr/bin/xcrun', 'simctl', 'boot', 'uuid'],
            ['/usr/bin/xcrun', 'simctl', 'bootstatus', 'uuid', '-b']])

    @patch.object(p.subprocess, 'run')
    def test_commands_are_argument_vectors_with_timeout_and_no_shell(self, run):
        run.return_value.returncode = 0
        run.return_value.stdout = 'ok'
        words = ['/sdk/emulator', '-avd', 'name with spaces; echo unsafe']
        self.assertEqual(p.run(words), 'ok')
        run.assert_called_once_with(words, capture_output=True, text=True, timeout=20, check=False)


if __name__ == '__main__':
    unittest.main()
