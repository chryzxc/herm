import Foundation
import Testing

@testable import Herm

@MainActor
struct ConversationExcerptTests {
    private let session = HermesSession(
        id: "owner", profileID: "research", title: "Source", preview: "", startedAt: nil, messageCount: 0,
        source: "fixture")
    @Test func rejectsWrongSessionAndProfile() {
        #expect(throws: (any Error).self) {
            try HermesConversationExcerptService.parse(["session_id": "other", "data": []], session: session)
        }
        #expect(throws: (any Error).self) {
            try HermesConversationExcerptService.parse(["profile": "other", "data": []], session: session)
        }
    }
    @Test func boundsMessagesAndIgnoresToolPayloads() throws {
        var rows: [[String: Any]] = (0..<501).map { ["role": "user", "content": "Message \($0)"] }
        rows.append(["role": "tool", "content": "Internal tool payload"])
        rows.append(["role": "assistant", "content": [["type": "text", "text": "Visible reply"]]])
        let page = try HermesConversationExcerptService.parse(
            ["session_id": "owner", "profile": "research", "data": rows], session: session)
        #expect(page.partial)
        #expect(page.messages.count == 499)
        #expect(page.messages.first == "user: Message 3")
        #expect(page.messages.last == "assistant: Visible reply")
        #expect(!page.messages.contains { $0.contains("Internal tool") })
    }
}
