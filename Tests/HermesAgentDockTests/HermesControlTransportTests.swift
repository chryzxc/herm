import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
private final class RecordingRPCClient: HermesRPCClientProtocol {
    struct Call {
        let method: String
        let params: [String: Any]
    }

    var onEvent: ((String, [String: Any]) -> Void)?
    var calls: [Call] = []

    func connect() async throws {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append(Call(method: method, params: params))
        return [:]
    }

    func close() {}
}

private actor ConnectionAttemptCounter {
    private var value = 0

    func increment() { value += 1 }
    func currentValue() -> Int { value }
}

@MainActor
struct HermesControlTransportTests {
    @Test func concurrentConnectionRequestsShareOneAttempt() async throws {
        let gate = HermesConnectionGate()
        let counter = ConnectionAttemptCounter()

        async let first: Void = gate.perform {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(20))
        }
        async let second: Void = gate.perform {
            await counter.increment()
        }

        _ = try await (first, second)
        let attemptCount = await counter.currentValue()

        #expect(attemptCount == 1)
    }

    @Test func routesEventsToSubscribers() {
        let router = HermesEventRouter()
        var received: [(String, String)] = []
        _ = router.subscribe { type, params in
            received.append((type, params["session_id"] as? String ?? ""))
        }

        router.route(type: "approval.request", params: ["session_id": "session-7"])

        #expect(received.count == 1)
        #expect(received.first?.0 == "approval.request")
        #expect(received.first?.1 == "session-7")
    }

    @Test func unsubscribedHandlersStopReceivingEvents() {
        let router = HermesEventRouter()
        var callCount = 0
        let subscription = router.subscribe { _, _ in callCount += 1 }

        router.unsubscribe(subscription)
        router.route(type: "message.complete", params: [:])

        #expect(callCount == 0)
    }

    @Test func sessionScopedSubscriptionIgnoresOtherSessions() {
        let router = HermesEventRouter()
        var received = 0
        _ = router.subscribe(sessionID: "session-1") { _, _ in received += 1 }

        router.route(type: "message.delta", params: ["session_id": "session-2"])
        router.route(type: "message.delta", params: ["session_id": "session-1"])

        #expect(received == 1)
    }

    @Test func webSocketRequestAuthenticatesViaQueryToken() {
        let request = HermesGateway.webSocketRequest(port: 54321, token: "secret-session-token")

        #expect(request.url?.absoluteString == "ws://127.0.0.1:54321/api/ws?token=secret-session-token")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func namedProjectRPCsUseHermesMethodNames() async throws {
        let client = RecordingRPCClient()
        let rpc = HermesControlRPC(client: client)

        _ = try await rpc.projectsTree()
        _ = try await rpc.projectSessions(projectID: "project-1")

        #expect(client.calls.map(\.method) == ["projects.tree", "projects.project_sessions"])
        #expect(client.calls.last?.params["project_id"] as? String == "project-1")
    }

    @Test func reloadMCPRequiresExplicitConfirmationParameter() async throws {
        let client = RecordingRPCClient()
        let rpc = HermesControlRPC(client: client)

        _ = try await rpc.reloadMCP(sessionID: "session-1")

        #expect(client.calls.last?.method == "reload.mcp")
        #expect(client.calls.last?.params["confirm"] as? Bool == true)
    }

    @Test func sessionScopedCockpitAndProcessRPCsForwardSessionIDs() async throws {
        let client = RecordingRPCClient()
        let rpc = HermesControlRPC(client: client)

        _ = try await rpc.sessionUsage(sessionID: "session-1")
        _ = try await rpc.sessionContextBreakdown(sessionID: "session-1")
        _ = try await rpc.processes(sessionID: "session-1")

        #expect(client.calls.map(\.method) == ["session.usage", "session.context_breakdown", "process.list"])
        #expect(client.calls.allSatisfy { $0.params["session_id"] as? String == "session-1" })
    }

    @Test func steeringRPCForwardsSessionAndText() async throws {
        let client = RecordingRPCClient()
        let rpc = HermesControlRPC(client: client)

        _ = try await rpc.steer(sessionID: "session-1", text: "focus on the auth module")

        #expect(client.calls.last?.method == "session.steer")
        #expect(client.calls.last?.params["session_id"] as? String == "session-1")
        #expect(client.calls.last?.params["text"] as? String == "focus on the auth module")
    }

    @Test func workflowRPCsUseHermesContracts() async throws {
        let client = RecordingRPCClient()
        let rpc = HermesControlRPC(client: client)
        _ = try await rpc.projectFacts(cwd: "/work/app")
        _ = try await rpc.verificationStatus(sessionID: "s1", cwd: "/work/app")
        _ = try await rpc.startBackgroundPrompt(sessionID: "s1", text: "Run tests")
        _ = try await rpc.undo(sessionID: "s1")
        _ = try await rpc.redirect(sessionID: "s1", text: "Focus")
        _ = try await rpc.pauseDelegation(true)
        _ = try await rpc.interruptSubagent(subagentID: "a1")

        #expect(client.calls.map(\.method) == ["project.facts", "verification.status", "prompt.background", "session.undo", "session.redirect", "delegation.pause", "subagent.interrupt"])
        #expect(client.calls.last?.params["subagent_id"] as? String == "a1")
    }
}
