import Foundation
import Testing

@testable import Herm

@MainActor
struct SessionUnreadRepliesTests {
    private final class Client: HermesRPCClientProtocol {
        var onEvent: ((String, [String: Any]) -> Void)?
        var rows: [[String: Any]] = []
        var paths: [String] = []
        var fails = false

        func connect() async throws {}
        func close() {}
        func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
            Issue.record("Unread counts must never resume or mutate sessions")
            return [:]
        }

        func fetchHTTP(_ path: String) async throws -> [String: Any] {
            paths.append(path)
            if fails { throw URLError(.cannotConnectToHost) }
            let query = URLComponents(string: path)?.queryItems ?? []
            let offset = Int(query.first { $0.name == "offset" }?.value ?? "0") ?? 0
            let limit = Int(query.first { $0.name == "limit" }?.value ?? "500") ?? 500
            let upper = max(0, rows.count - offset)
            let lower = max(0, upper - limit)
            let page = Array(rows[lower..<upper])
            return ["messages": page, "pagination": ["returned": page.count]]
        }
    }

    private func session() -> HermesSession {
        HermesSession(id: "stored-session", title: "Chat", preview: "", startedAt: nil, messageCount: 0, source: "test")
    }

    private func row(_ id: Int, role: String, text: String, timestamp: Double) -> [String: Any] {
        ["id": id, "role": role, "content": text, "timestamp": timestamp]
    }

    @Test func storedHistoryAndLiveMessagesUseTheSameResponsePolicy() async throws {
        let client = Client()
        client.rows = [
            row(1, role: "assistant", text: "Already read", timestamp: 100),
            row(2, role: "user", text: "Question", timestamp: 101),
            row(3, role: "assistant", text: "", timestamp: 102),
            row(4, role: "tool", text: "Tool result", timestamp: 103),
            row(5, role: "system", text: "Activity", timestamp: 104),
            row(6, role: "assistant", text: "First reply", timestamp: 105),
            row(7, role: "assistant", text: "Second reply", timestamp: 106),
        ]
        var hidden = row(8, role: "assistant", text: "Hidden scaffolding", timestamp: 107)
        hidden["display_kind"] = "hidden"
        client.rows.append(hidden)
        let count = try await SessionUnreadReplies(client: client).count(
            session: session(), profileID: "other-bot", after: Date(timeIntervalSince1970: 100))
        #expect(count == 2)
        #expect(client.paths.count == 1)
        #expect(client.paths[0].contains("profile=other-bot"))
    }

    @Test func toolHeavyHistoryPagesDoNotHideAnUnreadReply() async throws {
        let client = Client()
        client.rows = [row(1, role: "assistant", text: "Unread reply", timestamp: 101)]
        client.rows += (2...502).map { row($0, role: "tool", text: "Activity", timestamp: 102) }
        let count = try await SessionUnreadReplies(client: client).count(
            session: session(), profileID: nil, after: Date(timeIntervalSince1970: 100))
        #expect(count == 1)
        #expect(client.paths.count == 2)
    }

    @Test func activityWithoutAnAIReplyHasNoUnreadMessages() async throws {
        let client = Client()
        client.rows = [
            row(1, role: "user", text: "Question", timestamp: 101),
            row(2, role: "assistant", text: "", timestamp: 102),
            row(3, role: "tool", text: "Tool result", timestamp: 103),
            row(4, role: "system", text: "Completed activity", timestamp: 104),
        ]
        let count = try await SessionUnreadReplies(client: client).count(
            session: session(), profileID: nil, after: Date(timeIntervalSince1970: 100))
        #expect(count == 0)
    }

    @Test func unavailableHistoryDoesNotInventACount() async {
        let client = Client()
        client.fails = true
        await #expect(throws: (any Error).self) {
            try await SessionUnreadReplies(client: client).count(
                session: session(), profileID: nil, after: .distantPast)
        }
    }

    @Test func missingTimestampsCannotBecomeUnreadReplies() async {
        let client = Client()
        client.rows = [["id": 1, "role": "assistant", "content": "Unknown date"]]
        await #expect(throws: (any Error).self) {
            try await SessionUnreadReplies(client: client).count(
                session: session(), profileID: nil, after: .distantPast)
        }
    }
}
