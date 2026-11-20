import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('perf', Path(__file__).with_name('check-perf-contract.py'))
perf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(perf)


class PerfContractTests(unittest.TestCase):
    def test_flags_perpetual_motion(self):
        for source in [
            'withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { on = true }',
            'TimelineView(.animation(minimumInterval: 0.1, paused: false)) { _ in }',
            'TimelineView(.periodic(from: .now, by: 0.5)) { _ in }',
            'Circle().phaseAnimator([false, true]) { view, on in view }',
        ]:
            with self.subTest(source=source):
                self.assertTrue(perf.violations(source))

    def test_allows_scheduled_motion(self):
        for source in [
            'TimelineView(.dockMotion(rate: 15, paused: !animates)) { _ in }',
            'TimelineView(.periodic(from: .now, by: 60)) { _ in }',
            'Circle().phaseAnimator([false, true], trigger: count) { view, on in view }',
            '/// `repeatForever` ran at 120Hz, so this uses the shared clock.',
        ]:
            with self.subTest(source=source):
                self.assertFalse(perf.violations(source))

    def test_allow_marker_needs_reason(self):
        line = 'withAnimation(.linear.repeatForever()) { on = true }'
        self.assertFalse(perf.violations('// perf-contract: allow only while dragging\n' + line))
        self.assertTrue(perf.violations('// perf-contract: allow\n' + line))

    def test_flags_per_call_formatters(self):
        self.assertTrue(perf.violations('let date = ISO8601DateFormatter().date(from: raw)'))
        self.assertTrue(perf.violations('return DateFormatter().string(from: date)'))
        self.assertFalse(perf.violations('private static let formatter = ISO8601DateFormatter()'))
        self.assertFalse(perf.violations('let date = ISO8601Parsing.date(raw)'))

    def test_repeating_timers_need_tolerance(self):
        self.assertTrue(perf.violations('timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }'))
        self.assertTrue(perf.violations('let timer = Timer.publish(every: 0.1, on: .main, in: .common)'))
        self.assertFalse(perf.violations('Timer.publish(every: 60, tolerance: 10, on: .main, in: .common)'))
        self.assertFalse(perf.violations(
            'timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in\n  tick()\n}\ntimer?.tolerance = 0.1'))
        self.assertFalse(perf.violations('Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in }'))

    def test_measures_observation_fan_out(self):
        files = {
            Path('DockModel.swift'): '@Published var a = 1\n@Published var b = 2',
            Path('View.swift'): '@ObservedObject var model: DockModel\n@EnvironmentObject private var control: ControlCenterModel',
        }
        measured = perf.measure(files)
        self.assertEqual(measured['DockModel @Published'], 2)
        self.assertEqual(measured['DockModel whole-model observers'], 1)
        self.assertEqual(measured['ControlCenterModel whole-model observers'], 1)


if __name__ == '__main__':
    unittest.main()
