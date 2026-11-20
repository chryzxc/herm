import Foundation
import Testing

@testable import Herm

struct SessionDashboardTests {
    private func session(
        _ id: String, profile: String? = nil, date: Double = 0, hidden: Bool = false
    ) -> HermesSession {
        HermesSession(
            id: id, profileID: profile, title: "Work \(id)", preview: "Review the changes", startedAt: nil,
            updatedAt: Date(timeIntervalSince1970: date), messageCount: 1, source: "conversation", isHidden: hidden)
    }

    @Test @MainActor func boardIncludesEveryBotsSessions() {
        let suite = "DashboardAllBots.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockModel(defaults: defaults)
        defer { model.shutdown() }
        model.sessions = [session("mine")]
        model.allBotSessionsState = .ready([session("theirs", profile: "other"), session("also", profile: "third")])
        let snapshot = SessionNavSidebarSnapshot(
            inputs: SessionNavSidebarSnapshot.inputs(model: model, control: ControlCenterModel()))
        let rows = SessionDashboardProjection.rows(
            sessions: SessionDashboardProjection.sessions(in: snapshot), statuses: [:], projects: [:])
        #expect(Set(rows.map(\.id)) == ["mine", "theirs", "also"])
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
        let snapshot = SessionNavSidebarSnapshot(
            inputs: SessionNavSidebarSnapshot.inputs(model: model, control: control))
        let sessions = SessionDashboardProjection.sessions(in: snapshot)
        let rows = SessionDashboardProjection.rows(
            sessions: sessions, statuses: [:], projects: [:])
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
        let snapshot = SessionNavSidebarSnapshot(
            inputs: SessionNavSidebarSnapshot.inputs(model: model, control: control))
        let rows = SessionDashboardProjection.rows(
            sessions: SessionDashboardProjection.sessions(in: snapshot),
            statuses: [:], projects: [:])
        #expect(Set(rows.map(\.id)) == ["saved", "new-saved", "foreign"])
        #expect(rows.count == 3)
    }

    @Test func identicalTitlesAreStillDistinctConversations() {
        let sessions = ["first", "second"].map {
            HermesSession(
                id: $0, title: "Same title", preview: "Same reply", startedAt: nil,
                messageCount: 1, source: "conversation")
        }
        let rows = SessionDashboardProjection.rows(
            sessions: sessions, statuses: [:], projects: [:])
        #expect(rows.count == 2)
    }

    @Test func groupsOnlyActionableStatesAndKeepsSettledSessionsRecent() {
        #expect(SessionDashboardSection.section(for: .needsApproval) == .attention)
        #expect(SessionDashboardSection.section(for: .needsClarification) == .attention)
        #expect(SessionDashboardSection.section(for: .failed) == .attention)
        #expect(SessionDashboardSection.section(for: .unreadComplete) == .review)
        #expect(SessionDashboardSection.section(for: .working) == .working)
        #expect(SessionDashboardSection.section(for: .none) == .recent)
    }

    @Test func keepsEveryBotsSessionsAndFiltersHiddenAndDuplicatesWithStableOrdering() {
        let rows = SessionDashboardProjection.rows(
            sessions: [
                session("b", date: 20), session("a", date: 20), session("old"),
                session("a", date: 100), session("hidden", hidden: true), session("hidden"),
                session("foreign", profile: "another"), session("default", profile: "default"),
            ], statuses: ["a": .needsApproval, "b": .working], projects: [:])
        #expect(rows.map(\.id) == ["a", "b", "default", "foreign", "old"])
        #expect(rows[0].section == .attention)
        #expect(rows[1].section == .working)
    }

