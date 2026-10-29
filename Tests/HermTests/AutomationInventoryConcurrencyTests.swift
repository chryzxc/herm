import Foundation
import Testing

@testable import Herm

@MainActor
private final class InventoryGateClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var reads = 0
    var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        reads += 1
        let read = reads
        return try await withCheckedThrowingContinuation { pending[read] = $0 }
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] { ["runs": []] }
    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] { [:] }
    func release(_ read: Int = 1, jobID: String = "new") {
        pending.removeValue(forKey: read)?.resume(returning: [
            "scoped": "research",
            "jobs": [["job_id": jobID, "name": jobID, "schedule": "daily", "enabled": true]],
        ])
    }
}

@MainActor
struct AutomationInventoryConcurrencyTests {
    @Test func sharedReadSurvivesOneConsumerCancellation() async throws {
        let client = InventoryGateClient()
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))
        model.routineProfileID = "research"
        let first = Task { await model.refreshRoutineInventory(profileID: "research") }
        for _ in 0..<10_000 where client.pending[1] == nil { await Task.yield() }
        try #require(client.pending[1] != nil)
        let second = Task { await model.refreshRoutineInventory(profileID: "research") }
        for _ in 0..<10_000 where model.routineInventoryConsumers < 2 { await Task.yield() }
        #expect(model.routineInventoryConsumers == 2)
        first.cancel()
        client.release()
        await first.value
        await second.value
        #expect(client.reads == 1)
        #expect(model.cronJobs.first?.id == "new")
    }

    @Test func reboundContextRejectsSuspendedInventory() async throws {
        let client = InventoryGateClient()
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))
        model.routineProfileID = "research"
        let first = Task { await model.refreshRoutineInventory(profileID: "research") }
        for _ in 0..<10_000 where client.pending[1] == nil { await Task.yield() }
        try #require(client.pending[1] != nil)
        model.clientBindingGeneration += 1
        model.resetRoutineRunState()
        model.routineProfileID = "other"
        client.release()
        await first.value
        #expect(model.cronJobs.isEmpty)
        #expect(model.routineProfileID == "other")
    }

    @Test func forcedFreshInventoryWinsWhenOlderReadCompletesLast() async throws {
        let client = InventoryGateClient()
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))
        model.routineProfileID = "research"
        let old = Task { await model.refreshRoutineInventory(profileID: "research") }
        for _ in 0..<10_000 where client.pending[1] == nil { await Task.yield() }
        try #require(client.pending[1] != nil)
        let fresh = Task { await model.refreshRoutineInventory(profileID: "research", fresh: true) }
        for _ in 0..<10_000 where client.pending[2] == nil { await Task.yield() }
        try #require(client.pending[2] != nil)
        #expect(client.reads == 2)
        client.release(2, jobID: "fresh")
        await fresh.value
        #expect(model.cronJobs.map(\.id) == ["fresh"])
        client.release(1, jobID: "old")
        await old.value
        #expect(model.cronJobs.map(\.id) == ["fresh"])
    }
}
