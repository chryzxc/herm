import Foundation
import Testing

@testable import Herm

@MainActor
private final class SessionStartupRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var rows: [[String: Any]] = [
        ["id": "latest", "title": "Latest", "last_activity_at": 200],
        ["id": "older", "title": "Older", "last_activity_at": 100, "pinned": true],
    ]
    var holdsList = false
    var failsList = false
    var storedRows: [[String: Any]]?
    var holdsOlderPage = false
    var failsOlderPage = false
    var transcriptRows: [[String: Any]]?
    private(set) var listLimits: [Int] = []
    private(set) var sessionPageReads = 0
    private(set) var preloadedSessionIDs: [String] = []
    private var listStarted: CheckedContinuation<Void, Never>?
    private var listResponse: CheckedContinuation<Void, Never>?
    private var olderPageStarted: CheckedContinuation<Void, Never>?
    private var olderPageResponse: CheckedContinuation<Void, Never>?
    private var connectionCount = 0
    private var connectionWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    func connect() async throws {
        connectionCount += 1
        if let waiter = connectionWaiter, connectionCount >= waiter.count {
            connectionWaiter = nil
            waiter.continuation.resume()
        }
    }
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "session.list":
            if failsList { throw HermesGateway.GatewayError.disconnected }
            let limit = params["limit"] as? Int ?? 50
            listLimits.append(limit)
            let snapshot = Array(rows.prefix(limit))
            if holdsList, listLimits.count == 1 {
                await withCheckedContinuation { continuation in
                    listResponse = continuation
                    listStarted?.resume()
                    listStarted = nil
                }
            }
            return ["sessions": snapshot]
        case "session.resume":
            return ["session_id": params["session_id"] as? String ?? "", "messages": []]
        case "session.active_list":
            return ["sessions": []]
        default:
            throw HermesGateway.GatewayError.malformedResponse
        }
    }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        if let transcriptRows, let url = URLComponents(string: path), url.path.hasSuffix("/messages") {
            let id = String(url.path.split(separator: "/").dropLast().last ?? "")
            preloadedSessionIDs.append(id)
            return [
                "session_id": id, "profile": url.queryItems?.first { $0.name == "profile" }?.value ?? "",
                "messages": transcriptRows, "pagination": ["returned": transcriptRows.count],
            ]
        }
        guard path.hasPrefix("/api/sessions?") else { throw HermesGateway.GatewayError.malformedResponse }
        sessionPageReads += 1
        if let storedRows {
            let items = URLComponents(string: path)?.queryItems
            let offset = Int(items?.first(where: { $0.name == "offset" })?.value ?? "0") ?? 0
            let limit = Int(items?.first(where: { $0.name == "limit" })?.value ?? "100") ?? 100
            if offset > 0, holdsOlderPage {
                await withCheckedContinuation { continuation in
                    olderPageResponse = continuation
                    olderPageStarted?.resume()
                    olderPageStarted = nil
                }
            }
            if offset > 0, failsOlderPage { throw HermesGateway.GatewayError.disconnected }
            return ["sessions": Array(storedRows.dropFirst(offset).prefix(limit)), "total": storedRows.count]
        }
        return ["sessions": rows]
    }

    func waitForOlderPage() async {
        if olderPageResponse != nil { return }
        await withCheckedContinuation { olderPageStarted = $0 }
    }

    func releaseOlderPage() {
        holdsOlderPage = false
        olderPageResponse?.resume()
        olderPageResponse = nil
    }

    func waitForList() async {
        if listResponse != nil { return }
        await withCheckedContinuation { listStarted = $0 }
    }

    func releaseList() {
        holdsList = false
        listResponse?.resume()
        listResponse = nil
    }

    func waitForConnections(_ count: Int) async {
        if connectionCount >= count { return }
        await withCheckedContinuation { connectionWaiter = (count, $0) }
    }
}

@MainActor
struct SessionStartupTests {
    private func withModel(
        _ body: (DockModel, SessionStartupRPCClient) async throws -> Void
    ) async throws {
        let suite = "SessionStartupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = SessionStartupRPCClient()
        let model = DockModel(defaults: defaults, rpcClient: client)
        defer { model.delegationMonitoringTask?.cancel() }
        try await body(model, client)
    }

