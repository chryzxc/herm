import Foundation

/// The small transport surface used by control-center services. Keeping this
/// separate from the concrete gateway makes capability and projection logic
/// testable without launching a Hermes process.
@MainActor
protocol HermesRPCClientProtocol: AnyObject {
    var onEvent: ((String, [String: Any]) -> Void)? { get set }
    func connect() async throws
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any]
    func close()
}

extension HermesGateway: HermesRPCClientProtocol {}

@MainActor
final class HermesEventRouter {
    typealias Handler = @MainActor (String, [String: Any]) -> Void

    private struct Subscription {
        let sessionID: String?
        let handler: Handler
    }

    private var handlers: [UUID: Subscription] = [:]

    @discardableResult
    func subscribe(sessionID: String? = nil, _ handler: @escaping Handler) -> UUID {
        let id = UUID()
        handlers[id] = Subscription(sessionID: sessionID, handler: handler)
        return id
    }

    func unsubscribe(_ id: UUID) {
        handlers.removeValue(forKey: id)
    }

    func route(type: String, params: [String: Any]) {
        let payload = params["payload"] as? [String: Any] ?? [:]
        let eventSessionID = (params["session_id"] as? String) ?? (payload["session_id"] as? String)
        for subscription in handlers.values {
            guard subscription.sessionID == nil || subscription.sessionID == eventSessionID else { continue }
            subscription.handler(type, params)
        }
    }
}

/// Named wrappers for the control-center RPC surface. The raw request method
/// remains available on the protocol for forward-compatible Hermes methods.
@MainActor
final class HermesControlRPC {
    private let client: HermesRPCClientProtocol

    init(client: HermesRPCClientProtocol) {
        self.client = client
    }

    func activeSessions() async throws -> [String: Any] { try await client.request("session.active_list", params: [:]) }
    func sessions(limit: Int = 50) async throws -> [String: Any] { try await client.request("session.list", params: ["limit": limit]) }
    func activate(sessionID: String) async throws -> [String: Any] { try await client.request("session.activate", params: ["session_id": sessionID]) }
    func resume(sessionID: String) async throws -> [String: Any] { try await client.request("session.resume", params: ["session_id": sessionID, "source": "hermes-agent-dock-control"]) }
    func interrupt(sessionID: String) async throws -> [String: Any] { try await client.request("session.interrupt", params: ["session_id": sessionID]) }
    func respondToApproval(sessionID: String, choice: String) async throws -> [String: Any] { try await client.request("approval.respond", params: ["session_id": sessionID, "choice": choice]) }
    func respondToClarification(sessionID: String, response: String) async throws -> [String: Any] { try await client.request("clarify.respond", params: ["session_id": sessionID, "response": response]) }
    func delegationStatus() async throws -> [String: Any] { try await client.request("delegation.status", params: [:]) }
    func cron(action: String, jobID: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["action": action]
        if let jobID { params["name"] = jobID }
        return try await client.request("cron.manage", params: params)
    }
    func processes() async throws -> [String: Any] { try await client.request("process.list", params: [:]) }
    func tools() async throws -> [String: Any] { try await client.request("tools.list", params: [:]) }
    func plugins() async throws -> [String: Any] { try await client.request("plugins.list", params: [:]) }
    func configuration() async throws -> [String: Any] { try await client.request("config.show", params: [:]) }
    func projectsTree() async throws -> [String: Any] { try await client.request("projects.tree", params: [:]) }
    func projectSessions(projectID: String) async throws -> [String: Any] {
        try await client.request("projects.project_sessions", params: ["project_id": projectID])
    }
    func shell(_ command: String) async throws -> [String: Any] { try await client.request("shell.exec", params: ["command": command]) }
    func raw(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] { try await client.request(method, params: params) }
}
