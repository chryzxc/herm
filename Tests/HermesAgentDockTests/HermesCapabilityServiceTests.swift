import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct HermesCapabilityServiceTests {
    @Test func shellAvailabilityRequiresSuccessfulExitCode() {
        #expect(HermesCapabilityService.shellResultSucceeded(["code": 0, "stdout": "memo 1.0"]) == true)
        #expect(HermesCapabilityService.shellResultSucceeded(["code": 127, "stderr": "command not found"]) == false)
        #expect(HermesCapabilityService.shellResultSucceeded(nil) == false)
    }

    @Test func exposesDocumentedProviderRecoveryCommandsWhenCLIsAreMissing() async {
        let client = CapabilityProbeClient()
        let capabilities = await HermesCapabilityService().probe(client: client, remindersAvailable: false)
        let byID = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.id, $0) })

        #expect(byID["notes"]?.recoveryCommand == "brew tap antoniorodr/memo && brew install antoniorodr/memo/memo")
        #expect(byID["messaging"]?.recoveryCommand == "brew install steipete/tap/imsg")
        #expect(byID["email"]?.recoveryCommand == "brew install himalaya")
    }

    @Test func cachesCapabilitySnapshotUntilForcedRefresh() async {
        let client = CapabilityProbeClient()
        let service = HermesCapabilityService()

        _ = await service.probe(client: client, remindersAvailable: false)
        let firstRequestCount = client.requestCount
        _ = await service.probe(client: client, remindersAvailable: false)

        #expect(client.requestCount == firstRequestCount)

        _ = await service.probe(client: client, remindersAvailable: false, forceRefresh: true)
        #expect(client.requestCount > firstRequestCount)
    }

    @Test func capabilityCacheIsScopedToTheActiveSession() async {
        let client = CapabilityProbeClient()
        let service = HermesCapabilityService()

        _ = await service.probe(client: client, remindersAvailable: false)
        let noSessionRequestCount = client.requestCount

        _ = await service.probe(client: client, remindersAvailable: false, sessionID: "session-a")
        let firstSessionRequestCount = client.requestCount
        #expect(firstSessionRequestCount > noSessionRequestCount)

        _ = await service.probe(client: client, remindersAvailable: false, sessionID: "session-a")
        #expect(client.requestCount == firstSessionRequestCount)

        _ = await service.probe(client: client, remindersAvailable: false, sessionID: "session-b")
        #expect(client.requestCount > firstSessionRequestCount)
    }

    @Test func classifiesCapabilitiesBySourceAndAccess() async {
        let client = CapabilityProbeClient()
        let capabilities = await HermesCapabilityService().probe(client: client, remindersAvailable: true)
        let byID = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.id, $0) })

        #expect(byID["kanban.taskDetails"]?.source == .cli)
        #expect(byID["kanban.taskDetails"]?.access == .readOnly)
        #expect(byID["kanban.boards"]?.isAvailable == true)
        #expect(byID["rpc-sessions"]?.source == .gateway)
        #expect(byID["reminders"]?.source == .external)
        #expect(byID["reminders"]?.availability == .available)
    }

    @Test func mutationCapabilitiesRequireTheirDocumentedHelpTerms() async {
        let client = CapabilityProbeClient()
        let capabilities = await HermesCapabilityService().probe(client: client, remindersAvailable: false)
        let byID = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.id, $0) })

        // The fixture returns a successful generic response, not the required
        // argument contract. A successful --help exit alone must fail closed.
        #expect(byID["kanban.comment"]?.isAvailable == false)
        #expect(byID["cron.edit"]?.isAvailable == false)
        #expect(byID["kanban.filters"]?.isAvailable == false)
    }
}

@MainActor
private final class CapabilityProbeClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var requestCount = 0

    func connect() async throws {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requestCount += 1
        guard method == "shell.exec" else { return [:] }
        let command = params["command"] as? String ?? ""
        switch command {
        case "memo --version", "himalaya --version", "imsg --version":
            return ["code": 127, "stderr": "command not found"]
        case "hermes mcp list":
            return ["code": 0, "stdout": "No MCP servers configured"]
        case "hermes kanban boards list --help":
            return ["code": 0, "stdout": "List all boards\n--json\n--all"]
        case "hermes kanban boards switch --help":
            return ["code": 0, "stdout": "switch slug\nslug"]
        default:
            return ["code": 0, "stdout": "available"]
        }
    }

    func close() {}
}
