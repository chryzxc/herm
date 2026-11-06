import Foundation
import Testing

@testable import Herm

@MainActor
private final class EffortFixtureRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var requests: [(String, [String: Any])] = []
    var failRead = false
    var failFastSet = false
    var readValue = "medium"
    var modelOptionsResult: [String: Any] = [:]
    var onSet: (() -> Void)?
    var onRequest: ((String, [String: Any]) -> Void)?
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        onRequest?(method, params)
        if method == "config.set" {
            onSet?()
            if params["key"] as? String == "fast", failFastSet { throw NSError(domain: "fixture", code: 1) }
            if params["key"] as? String == "fast" { return ["key": "fast", "value": params["value"] ?? "normal"] }
            return ["key": "reasoning", "value": "high", "scope": "session"]
        }
        if method == "config.get" {
            if failRead { throw NSError(domain: "fixture", code: 1) }
            return ["value": readValue]
        }
        if method == "model.options" { return modelOptionsResult }
        return [:]
    }
}

@MainActor
struct HermesEffortPolicyTests {
    @Test func fastSelectionIsPendingImmediatelyAndRevertsOnFailure() async {
        let client = EffortFixtureRPC()
        client.failFastSet = true
        let model = DockModel(initialSessionID: "owner", rpcClient: client)
        model.sessionFastEnabled = false
        model.updateSessionFast(true)
        #expect(model.pendingSessionFastEnabled == true)
        #expect(model.sessionFastEnabled == false)
        #expect(model.isUpdatingSessionFast)
        await withCheckedContinuation { continuation in
            client.onRequest = { method, _ in
                guard method == "config.set" else { return }
                client.onRequest = nil
                continuation.resume()
            }
        }
        #expect(model.pendingSessionFastEnabled == nil)
        #expect(model.sessionFastEnabled == false)
        #expect(!model.isUpdatingSessionFast)
        #expect(model.runtimeConfigurationError != nil)
    }

    @Test func fastMutationAndReadbackUseSessionScope() async {
        let client = EffortFixtureRPC()
        let model = DockModel(initialSessionID: "owner", rpcClient: client)
        model.sessionProfileID = "profile"
        await withCheckedContinuation { continuation in
            client.onRequest = { method, params in
                guard method == "config.set" else { return }
                #expect(params["key"] as? String == "fast")
                #expect(params["value"] as? String == "fast")
                #expect(params["session_id"] as? String == "owner")
                #expect(params["profile"] as? String == "profile")
                client.onRequest = nil
                continuation.resume()
            }
            model.updateSessionFast(true)
        }
        #expect(model.sessionFastEnabled == true)
        client.readValue = "normal"
        await withCheckedContinuation { continuation in
            client.onRequest = { method, params in
                guard method == "config.get" else { return }
                #expect(params["key"] as? String == "fast")
                client.onRequest = nil
                continuation.resume()
            }
            model.refreshSessionFast()
        }
        #expect(model.sessionFastEnabled == false)
        model.resetEffortTransition()
        #expect(model.sessionFastEnabled == nil)
    }
    @Test func routeChangeInvalidatesOldWireMappingBeforeEqualReadback() async {
        let client = EffortFixtureRPC()
        client.readValue = "ultra"
        client.modelOptionsResult = [
            "provider": "b", "model": "model-b",
            "providers": [["slug": "b", "models": ["model-b"], "capabilities": ["model-b": ["reasoning": true]]]],
        ]
        let model = DockModel(initialSessionID: "owner", rpcClient: client)
        model.sessionModelOptionID = "a|model-a"
        model.sessionReasoningVariant = .ultra
        model.sessionReasoningWire = "max"
        await withCheckedContinuation { continuation in
            client.onRequest = { method, _ in
                guard method == "model.options" else { return }
                client.onRequest = nil
                continuation.resume()
            }
            model.refreshSessionModelOptions()
        }
        #expect(model.sessionModelOptionID == "b|model-b")
        await withCheckedContinuation { continuation in
            client.onRequest = { method, _ in
                guard method == "config.get" else { return }
                client.onRequest = nil
                continuation.resume()
            }
            model.refreshSessionReasoningVariant()
        }
        #expect(model.sessionReasoningVariant == .ultra)
        #expect(model.sessionReasoningWire == nil)
    }
    @Test func routeSnapshotRefreshesScopedOptions() async {
        let client = EffortFixtureRPC()
        let model = DockModel(initialSessionID: "owner", rpcClient: client)
        model.sessionProfileID = "profile"
        model.sessionModelOptionID = "first|shared"
        for payload in [["model": "new"], ["model": "shared", "provider": "second"]] {
            await withCheckedContinuation { continuation in
                client.onRequest = { method, params in
                    guard method == "model.options" else { return }
                    #expect(params["session_id"] as? String == "owner")
                    #expect(params["profile"] as? String == "profile")
                    client.onRequest = nil
                    continuation.resume()
                }
                model.receiveGatewayEvent("session.info", params: ["session_id": "owner", "payload": payload])
            }
        }
    }

