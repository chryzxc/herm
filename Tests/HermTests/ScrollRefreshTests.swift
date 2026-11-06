import Combine
import Foundation
import Testing

@testable import Herm

@MainActor
private final class ScrollRefreshClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var title = "Existing conversation"

    private var row: [String: Any] {
        ["id": "scroll-refresh", "title": title, "source": "cli", "model": "fixture"]
    }

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == HermesFeatureIDs.ID.sessionList.rawValue { return ["sessions": [row]] }
        return ["sessions": []]
    }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        if path.hasPrefix("/api/profiles/sessions/sidebar") { return ["recents": ["sessions": []]] }
        return ["sessions": [row]]
    }
}

@MainActor
struct ScrollRefreshTests {
    @Test func unchangedQuietRefreshDoesNotPublishWorkspaceChanges() async throws {
        let client = ScrollRefreshClient()
        let model = DockModel(initialSessionID: "scroll-refresh", rpcClient: client)
        defer { model.shutdown() }
        await model.loadSessions(quiet: true)?.value
        try await Task.sleep(for: .milliseconds(30))

        var updates = 0
        let subscription = model.workspacePresentationChanges.sink { updates += 1 }
        for _ in 0..<3 { await model.loadSessions(quiet: true)?.value }
        try await Task.sleep(for: .milliseconds(30))
        #expect(updates == 0)

        client.title = "Renamed conversation"
        await model.loadSessions(quiet: true)?.value
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.currentSessionTitle == "Renamed conversation")
        #expect(updates > 0)
        withExtendedLifetime(subscription) {}
    }
}
