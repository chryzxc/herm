import Combine
import Foundation
import Testing

@testable import Herm

@MainActor
private final class UsagePublicationRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var pending: CheckedContinuation<[String: Any], Error>?
    var holdUsage = false
    func connect() async throws {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "session.usage", holdUsage {
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        throw CancellationError()
    }
    func close() {}
}

@MainActor
struct SessionTokenUsagePublicationTests {
    @Test func refreshPublishesTransitionsAndStillAppliesContext() async throws {
        let client = UsagePublicationRPC()
        client.holdUsage = true
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            initialSessionID: "one", rpcClient: client)
        defer { model.shutdown() }
        var values: [String] = []
        let subscription = model.$sessionTokenUsage.dropFirst().sink { value in
            if let value { values.append("\(value.sessionID):\(value.total)") }
        }
        for (index, total) in [100, 100, 120, 90, 0].enumerated() {
            model.refreshSessionTokenUsage()
            for _ in 0..<10_000 where client.pending == nil { await Task.yield() }
            let pending = try #require(client.pending)
            client.pending = nil
            pending.resume(returning: ["total": total, "context_used": index + 1, "context_max": 1_000])
            for _ in 0..<10_000 where model.sessionContextUsage?.used != index + 1 { await Task.yield() }
            #expect(model.sessionContextUsage?.used == index + 1)
        }
        #expect(values == ["one:100", "one:120", "one:90", "one:0"])
        model.sessionID = "two"
        model.refreshSessionTokenUsage()
        for _ in 0..<10_000 where client.pending == nil { await Task.yield() }
        let pending = try #require(client.pending)
        client.pending = nil
        pending.resume(returning: ["total": 0, "context_used": 7, "context_max": 1_000])
        for _ in 0..<10_000 where model.sessionContextUsage?.used != 7 { await Task.yield() }
        #expect(values == ["one:100", "one:120", "one:90", "one:0", "two:0"])
        withExtendedLifetime(subscription) {}
    }

    @Test func lateAndFailedRefreshesLeaveUsageUntouched() async throws {
        let client = UsagePublicationRPC()
        client.holdUsage = true
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            initialSessionID: "one", rpcClient: client)
        defer { model.shutdown() }
        model.sessionTokenUsage = ("one", 10)
        var publications = 0
        let subscription = model.$sessionTokenUsage.dropFirst().sink { _ in publications += 1 }
        model.refreshSessionTokenUsage()
        for _ in 0..<10_000 where client.pending == nil { await Task.yield() }
        let pending = try #require(client.pending)
        client.pending = nil
        model.sessionID = "two"
        pending.resume(returning: ["total": 50, "context_used": 5, "context_max": 100])
        model.refreshSessionTokenUsage()
        for _ in 0..<10_000 where client.pending == nil { await Task.yield() }
        let failure = try #require(client.pending)
        client.pending = nil
        failure.resume(throwing: CancellationError())
        for _ in 0..<100 { await Task.yield() }
        #expect(publications == 0)
        #expect(model.sessionTokenUsage?.total == 10)
        #expect(model.sessionContextUsage?.used == nil)
        withExtendedLifetime(subscription) {}
    }

    @Test func completionPublishesOnlyChangedUsage() {
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            initialSessionID: "usage-session", rpcClient: UsagePublicationRPC())
        defer { model.shutdown() }
        model.sessionTokenUsage = ("usage-session", 100)
        var values: [Int] = []
        let subscription = model.$sessionTokenUsage.dropFirst().sink { value in
            if let value { values.append(value.total) }
        }
        func complete(_ payload: [String: Any]) {
            model.receiveGatewayEvent("message.complete", params: ["session_id": "usage-session", "payload": payload])
        }
        complete(["usage": ["total": 100]])
        complete([:])
        #expect(values.isEmpty)
        model.receiveGatewayEvent("message.start", params: ["session_id": "usage-session", "payload": [:]])
        complete(["usage": ["total": 110], "text": "Done"])
        #expect(values == [110])
        #expect(model.messages.last?.tokenCount == 10)
        withExtendedLifetime(subscription) {}
    }

    @Test func completionPreservesEstimateAndForeignUsage() {
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            initialSessionID: "usage-session", rpcClient: UsagePublicationRPC())
        defer { model.shutdown() }
        model.sessionTokenUsage = ("usage-session", 100)
        var values: [Int] = []
        let subscription = model.$sessionTokenUsage.dropFirst().sink { value in
            if let value { values.append(value.total) }
        }
        model.receiveGatewayEvent("message.start", params: ["session_id": "usage-session", "payload": [:]])
        model.receiveGatewayEvent(
            "message.delta", params: ["session_id": "usage-session", "payload": ["delta": "🙂🙂"]])
        model.receiveGatewayEvent("message.complete", params: ["session_id": "usage-session", "payload": [:]])
        #expect(values == [102])
        model.sessionTokenUsage = ("foreign", 12)
        values.removeAll()
        model.receiveGatewayEvent(
            "message.complete", params: ["session_id": "usage-session", "payload": ["usage": ["total": 20]]])
        #expect(values.isEmpty)
        model.sessionTokenUsage = nil
        values.removeAll()
        model.receiveGatewayEvent(
            "message.complete", params: ["session_id": "usage-session", "payload": ["usage": ["total": 20]]])
        #expect(values.isEmpty)
        withExtendedLifetime(subscription) {}
    }
}
