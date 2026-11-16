import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text()


class BotsNavigationTests(unittest.TestCase):
    def test_roster_is_a_global_destination_not_a_setting(self):
        rail = source('Sources/Herm/Conversation/DockRailDestination.swift')
        settings = source('Sources/Herm/Settings/SettingsComponents.swift')
        navigation = source('Sources/Herm/ControlCenter/WorkspaceActivitySidebar+Navigation.swift')
        self.assertIn('case .bots: .bots', rail)
        self.assertNotIn('case bots\n', settings)
        self.assertIn('selectedMode == .bots', navigation)
        self.assertNotIn('selectedSettingsCategory == .bots', navigation)
        self.assertIn('onOpenRecentBotSession', navigation)

    def test_roster_has_no_routine_management(self):
        roster = source('Sources/Herm/Bots/BotViews.swift').split('/// One New Bot form', 1)[0]
        for obsolete in ('loadRoutines()', 'routinesContent', 'New Routine', 'Remove Routine?', 'BotRosterSection'):
            self.assertNotIn(obsolete, roster)
        self.assertIn('guard hostVisible else { return }', roster)
        self.assertIn('botFilters', roster)
        self.assertIn('botsContent', roster)

    def test_automation_and_independent_bot_chats_remain(self):
        navigation = source('Sources/Herm/ControlCenter/WorkspaceActivitySidebar+Navigation.swift')
        context = source('Sources/Herm/Conversation/DockPopover+Context.swift')
        self.assertIn('AutomationWorkspaceView(', navigation)
        self.assertIn('case .bots: openBotsPage()', context)


if __name__ == '__main__':
    unittest.main()
