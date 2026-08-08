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
}

@MainActor
private final class CapabilityProbeClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?

    func connect() async throws {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard method == "shell.exec" else { return [:] }
        let command = params["command"] as? String ?? ""
        switch command {
        case "memo --version", "himalaya --version", "imsg --version":
            return ["code": 127, "stderr": "command not found"]
        case "hermes mcp list":
            return ["code": 0, "stdout": "No MCP servers configured"]
        default:
            return ["code": 0, "stdout": "available"]
        }
    }

    func close() {}
}
