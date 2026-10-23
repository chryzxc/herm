import Foundation
import Testing

@testable import Herm

@MainActor
private final class RuntimeMutationRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var pending: CheckedContinuation<Void, Never>?
    var creates = 0
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "session.create" {
            creates += 1
            await withCheckedContinuation { pending = $0 }
            return ["session_id": "fixture-draft"]
        }
        return [:]
    }
}

@MainActor
struct RuntimeModelMutationTests {
    @Test(arguments: [false, true]) func automaticRefreshCannotReleaseMutationGuard(warm: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try #require(UserDefaults(suiteName: "RuntimeMutation-\(UUID().uuidString)"))
        let rpc = RuntimeMutationRPC()
        let model = DockModel(
            sessionAgentStateFileURL: directory.appendingPathComponent("agents.json"),
            defaults: defaults, botActivityFileURL: directory.appendingPathComponent("bots.json"), rpcClient: rpc)
        let value = HermesRuntimeConfiguration(
            agentName: "Fixture", model: "model", provider: "provider",
            configPath: "/fixture/config.yaml", maxTurns: "10", terminalTimeout: "15",
            skills: [], skillsInventory: .supported([]), mcpServers: [], plugins: [])
        var reads = 0
        var readback: CheckedContinuation<Void, Never>?
        model.runtimeConfigurationRefresh = HermesRuntimeConfigurationRefresh(
            scope: { "fixture" },
            metadata: { _ in "same" },
            reader: { _ in
                reads += 1
                if reads == 2 { await withCheckedContinuation { readback = $0 } }
                return .init(configuration: value, isComplete: true, initialSignature: "same")
            })
        if warm { await model.loadRuntimeConfiguration(force: false) }
        let option = HermesModelOption(provider: "provider", model: "chosen")
        model.updateRuntimeModel(option)
        while rpc.pending == nil { await Task.yield() }
        await model.loadRuntimeConfiguration(force: false)
        #expect(model.isLoadingRuntimeConfiguration)
        model.updateRuntimeModel(option)
        // Flush a wrongly accepted second write without leaving a suspended task.
        let first = rpc.pending
        rpc.pending = nil
        for _ in 0..<20 { await Task.yield() }
        #expect(rpc.creates == 1)
        let second = rpc.pending
        first?.resume()
        second?.resume()
        while readback == nil { await Task.yield() }
        #expect(model.isLoadingRuntimeConfiguration)
        readback?.resume()
        while model.isLoadingRuntimeConfiguration { await Task.yield() }
    }
}
