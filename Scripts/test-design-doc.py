import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('check', Path(__file__).with_name('check-design-doc.py'))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

GOOD = '# Herm\n\nThis document is the source of truth.\n\n' + ''.join(
    f'## {part}\n\nText.\n\n' for part in check.PARTS)


class DesignDocTests(unittest.TestCase):
    def test_documented_order_passes(self):
        self.assertEqual(check.violations(GOOD), [])

    def test_appended_sections_and_stray_intro_text_fail(self):
        self.assertEqual(len(check.violations(GOOD + '### New surface\n\nSpec.\n')), 1)
        stray = GOOD.replace('# Herm\n\n', '# Herm\n\nNew spec sentence.\n\n')
        self.assertEqual(len(check.violations(stray)), 1)


if __name__ == '__main__':
    unittest.main()
