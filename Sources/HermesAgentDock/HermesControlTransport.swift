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
    func sessionUsage(sessionID: String) async throws -> [String: Any] { try await client.request("session.usage", params: ["session_id": sessionID]) }
    func sessionContextBreakdown(sessionID: String) async throws -> [String: Any] { try await client.request("session.context_breakdown", params: ["session_id": sessionID]) }
    func sessionTitle(sessionID: String) async throws -> [String: Any] { try await client.request("session.title", params: ["session_id": sessionID]) }
    func setSessionTitle(sessionID: String, title: String) async throws -> [String: Any] {
        try await client.request("session.title", params: ["session_id": sessionID, "title": title])
    }
    func steer(sessionID: String, text: String) async throws -> [String: Any] {
        try await client.request("session.steer", params: ["session_id": sessionID, "text": text])
    }
    func branch(sessionID: String, name: String? = nil, count: Int? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["session_id": sessionID]
        if let name, !name.isEmpty { params["name"] = name }
        if let count, count > 0 { params["count"] = count }
        return try await client.request("session.branch", params: params)
    }
    func compress(sessionID: String, focusTopic: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["session_id": sessionID]
        if let focusTopic, !focusTopic.isEmpty { params["focus_topic"] = focusTopic }
        return try await client.request("session.compress", params: params)
    }
    func interruptSubagent(sessionID: String, childSessionID: String) async throws -> [String: Any] {
        try await client.request("subagent.interrupt", params: ["session_id": sessionID, "child_session_id": childSessionID])
    }
    func killProcess(sessionID: String, processID: String) async throws -> [String: Any] {
        try await client.request("process.kill", params: ["session_id": sessionID, "process_id": processID])
    }
    func respondToApproval(sessionID: String, choice: String) async throws -> [String: Any] { try await client.request("approval.respond", params: ["session_id": sessionID, "choice": choice]) }
    func respondToClarification(sessionID: String, response: String) async throws -> [String: Any] { try await client.request("clarify.respond", params: ["session_id": sessionID, "response": response]) }
    func delegationStatus() async throws -> [String: Any] { try await client.request("delegation.status", params: [:]) }
    func cron(action: String, jobID: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["action": action]
        if let jobID { params["name"] = jobID }
        return try await client.request("cron.manage", params: params)
    }
    func createCron(name: String, schedule: String, prompt: String) async throws -> [String: Any] {
        try await client.request("cron.manage", params: [
            "action": "add", "name": name, "schedule": schedule, "prompt": prompt
        ])
    }
    func setCron(jobID: String, enabled: Bool) async throws -> [String: Any] {
        try await cron(action: enabled ? "resume" : "pause", jobID: jobID)
    }
    func removeCron(jobID: String) async throws -> [String: Any] {
        try await cron(action: "remove", jobID: jobID)
    }
    func reloadMCP(sessionID: String) async throws -> [String: Any] {
        try await client.request("reload.mcp", params: ["session_id": sessionID, "confirm": true])
    }
    func processes(sessionID: String) async throws -> [String: Any] {
        try await client.request("process.list", params: ["session_id": sessionID])
    }
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
