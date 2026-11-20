from pathlib import Path
import unittest


class ComposerRestoreQuotaTests(unittest.TestCase):
    def test_quota_and_context_hidden_until_session_ready(self):
        source = (Path(__file__).resolve().parents[1] / 'Sources/Herm/Conversation/ChatComposerView.swift').read_text()
        toolbar = source[source.index('// Right Toolbar Group:'):source.index('if !speechInput.isRecording', source.index('// Right Toolbar Group:'))]
        self.assertIn('if !model.isRestoringSession && model.sessionActionsReady {', toolbar)
        self.assertLess(toolbar.index('if !model.isRestoringSession && model.sessionActionsReady {'), toolbar.index('ChatQuotaChip('))
        self.assertIn('if let controlCenter, let selectedModelOptionID {', toolbar)
        self.assertIn('selectedProvider: selectedModelOptionID.components(separatedBy: "|").first)', toolbar)
        self.assertLess(toolbar.index('SessionContextRing(model: model)'), toolbar.rindex('}'))


if __name__ == '__main__':
    unittest.main()
