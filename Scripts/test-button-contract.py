import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('buttons', Path(__file__).with_name('check-button-contract.py'))
buttons = importlib.util.module_from_spec(spec)
spec.loader.exec_module(buttons)


class ButtonContractTests(unittest.TestCase):
    def test_rejects_press_style_on_text_actions_and_inherited_groups(self):
        for source in [
            'Button("Save") {}.buttonStyle(.dockPress)',
            'Button(title, role: .destructive) {}.disabled(true).buttonStyle(DockPressButtonStyle())',
            'DockAsyncButton("Refresh") { await refresh() }.buttonStyle(.dockPress)',
            'Button {} label: { DockActionLabel(title: "Test", isPending: busy) }.buttonStyle(.dockPress)',
            'Button {} label: { Text("Restart").frame(width: 140) }.buttonStyle(.dockPress)',
            'Button {} label: { DockIconLabel("Sync", icon: .arrowsClockwise) }.buttonStyle(.dockPress)',
            'HStack { Button("New") {}; Button("Remove") {} }.buttonStyle(.dockPress)',
        ]:
            with self.subTest(source=source):
                self.assertTrue(buttons.violations(source))

    def test_large_sizes_need_a_reviewed_allowance(self):
        source = 'HStack { Button("Record") {}.buttonStyle(.dockPrimary) }.dockButtonSize(.standard)'
        self.assertTrue(buttons.violations(source, 'Sources/Herm/Settings/New.swift'))
        self.assertEqual(buttons.violations(source, 'Sources/Herm/DesignSystem/DockModal.swift'), [])
        self.assertEqual(buttons.violations(source.replace('.standard', '.compact')), [])

    def test_press_style_allows_icon_controls_and_content_rows(self):
        for source in [
            'Button {} label: { DockIcon(.x).frame(width: 28, height: 28) }.buttonStyle(.dockPress)',
            'Button(action: close) { DockIcon(.x) }.buttonStyle(DockPressButtonStyle())',
            'HStack { Button( action: close) { DockIcon(.x) } }.buttonStyle(.dockPress)',
            'Button {} label: { HStack { Text("Provider"); Spacer(); DockIcon(.caretDown) } }.buttonStyle(.dockPress)',
            '// Button("Save") {}.buttonStyle(.dockPress)',
        ]:
            with self.subTest(source=source):
                self.assertEqual(buttons.violations(source), [])

    def test_rejects_root_label_geometry_and_individual_size(self):
        for source in [
            'Button {} label: { Text("Go").frame(height: 36) }.buttonStyle(.dockPrimary)',
            'Button {} label: { HStack { Text("Go") }.padding(.vertical, 9) }.buttonStyle(.dockCompact)',
            'Button("Go") {}.frame(minHeight: 44).buttonStyle(.dockSecondary)',
            'Button("Go") {}.buttonStyle(.dockPrimary).disabled(true).dockButtonSize(.standard)',
            'Button {} label: { Text("Go").frame(\nminHeight: 36\n) }.buttonStyle(DockSecondaryButtonStyle())',
            'Button("Go") {}.buttonStyle(DockSecondaryButtonStyle(compact: true))',
        ]:
            with self.subTest(source=source):
                self.assertTrue(buttons.violations(source))

    def test_allows_container_size_icons_width_and_outer_layout(self):
        for source in [
            'HStack { Button("Go") {}.buttonStyle(.dockPrimary) }.dockButtonSize(.standard)',
            'Button {} label: { HStack { Image("icon").frame(width: 14, height: 14); Text("Go") } }.buttonStyle(.dockCompact)',
            'Button {} label: { Text("Go").frame(minWidth: 80) }.buttonStyle(.dockSecondary)',
            'Button("Go") {}.buttonStyle(.dockSecondary).padding(.vertical, 12)',
            'Button {} label: { Image("icon").frame(height: 24) }.buttonStyle(.dockHover)',
            '// Button {} label: { Text("Go").frame(height: 33) }.buttonStyle(.dockPrimary)',
            'let example = "Button {} label: { Text().frame(height: 33) }.buttonStyle(.dockPrimary)"',
        ]:
            with self.subTest(source=source):
                self.assertEqual(buttons.violations(source), [])

    def test_reports_original_line_number(self):
        result = buttons.violations('Button {} label: {\n Text("Go")\n .frame(height: 33)\n}.buttonStyle(.dockPrimary)', 'Page.swift')
        self.assertIn('Page.swift:3: error:', result[0])


if __name__ == '__main__':
    unittest.main()
