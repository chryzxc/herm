from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SplitColumnOwnershipTests(unittest.TestCase):
    def test_panes_use_window_models_without_binding_or_focusing_them(self):
        views = (ROOT / "Sources/Herm/Conversation/SessionPaneViews.swift").read_text()
        layout = (ROOT / "Sources/Herm/Conversation/DockPopover+Layout.swift").read_text()
        pane = views.split("struct SessionPaneChat:", 1)[1].split("private struct ColumnResizeCursor:", 1)[0]
        self.assertNotIn("ControlCenterModel()", pane)
        self.assertNotIn("BotModeModel()", pane)
        self.assertNotIn("control.bind(", pane)
        self.assertNotIn("control.focus(", pane)
        self.assertIn("control: controlCenter, bots: botMode", layout)
        self.assertIn("SessionPaneChat(model: conversation, control: control, bots: bots, metrics: metrics)", views)


if __name__ == "__main__":
    unittest.main()
