import XCTest

@testable import Herm

@MainActor
private final class PinRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var rows: [[String: Any]] = []
    var liveRows: [[String: Any]] = []
    var liveUnavailable = false
    var duringLiveRead: (() -> Void)?
    var snapshot: [String: Any]?
    var writeError: Error?
    var beforeWrite: (() async -> Void)?
    var beforeIndexRead: (() async -> Void)?
    private(set) var fetchedPaths: [String] = []
    private(set) var writes: [(method: String, path: String, body: [String: Any])] = []

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "session.list" { return ["sessions": rows] }
        if method == "session.active_list" {
            if liveUnavailable { throw HermesGateway.GatewayError.malformedResponse }
            duringLiveRead?()
            return ["sessions": liveRows]
        }
        return [:]
    }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        fetchedPaths.append(path)
        if path.contains("/mutation-snapshot") {
            let id =
                URLComponents(string: path)?.percentEncodedPath.split(separator: "/").dropLast().last
                .flatMap { String($0).removingPercentEncoding } ?? ""
            return snapshot ?? ["session_id": id, "exists": true, "runtime_revision": 7, "runtime_generation": 3]
        }
        let captured = rows
        if let beforeIndexRead {
            self.beforeIndexRead = nil
            await beforeIndexRead()
        }
        return ["sessions": captured]
    }

    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        writes.append((method, path, body))
        await beforeWrite?()
        if let writeError { throw writeError }
        let id = URLComponents(string: path)?.percentEncodedPath.split(separator: "/").last
            .flatMap { String($0).removingPercentEncoding }
        for index in rows.indices where rows[index]["id"] as? String == id {
            rows[index]["pinned"] = body["pinned"]
        }
        return ["ok": true]
    }
}

@MainActor
final class PinnedSessionTests: XCTestCase {
    func testLiveActivityRefreshesUnopenedSessionsAcrossProfiles() async throws {
        for profile in [nil, "other-bot"] as [String?] {
            let client = PinRPCClient()
            client.rows = [
                ["id": "done", "pinned": true, "is_active": true, "last_active": Date().timeIntervalSince1970],
                ["id": "busy", "pinned": true, "is_active": false, "last_active": 1],
            ]
            client.liveRows = [
                ["session_key": "done", "status": "idle"],
                ["session_key": "busy", "status": "working"],
            ]
            let suite = "SessionActivityTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = DockModel(defaults: defaults, rpcClient: client)
            model.profileScopeID = profile
            await model.loadSessions(quiet: true)?.value
            XCTAssertNil(model.sessionID)
            XCTAssertEqual(model.sessions.filter(\.isWorking).map(\.id), ["busy"])
            XCTAssertEqual(model.pinnedSessions.filter(\.isWorking).map(\.id), ["busy"])
            XCTAssertTrue(model.sessions.allSatisfy { $0.profileID == profile })

            // A missed complete event is repaired by the next successful poll.
            client.liveRows = []
            await model.loadSessions(quiet: true)?.value
            XCTAssertFalse(model.sessions.contains(where: \.isWorking))
            XCTAssertFalse(model.pinnedSessions.contains(where: \.isWorking))

            // A turn can start elsewhere without this chat ever being opened.
            client.liveRows = [["session_key": "done", "status": "working"]]
            await model.loadSessions(quiet: true)?.value
            XCTAssertEqual(model.sessions.filter(\.isWorking).map(\.id), ["done"])

            client.liveUnavailable = true
            await model.loadSessions(quiet: true)?.value
            XCTAssertEqual(model.sessions.filter(\.isWorking).map(\.id), ["done"])
            XCTAssertEqual(model.pinnedSessions.filter(\.isWorking).map(\.id), ["done"])

            // An event arriving during a snapshot read takes precedence.
            client.liveUnavailable = false
            client.duringLiveRead = { model.updateSessionActivity(sessionID: "done", isWorking: false) }
            await model.loadSessions(quiet: true)?.value
            XCTAssertFalse(model.sessions.contains(where: \.isWorking))
            XCTAssertFalse(model.pinnedSessions.contains(where: \.isWorking))
        }
    }

