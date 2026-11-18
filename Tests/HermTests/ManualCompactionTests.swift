import Foundation
import Testing

@testable import Herm

@MainActor
private final class ManualCompactionRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var duringCompress: (() -> Void)?
    var fails = true
    var resultStatus = "compressed"
    private(set) var compressionCalls = 0

    func connect() async throws {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard method == "session.compress" else { return [:] }
        compressionCalls += 1
        duringCompress?()
        if fails {
            throw NSError(
                domain: "Hermes", code: 408,
                userInfo: [NSLocalizedDescriptionKey: "Hermes did not respond in time."])
        }
        return ["status": resultStatus]
    }

    func close() {}
}

@MainActor
struct ManualCompactionTests {
    @Test func compressionUsesLongRunningRequestBudget() {
        #expect(HermesGateway.requestTimeout(for: "session.compress") == 1500)
        #expect(HermesGateway.requestTimeout(for: "session.title") == 15)
        #expect(HermesGateway.requestTimeout(for: HermesFeatureIDs.ID.botRelayDeliver.rawValue) == 1500)
        #expect(HermesGateway.requestTimeout(for: "plugins.manage", params: ["action": "install"]) == 300)
        #expect(HermesGateway.requestTimeout(for: "plugins.manage", params: ["action": "list"]) == 45)
    }

    @Test(arguments: ["compress", "compact"])
    func timedOutManualCompactionDoesNotLeaveComposerCompacting(command: String) async throws {
        let client = ManualCompactionRPCClient()
        let model = DockModel(initialSessionID: "owner", rpcClient: client)
        client.duringCompress = {
            model.receiveGatewayEvent(
                "status.update", params: ["session_id": "owner", "payload": ["kind": "compressing"]])
        }
        model.draft = "/\(command)"
        model.send()
        try await waitUntil { model.messages.contains { $0.isError } && !model.isSending }
        #expect(client.compressionCalls == 1)
        #expect(model.messages.last?.text.contains("did not respond in time") == true)
        #expect(model.compactingSessionID == nil)
        #expect(model.status == .idle)
    }

    @Test(arguments: ["compress", "compact"])
    func acknowledgedManualCompactionClearsProgressWithoutTerminalEvent(command: String) async throws {
        let client = ManualCompactionRPCClient()
        client.fails = false
        let model = DockModel(initialSessionID: "owner", rpcClient: client)
        client.duringCompress = {
            model.receiveGatewayEvent(
                "status.update", params: ["session_id": "owner", "payload": ["kind": "compressing"]])
        }
        model.draft = "/\(command)"
        model.send()
        try await waitUntil { model.messages.contains { $0.text == "Context compressed." } && !model.isSending }
        #expect(client.compressionCalls == 1)
        #expect(model.compactingSessionID == nil)
        #expect(model.status == .idle)
    }

    @Test(arguments: ["pending", "aborted"])
    func reportedStatusDoesNotClaimSuccess(resultStatus: String) async throws {
        let client = ManualCompactionRPCClient()
        client.fails = false
        client.resultStatus = resultStatus
        let model = DockModel(initialSessionID: "owner", rpcClient: client)
        model.draft = "/compress"
        model.send()
        try await waitUntil { model.messages.count >= 2 && !model.isSending }
        #expect(!model.messages.contains { $0.text == "Context compressed." })
        #expect(model.messages.last?.isError == (resultStatus == "aborted"))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Manual compaction did not settle")
        throw CancellationError()
    }
}
