import Foundation
import Testing

@testable import Herm

@MainActor
private final class DashboardCardRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var response: [String: Any] = [:]
    var paths: [String] = []
    var requests: [String] = []
    var delay: Duration?
    var concurrent = 0
    var maximumConcurrent = 0
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append(method)
        return [:]
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
        defer { concurrent -= 1 }
        paths.append(path)
        if let delay { try await Task.sleep(for: delay) }
        return response
    }
}

@MainActor
struct SessionDashboardCardContentTests {
    @Test func latestReplyIsPreferredOverFollowingUserOrToolActivity() {
        #expect(
            SessionDashboardCardContent.latestUpdate([
                "assistant: First", "hermes: Latest reply", "user: Next question",
            ]) == "Latest reply")
        #expect(SessionDashboardCardContent.latestUpdate(["user: Question"]) == "Question")
        #expect(SessionDashboardCardContent.latestUpdate([]) == nil)
    }

    @Test func longTilePreviewBoundsMarkdownWorkAndKeepsInlineLinks() {
        let link = "[Review](https://example.com/review)"
        let result = SessionDashboardCard.renderedPreview(link + String(repeating: " detail", count: 12_000))
        #expect(result.characters.count <= 1024)
        #expect(result.runs.first?.link?.absoluteString == "https://example.com/review")
    }

    @Test func visualReplyUsesReadableFallbackInsteadOfJSON() {
        let source = """
            ```herm-ui
            {"version":2,"id":"budget","title":"Budget","fallback":"Monthly budget overview","blocks":[]}
            ```
            """
        let preview = SessionDashboardCardContent.preview(source)
        #expect(preview?.contains("Monthly budget overview") == true)
        #expect(preview?.contains("\"version\"") == false)
        #expect(SessionDashboardCardContent.latestUpdate(["assistant: " + source]) == preview)
    }

    @Test func loadsBoundedTailWithExplicitProfileWithoutActivatingSession() async {
        let client = DashboardCardRPC()
        client.response = [
            "session_id": "session", "profile": "bot",
            "messages": [
                ["role": "assistant", "content": "Older"],
                ["role": "assistant", "content": "**Latest** update"],
                ["role": "tool", "content": "Tool payload"],
            ],
        ]
        let content = SessionDashboardCardContent()
        let session = HermesSession(
            id: "session", title: "Work", preview: "", startedAt: nil, messageCount: 3, source: "conversation")
        await content.load(session: session, profileID: "bot", client: client)
        #expect(content.text == "**Latest** update")
        #expect(client.paths == ["/api/sessions/session/messages?limit=8&order=latest&profile=bot"])
        #expect(client.requests.isEmpty)
        #expect(!content.loading && content.error == nil)
        client.response = ["session_id": "other", "data": []]
        let updated = HermesSession(
            id: "session", title: "Work", preview: "", startedAt: nil, updatedAt: Date(timeIntervalSince1970: 1),
            messageCount: 3, source: "conversation")
        await content.load(session: updated, profileID: "bot", client: client)
        #expect(content.error != nil)
        #expect(content.text == "**Latest** update")
    }

    @Test func openingATileAgainReadsPastAnEmptyPreviewWithoutAnUpdateStamp() async {
        let client = DashboardCardRPC()
        let session = HermesSession(
            id: UUID().uuidString, title: "Work", preview: "", startedAt: nil, messageCount: 0, source: "conversation")
        client.response = ["data": [[String: Any]]()]
        let first = SessionDashboardCardContent()
        await first.load(session: session, profileID: nil, client: client)
        #expect(first.text == nil && first.error == nil)

        client.response = ["data": [["role": "assistant", "content": "Reply received"]]]
        let reopened = SessionDashboardCardContent()
        await reopened.load(session: session, profileID: nil, client: client)
        #expect(reopened.text == "Reply received")
        #expect(client.paths.count == 2)
    }

    @Test func visibleTilesShareABoundedPreviewReadBudget() async {
        let client = DashboardCardRPC()
        client.delay = .milliseconds(50)
        client.response = ["data": [["role": "assistant", "content": "Shared test preview"]]]
        let tiles = (0..<9).map { _ in SessionDashboardCardContent() }
        let id = UUID().uuidString
        let reads = tiles.enumerated().map { index, tile in
            Task {
                let session = HermesSession(
                    id: "\(id)-\(index)", title: "Work", preview: "", startedAt: nil, messageCount: 1,
                    source: "conversation")
                await tile.load(session: session, profileID: nil, client: client)
            }
        }
        for read in reads { await read.value }
        #expect(client.paths.count == tiles.count)
        #expect(client.maximumConcurrent == 3)
        #expect(tiles.allSatisfy { $0.text == "Shared test preview" })
    }
}
