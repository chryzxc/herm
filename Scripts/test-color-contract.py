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
                       'let css = "#112233"', "NSColor.systemTeal", "color(0x112233)",
                       "Color(\n    red: 1, green: 0, blue: 0\n)",
                       "Circle().tint(\n    .purple\n)"]:
            with self.subTest(source=source), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                folder = root / "Sources/Herm/NewFeature"
                folder.mkdir(parents=True)
                (folder / "New.swift").write_text(source)
                self.assertTrue(colors.violations(colors.sources(root), {}))

    def test_tokens_are_allowed_and_central_palette_can_define_colors(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "Sources/Herm/DesignSystem"
            folder.mkdir(parents=True)
            (folder / "DockAccentPalette.swift").write_text('let blue = "#387FF2"')
            (folder / "New.swift").write_text("Circle().fill(Color.dockSuccessFill)\nDockAccentColor.teal.fill")
            self.assertEqual(colors.sources(root), {})

    def test_exception_does_not_allow_another_use_or_file(self):
        allowed = {"Logo.swift": {"Color.blue": 1}}
        self.assertFalse(colors.violations({"Logo.swift": "Color.blue"}, allowed))
        self.assertTrue(colors.violations({"Logo.swift": "Color.blue\nColor.blue"}, allowed))
        self.assertTrue(colors.violations({"New.swift": "Color.blue"}, allowed))

    def test_formatting_preserves_exact_exception_without_allowing_new_colors(self):
        allowed = {"Logo.swift": {'let colors = [Color(red: 1, green: 0, blue: 0)]; draw()': 1}}
        formatted = "let colors = [\n    Color(\n        red: 1, green: 0, blue: 0\n    ),\n]\ndraw()"
        self.assertFalse(colors.violations({"Logo.swift": formatted}, allowed))
        self.assertTrue(colors.violations({"Logo.swift": formatted + "\nColor.blue"}, allowed))
        self.assertTrue(colors.violations({"Logo.swift": formatted.replace("red: 1", "red: 0")}, allowed))
        self.assertTrue(colors.violations({"Logo.swift": formatted + "\n" + formatted}, allowed))

    def test_new_color_inside_existing_collection_is_rejected(self):
        allowed = {"Logo.swift": {'let colors = ["#112233"]': 1}}
        self.assertTrue(colors.violations({"Logo.swift": 'let colors = ["#112233", "#445566"]'}, allowed))

    def test_string_contents_remain_exact(self):
        allowed = {"Logo.swift": {'let css = "color: #112233"': 1}}
        self.assertTrue(colors.violations({"Logo.swift": 'let css = "color:#112233"'}, allowed))

    def test_multiline_diagnostic_keeps_source_line_number(self):
        failures = colors.violations({"New.swift": "\nColor(\n    red: 1, green: 0, blue: 0\n)"}, {})
        self.assertIn("New.swift:2: error:", failures[0])


if __name__ == "__main__":
    unittest.main()
