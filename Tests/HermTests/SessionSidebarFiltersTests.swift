import Foundation
import Testing

@testable import Herm

struct SessionSidebarFiltersTests {
    @Test func preferencesDefaultToVisibleAndDisabledSelectionFallsBackToAll() {
        for option in SessionSidebarVisibility.allCases {
            #expect(option.isVisible(in: 0))
            let hidden = option.toggled(in: 0)
            #expect(!option.isVisible(in: hidden))
            #expect(option.toggled(in: hidden) == 0)
            #expect(SessionSidebarVisibility.allCases.filter { !$0.isVisible(in: hidden) } == [option])
        }
        for filter in SessionSidebarFilter.allCases {
            #expect(filter.enabled(in: 0) == filter)
        }
        #expect(SessionSidebarFilter.running.enabled(in: SessionSidebarVisibility.running.toggled(in: 0)) == .all)
        #expect(!SessionSidebarVisibility.allCases.map(\.title).contains("Recents"))
    }

    @Test func usesApprovalLiveActivityAndIndependentScopedSeenState() {
        let row = session("same", profile: "dev", time: 100)
        #expect(SessionSidebarFilter.needsYou.matches(row, status: .needsApproval, isUnread: false))
        #expect(!SessionSidebarFilter.needsYou.matches(row, status: .needsClarification, isUnread: false))
        #expect(SessionSidebarFilter.running.matches(row, status: .working, isUnread: false))
        #expect(!SessionSidebarFilter.running.matches(row, status: .unreadComplete, isUnread: true))
        #expect(SessionSidebarFilter.unread.matches(row, status: .needsApproval, isUnread: true))
    }

    @Test func sectionTogglesHideOnlyTheirOwnSectionsWithoutReordering() {
        let order: [SessionRailSection] = [.projects, .recents, .automations, .pinned]
        let toggles: [(SessionSidebarVisibility, SessionRailSection)] = [
            (.pinned, .pinned), (.projects, .projects), (.automations, .automations),
        ]
        #expect(SessionSidebarVisibility.visibleSections(order, hidden: 0) == order)
        for (option, section) in toggles {
            let visible = SessionSidebarVisibility.visibleSections(order, hidden: option.toggled(in: 0))
            #expect(visible == order.filter { $0 != section })
        }
        let onlyRecents = SessionSidebarVisibility.allCases.reduce(0) { $1.toggled(in: $0) }
        #expect(SessionSidebarVisibility.visibleSections(order, hidden: onlyRecents) == [.recents])
    }

    @Test func searchesProjectNamesAndKeepsBothProfileIdentitiesInRecencyOrder() {
        let dev = session("same", profile: "dev", time: 150)
        let primary = session("same", profile: "default", time: 100)
        let other = session("other", profile: "dev", time: 200)
        let projectNames = [dev.scopedID: "build-tools", primary.scopedID: "build-tools"]
        let matches = SessionSidebarFilter.results(
            [primary, dev, other, dev], query: "  BUILD ", profileID: nil, projectNames: projectNames)
        #expect(matches == [dev, primary])
        let scoped = SessionSidebarFilter.results([dev, primary], query: "", profileID: "default", projectNames: [:])
        #expect(scoped == [primary])
    }

    @Test func liveAndAttentionInputsResolveByProfileAndDoNotReviveFinishedTurns() {
        let stored = session("same", profile: "work", time: 100)
        let other = session("same", profile: "personal", time: 100)
        let active = SessionSummary(
            id: "runtime", title: "Live", state: "working", preview: nil,
            profileID: "work", storedSessionID: stored.id)
        let waiting = SessionSummary(
            id: "waiting", title: "Waiting", state: "waiting", preview: nil,
            profileID: "personal", storedSessionID: other.id)
        let approval = AttentionItem(
            id: "approval", reference: .init(source: .hermesApproval, sourceID: "approval", sessionID: waiting.id),
            kind: .approval, title: "Approve", detail: "", createdAt: .distantPast, state: .open, actions: [.approve])
        var inputs = SessionNavSidebarSnapshot.Inputs(
            activeSessionID: nil, activeStatus: nil, profileScopeID: "personal", agentDisplayName: "Herm",
            isLoadingSessions: false, isCreatingSession: false, deletingSessionID: nil, renamingSessionID: nil,
            updatingSessionVisibilityID: nil, sessions: [other], sessionProjectionState: .ready([other]),
            activeSessions: [active, waiting], projects: [], projectIDBySessionID: [:], projectSessionsByProjectID: [:],
            projectProfileID: nil, isLoadingProjects: false, isRefreshingProjectNavigation: false,
            attention: [approval], latestActivities: [], allBotSessionsState: .ready([stored, other]),
            baselinedProfiles: ["personal", "work"])
        let inventory = SessionSidebarFilterInventory(inputs: inputs, unreadSessions: [other.scopedID])
        #expect(inventory.status(for: stored) == .working)
        #expect(inventory.status(for: other) == .needsApproval)
        #expect(!inventory.isUnread(stored))
        #expect(inventory.isUnread(other))
        let refreshed = SessionSidebarFilterInventory(inputs: inputs, confirmedApprovals: [])
        #expect(refreshed.status(for: other) == .none)

        inputs.profileScopeID = "work"
        inputs.activeSessionID = stored.id
        inputs.activeStatus = .idle
        inputs.attention = []
        inputs.activeSessions.append(
            SessionSummary(id: "ownerless", title: "Live", state: "working", preview: nil, storedSessionID: stored.id))
        let finished = SessionSidebarFilterInventory(inputs: inputs)
        #expect(finished.status(for: stored) == .none)
        #expect(finished.status(for: other) == .none)
        let confirmed = SessionSidebarFilterInventory(inputs: inputs, confirmedApprovals: [other.scopedID])
        #expect(confirmed.status(for: other) == .needsApproval)
    }

    private func session(_ id: String, profile: String, time: Double) -> HermesSession {
        HermesSession(
            id: id, profileID: profile, title: "Conversation", preview: "", startedAt: nil,
            updatedAt: Date(timeIntervalSince1970: time), messageCount: 1, source: "conversation")
    }
}
