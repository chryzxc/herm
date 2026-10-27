"""Regression checks for the client/backend naming distinction."""
import runpy
from pathlib import Path
import unittest

violations = runpy.run_path(str(Path(__file__).with_name('check-naming-contract.py')))['violations']


class NamingContractTests(unittest.TestCase):
    def test_rejects_default_names_and_client_copy(self):
        for source in ['return "Hermes"', 'Text("Hermes can\'t browse.")',
                       'Text("HERMES IS THINKING")', 'Button("Prepare in Hermes")',
                       '.accessibilityLabel("Hermes navigation")']:
            with self.subTest(source=source):
                self.assertTrue(violations(source))

    def test_preserves_backend_contracts_and_names(self):
        source = '''
        Text("Herm")
        Text("Connect to Hermes")
        Text("Hermes Agent")
        let command = "hermes update"
        let executable = "hermes"
        let method = "session.create"
        let path = "~/.hermes"
        let key = "HERMES_HOME"
        NSError(domain: "Hermes", code: 1)
        if error.domain == "Hermes" {}
        Text(bot.name)
        // Default used to be "Hermes".
        '''
        self.assertEqual(violations(source), [])

    def test_skin_exception_is_scoped(self):
        source = 'case .hermesClassic: "Hermes"'
        self.assertEqual(violations(source, 'Sources/Herm/DesignSystem/DockTheme.swift'), [])
        self.assertTrue(violations(source))


if __name__ == '__main__':
    unittest.main()