    func testSessionIndexPreservesSourceForConversationBadges() async throws {
        let client = PinRPCClient()
        client.rows = [
            ["id": "discord", "source": " Discord ", "pinned": true],
            ["id": "slack", "source": "slack", "pinned": true],
            ["id": "local", "source": "herm", "pinned": true],
            ["id": "legacy", "pinned": true],
            ["id": "other", "source": "custom_channel", "pinned": true],
            ["id": "conversation", "source": "conversation", "pinned": true],
            ["id": "project", "source": "projects", "pinned": true],
        ]
        let index = try await DockModel.fetchSessionIndex(client: client, profileID: nil)
        let labels = Dictionary(uniqueKeysWithValues: index.pinned.map { ($0.id, $0.sourceBadgeTitle) })
        XCTAssertEqual(labels["discord"]!, "Discord")
        XCTAssertNil(labels["slack"]!)
        XCTAssertNil(labels["local"]!)
        XCTAssertNil(labels["legacy"]!)
        XCTAssertNil(labels["other"]!)
        XCTAssertNil(labels["conversation"]!)
        XCTAssertNil(labels["project"]!)
    }

    private func session(_ id: String, updatedAt: TimeInterval = 0, working: Bool = false) -> HermesSession {
        HermesSession(
            id: id, title: id, preview: "", startedAt: nil,
            updatedAt: Date(timeIntervalSince1970: updatedAt), messageCount: 1, source: "",
            isWorking: working)
    }

    func testFetchReadsHermesPinnedFlagFromTheDesktopSessionsEndpoint() async throws {
        let client = PinRPCClient()
        client.rows = [
            ["id": "recent", "title": "Recent", "pinned": false, "started_at": 100, "last_active": 900],
            ["id": "pinned", "title": "Pinned", "pinned": true],
        ]

        let index = try await DockModel.fetchSessionIndex(client: client, profileID: "bot a")

        XCTAssertEqual(index.pinned.map(\.id), ["pinned"])
        XCTAssertEqual(index.pinned.first?.profileID, "bot a")
        XCTAssertEqual(client.fetchedPaths, ["/api/sessions?limit=100&order=recent&profile=bot%20a"])
        XCTAssertEqual(index.lastActive["recent"], Date(timeIntervalSince1970: 900))
    }

    func testSessionListRowTakesLastActiveInsteadOfStartTime() {
        let stale = HermesSession(
            id: "a", title: "A", preview: "", startedAt: Date(timeIntervalSince1970: 100), messageCount: 1, source: "")
        let fresh = DockModel.withRecency(stale, from: ["a": Date(timeIntervalSince1970: 900)])
        XCTAssertEqual(fresh.lastUpdatedAt, Date(timeIntervalSince1970: 900))
        XCTAssertEqual(
            DockModel.withRecency(fresh, from: ["a": Date(timeIntervalSince1970: 500)]).lastUpdatedAt,
            Date(timeIntervalSince1970: 900))
    }