    @Test func sessionWorkspaceFollowsOnlyOwnedOrderedInfo() {
        let model = DockModel(initialSessionID: "owner", rpcClient: EffortFixtureRPC())
        model.sessionStorageID = "owner"
        model.sessionProfileID = "profile"
        model.receiveGatewayEvent(
            "session.info",
            params: [
                "session_id": "owner", "seq": 10,
                "payload": ["cwd": "/tmp/first", "stored_session_id": "owner", "reasoning_effort": "high"],
            ])
        #expect(model.sessionWorkspace?.cwd == "/tmp/first")
        model.receiveGatewayEvent(
            "session.info",
            params: [
                "session_id": "other", "seq": 11, "payload": ["cwd": "/tmp/other"],
            ])
        model.receiveGatewayEvent(
            "session.info",
            params: [
                "session_id": "owner", "seq": 9, "payload": ["cwd": "/tmp/old", "reasoning_effort": "low"],
            ])
        #expect(model.sessionWorkspace?.cwd == "/tmp/first")
        #expect(model.sessionReasoningVariant == .high)
        model.receiveGatewayEvent(
            "session.info",
            params: [
                "session_id": "owner", "seq": 12, "payload": ["branch": "feature/test"],
            ])
        #expect(model.sessionWorkspace?.cwd == "/tmp/first")
        #expect(model.sessionWorkspace?.branch == "feature/test")
        model.receiveGatewayEvent(
            "session.info",
            params: [
                "session_id": "owner", "seq": 13,
                "payload": ["cwd": "/tmp/wrong", "stored_session_id": "other"],
            ])
        #expect(model.sessionWorkspace?.cwd == "/tmp/first")
        model.receiveGatewayEvent(
            "session.info",
            params: [
                "session_id": "owner", "seq": 14, "payload": ["cwd": "/tmp/second"],
            ])
        #expect(model.sessionWorkspace?.cwd == "/tmp/second")
        model.newChat()
        #expect(model.sessionWorkspace == nil)
        model.shutdown()
    }

    @Test func olderReplayDoesNotOverwriteSnapshot() {
        let model = DockModel(initialSessionID: "owner", rpcClient: EffortFixtureRPC())
        model.receiveGatewayEvent(
            "session.info",
            params: [
                "session_id": "owner", "seq": 10,
                "payload": ["reasoning_effort": "high"],
            ])
        model.receiveGatewayEvent(
            "session.info",
            params: [
                "session_id": "owner", "seq": 9,
                "herm_trace_replayed": true, "payload": ["reasoning_effort": "low"],
            ])
        #expect(model.sessionReasoningVariant == .high)
    }

    @Test func eventBeforeAcknowledgementStillReadsBack() async {
        let client = EffortFixtureRPC()
        let model = DockModel(initialSessionID: "owner", rpcClient: client)
        client.onSet = {
            model.receiveGatewayEvent(
                "session.info",
                params: [
                    "session_id": "owner", "seq": 1,
                    "payload": ["reasoning_effort": "high"],
                ])
        }
        await withCheckedContinuation { continuation in
            client.onRequest = { method, _ in
                guard method == "config.get" else { return }
                client.onRequest = nil
                continuation.resume()
            }
            model.updateSessionReasoning(.high)
        }
        #expect(client.requests.map(\.0).contains("config.get"))
        #expect(model.sessionReasoningVariant == .medium)
    }

    @Test func newerEventDuringReadbackWinsOverOlderResponse() async {
        let client = EffortFixtureRPC()
        let model = DockModel(initialSessionID: "owner", rpcClient: client)
        await withCheckedContinuation { continuation in
            client.onRequest = { method, _ in
                guard method == "config.get" else { return }
                client.onRequest = nil
                model.receiveGatewayEvent(
                    "session.info",
                    params: [
                        "session_id": "owner", "seq": 2,
                        "payload": ["reasoning_effort": "ultra", "reasoning_effort_wire": "max"],
                    ])
                continuation.resume()
            }
            model.updateSessionReasoning(.high)
        }
        #expect(model.sessionReasoningVariant == .ultra)
        #expect(model.sessionReasoningWire == "max")
    }

    @Test func profileChangeDuringReadbackDoesNotPublish() async {
        let client = EffortFixtureRPC()
        let model = DockModel(initialSessionID: "owner", rpcClient: client)
        model.sessionProfileID = "first"
        model.sessionReasoningVariant = .low
        await withCheckedContinuation { continuation in
            client.onRequest = { method, params in
                guard method == "config.get" else { return }
                #expect(params["profile"] as? String == "first")
                client.onRequest = nil
                model.sessionProfileID = "second"
                continuation.resume()
            }
            model.updateSessionReasoning(.high)
        }
        #expect(model.sessionReasoningVariant == .low)
    }

