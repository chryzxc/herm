import XCTest
@testable import Herm

@MainActor
private final class PinRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var rows: [[String: Any]] = []
    private(set) var fetchedPaths: [String] = []
    private(set) var writes: [(method: String, path: String, body: [String: Any])] = []

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }

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
    func testSessionIndexPreservesSourceForConversationBadges() async throws {
        let client = PinRPCClient()
        client.rows = [
            ["id": "discord", "source": " Discord ", "pinned": true],
            ["id": "slack", "source": "slack", "pinned": true],
            ["id": "local", "source": "herm", "pinned": true],
            ["id": "legacy", "pinned": true],
            ["id": "other", "source": "custom_channel", "pinned": true],
            ["id": "conversation", "source": "conversation", "pinned": true],
            ["id": "project", "source": "projects", "pinned": true]
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
        HermesSession(id: id, title: id, preview: "", startedAt: nil,
                      updatedAt: Date(timeIntervalSince1970: updatedAt), messageCount: 1, source: "",
                      isWorking: working)
    }

    func testFetchReadsHermesPinnedFlagFromTheDesktopSessionsEndpoint() async throws {
        let client = PinRPCClient()
        client.rows = [
            ["id": "recent", "title": "Recent", "pinned": false, "started_at": 100, "last_active": 900],
            ["id": "pinned", "title": "Pinned", "pinned": true]
        ]

        let index = try await DockModel.fetchSessionIndex(client: client, profileID: "bot a")

        XCTAssertEqual(index.pinned.map(\.id), ["pinned"])
        XCTAssertEqual(index.pinned.first?.profileID, "bot a")
        XCTAssertEqual(client.fetchedPaths, ["/api/sessions?limit=100&order=recent&profile=bot%20a"])
        XCTAssertEqual(index.lastActive["recent"], Date(timeIntervalSince1970: 900))
    }

    func testSessionListRowTakesLastActiveInsteadOfStartTime() {
        let stale = HermesSession(id: "a", title: "A", preview: "", startedAt: Date(timeIntervalSince1970: 100), messageCount: 1, source: "")
        let fresh = DockModel.withRecency(stale, from: ["a": Date(timeIntervalSince1970: 900)])
        XCTAssertEqual(fresh.lastUpdatedAt, Date(timeIntervalSince1970: 900))
        XCTAssertEqual(DockModel.withRecency(fresh, from: ["a": Date(timeIntervalSince1970: 500)]).lastUpdatedAt, Date(timeIntervalSince1970: 900))
    }

    func testWritePatchesHermesPinnedFlagWithOwningProfile() async throws {
        let client = PinRPCClient()

        try await DockModel.writeSessionPin(client: client, sessionID: "20260916_125552_df7428", profileID: "coder", pinned: true)
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
