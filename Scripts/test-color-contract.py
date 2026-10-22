import importlib.util
from pathlib import Path
import tempfile
import sys
import unittest

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("colors", Path(__file__).with_name("check-colors.py"))
colors = importlib.util.module_from_spec(spec)
spec.loader.exec_module(colors)


class ColorContractTests(unittest.TestCase):
    def test_new_feature_literals_and_system_accents_are_rejected(self):
        for source in ["Color(red: 1, green: 0, blue: 0)", "Color.blue", ".tint(.purple)",
                       'let css = "#112233"', "NSColor.systemTeal", "color(0x112233)"]:
            with self.subTest(source=source), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                folder = root / "Sources/Herm/NewFeature"
                folder.mkdir(parents=True)
                (folder / "New.swift").write_text(source)
                self.assertTrue(colors.violations(colors.occurrences(root), {}))

    def test_tokens_are_allowed_and_central_palette_can_define_colors(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "Sources/Herm/DesignSystem"
            folder.mkdir(parents=True)
            (folder / "DockAccentPalette.swift").write_text('let blue = "#387FF2"')
            (folder / "New.swift").write_text("Circle().fill(Color.dockSuccessFill)\nDockAccentColor.teal.fill")
            self.assertEqual(colors.occurrences(root), {})

    def test_exception_does_not_allow_another_use_or_file(self):
        allowed = {"Logo.swift": {"Color.blue": 1}}
        self.assertFalse(colors.violations(allowed, allowed))
        self.assertTrue(colors.violations({"Logo.swift": {"Color.blue": 2}}, allowed))
        self.assertTrue(colors.violations({"New.swift": {"Color.blue": 1}}, allowed))


if __name__ == "__main__":
    unittest.main()
