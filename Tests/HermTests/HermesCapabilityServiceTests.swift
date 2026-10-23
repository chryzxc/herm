import Foundation
import Testing

@testable import Herm

@MainActor
@Suite(.serialized)
struct HermesCapabilityServiceTests {
    @Test func shellAvailabilityRequiresSuccessfulExitCode() {
        #expect(HermesCapabilityService.shellResultSucceeded(["code": 0, "stdout": "memo 1.0"]) == true)
        #expect(HermesCapabilityService.shellResultSucceeded(["code": 127, "stderr": "command not found"]) == false)
        #expect(HermesCapabilityService.shellResultSucceeded(["exit_code": 0, "output": "hermes kanban"]) == true)
        #expect(HermesCapabilityService.shellResultSucceeded(["exit_code": 1, "error": "failed"]) == false)
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

    @Test func capabilityProbeHonorsTotalDeadline() async {
        let client = HangingCapabilityProbeClient()
        let service = HermesCapabilityService(probeTimeout: .milliseconds(20))
        let states = await service.probe(client: client, remindersAvailable: false)
        let elapsed = client.firstRequestStarted.map { $0.duration(to: .now) }

        #expect(states.isEmpty)
        #expect(elapsed != nil)
        #expect(elapsed! < .seconds(1))
        client.release()
    }

    @Test func timedOutProbeDoesNotWaitForNonCooperativeTransport() async {
        let client = HangingCapabilityProbeClient()
        let service = HermesCapabilityService(probeTimeout: .milliseconds(10))

        let states = await service.probe(client: client, remindersAvailable: false)

        #expect(states.isEmpty)
        client.release()
    }

    @Test func concurrentTimedOutProbesDoNotStartUnboundedRequests() async {
        let client = HangingCapabilityProbeClient(delay: .milliseconds(1))
        let service = HermesCapabilityService(probeTimeout: .milliseconds(20))

        let probes = (0..<8).map { index in
            Task {
                await service.probe(
                    client: client,
                    remindersAvailable: index.isMultiple(of: 2),
                    sessionID: "session-\(index)",
                    forceRefresh: true
                )
            }
        }
        for probe in probes {
            _ = await probe.value
        }

        #expect(client.requestCount <= 16)
        client.release()
    }

    @Test func completedProbeTimeoutCannotInvalidateLaterCache() async {
        let client = CapabilityProbeClient()
        let service = HermesCapabilityService(probeTimeout: .seconds(2))
        let firstStates = await service.probe(client: client, remindersAvailable: false)
        let count = client.requestCount
        let cachedStates = await service.probe(client: client, remindersAvailable: false)

        #expect(!firstStates.isEmpty)
        #expect(cachedStates == firstStates)
        #expect(client.requestCount == count)
    }

    @Test func timedOutRefreshPreservesLastSnapshotAndMarksItStale() async {
        let client = ToggleHangingCapabilityProbeClient()
        let service = HermesCapabilityService(probeTimeout: .seconds(2))
        let successful = await service.probe(client: client, remindersAvailable: false)
        #expect(!successful.isEmpty)

        client.isHanging = true
        let timedOut = await service.probe(client: client, remindersAvailable: false, forceRefresh: true)

        #expect(timedOut.count == successful.count)
        #expect(timedOut.allSatisfy { $0.detail.localizedCaseInsensitiveContains("timed out") })
        client.release()
    }

    @Test func timedOutSessionProbeCannotReuseAnotherSessionSnapshot() async {
        let client = ToggleHangingCapabilityProbeClient()
        let service = HermesCapabilityService(probeTimeout: .seconds(2))
        let sessionA = await service.probe(client: client, remindersAvailable: false, sessionID: "session-a")
        #expect(!sessionA.isEmpty)
        client.isHanging = true
        let sessionB = await service.probe(client: client, remindersAvailable: false, sessionID: "session-b")
        #expect(sessionB.isEmpty)
        client.release()
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

    @Test func supersededProbeReturnsImmediatelyWhenNoNewerSnapshotIsPublished() async {
        let client = OverlappingCapabilityProbeClient()
        let service = HermesCapabilityService()

        let first = Task { await service.probe(client: client, remindersAvailable: false) }
        await client.waitUntilFirstProbeSuspends()
        let second = Task { await service.probe(client: client, remindersAvailable: true, forceRefresh: true) }
        await client.waitUntilSecondProbeSuspends()
        client.releaseFirstProbe()

        let firstStates = await first.value
        #expect(firstStates.isEmpty)

        client.releaseProbes()
        _ = await second.value
        let cached = await service.probe(client: client, remindersAvailable: true)
        #expect(cached.first(where: { $0.id == "reminders" })?.availability == .available)
    }

    @Test func supersededProbeCannotOverwriteNewerCache() async {
        let client = OverlappingCapabilityProbeClient()
        let service = HermesCapabilityService()

        let first = Task { await service.probe(client: client, remindersAvailable: false) }
        await client.waitUntilFirstProbeSuspends()
        let second = Task { await service.probe(client: client, remindersAvailable: true, forceRefresh: true) }
        await client.waitUntilSecondProbeSuspends()
        client.releaseProbes()

        _ = await first.value
        _ = await second.value
        let cached = await service.probe(client: client, remindersAvailable: true)

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
    private var firstProbeHasEntered = false
    private var firstProbeIsReleased = false
    private var secondProbeHasEntered = false
    private var firstProbeEntryWaiter: CheckedContinuation<Void, Never>?
    private var secondProbeEntryWaiter: CheckedContinuation<Void, Never>?
    private var firstProbeRelease: CheckedContinuation<Void, Never>?
    private var secondProbeRelease: CheckedContinuation<Void, Never>?

    func waitUntilFirstProbeSuspends() async {
        await waitUntilFirstProbeEnters()
    }

    func waitUntilSecondProbeSuspends() async {
        await waitUntilSecondProbeEnters()
    }

    private func waitUntilFirstProbeEnters() async {
        guard !firstProbeHasEntered else { return }
        await withCheckedContinuation { continuation in
            firstProbeEntryWaiter = continuation
        }
    }

    private func waitUntilSecondProbeEnters() async {
        guard !secondProbeHasEntered else { return }
        await withCheckedContinuation { continuation in
            secondProbeEntryWaiter = continuation
        }
    }

    func releaseFirstProbe() {
        firstProbeIsReleased = true
        firstProbeRelease?.resume()
        firstProbeRelease = nil
    }

    func releaseProbes() {
        releaseFirstProbe()
        secondProbeRelease?.resume()
        secondProbeRelease = nil
    }

    override func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if !firstProbeHasEntered {
            firstProbeHasEntered = true
            firstProbeEntryWaiter?.resume()
            firstProbeEntryWaiter = nil
            if !firstProbeIsReleased {
                await withCheckedContinuation { continuation in
                    firstProbeRelease = continuation
                }
            }
        } else if !secondProbeHasEntered {
            secondProbeHasEntered = true
            secondProbeEntryWaiter?.resume()
            secondProbeEntryWaiter = nil
            await withCheckedContinuation { continuation in
                secondProbeRelease = continuation
            }
        }
        return try await super.request(method, params: params)
    }
}

private enum TestRPCError: Error { case failed }

@MainActor
private final class HangingCapabilityProbeClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var requestCount = 0
    private(set) var firstRequestStarted: ContinuousClock.Instant?
    private let delay: Duration?
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(delay: Duration? = nil) {
        self.delay = delay
    }

    func connect() async throws {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requestCount += 1
        firstRequestStarted = firstRequestStarted ?? .now
        if let delay {
            try await Task.sleep(for: delay)
            return ["ok": true]
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        return [:]
    }
    func release() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
    func close() { release() }
}

@MainActor
private final class ToggleHangingCapabilityProbeClient: CapabilityProbeClient {
    var isHanging = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    override func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if isHanging {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }
        return try await super.request(method, params: params)
    }

    func release() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