    @Test func restoringAfterTheListLoadsKeepsEveryConversation() async throws {
        try await withModel { model, _ in
            await model.loadSessions()?.value
            let loadedIDs = model.sessions.map(\.id)

            await model.restoreLatestSessionIfNeeded()?.value

            #expect(model.sessions.map(\.id) == loadedIDs)
            #expect(model.sessionProjectionState == .ready(model.sessions))
            #expect(model.sessionID == "latest")
            #expect(model.pinnedSessions.map(\.id) == ["older"])
        }
    }

    @Test func savedSessionsBeyondFirstPageRemainAvailableWhenLiveListIsShort() async throws {
        try await withModel { model, client in
            client.rows = [["id": "live", "title": "Live"]]
            client.storedRows = (0..<151).map { ["id": "saved-\($0)", "title": "Saved \($0)"] }
            await model.loadSessions()?.value
            #expect(model.sessions.contains { $0.id == "saved-150" })
            #expect(model.sessions.contains { $0.id == "live" })
        }
    }

    @Test func coldListShowsRecentSessionsAndPinsWhileTheSecondPageIsHeld() async throws {
        try await withModel { model, client in
            let profile = UUID().uuidString
            model.profileScopeID = profile
            client.rows = []
            client.storedRows = (0..<1501).map { ["id": "saved-\($0)", "pinned": $0 == 0] }
            client.transcriptRows = [["id": 1, "role": "assistant", "content": "Saved reply", "timestamp": 100]]
            client.holdsOlderPage = true
            model.loadInitialWorkspaceSessions()
            #expect(model.workspaceStartup.phase == .loadingSessions)
            let load = model.sessionLoadTask
            await client.waitForOlderPage()

            #expect(model.sessions.count == 100)
            #expect(model.pinnedSessions.map(\.id) == ["saved-0"])
            #expect(model.sessionProjectionState == .loading)
            #expect(model.workspaceStartup.phase == .finished)
            await model.sessionTranscriptPreloadTask?.value
            #expect(client.preloadedSessionIDs.count == 2)
            #expect(client.preloadedSessionIDs.first == "saved-0")
            let pinnedKey = WorkspaceIdentity.session(profileID: profile, sessionID: "saved-0")
            #expect(model.sessionTranscriptCache.value(for: pinnedKey)?.messages.first?.text == "Saved reply")

            client.releaseOlderPage()
            await load?.value
            #expect(model.sessions.count == 1501)
            #expect(client.sessionPageReads == 16)
            #expect(model.sessionProjectionState == .ready(model.sessions))
        }
    }

    @Test(arguments: [false, true])
    func startupEndsWhenTheFirstReadIsEmptyOrFails(fails: Bool) async throws {
        try await withModel { model, client in
            client.rows = []
            client.failsList = fails
            model.loadInitialWorkspaceSessions()
            await model.sessionLoadTask?.value

            #expect(model.workspaceStartup.phase == .finished)
            if fails {
                guard case .failed = model.sessionProjectionState else {
                    Issue.record("Expected an unavailable session list")
                    return
                }
            } else {
                #expect(model.sessionProjectionState == .empty)
            }
            let connections = client.listLimits.count
            model.loadInitialWorkspaceSessions()
            #expect(model.sessionLoadTask == nil)
            #expect(client.listLimits.count == connections)
        }
    }