    @Test func searchAndProjectFiltersIntersect() {
        let sessions = [session("one"), session("two"), session("three")]
        let projects = ["one": "Herm", "two": "Website"]
        let rows = SessionDashboardProjection.rows(
            sessions: sessions, statuses: [:], projects: projects,
            query: " REVIEW ", project: "Herm")
        #expect(rows.map(\.id) == ["one"])
        #expect(
            SessionDashboardProjection.rows(
                sessions: sessions, statuses: [:], projects: projects, query: "website"
            ).map(\.id) == ["two"])
    }

    @Test func filteringProjectedRowsMatchesFilteringWhileProjecting() {
        let sessions = [session("one", date: 3), session("two", date: 2), session("three", date: 1)]
        let projects = ["one": "Herm", "two": "Website"]
        let all = SessionDashboardProjection.rows(sessions: sessions, statuses: [:], projects: projects)
        for (query, project) in [("", nil), (" REVIEW ", "Herm"), ("website", nil), ("missing", nil)]
            as [(String, String?)]
        {
            #expect(
                SessionDashboardProjection.filter(all, query: query, project: project)
                    == SessionDashboardProjection.rows(
                        sessions: sessions, statuses: [:], projects: projects, query: query, project: project))
        }
    }

    @Test func layoutSignatureChangesOnlyWhenCardsMove() {
        let rows = SessionDashboardProjection.rows(
            sessions: [session("one", date: 2), session("two", date: 1)], statuses: [:], projects: [:])
        let same = SessionDashboardVisibleRows(rows)
        #expect(SessionDashboardVisibleRows(rows).layoutSignature == same.layoutSignature)
        #expect(SessionDashboardVisibleRows(rows.reversed()).layoutSignature != same.layoutSignature)
        let moved = [SessionDashboardRow(session: rows[0].session, status: .working, project: nil), rows[1]]
        #expect(SessionDashboardVisibleRows(moved).layoutSignature != same.layoutSignature)
        #expect(SessionDashboardVisibleRows(moved).counts == [.working: 1, .recent: 1])
    }

    @Test @MainActor func boardModelRebuildsOnSnapshotAndFiltersWithoutReprojecting() {
        let suite = "DashboardBoardModel.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockModel(defaults: defaults)
        defer { model.shutdown() }
        model.sessions = [session("one", date: 2), session("two", date: 1)]
        let sidebar = SessionNavSidebarModel(
            model: model, control: ControlCenterModel(),
            store: WorkspaceStore(fileURL: URL(fileURLWithPath: "/tmp/dashboard-board-\(UUID()).json")))
        let board = SessionDashboardBoardModel(sidebar: sidebar, seen: SidebarSessionSeenStore(defaults: defaults))
        #expect(board.visible.members(.recent).map(\.id) == ["one", "two"])

        model.sessions.append(session("three", date: 3))
        sidebar.refresh()
        #expect(board.visible.members(.recent).map(\.id) == ["three", "one", "two"])

        board.filter(query: "Work two", project: nil)
        #expect(board.visible.members(.recent).map(\.id) == ["two"])
        #expect(board.board.rows.count == 3)
    }

    @Test @MainActor func unreadInventoryRefreshesWhenAnotherBotsHistoryChanges() {
        let suite = "SidebarUnreadInventory.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockModel(defaults: defaults)
        defer { model.shutdown() }
        model.sessions = [session("mine")]
        let sidebar = SessionNavSidebarModel(
            model: model, control: ControlCenterModel(),
            store: WorkspaceStore(fileURL: URL(fileURLWithPath: "/tmp/sidebar-unread-\(UUID()).json")))
        #expect(Set(sidebar.unreadSessions.rows.map(\.id)) == ["mine"])

        model.allBotSessionsState = .ready([session("other", profile: "bot", date: 2)])
        sidebar.refresh()
        #expect(Set(sidebar.unreadSessions.rows.map(\.id)) == ["mine", "other"])
        #expect(sidebar.unreadSessions.sessions == SessionDashboardProjection.sessions(in: sidebar.snapshot))

        model.allBotSessionsState = .empty
        sidebar.refresh()
        #expect(Set(sidebar.unreadSessions.rows.map(\.id)) == ["mine"])
    }

    @Test func lateLoadsCannotEnableRepliesForAnotherSessionOrProfile() {
        var selection = SessionDashboardSelection()
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
