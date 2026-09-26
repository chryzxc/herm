import XCTest
@testable import HermesAgentDock

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
    private func session(_ id: String, updatedAt: TimeInterval = 0, working: Bool = false) -> HermesSession {
        HermesSession(id: id, title: id, preview: "", startedAt: nil,
                      updatedAt: Date(timeIntervalSince1970: updatedAt), messageCount: 1, source: "",
                      isWorking: working)
    }

    func testFetchReadsHermesPinnedFlagFromTheDesktopSessionsEndpoint() async throws {
        let client = PinRPCClient()
        client.rows = [
            ["id": "recent", "title": "Recent", "pinned": false],
            ["id": "pinned", "title": "Pinned", "pinned": true]
        ]

        let pinned = try await DockModel.fetchPinnedSessions(client: client, profileID: "bot a")

        XCTAssertEqual(pinned.map(\.id), ["pinned"])
        XCTAssertEqual(pinned.first?.profileID, "bot a")
        XCTAssertEqual(client.fetchedPaths, ["/api/sessions?limit=1&order=recent&profile=bot%20a"])
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
