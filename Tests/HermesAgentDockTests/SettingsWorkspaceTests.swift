import Testing
@testable import HermesAgentDock

@Suite("Settings workspace")
struct SettingsWorkspaceTests {
    @Test("categories keep the documented order")
    func categoryOrder() {
        #expect(SettingsCategory.allCases == [.general, .runtime, .integrations, .session, .project, .diagnostics])
        #expect(SettingsCategory.general.title == "General")
        #expect(SettingsCategory.diagnostics.icon == "stethoscope")
    }

    @Test("layout switches at the native compact breakpoint")
    func layoutBreakpoint() {
        #expect(SettingsLayoutMode.forWidth(759) == .menu)
        #expect(SettingsLayoutMode.forWidth(760) == .rail)
        #expect(SettingsLayoutMode.forWidth(920) == .rail)
    }

    @Test("badges expose only actionable states")
    func badgeKinds() {
        #expect(SettingsCategoryBadge(kind: .dot, isWarning: true) != SettingsCategoryBadge(kind: .dot, isWarning: false))
        #expect(SettingsCategoryBadge(kind: .count(2), isWarning: true).kind == .count(2))
    }
}
