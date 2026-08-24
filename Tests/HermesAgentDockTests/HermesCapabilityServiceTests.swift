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

    @Test func capabilityCacheIsScopedToTheRPCClientInstance() async {
        let firstClient = CapabilityProbeClient()
        let secondClient = CapabilityProbeClient()
        let service = HermesCapabilityService()

        _ = await service.probe(client: firstClient, remindersAvailable: false)
        _ = await service.probe(client: secondClient, remindersAvailable: false)

        #expect(secondClient.requestCount > 0)
    }

    @Test func thrownAndMalformedRPCResponsesAreClassifiedAsUnavailable() async {
        let client = FailingCapabilityProbeClient()
        let capabilities = await HermesCapabilityService().probe(client: client, remindersAvailable: false)
        let byID = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.id, $0) })

        #expect(byID["rpc-sessions"]?.isAvailable == false)
        #expect(byID["rpc-sessions"]?.availability == .unsupported)
        #expect(byID["gateway"]?.isAvailable == false)
        #expect(byID["tools"]?.isAvailable == false)
    }

    @Test func supersededProbeCannotOverwriteNewerCache() async {
        let client = OverlappingCapabilityProbeClient()
        let service = HermesCapabilityService()

        let first = Task { await service.probe(client: client, remindersAvailable: false) }
        await client.waitUntilFirstProbeSuspends()
        let second = Task { await service.probe(client: client, remindersAvailable: true, forceRefresh: true) }
        await client.waitUntilSecondProbeSuspends()
        client.releaseProbes()

        let firstStates = await first.value
        _ = await second.value
        let cached = await service.probe(client: client, remindersAvailable: true)

        #expect(firstStates.first(where: { $0.id == "reminders" })?.availability == .available)
        #expect(cached.first(where: { $0.id == "reminders" })?.availability == .available)
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

    @Test func productionProbesExposeReadinessMetadataForRealCapabilities() async {
        let client = CapabilityProbeClient()
        let capabilities = await HermesCapabilityService().probe(client: client, remindersAvailable: true)
        let byID = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.id, $0) })

        #expect(byID["gateway"]?.category == .core)
        #expect(byID["gateway"]?.provenance == .hermesGateway)
        #expect(byID["gateway"]?.probeState == .verified)
        #expect(byID["rpc-sessions"]?.category == .core)
        #expect(byID["kanban"]?.category == .integration)
        #expect(byID["kanban"]?.provenance == .hermesCLI)
        #expect(byID["kanban"]?.probeState == .verified)
        #expect(byID["mcp"]?.category == .integration)
        #expect(byID["mcp"]?.probeState != .verified)
        #expect(byID["tools"]?.category == .core)
        #expect(byID["notes"]?.probeState == .missing)
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
private class CapabilityProbeClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var requestCount = 0

    func connect() async throws {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requestCount += 1
        guard method == "shell.exec" else { return ["ok": true] }
        let command = params["command"] as? String ?? ""
        switch command {
        case "memo --version", "himalaya --version", "imsg --version":
            return ["code": 127, "stderr": "command not found"]
        case "hermes mcp list":
            return ["code": 0, "stdout": "No MCP servers configured"]
        case "hermes kanban list --help":
            return ["code": 0, "stdout": "list --json"]
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

@MainActor
private final class FailingCapabilityProbeClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    func connect() async throws {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "session.active_list" { throw TestRPCError.failed }
        if method == "tools.list" { return ["error": "bad response"] }
        return [:]
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] { [:] }
    func close() {}
}

@MainActor
private final class OverlappingCapabilityProbeClient: CapabilityProbeClient {
    private var suspensionCount = 0
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var suspensionWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func waitUntilFirstProbeSuspends() async {
        await waitForSuspension(number: 1)
    }

    func waitUntilSecondProbeSuspends() async {
        await waitForSuspension(number: 2)
    }

    private func waitForSuspension(number: Int) async {
        guard suspensionCount < number else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters[number] = continuation
        }
    }

    func releaseProbes() {
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    override func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if suspensionCount < 2 {
            suspensionCount += 1
            suspensionWaiters.removeValue(forKey: suspensionCount)?.resume()
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }
        return try await super.request(method, params: params)
    }
}

private enum TestRPCError: Error { case failed }
