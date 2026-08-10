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

@MainActor
struct HermesControlTransportTests {
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
}
