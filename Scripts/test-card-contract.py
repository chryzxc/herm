import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('cards', Path(__file__).with_name('check-card-contract.py'))
cards = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cards)


class CardContractTests(unittest.TestCase):
    def test_flags_filled_and_stroked_shapes(self):
        for source in [
            'x.background(RoundedRectangle(cornerRadius: 8).fill(Color.dockSurface))\n.overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.dockBorderLight))',
            'x.background(\nDockThemeShape(cornerRadius: r)\n.dockSurfaceFill(Color.dockSurface2,\nstroke: Color.dockBorder))',
        ]:
            with self.subTest(source=source):
                self.assertTrue(cards.violations(source))

    def test_flags_unstroked_surface_boxes(self):
        self.assertTrue(cards.violations('x.background(RoundedRectangle(cornerRadius: 8).fill(Color.dockSurface))'))

    def test_flags_hand_built_capsules(self):
        self.assertTrue(cards.violations('x.background(Capsule().fill(Color.dockSurface4))'))
        self.assertTrue(cards.violations('    Capsule().fill(Color.dockBorderLight)'))

    def test_allows_unstroked_fills_and_dockcard(self):
        for source in [
            'x.dockCard(padding: 12)',
            'x.dockPill(tint: .dockAccent)',
        ]:
            with self.subTest(source=source):
                self.assertFalse(cards.violations(source))


if __name__ == '__main__':
    unittest.main()
