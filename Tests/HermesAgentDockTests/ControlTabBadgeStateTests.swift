import Foundation
import Testing
@testable import HermesAgentDock

struct ControlTabBadgeStateTests {
    @Test func keepsDailyWorkInThePrimaryNavigationAndGroupsSupportingViews() {
        #expect(ControlTab.primaryNavigation == [.today, .inbox, .kanban, .activity])
        #expect(ControlTab.sessionNavigation == [.activity, .changes, .verification])
        #expect(ControlTab.workspaceNavigation == [.projects])
        #expect(ControlTab.toolsNavigation == [.automations, .search, .core])
        #expect(Set(ControlTab.primaryNavigation + ControlTab.workspaceNavigation + ControlTab.secondaryNavigation) == Set(ControlTab.allCases))
    }

    @Test func surfacesUrgentAttentionSeparatelyFromTheFullInbox() {
        let attention = [
            item(id: "approval", kind: .approval),
            item(id: "reminder", kind: .reminder),
            item(id: "snoozed", kind: .failure, state: .snoozed)
        ]

        let badges = ControlTabBadgeState.make(attention: attention, activeAgentCount: 1, activeToolCount: 2)

        #expect(badges.count(for: .today) == 1)
        #expect(badges.count(for: .inbox) == 2)
        #expect(badges.count(for: .activity) == 3)
        #expect(badges.isUrgent(for: .today))
        #expect(badges.isUrgent(for: .inbox))
        #expect(!badges.isUrgent(for: .activity))
    }

    private func item(id: String, kind: AttentionKind, state: AttentionState = .open) -> AttentionItem {
        AttentionItem(
            id: id,
            reference: ControlReference(source: .hermesSession, sourceID: id),
            kind: kind,
            title: id,
            detail: "",
            createdAt: Date(),
            state: state,
            actions: []
        )
    }
}
