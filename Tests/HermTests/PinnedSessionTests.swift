import XCTest

@testable import Herm

@MainActor
private final class PinRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var rows: [[String: Any]] = []
    var liveRows: [[String: Any]] = []
    var liveUnavailable = false
    var duringLiveRead: (() -> Void)?
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
        return ["sessions": rows]
    }

    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        writes.append((method, path, body))
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

        try await DockModel.writeSessionPin(
            client: client, sessionID: "20260916_125552_df7428", profileID: "coder", pinned: true)
        try await DockModel.writeSessionPin(client: client, sessionID: "a/b", profileID: nil, pinned: false)

        XCTAssertEqual(client.writes.map(\.method), ["PATCH", "PATCH"])
        XCTAssertEqual(client.writes.map(\.path), ["/api/sessions/20260916_125552_df7428", "/api/sessions/a%2Fb"])
        XCTAssertEqual(client.writes[0].body as? [String: AnyHashable], ["pinned": true, "profile": "coder"])
        XCTAssertEqual(client.writes[1].body as? [String: AnyHashable], ["pinned": false])
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
