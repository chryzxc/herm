import importlib.util
import queue
import threading
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "simulator_bridge", Path(__file__).parents[1] / "Sources/Herm/Resources/SimulatorBridge/bridge.py"
)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class FakeDevice:
    def __init__(self):
        self.started = queue.Queue()
        self.stopped = queue.Queue()

    def frames(self, register):
        cancelled = threading.Event()
        if not register(cancelled.set):
            return
        self.started.put(True)
        yield b"frame"
        if not cancelled.wait(timeout=2):
            raise AssertionError("The frame producer was not cancelled")
        self.stopped.put(True)
        raise RuntimeError("The simulated stream was cancelled")


class DisplayTests(unittest.TestCase):
    def test_hiding_cancels_stream_and_reshowing_starts_again(self):
        device = FakeDevice()
        emitted = queue.Queue()
        display = bridge.DisplayStream(device, visible=False)
        worker = threading.Thread(target=display.run, daemon=True)
        with patch.object(bridge, "emit", side_effect=lambda *packet: emitted.put(packet)):
            worker.start()
            try:
                with self.assertRaises(queue.Empty):
                    device.started.get(timeout=0.03)
                display.set_visible(True)
                self.assertTrue(device.started.get(timeout=1))
                self.assertEqual(emitted.get(timeout=1), ("I", b"frame"))
                display.set_visible(False)
                self.assertTrue(device.stopped.get(timeout=1))
                display.set_visible(True, client_revision=9)
                self.assertTrue(device.started.get(timeout=1))
                self.assertEqual(emitted.get(timeout=1), ("J", {"displayReady": 9}))
                self.assertEqual(emitted.get(timeout=1), ("I", b"frame"))
            finally:
                display.close()
                worker.join(timeout=1)
            self.assertFalse(worker.is_alive())
            self.assertTrue(emitted.empty())


if __name__ == "__main__":
    unittest.main()