    @Test func failedOlderPageKeepsRecentSessionsAndRetriesTheFullHistory() async throws {
        try await withModel { model, client in
            client.rows = []
            client.storedRows = (0..<151).map { ["id": "saved-\($0)"] }
            client.failsOlderPage = true

            await model.loadSessions()?.value
            #expect(model.sessions.count == 100)
            #expect(model.sessionHistoryLoadedAt == nil)
            #expect(
                model.sessionProjectionState
                    == .stale(
                        model.sessions, safeMessage: "Hermes session data is unavailable. Try refreshing."))

            client.failsOlderPage = false
            await model.loadSessions(quiet: true)?.value
            #expect(model.sessions.count == 151)
            #expect(model.sessionProjectionState == .ready(model.sessions))
        }
    }

    @Test func changingProfileDuringOlderHistoryKeepsTheNewProfilesRows() async throws {
        try await withModel { model, client in
            client.rows = []
            client.storedRows = (0..<151).map { ["id": "saved-\($0)"] }
            client.holdsOlderPage = true
            let first = model.loadSessions()
            await client.waitForOlderPage()

            client.storedRows = [["id": "other-chat"]]
            model.setProfileScope("other")
            await model.sessionLoadTask?.value
            client.releaseOlderPage()
            await first?.value

            #expect(model.sessions.map(\.id) == ["other-chat"])
            #expect(model.sessions.first?.profileID == "other")
            #expect(model.sessionProjectionState == .ready(model.sessions))
        }
    }

    @Test func choosingARecentRowDuringHistoryLoadWinsOverStartupRestoration() async throws {
        try await withModel { model, client in
            client.rows = []
            client.storedRows = (0..<151).map { ["id": "saved-\($0)"] }
            client.holdsOlderPage = true
            let restoration = model.restoreLatestSessionIfNeeded()
            await client.waitForOlderPage()

            if let chosen = model.sessions.first(where: { $0.id == "saved-50" }) {
                model.resumeSession(chosen)
                _ = await model.sessionResumeTask?.value
                #expect(!model.isRestoringSession)
            } else {
                Issue.record("Recent row was unavailable before the second page finished")
            }
            client.releaseOlderPage()
            await restoration?.value

            #expect(model.sessionID == "saved-50")
            #expect(model.sessions.count == 151)
        }
    }

    @Test func quietRefreshReadsOnePageAndKeepsOlderHistory() async throws {
        try await withModel { model, client in
            client.rows = []
            client.storedRows = (0..<1501).map { ["id": "saved-\($0)", "title": "Saved \($0)"] }
            await model.loadSessions()?.value
            let initialReads = client.sessionPageReads
            client.storedRows?[0]["title"] = "Updated title"
            await model.loadSessions(quiet: true)?.value
            #expect(client.sessionPageReads - initialReads == 1)
            #expect(model.sessions.count == 1501)
            #expect(model.sessions.first?.title == "Updated title")
            #expect(model.sessions.contains { $0.id == "saved-1500" })

            // A side-effect foreground load (after a send, stop, or project
            // attach) also reuses history instead of walking every page.
            let beforeForeground = client.sessionPageReads
            await model.loadSessions()?.value
            #expect(client.sessionPageReads - beforeForeground == 1)
            #expect(model.sessions.count == 1501)

            // An explicit refresh must still reconcile removals from older pages.
            client.storedRows?.removeLast()
            await model.loadSessions(reconcileHistory: true)?.value
            #expect(!model.sessions.contains { $0.id == "saved-1500" })
        }
    }

    @Test func historyCacheExpiresAndDoesNotCrossProfiles() async throws {
        try await withModel { model, client in
            client.rows = []
            client.storedRows = (0..<151).map { ["id": "saved-\($0)"] }
            await model.loadSessions()?.value
            client.storedRows?.removeLast()
            model.sessionHistoryLoadedAt = (nil, Date().addingTimeInterval(-DockModel.sessionHistoryReuseWindow - 1))
            let beforeExpiry = client.sessionPageReads
            await model.loadSessions(quiet: true)?.value
            #expect(client.sessionPageReads - beforeExpiry == 2)
            #expect(!model.sessions.contains { $0.id == "saved-150" })

            // A scope mismatch cannot append cached rows from another bot.
            model.profileScopeID = "other-bot"
            client.storedRows = [["id": "other-session"]]
            await model.loadSessions(quiet: true)?.value
            #expect(model.sessions.map(\.id) == ["other-session"])
            #expect(model.sessions.allSatisfy { $0.profileID == "other-bot" })
        }
    }

    @Test func completionAndDatabaseChangeRefreshesReuseHistoryUntilItExpires() async throws {
        try await withModel { model, client in
            client.rows = []
            client.storedRows = (0..<151).map { ["id": "saved-\($0)"] }
            model.sessionIndexActivitySpacing = 0
            await model.loadSessions()?.value
            let initialReads = client.sessionPageReads
            model.refreshSessionIndexAfterActivity()
            await model.sessionLoadTask?.value
            #expect(client.sessionPageReads - initialReads == 1)
            #expect(model.sessions.count == 151)

            client.storedRows?.removeLast()
            model.receiveGatewayEvent("sessions.changed", params: [:])
            await model.sessionLoadTask?.value
            #expect(client.sessionPageReads - initialReads == 2)
            #expect(model.sessions.count == 151)

            // Database writes are frequent; reconcile older external deletions on expiry.
            model.sessionHistoryLoadedAt = (nil, Date().addingTimeInterval(-DockModel.sessionHistoryReuseWindow - 1))
            model.receiveGatewayEvent("sessions.changed", params: [:])
            await model.sessionLoadTask?.value
            #expect(!model.sessions.contains { $0.id == "saved-150" })
        }
    }

    @Test func restorationWithoutAMountedSidebarLoadsTheCompleteList() async throws {
        try await withModel { model, client in
            await model.restoreLatestSessionIfNeeded()?.value

            #expect(model.sessions.map(\.id) == ["latest", "older"])
            #expect(model.sessionProjectionState == .ready(model.sessions))
            #expect(model.sessionID == "latest")
            #expect(client.listLimits == [50])
        }
    }

    @Test func overlappingForegroundReadsShareTheirCompletion() async throws {
        try await withModel { model, client in
            client.holdsList = true
            let initial = model.loadSessions()
            await client.waitForList()
            let overlapping = model.loadSessions()
            #expect(overlapping != nil)
            #expect(model.isLoadingSessions)
            client.releaseList()
            await initial?.value
            await overlapping?.value

            #expect(client.listLimits == [50])
            #expect(model.sessions.map(\.id) == ["latest", "older"])
            #expect(!model.isLoadingSessions)
            #expect(!model.isPollingSessions)
        }
    }

    @Test func shutdownDiscardsQueuedActivityRefresh() async throws {
        try await withModel { model, client in
            client.holdsList = true
            let initial = model.loadSessions()
            await client.waitForList()
            model.refreshSessionIndexAfterActivity()
            model.shutdown()
            client.releaseList()
            await initial?.value
            #expect(client.listLimits == [50])
            #expect(!model.pendingSessionIndexRefresh)
            #expect(model.loadSessions() == nil)
        }
    }

    @Test(arguments: [false, true])
    func activityDuringReadRefreshesAfterward(quiet: Bool) async throws {
        try await withModel { model, client in
            client.holdsList = true
            model.sessionIndexActivitySpacing = 0
            let initial = model.loadSessions(quiet: quiet)
            await client.waitForList()
            client.rows = [["id": "updated", "title": "Updated"]]
            model.refreshSessionIndexAfterActivity()
            model.refreshSessionIndexAfterActivity()
            client.releaseList()
            await initial?.value
            await model.sessionLoadTask?.value
            #expect(client.listLimits == [50, 50])
            #expect(model.sessions.map(\.id) == ["updated"])
            #expect(!model.isLoadingSessions)
        }
    }

    @Test(arguments: [false, true])
    func restorationWaitsForTheInFlightList(quietFirst: Bool) async throws {
        try await withModel { model, client in
            client.holdsList = true
            let initial = model.loadSessions(quiet: quietFirst)
            await client.waitForList()
            let restoration = model.restoreLatestSessionIfNeeded()
            await client.waitForConnections(2)
            #expect(client.listLimits == [50])
            client.releaseList()
            await initial?.value
            await restoration?.value

            #expect(client.listLimits == [50])
            #expect(model.sessions.map(\.id) == ["latest", "older"])
            #expect(model.sessionID == "latest")
            #expect(model.sessionProjectionState == .ready(model.sessions))
        }
    }

    @Test func activityBurstDefersToOneSpacedRead() async throws {
        try await withModel { model, client in
            client.rows = []
            client.storedRows = (0..<151).map { ["id": "saved-\($0)"] }
            await model.loadSessions()?.value
            let initialReads = client.sessionPageReads
            // A burst right after a read schedules one deferred read, not one per event.
            for _ in 0..<5 { model.receiveGatewayEvent("sessions.changed", params: [:]) }
            #expect(model.sessionLoadTask == nil)
            #expect(model.sessionIndexRefreshTask != nil)
            #expect(client.sessionPageReads == initialReads)

            model.sessionIndexActivitySpacing = 0
            await model.sessionIndexRefreshTask?.value
            await model.sessionLoadTask?.value
            #expect(client.sessionPageReads - initialReads == 1)
            #expect(model.sessionIndexRefreshTask == nil)
        }
    }

    @Test func profileSwitchAndShutdownCancelDeferredActivityRead() async throws {
        try await withModel { model, _ in
            await model.loadSessions()?.value
            model.refreshSessionIndexAfterActivity()
            let deferred = try #require(model.sessionIndexRefreshTask)
            model.setProfileScope("other-bot")
            #expect(deferred.isCancelled)
            #expect(model.sessionIndexRefreshTask == nil)

            await model.sessionLoadTask?.value
            model.refreshSessionIndexAfterActivity()
            let next = try #require(model.sessionIndexRefreshTask)
            model.shutdown()
            #expect(next.isCancelled)
            model.refreshSessionIndexAfterActivity()
            #expect(model.sessionIndexRefreshTask == nil)
        }
    }

    @Test func historyReuseRequiresSameScopeFreshWindowAndNoReconcile() {
        let now = Date()
        let fresh = (profileID: String?.some("bot"), date: now.addingTimeInterval(-10))
        #expect(DockModel.canReuseSessionHistory(loadedAt: fresh, scope: "bot", now: now, reconcile: false))
        #expect(!DockModel.canReuseSessionHistory(loadedAt: fresh, scope: "bot", now: now, reconcile: true))
        #expect(!DockModel.canReuseSessionHistory(loadedAt: fresh, scope: "other", now: now, reconcile: false))
        #expect(!DockModel.canReuseSessionHistory(loadedAt: nil, scope: "bot", now: now, reconcile: false))
        let expiredDate = now.addingTimeInterval(-DockModel.sessionHistoryReuseWindow)
        let expired = (profileID: String?.some("bot"), date: expiredDate)
        #expect(!DockModel.canReuseSessionHistory(loadedAt: expired, scope: "bot", now: now, reconcile: false))
    }

    @Test func activityRefreshDelaySpacesReadsFromTheLastOne() {
        let now = Date()
        #expect(DockModel.activityRefreshDelay(since: nil, spacing: 3, now: now) == 0)
        #expect(DockModel.activityRefreshDelay(since: now.addingTimeInterval(-1), spacing: 3, now: now) == 2)
        #expect(DockModel.activityRefreshDelay(since: now.addingTimeInterval(-5), spacing: 3, now: now) == 0)
    }

    @Test func timerPollSkipsWhenIndexWasJustRead() async throws {
        try await withModel { model, _ in
            #expect(!model.sessionIndexReadRecently(within: 10))
            await model.loadSessions()?.value
            #expect(model.sessionIndexReadRecently(within: 10))
            #expect(!model.sessionIndexReadRecently(within: 10, now: Date().addingTimeInterval(11)))
        }
    }

    @Test func explicitRefreshSupersedesAnOlderBackgroundSnapshot() async throws {
        try await withModel { model, client in
            client.holdsList = true
            let poll = model.loadSessions(quiet: true)
            await client.waitForList()
            client.rows = [["id": "after-mutation", "title": "Updated"]]
            await model.loadSessions()?.value

            #expect(client.listLimits == [50, 50])
            #expect(model.sessions.map(\.id) == ["after-mutation"])
            client.releaseList()
            await poll?.value

            #expect(model.sessions.map(\.id) == ["after-mutation"])
            #expect(!model.isLoadingSessions)
            #expect(!model.isPollingSessions)
        }
    }
}
