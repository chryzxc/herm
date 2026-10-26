import Foundation
import Testing

@testable import Herm

@MainActor
private final class DashboardCardRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var response: [String: Any] = [:]
    var paths: [String] = []
    var requests: [String] = []
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append(method)
        return [:]
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        paths.append(path)
        return response
    }
}

@MainActor
struct MissionControlCardContentTests {
    @Test func latestReplyIsPreferredOverFollowingUserOrToolActivity() {
        #expect(
            MissionControlCardContent.latestUpdate([
                "assistant: First", "hermes: Latest reply", "user: Next question",
            ]) == "Latest reply")
        #expect(MissionControlCardContent.latestUpdate(["user: Question"]) == "Question")
        #expect(MissionControlCardContent.latestUpdate([]) == nil)
    }

    @Test func visualReplyUsesReadableFallbackInsteadOfJSON() {
        let source = """
            ```herm-ui
            {"version":2,"id":"budget","title":"Budget","fallback":"Monthly budget overview","blocks":[]}
            ```
            """
        let preview = MissionControlCardContent.preview(source)
        #expect(preview?.contains("Monthly budget overview") == true)
        #expect(preview?.contains("\"version\"") == false)
        #expect(MissionControlCardContent.latestUpdate(["assistant: " + source]) == preview)
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
        let content = MissionControlCardContent()
        let session = HermesSession(
            id: "session", title: "Work", preview: "", startedAt: nil, messageCount: 3, source: "conversation")
        await content.load(session: session, profileID: "bot", client: client)
        #expect(content.text == "**Latest** update")
        #expect(client.paths == ["/api/sessions/session/messages?limit=8&order=latest&profile=bot"])
        #expect(client.requests.isEmpty)
        #expect(!content.loading && content.error == nil)
        client.response = ["session_id": "other", "data": []]
        await content.load(session: session, profileID: "bot", client: client)
        #expect(content.error != nil)
        #expect(content.text == "**Latest** update")
    }
}