    @Test func effortAccessibilityPresentationIncludesMappingAndUnsupportedValue() {
        let model = DockModel(initialSessionID: "owner", rpcClient: EffortFixtureRPC())
        model.receiveGatewayEvent(
            "session.info",
            params: [
                "session_id": "owner", "seq": 1,
                "payload": ["reasoning_effort": "ultra", "reasoning_effort_wire": "max"],
            ])
        let mapped = ComposerEffortPresentation(
            selection: model.sessionReasoningVariant, choices: [.ultra], wire: model.sessionReasoningWire,
            pending: false, loading: false, stale: false)
        #expect(mapped.status == "Ultra → Max")
        #expect(mapped.accessibilityLabel.contains("Ultra → Max"))
        let catalog = HermesEffortCatalog(result: [
            "providers": [["slug": "p", "models": ["m"], "capabilities": ["m": ["reasoning": false]]]]
        ])
        let unsupported = ComposerEffortPresentation(
            selection: .high, choices: catalog.choices(for: "p|m"), wire: nil, pending: false, loading: false,
            stale: false)
        #expect(unsupported.status == "High — unavailable")
        #expect(unsupported.accessibilityLabel.contains("High — unavailable"))
        #expect(unsupported.disabled)
    }
    @Test func fastCapabilityComesFromTheCatalog() {
        let catalog = HermesEffortCatalog(result: [
            "providers": [
                [
                    "slug": "p", "models": ["on", "off", "silent"],
                    "capabilities": ["on": ["fast": true], "off": ["fast": false], "silent": [:]],
                ]
            ]
        ])
        #expect(catalog.supportsFast(for: "p|on") == true)
        #expect(catalog.supportsFast(for: "p|off") == false)
        #expect(catalog.supportsFast(for: "p|silent") == nil)
        #expect(catalog.supportsFast(for: nil) == nil)
    }
    @Test func capabilityAvailabilityMatrix() {
        let catalog = HermesEffortCatalog(result: [
            "providers": [
                [
                    "slug": "example", "models": ["enabled", "mandatory", "disabled", "legacy", "malformed"],
                    "capabilities": [
                        "enabled": ["reasoning": true],
                        "mandatory": ["reasoning": true, "can_disable_reasoning": false],
                        "disabled": ["reasoning": false],
                        "malformed": ["reasoning": "yes"],
                    ],
                ]
            ]
        ])
        #expect(catalog.choices(for: "example|enabled") == HermesReasoningVariant.allCases)
        #expect(catalog.choices(for: "example|mandatory") == Array(HermesReasoningVariant.allCases.dropFirst()))
        #expect(catalog.choices(for: "example|disabled") == [])
        #expect(catalog.choices(for: "example|legacy") == HermesReasoningVariant.allCases)
        #expect(catalog.choices(for: "example|malformed") == nil)
    }
    @Test func effortMutationRequiresReadback() async {
        let client = EffortFixtureRPC()
        let model = DockModel(initialSessionID: "effort-test", rpcClient: client)
        model.sessionProfileID = "effort-profile"
        model.sessionReasoningVariant = .low
        model.updateSessionReasoning(.high)
        for _ in 0..<100 { await Task.yield() }
        #expect(client.requests.map(\.0) == ["config.set", "config.get"])
        #expect(client.requests.first?.1["profile"] as? String == "effort-profile")
        #expect(model.sessionReasoningVariant == .medium)
    }

    @Test func draftChoiceDoesNotChangeGlobalDefault() {
        let model = DockModel(rpcClient: EffortFixtureRPC())
        model.defaultReasoningVariant = .medium
        model.updateDefaultReasoning(.high)
        #expect(model.defaultReasoningVariant == .medium)
    }

    @Test func sessionInfoOnlyReconcilesOwningSession() {
        let model = DockModel(initialSessionID: "owner", rpcClient: EffortFixtureRPC())
        model.sessionReasoningVariant = .low
        model.handleEvent(
            "session.info",
            params: [
                "session_id": "other", "payload": ["reasoning_effort": "high"],
            ])
        #expect(model.sessionReasoningVariant == .low)
        model.handleEvent(
            "session.info",
            params: [
                "session_id": "owner", "payload": ["reasoning_effort": "high"],
            ])
        #expect(model.sessionReasoningVariant == .high)
    }

    @Test func failedReadbackRefreshDoesNotRewrite() async {
        let client = EffortFixtureRPC()
        client.failRead = true
        let model = DockModel(initialSessionID: "owner", rpcClient: client)
        model.sessionReasoningVariant = .low
        model.updateSessionReasoning(.high)
        for _ in 0..<100 { await Task.yield() }
        #expect(model.sessionReasoningStale)
        #expect(model.sessionReasoningVariant == .low)
        client.failRead = false
        model.refreshSessionReasoningVariant()
        for _ in 0..<100 { await Task.yield() }
        #expect(!model.sessionReasoningStale)
        #expect(model.sessionReasoningVariant == .medium)
        #expect(client.requests.map(\.0) == ["config.set", "config.get", "config.get"])
    }

    @Test func slashReasoningRefreshesSelection() async throws {
        let client = EffortFixtureRPC()
        let model = DockModel(initialSessionID: "owner", rpcClient: client)
        try await model.execSlashCommand(ComposerSlashCommand("/reasoning high")!, sessionID: "owner", generation: 0)
        for _ in 0..<100 { await Task.yield() }
        #expect(client.requests.map(\.0).contains("config.get"))
        #expect(model.sessionReasoningVariant == .medium)
    }
}
