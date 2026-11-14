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

    private func session(updatedAt: Double) -> HermesSession {
        HermesSession(
            id: "stored-session", profileID: "bot", title: "Chat", preview: "", startedAt: nil,
            updatedAt: Date(timeIntervalSince1970: updatedAt), messageCount: 1, source: "test")
    }

    @Test func unchangedHistoryIsRevalidatedWithOneRowInsteadOfReread() async throws {
        let client = Client()
        client.rows = [row(1, role: "assistant", text: "Unread reply", timestamp: 102)]
        client.rows += (2...600).map { row($0, role: "tool", text: "Activity", timestamp: 103) }
        var now = Date(timeIntervalSince1970: 1_000)
        let replies = SessionUnreadReplies(client: client, now: { now })
        let seenAt = Date(timeIntervalSince1970: 100)
        #expect(try await replies.count(session: session(updatedAt: 200), profileID: "bot", after: seenAt) == 1)
        let fullRead = client.paths.count
        #expect(fullRead == 2)

        // A running session bumps its timestamp, and the badge refresh tick
        // arrives after the short cache window; neither added a row.
        #expect(try await replies.count(session: session(updatedAt: 201), profileID: "bot", after: seenAt) == 1)
        now = now.addingTimeInterval(16)
        #expect(try await replies.count(session: session(updatedAt: 201), profileID: "bot", after: seenAt) == 1)
        let probes = client.paths.dropFirst(fullRead)
        #expect(probes.count == 2)
        #expect(probes.allSatisfy { $0.contains("limit=1&") })
    }

    @Test func aNewRowAfterTheCachedReadIsCounted() async throws {
        let client = Client()
        client.rows = [row(1, role: "assistant", text: "First reply", timestamp: 102)]
        var now = Date(timeIntervalSince1970: 1_000)
        let replies = SessionUnreadReplies(client: client, now: { now })
        let seenAt = Date(timeIntervalSince1970: 100)
        #expect(try await replies.count(session: session(updatedAt: 200), profileID: "bot", after: seenAt) == 1)

        // The session timestamp has not caught up yet, so only the probe can
        // notice the reply.
        client.rows.append(row(2, role: "assistant", text: "Second reply", timestamp: 103))
        now = now.addingTimeInterval(16)
        #expect(try await replies.count(session: session(updatedAt: 200), profileID: "bot", after: seenAt) == 2)
    }

    @Test func aNewestRowRewrittenInPlaceIsReread() async throws {
        let client = Client()
        client.rows = [
            row(1, role: "assistant", text: "First reply", timestamp: 102),
            row(2, role: "assistant", text: "", timestamp: 103),
        ]
        var now = Date(timeIntervalSince1970: 1_000)
        let replies = SessionUnreadReplies(client: client, now: { now })
        let seenAt = Date(timeIntervalSince1970: 100)
        #expect(try await replies.count(session: session(updatedAt: 200), profileID: "bot", after: seenAt) == 1)

        // The streamed row is finalized under the same id and timestamp.
        client.rows[1] = row(2, role: "assistant", text: "Second reply", timestamp: 103)
        now = now.addingTimeInterval(16)
        #expect(try await replies.count(session: session(updatedAt: 200), profileID: "bot", after: seenAt) == 2)
    }

    @Test func olderRowsRewrittenInPlaceAreCaughtByThePeriodicFullRead() async throws {
        let client = Client()
        client.rows = [
            row(1, role: "assistant", text: "", timestamp: 102),
            row(2, role: "tool", text: "Activity", timestamp: 103),
        ]
        var now = Date(timeIntervalSince1970: 1_000)
        let replies = SessionUnreadReplies(client: client, now: { now })
        let seenAt = Date(timeIntervalSince1970: 100)
        #expect(try await replies.count(session: session(updatedAt: 200), profileID: "bot", after: seenAt) == 0)

        // A repair fills in an older row; the newest row is untouched.
        client.rows[0] = row(1, role: "assistant", text: "Repaired reply", timestamp: 102)
        now = now.addingTimeInterval(16)
        #expect(try await replies.count(session: session(updatedAt: 200), profileID: "bot", after: seenAt) == 0)
        now = now.addingTimeInterval(300)
        #expect(try await replies.count(session: session(updatedAt: 200), profileID: "bot", after: seenAt) == 1)
    }

    /// Serves each page from the rows as they were when the request arrived,
    /// holding the first request open until released.
    private final class HeldClient: HermesRPCClientProtocol {
        var onEvent: ((String, [String: Any]) -> Void)?
        var rows: [[String: Any]] = []
        var requests = 0
        private var held: CheckedContinuation<Void, Never>?

        func connect() async throws {}
        func close() {}
        func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }

        func fetchHTTP(_ path: String) async throws -> [String: Any] {
            requests += 1
            let page = rows
            if requests == 1 { await withCheckedContinuation { held = $0 } }
            return ["messages": page, "pagination": ["returned": page.count]]
        }

        func release() {
            held?.resume()
            held = nil
        }
    }

    @Test func aNewerSessionSnapshotDoesNotJoinAnOlderRead() async throws {
        let client = HeldClient()
        client.rows = [row(1, role: "assistant", text: "First reply", timestamp: 102)]
        let replies = SessionUnreadReplies(client: client)
        let seenAt = Date(timeIntervalSince1970: 100)
        let older = Task { try await replies.count(session: session(updatedAt: 200), profileID: "bot", after: seenAt) }
        for _ in 0..<1_000 where client.requests == 0 { await Task.yield() }

        client.rows.append(row(2, role: "assistant", text: "Second reply", timestamp: 103))
        let newer = Task { try await replies.count(session: session(updatedAt: 201), profileID: "bot", after: seenAt) }
        for _ in 0..<1_000 where client.requests == 1 { await Task.yield() }
        // The newer caller issued its own request instead of joining the held one.
        #expect(client.requests == 2)
        client.release()
        #expect(try await older.value == 1)
        #expect(try await newer.value == 2)
    }

    @Test func staleSessionTimestampDoesNotHideUnreadReplyFromBadge() async throws {
        let client = Client()
        client.rows = [row(1, role: "assistant", text: "Unread reply", timestamp: 102)]
        let session = HermesSession(
            id: "stored-session", profileID: "bot", title: "Chat", preview: "", startedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 100), messageCount: 1, source: "test")
        let seenAt = Date(timeIntervalSince1970: 100)
        let status = SidebarSessionStatusResolver.resolve(
            session: session, summary: nil, activeSessionID: nil, activeStatus: nil, attention: nil,
            seenAt: seenAt, isProfileBaselined: true)
        #expect(status == .none)
        #expect(SessionNavBotSessionRow.showsUnreadCount(for: status))
        let projection = try await SessionUnreadReplies(client: client).project(
            session: session, profileID: "bot", after: seenAt)
        #expect(projection.count == 1)
        #expect(projection.firstRowID == 1)
    }

    @Test func projectionReturnsFirstUnreadStoredRowAndHonorsCutoff() async throws {
        let client = Client()
        client.rows = [
            row(1, role: "assistant", text: "Read", timestamp: 100),
            row(2, role: "user", text: "Question", timestamp: 101),
            row(3, role: "assistant", text: "First", timestamp: 102),
            row(4, role: "assistant", text: "Later", timestamp: 104),
        ]
        let projection = try await SessionUnreadReplies(client: client).project(
            session: session(), profileID: "bot", after: Date(timeIntervalSince1970: 100),
            through: Date(timeIntervalSince1970: 103))
        #expect(projection.count == 1)
        #expect(projection.firstRowID == 3)
    }

    @Test func botCountsCountDistinctSessionsAndPreservePartialState() async throws {
        let client = Client()
        client.rows = [
            row(1, role: "assistant", text: "First", timestamp: 101),
            row(2, role: "assistant", text: "Second", timestamp: 102),
        ]
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let seen = SidebarSessionSeenStore(defaults: defaults)
        seen.baseline(profileID: "a", sessions: [])
        seen.baseline(profileID: "b", sessions: [])
        func session(_ id: String, _ profile: String) -> HermesSession {
            HermesSession(
                id: id, profileID: profile, title: "Chat", preview: "", startedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 102), messageCount: 2, source: "test")
        }
        let first = session("one", "a")
        let second = session("two", "a")
        let other = session("one", "b")
        for item in [first, second, other] {
            seen.markSeen(profileID: item.profileID, sessionID: item.id, at: Date(timeIntervalSince1970: 100))
        }
        let result = try await SessionUnreadReplies(client: client).botCounts(
            sessions: [first, first, second, other], scopeProfileID: nil, seenStore: seen, incomplete: true)
        #expect(result.counts == ["a": 2, "b": 1])
        #expect(result.incomplete)
        #expect(client.paths.count == 3)
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
