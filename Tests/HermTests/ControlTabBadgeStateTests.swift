import Foundation
import Testing
@testable import Herm

struct ControlTabBadgeStateTests {
    @Test func keepsDailyWorkInThePrimaryNavigationAndGroupsSupportingViews() {
        #expect(ControlTab.primaryNavigation == [.kanban])
        #expect(ControlTab.sessionNavigation == [.changes])
        #expect(ControlTab.workspaceNavigation == [.projects])
        #expect(ControlTab.toolsNavigation == [.automations, .search, .officePreview, .core])
        #expect(ControlTab.globalNavigation == [.kanban, .projects, .capabilities, .messaging, .quota, .usage, .calendar])
        #expect(Set(ControlTab.globalNavigation + ControlTab.secondaryNavigation) == Set(ControlTab.allCases))
    }

    @Test func badgesOnlyChanges() {
        let badges = ControlTabBadgeState.make(changeCount: 3)

        #expect(badges.count(for: .changes) == 3)
        #expect(badges.count(for: .kanban) == 0)
        #expect(badges.isUrgent(for: .changes))
    }
}
