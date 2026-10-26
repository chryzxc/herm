import Foundation
import Testing

@testable import Herm

struct MissionControlDashboardTests {
    private func session(
        _ id: String, profile: String? = nil, date: Double = 0, hidden: Bool = false
    ) -> HermesSession {
        HermesSession(
            id: id, profileID: profile, title: "Work \(id)", preview: "Review the changes", startedAt: nil,
            updatedAt: Date(timeIntervalSince1970: date), messageCount: 1, source: "conversation", isHidden: hidden)
    }

    @Test @MainActor func includesActiveSessionsOutsideRecentsWithoutRevivingHiddenRows() {
        let suite = "DashboardProjectionTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockModel(defaults: defaults)
        defer { model.shutdown() }
        let control = ControlCenterModel()
        model.sessions = [session("hidden", hidden: true), session("known")]
        control.activeSessions = [
            SessionSummary(id: "active", title: "Live work", state: "active", preview: nil, updatedAt: nil),
            SessionSummary(id: "hidden", title: "Hidden", state: "active", preview: nil, updatedAt: nil),
        ]
        let snapshot = MissionControlSidebarSnapshot(
            inputs: MissionControlSidebarSnapshot.inputs(model: model, control: control))
        let sessions = MissionControlDashboardProjection.sessions(in: snapshot)
        let rows = MissionControlDashboardProjection.rows(
            sessions: sessions, statuses: [:], projects: [:], profileID: model.profileScopeID)
        #expect(Set(rows.map(\.id)) == ["active", "known"])
        #expect(rows.first { $0.id == "active" }?.session.isWorking == true)
    }

    @Test @MainActor func runtimeAliasesDoNotCreateDuplicateCardsOrReviveHiddenSessions() throws {
        let suite = "DashboardAliases.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockModel(defaults: defaults)
        defer { model.shutdown() }
        let control = ControlCenterModel()
        model.sessions = [session("saved"), session("hidden", hidden: true)]
        control.activeSessions = try #require(
            ControlCenterModel.parseSessions([
                "sessions": [
                    ["id": "runtime", "session_key": "saved", "title": "Same chat", "status": "idle"],
                    ["id": "hidden-runtime", "session_key": "hidden", "status": "working"],
                    ["id": "new-runtime", "session_key": "new-saved", "status": "working"],
                    ["id": "foreign", "session_key": "saved", "profile": "other", "status": "working"],
                ]
            ]))
        #expect(control.activeSessions.first?.id == "runtime")
        #expect(control.activeSessions.first?.storedSessionID == "saved")
        let snapshot = MissionControlSidebarSnapshot(
            inputs: MissionControlSidebarSnapshot.inputs(model: model, control: control))
        let rows = MissionControlDashboardProjection.rows(
            sessions: MissionControlDashboardProjection.sessions(in: snapshot),
            statuses: [:], projects: [:], profileID: model.profileScopeID)
        #expect(Set(rows.map(\.id)) == ["saved", "new-saved"])
        #expect(rows.count == 2)
    }

    @Test func identicalTitlesAreStillDistinctConversations() {
        let sessions = ["first", "second"].map {
            HermesSession(
                id: $0, title: "Same title", preview: "Same reply", startedAt: nil,
                messageCount: 1, source: "conversation")
        }
        let rows = MissionControlDashboardProjection.rows(
            sessions: sessions, statuses: [:], projects: [:], profileID: nil)
        #expect(rows.count == 2)
    }

    @Test func groupsOnlyActionableStatesAndKeepsSettledSessionsRecent() {
        #expect(MissionControlDashboardSection.section(for: .needsApproval) == .attention)
        #expect(MissionControlDashboardSection.section(for: .needsClarification) == .attention)
        #expect(MissionControlDashboardSection.section(for: .failed) == .attention)
        #expect(MissionControlDashboardSection.section(for: .unreadComplete) == .review)
        #expect(MissionControlDashboardSection.section(for: .working) == .working)
        #expect(MissionControlDashboardSection.section(for: .none) == .recent)
    }

    @Test func filtersProfileHiddenAndDuplicatesWithStableOrdering() {
        let rows = MissionControlDashboardProjection.rows(
            sessions: [
                session("b", date: 20), session("a", date: 20), session("old"),
                session("a", date: 100), session("hidden", hidden: true), session("hidden"),
                session("foreign", profile: "another"), session("default", profile: "default"),
            ], statuses: ["a": .needsApproval, "b": .working], projects: [:], profileID: nil)
        #expect(rows.map(\.id) == ["a", "b", "default", "old"])
        #expect(rows[0].section == .attention)
        #expect(rows[1].section == .working)
    }

    @Test func searchAndProjectFiltersIntersect() {
        let sessions = [session("one"), session("two"), session("three")]
        let projects = ["one": "Herm", "two": "Website"]
        let rows = MissionControlDashboardProjection.rows(
            sessions: sessions, statuses: [:], projects: projects, profileID: nil,
            query: " REVIEW ", project: "Herm")
        #expect(rows.map(\.id) == ["one"])
        #expect(
            MissionControlDashboardProjection.rows(
                sessions: sessions, statuses: [:], projects: projects, profileID: nil, query: "website"
            ).map(\.id) == ["two"])
    }

    @Test func lateLoadsCannotEnableRepliesForAnotherSessionOrProfile() {
        var selection = MissionControlDashboardSelection()
        let first = selection.begin(session("first", profile: "bot"))
        #expect(!selection.canRespond(activeSessionID: "first", activeProfileID: "bot", profileID: "bot"))
        let second = selection.begin(session("second", profile: "bot"))
        selection.finish(first, loaded: true)
        #expect(selection.isLoading)
        selection.finish(second, loaded: true)
        #expect(selection.canRespond(activeSessionID: "second", activeProfileID: "bot", profileID: "bot"))
        #expect(!selection.canRespond(activeSessionID: "first", activeProfileID: "bot", profileID: "bot"))
        #expect(!selection.canRespond(activeSessionID: "second", activeProfileID: "other", profileID: "other"))
        let retry = selection.begin(session("second", profile: "bot"))
        selection.finish(retry, loaded: false)
        #expect(!selection.isLoading && !selection.isLoaded)
    }
}
