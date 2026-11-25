import Foundation
import Testing

@testable import Herm

struct SessionSidebarFiltersTests {
    @Test func onlyPinnedAndProjectsAreEnabledByDefault() {
        let enabled = SessionRailSection.filterOptions.filter {
            $0.isVisible(in: SessionRailSection.defaultHiddenOptions)
        }
        #expect(enabled == [.pinned, .projects])
        #expect(SessionRailSection.recents.isVisible(in: SessionRailSection.defaultHiddenOptions))
    }

    @Test func sectionTogglesHideOnlyTheirOwnSectionsWithoutReordering() {
        let order: [SessionRailSection] = [
            .projects, .recents, .archived, .automations, .unread, .pinned, .needsYou, .running,
        ]
        #expect(order.filter { $0.isVisible(in: 0) } == order)
        let storedOptionOrder: [SessionRailSection] = [
            .pinned, .projects, .automations, .unread, .needsYou, .running, .archived,
        ]
        #expect(SessionRailSection.filterOptions == storedOptionOrder)
        for (bit, section) in storedOptionOrder.enumerated() {
            let hidden = section.toggled(in: 0)
            #expect(hidden == 1 << bit)
            let visible = order.filter { $0.isVisible(in: hidden) }
            #expect(visible == order.filter { $0 != section })
            #expect(section.toggled(in: hidden) == 0)
        }
        let onlyRecents = SessionRailSection.filterOptions.reduce(0) { $1.toggled(in: $0) }
        #expect(order.filter { $0.isVisible(in: onlyRecents) } == [.recents])
    }

    @Test func searchesProjectNamesAndKeepsBothProfileIdentitiesInRecencyOrder() {
        let dev = session("same", profile: "dev", time: 150)
        let primary = session("same", profile: "default", time: 100)
        let other = session("other", profile: "dev", time: 200)
        let scope = SessionSidebarSearch.Scope(
            mainChatIDs: [], showsAllProfiles: true, selectedBotID: nil, visibleBots: [])
        let inventory = SessionSidebarFilterInventory(inputs: inputs(profile: "dev"))
        let candidates = [primary, dev, other, dev]
        let matches = inventory.results(
            candidates, section: .archived, query: "", scope: scope, projectNames: [:])
        #expect(matches == [other, dev, primary])
        let projectMatches = inventory.results(
            candidates, section: .archived, query: "  BUILD ", scope: scope, projectNames: [dev.id: "build-tools"])
        #expect(projectMatches == [dev])
        let primaryScope = SessionSidebarSearch.Scope(
            mainChatIDs: [], showsAllProfiles: false, selectedBotID: "default", visibleBots: [])
        let scoped = inventory.results(
            candidates, section: .archived, query: "", scope: primaryScope, projectNames: [:])
        #expect(scoped == [primary])
        #expect(dev[sidebarSection: "archived"] != primary[sidebarSection: "archived"])
        #expect(dev[sidebarSection: "unread"] != dev[sidebarSection: "running"])
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
        var inputs = inputs(profile: "personal")
        inputs.activeSessions = [active, waiting]
        inputs.attention = [approval]
        let inventory = SessionSidebarFilterInventory(inputs: inputs, unreadSessions: [other.scopedID])
        #expect(inventory.status(for: stored) == .working)
        #expect(inventory.status(for: other) == .needsApproval)
        #expect(!inventory.isUnread(stored))
        #expect(inventory.isUnread(other))
        let scope = SessionSidebarSearch.Scope(
            mainChatIDs: [], showsAllProfiles: true, selectedBotID: nil, visibleBots: [])
        let rows = [stored, other]
        #expect(inventory.results(rows, section: .running, query: "", scope: scope, projectNames: [:]) == [stored])
        #expect(inventory.results(rows, section: .needsYou, query: "", scope: scope, projectNames: [:]) == [other])
        #expect(inventory.results(rows, section: .unread, query: "", scope: scope, projectNames: [:]) == [other])
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

    private func inputs(profile: String) -> SessionNavSidebarSnapshot.Inputs {
        .init(
            activeSessionID: nil, activeStatus: nil, profileScopeID: profile,
            isLoadingSessions: false, isCreatingSession: false, deletingSessionID: nil, renamingSessionID: nil,
            updatingSessionVisibilityID: nil, sessions: [], sessionProjectionState: .empty,
            activeSessions: [], projects: [], projectIDBySessionID: [:], projectSessionsByProjectID: [:],
            projectProfileID: nil, isLoadingProjects: false, isRefreshingProjectNavigation: false,
            attention: [], latestActivities: [])
    }

    private func session(_ id: String, profile: String, time: Double) -> HermesSession {
        HermesSession(
            id: id, profileID: profile, title: "Conversation", preview: "", startedAt: nil,
            updatedAt: Date(timeIntervalSince1970: time), messageCount: 1, source: "conversation")
    }
}
