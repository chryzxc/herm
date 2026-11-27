import Foundation
import Testing

@testable import Herm

@MainActor
struct GroupChatPreviewTests {
    @Test func failedPreviewRetriesTheSameRevision() async {
        let client = PreviewRoomClient()
        guard let store = await boundStore(client) else { return }
        client.revision = 2
        client.failPreview = true

        let listed = await store.refreshRooms()
        #expect(listed)
        #expect(store.rooms.first?.latestSeq == 2)
        #expect(store.lastMessages["r"]?.text == "You: message 1")

        client.failPreview = false
        await store.refreshRooms()
        #expect(client.previewRevisions == [1, 2, 2])
        #expect(store.lastMessages["r"]?.text == "You: message 2")
        #expect(store.lastMessages["r"]?.date == Date(timeIntervalSince1970: 2))
    }

    @Test func supersededPreviewDoesNotConsumeTheRevision() async {
        let client = PreviewRoomClient()
        guard let store = await boundStore(client) else { return }
        client.revision = 2
        let (pause, release) = AsyncStream<Void>.makeStream()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        client.logStarted = didStart
        client.logPause = pause
        let superseded = Task { await store.refreshRooms() }
        guard await waitForLog(started, continuation: didStart) else {
            release.finish()
            _ = await superseded.value
            Issue.record("Superseded refresh did not request the preview")
            return
        }

        client.failPreview = true
        let listed = await store.refreshRooms()
        #expect(listed)
        release.yield(())
        release.finish()
        let stale = await superseded.value
        #expect(!stale)
        #expect(store.lastMessages["r"]?.text == "You: message 1")

        client.failPreview = false
        await store.refreshRooms()
        #expect(client.previewRevisions == [1, 2, 2, 2])
        #expect(store.lastMessages["r"]?.text == "You: message 2")
    }

    private func boundStore(_ client: PreviewRoomClient) async -> GroupChatStore? {
        let store = GroupChatStore()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        client.logStarted = didStart
        store.bind(to: client)
        guard await waitForLog(started, continuation: didStart) else {
            Issue.record("Initial refresh did not request the preview")
            return nil
        }
        #expect(store.lastMessages["r"]?.text == "You: message 1")
        return store
    }

    private func waitForLog(
        _ started: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation
    ) async -> Bool {
        let timeout = Task {
            do {
                try await Task.sleep(for: .seconds(2))
                continuation.finish()
            } catch is CancellationError {
                return
            } catch {
                Issue.record("Preview wait failed: \(error)")
                continuation.finish()
            }
        }
        var iterator = started.makeAsyncIterator()
        let didStart = await iterator.next() != nil
        timeout.cancel()
        await timeout.value
        return didStart
    }
}

@MainActor
private final class PreviewRoomClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var revision = 1
    var failPreview = false
    var logStarted: AsyncStream<Void>.Continuation?
    var logPause: AsyncStream<Void>?
    private(set) var previewRevisions: [Int] = []

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "groups.capabilities": return ["driver": true]
        case "groups.list": return ["rooms": [["room_id": "r", "latest_seq": revision, "members": []]]]
        case "groups.log":
            let seq = revision
            previewRevisions.append(seq)
            logStarted?.yield(())
            logStarted?.finish()
            logStarted = nil
            if failPreview { throw HermesGateway.GatewayError.httpRefused(500, "refused") }
            if let logPause {
                self.logPause = nil
                for await _ in logPause { break }
            }
            return [
                "events": [
                    [
                        "seq": seq, "event_id": "e\(seq)", "kind": "message.user", "created_at": Double(seq),
                        "payload": ["text": "message \(seq)\nsecond line"],
                    ]
                ],
                "cursor": seq, "latest_seq": seq, "has_more": false,
            ]
        default: return [:]
        }
    }
}
