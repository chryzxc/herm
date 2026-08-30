import Foundation

/// The small transport surface used by control-center services. Keeping this
/// separate from the concrete gateway makes capability and projection logic
/// testable without launching a Hermes process. Gateway administration is
/// intentionally not represented here: Hermes 0.20.6 exposes human-oriented
/// gateway/pairing/webhook commands, not a verified typed RPC contract, so Dock
/// must not invent request methods for those mutations.
@MainActor
protocol HermesRPCClientProtocol: AnyObject {
    var onEvent: ((String, [String: Any]) -> Void)? { get set }
    func connect() async throws
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any]
    func fetchHTTP(_ path: String) async throws -> [String: Any]
    func close()
}

extension HermesRPCClientProtocol {
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        throw NSError(
            domain: "HermesControl",
            code: 501,
            userInfo: [NSLocalizedDescriptionKey: "This Hermes transport does not support read-only HTTP requests."]
        )
    }
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

    func activeSessions() async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.sessionActiveList.rawValue, params: [:]) }
    func sessions(limit: Int = 50) async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.sessionList.rawValue, params: ["limit": limit]) }
    func sessionPages(limit: Int = 100, offset: Int = 0) async throws -> [String: Any] {
        let result = try await client.fetchHTTP("/api/sessions?limit=\(limit)&offset=\(offset)")
        // Hermes Agent's REST endpoint uses `sessions`/`total`; the Dock's
        // activity projection predates that endpoint and uses `data`/`has_more`.
        // Adapt at the transport boundary so both forms remain supported.
        guard result["data"] == nil else { return result }
        guard let sessions = result["sessions"] as? [[String: Any]],
              let total = result["total"] as? Int,
              total >= offset + sessions.count else {
            return result
        }
        var canonical = result
        canonical["data"] = sessions
        canonical["has_more"] = offset + sessions.count < total
        return canonical
    }
    func sessionMessages(sessionID: String) async throws -> [String: Any] {
        let disallowed = CharacterSet(charactersIn: "/")
        let allowed = CharacterSet.urlPathAllowed.subtracting(disallowed)
        guard let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw NSError(domain: "HermesControl", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid session ID."])
        }
        let result = try await client.fetchHTTP("/api/sessions/\(encoded)/messages?limit=500")
        // The REST endpoint returns `messages`; normalize it to the envelope
        // consumed by the activity projection without relaxing its validation.
        guard result["data"] == nil, let messages = result["messages"] as? [[String: Any]] else {
            return result
        }
        var canonical = result
        canonical.removeValue(forKey: "messages")
        canonical["data"] = messages
        return canonical
    }
    func activate(sessionID: String) async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.sessionActivate.rawValue, params: ["session_id": sessionID]) }
    func resume(sessionID: String) async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.sessionResume.rawValue, params: ["session_id": sessionID, "source": "hermes-agent-dock-control"]) }
    func delete(sessionID: String) async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.sessionDelete.rawValue, params: ["session_id": sessionID]) }
    func interrupt(sessionID: String) async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.sessionInterrupt.rawValue, params: ["session_id": sessionID]) }
    func sessionUsage(sessionID: String) async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.sessionUsage.rawValue, params: ["session_id": sessionID]) }
    func sessionContextBreakdown(sessionID: String) async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.sessionContextBreakdown.rawValue, params: ["session_id": sessionID]) }
    func projectFacts(cwd: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.projectFacts.rawValue, params: ["cwd": cwd])
    }
    func verificationStatus(sessionID: String?, cwd: String) async throws -> [String: Any] {
        var params: [String: Any] = ["cwd": cwd]
        if let sessionID, !sessionID.isEmpty { params["session_id"] = sessionID }
        return try await client.request(HermesFeatureIDs.ID.verificationStatus.rawValue, params: params)
    }
    func startBackgroundPrompt(sessionID: String, text: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.promptBackground.rawValue, params: ["session_id": sessionID, "text": text])
    }
    func sessionTitle(sessionID: String) async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.sessionTitle.rawValue, params: ["session_id": sessionID]) }
    func setSessionTitle(sessionID: String, title: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.sessionTitle.rawValue, params: ["session_id": sessionID, "title": title])
    }
    func steer(sessionID: String, text: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.sessionSteer.rawValue, params: ["session_id": sessionID, "text": text])
    }
    func branch(sessionID: String, name: String? = nil, count: Int? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["session_id": sessionID]
        if let name, !name.isEmpty { params["name"] = name }
        if let count, count > 0 { params["count"] = count }
        return try await client.request(HermesFeatureIDs.ID.sessionBranch.rawValue, params: params)
    }
    func compress(sessionID: String, focusTopic: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["session_id": sessionID]
        if let focusTopic, !focusTopic.isEmpty { params["focus_topic"] = focusTopic }
        return try await client.request(HermesFeatureIDs.ID.sessionCompress.rawValue, params: params)
    }
    func undo(sessionID: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.sessionUndo.rawValue, params: ["session_id": sessionID])
    }
    func redirect(sessionID: String, text: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.sessionRedirect.rawValue, params: ["session_id": sessionID, "text": text])
    }
    func pauseDelegation(_ paused: Bool) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.delegationPause.rawValue, params: ["paused": paused])
    }
    func interruptSubagent(subagentID: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.subagentInterrupt.rawValue, params: ["subagent_id": subagentID])
    }
    func killProcess(sessionID: String, processID: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.processKill.rawValue, params: ["session_id": sessionID, "process_id": processID])
    }
    func respondToApproval(sessionID: String, choice: String) async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.approvalRespond.rawValue, params: ["session_id": sessionID, "choice": choice]) }
    func respondToClarification(sessionID: String, response: String) async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.clarifyRespond.rawValue, params: ["session_id": sessionID, "response": response]) }
    func delegationStatus() async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.delegationStatus.rawValue, params: [:]) }
    func cron(action: String, jobID: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["action": action]
        if let jobID { params["name"] = jobID }
        return try await client.request(HermesFeatureIDs.ID.cronManage.rawValue, params: params)
    }
    func createCron(name: String, schedule: String, prompt: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.cronManage.rawValue, params: [
            "action": "add", "name": name, "schedule": schedule, "prompt": prompt
        ])
    }
    func removeCron(jobID: String) async throws -> [String: Any] {
        try await cron(action: "remove", jobID: jobID)
    }
    func reloadMCP(sessionID: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.reloadMCP.rawValue, params: ["session_id": sessionID, "confirm": true])
    }
    func processes(sessionID: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.processList.rawValue, params: ["session_id": sessionID])
    }
    func tools() async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.toolsList.rawValue, params: [:]) }
    func plugins() async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.pluginsList.rawValue, params: [:]) }
    func configuration() async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.configShow.rawValue, params: [:]) }
    func projectsTree() async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.projectsTree.rawValue, params: [:]) }
    func projectSessions(projectID: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.projectsProjectSessions.rawValue, params: ["project_id": projectID])
    }
    /// Structured-command entry point; never accept an arbitrary shell string.
    func runCommand(_ command: HermesCLICommand) async throws -> [String: Any] {
        let rendered = try command.rendered()
        return try await client.request(HermesFeatureIDs.ID.shellExec.rawValue, params: ["command": rendered])
    }
}
