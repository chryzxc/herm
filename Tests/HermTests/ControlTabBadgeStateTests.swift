import Foundation
import Testing

@testable import Herm

struct ControlTabBadgeStateTests {
    @Test func keepsDailyWorkInThePrimaryNavigationAndGroupsSupportingViews() {
        #expect(ControlTab.primaryNavigation == [.kanban])
        #expect(ControlTab.sessionNavigation == [.changes])
        #expect(ControlTab.workspaceNavigation == [.projects])
        #expect(ControlTab.toolsNavigation == [.automations, .search, .officePreview, .core])
        #expect(
            ControlTab.globalNavigation.map(\.rawValue) == [
                "Kanban", "Projects", "Integrations", "Quota", "Usage", "Calendar", "Bots",
            ])
        #expect(Set(ControlTab.globalNavigation + ControlTab.secondaryNavigation) == Set(ControlTab.allCases))
    }

    @Test func badgesOnlyChanges() {
        let badges = ControlTabBadgeState.make(changeCount: 3)

        #expect(badges.count(for: .changes) == 3)
        #expect(badges.count(for: .kanban) == 0)
        #expect(badges.isUrgent(for: .changes))
        if let bots = ControlTab(rawValue: "Bots") {
            #expect(badges.count(for: bots) == 0)
            #expect(!badges.isUrgent(for: bots))
            #expect(bots.icon == .robot)
        } else {
            Issue.record("Bots global destination is missing")
        }
    }
}