    func testWritePatchesHermesPinnedFlagWithOwningProfile() async throws {
        let client = PinRPCClient()
        let service = HermesSessionPinService()
        try await service.setPinned(true, sessionID: "20260916_125552_df7428", profileID: "coder", client: client)
        try await service.setPinned(false, sessionID: "a/b", profileID: nil, client: client)

        XCTAssertEqual(client.writes.map(\.method), ["PATCH", "PATCH"])
        XCTAssertEqual(client.writes.map(\.path), ["/api/sessions/20260916_125552_df7428", "/api/sessions/a%2Fb"])
        XCTAssertEqual(
            client.fetchedPaths,
            [
                "/api/sessions/20260916_125552_df7428/mutation-snapshot?profile=coder",
                "/api/sessions/a%2Fb/mutation-snapshot",
            ])
        XCTAssertEqual(client.writes[0].body["pinned"] as? Bool, true)
        XCTAssertEqual(client.writes[0].body["profile"] as? String, "coder")
        XCTAssertEqual(client.writes[0].body["expected_revision"] as? Int, 7)
        XCTAssertEqual(client.writes[0].body["expected_generation"] as? Int, 3)
        XCTAssertNotNil((client.writes[0].body["request_id"] as? String).flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(client.writes[1].body["pinned"] as? Bool, false)
        XCTAssertNil(client.writes[1].body["profile"])
    }

    func testPresentationPrefersLiveRowsAndSortsByRecency() {
        let presentation = PinnedSessionPresentation(
            pinned: [session("old", updatedAt: 1), session("new", updatedAt: 2)],
            live: [session("old", updatedAt: 1, working: true)],
            projection: .ready([])
        )

        XCTAssertEqual(presentation.sessions.map(\.id), ["new", "old"])
        XCTAssertTrue(presentation.sessions[1].isWorking)
        XCTAssertEqual(presentation.count, 2)
        XCTAssertEqual(presentation.status, .ready)
    }

    func testPinRefusesMissingOrInvalidMutationSnapshots() async {
        let snapshots: [[String: Any]] = [
            [:],
            ["session_id": "other", "exists": true, "runtime_revision": 1, "runtime_generation": 1],
            ["session_id": "a", "exists": false, "runtime_revision": 0],
            ["session_id": "a", "exists": true, "runtime_revision": true, "runtime_generation": 1],
            ["session_id": "a", "exists": true, "runtime_revision": -1, "runtime_generation": 1],
            ["session_id": "a", "exists": true, "runtime_revision": 1.5, "runtime_generation": 1],
            ["session_id": "a", "exists": true, "runtime_revision": 1],
            ["session_id": "a", "exists": true, "runtime_revision": 1, "runtime_generation": -1],
        ]
        for snapshot in snapshots {
            let client = PinRPCClient()
            client.snapshot = snapshot
            do {
                try await HermesSessionPinService().setPinned(true, sessionID: "a", profileID: nil, client: client)
                XCTFail("An invalid snapshot must not permit a write")
            } catch {}
            XCTAssertTrue(client.writes.isEmpty)
        }
    }

    func testAmbiguousPinRetryReusesItsReceiptAndConflictRequiresANewSnapshot() async throws {
        let client = PinRPCClient()
        let service = HermesSessionPinService()
        client.writeError = URLError(.timedOut)
        do {
            try await service.setPinned(true, sessionID: "a", profileID: "bot + a", client: client)
            XCTFail("Expected timeout")
        } catch {}
        client.writeError = HermesGateway.GatewayError.httpRefused(409, "revision_conflict")
        do {
            try await service.setPinned(true, sessionID: "a", profileID: "bot + a", client: client)
            XCTFail("Expected conflict")
        } catch {}
        XCTAssertEqual(client.fetchedPaths, ["/api/sessions/a/mutation-snapshot?profile=bot%20%2B%20a"])
        XCTAssertEqual(client.writes[0].body["request_id"] as? String, client.writes[1].body["request_id"] as? String)
        client.writeError = nil
        try await service.setPinned(true, sessionID: "a", profileID: "bot + a", client: client)
        XCTAssertEqual(client.fetchedPaths.count, 2)
        XCTAssertNotEqual(
            client.writes[1].body["request_id"] as? String, client.writes[2].body["request_id"] as? String)
    }

    func testPinAndUnpinWaitForAcknowledgementAndSurviveRefresh() async throws {
        let (model, client) = try pinModel()
        let saved = session("a")
        client.rows = [["id": "a", "pinned": false]]
        let (stream, release) = AsyncStream<Void>.makeStream()
        let started = expectation(description: "Pin write started")
        client.beforeWrite = {
            started.fulfill()
            for await _ in stream { break }
        }
        let task = Task { await model.toggleSessionPinned(saved) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.pinningSessionID, "a")
        XCTAssertTrue(model.pinnedSessions.isEmpty)
        let repeated = await model.toggleSessionPinned(saved)
        XCTAssertFalse(repeated)
        release.yield(())
        release.finish()
        let pinned = await task.value
        XCTAssertTrue(pinned)
        XCTAssertTrue(model.isSessionPinned("a"))
        XCTAssertNil(model.pinningSessionID)
        client.beforeWrite = nil
        let unpinned = await model.toggleSessionPinned(saved)
        XCTAssertTrue(unpinned)
        XCTAssertFalse(model.isSessionPinned("a"))
    }

    func testOlderListCannotUndoAnAcknowledgedPin() async throws {
        let (model, client) = try pinModel()
        client.rows = [["id": "a", "pinned": false]]
        let (stream, release) = AsyncStream<Void>.makeStream()
        let started = expectation(description: "Old index read started")
        client.beforeIndexRead = {
            started.fulfill()
            for await _ in stream { break }
        }
        let oldLoad = model.loadSessions()
        await fulfillment(of: [started], timeout: 2)
        let pinned = await model.toggleSessionPinned(session("a"))
        XCTAssertTrue(pinned)
        XCTAssertTrue(model.isSessionPinned("a"))
        release.yield(())
        release.finish()
        await oldLoad?.value
        XCTAssertTrue(model.isSessionPinned("a"))
    }

    func testPinFailureReportsAnErrorWithoutChangingPins() async throws {
        let (model, client) = try pinModel()
        model.actionErrors = DockActionErrorCenter()
        client.writeError = HermesGateway.GatewayError.httpRefused(409, "revision_conflict")
        let result = await model.toggleSessionPinned(session("a"))
        XCTAssertFalse(result)
        XCTAssertTrue(model.pinnedSessions.isEmpty)
        XCTAssertNil(model.pinningSessionID)
        XCTAssertEqual(model.actionErrors.current?.title, "Could not pin session")
        XCTAssertEqual(model.actionErrors.current?.message, "revision_conflict")
    }

    func testPinCompletionCannotPublishIntoAnotherProfile() async throws {
        let (model, client) = try pinModel()
        model.profileScopeID = "first"
        client.beforeWrite = { model.profileScopeID = "second" }
        let result = await model.toggleSessionPinned(session("a"))
        XCTAssertTrue(result)
        XCTAssertTrue(model.pinnedSessions.isEmpty)
        XCTAssertEqual(client.writes.first?.body["profile"] as? String, "first")
    }

    func testLegacyPinMigrationKeepsUnverifiedReferences() async throws {
        let (model, client) = try pinModel()
        let key = "hermes.dock.pinned-sessions.v1"
        let saved = try JSONSerialization.data(withJSONObject: ["references": [["sessionID": "a", "profileID": "bot"]]])
        model.defaults.set(saved, forKey: key)
        client.snapshot = [:]
        await model.migrateLegacyLocalPins()
        XCTAssertNotNil(model.defaults.data(forKey: key))
        XCTAssertTrue(client.writes.isEmpty)
        client.snapshot = ["session_id": "a", "exists": false, "runtime_revision": 0]
        await model.migrateLegacyLocalPins()
        XCTAssertNil(model.defaults.data(forKey: key))
    }

    private func pinModel() throws -> (DockModel, PinRPCClient) {
        let suite = "PinnedSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let client = PinRPCClient()
        let model = DockModel(defaults: defaults, rpcClient: client)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return (model, client)
    }

    func testPresentationHidesPinsWhileTheSessionIndexIsUnavailable() {
        let pinned = [session("a")]
        XCTAssertEqual(PinnedSessionPresentation(pinned: pinned, live: [], projection: .loading).count, 0)
        XCTAssertEqual(
            PinnedSessionPresentation(pinned: pinned, live: [], projection: .failed(safeMessage: "Failed.")).status,
            .failed("Failed.")
        )
        XCTAssertEqual(
            PinnedSessionPresentation(pinned: [], live: [], projection: .empty, hasRequestedSessionIndex: false).status,
            .loading
        )
    }
}
