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
    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any]
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

    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        throw NSError(
            domain: "HermesControl",
            code: 501,
            userInfo: [NSLocalizedDescriptionKey: "This Hermes transport does not support HTTP writes."]
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
    func sessions(limit: Int = 50, profileID: String? = nil) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.sessionList.rawValue, params: Self.profileParams(["limit": limit], profileID: profileID))
    }
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
    func sessionMessages(sessionID: String, profileID: String? = nil, latest: Bool = false) async throws -> [String: Any] {
        let disallowed = CharacterSet(charactersIn: "/")
        let allowed = CharacterSet.urlPathAllowed.subtracting(disallowed)
        guard let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw NSError(domain: "HermesControl", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid session ID."])
        }
        let profile = profileID?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).map { "&profile=\($0)" } ?? ""
        let result = try await client.fetchHTTP("/api/sessions/\(encoded)/messages?limit=500\(latest ? "&order=latest" : "")\(profile)")
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
    /// Sessions whose ID or message text matches `query` (Hermes FTS).
    func searchSessions(query: String, limit: Int = 20) async throws -> [[String: Any]] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }
        return try await client.fetchHTTP("/api/sessions/search?q=\(encoded)&limit=\(limit)")["results"] as? [[String: Any]] ?? []
    }
    func activate(sessionID: String) async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.sessionActivate.rawValue, params: ["session_id": sessionID]) }
    func resume(sessionID: String, profileID: String? = nil) async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.sessionResume.rawValue, params: Self.profileParams(["session_id": sessionID, "source": "herm-control"], profileID: profileID)) }
    func delete(sessionID: String, profileID: String? = nil) async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.sessionDelete.rawValue, params: Self.profileParams(["session_id": sessionID], profileID: profileID)) }
    func interrupt(sessionID: String, profileID: String? = nil) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.sessionInterrupt.rawValue,
            params: Self.profileParams(["session_id": sessionID], profileID: profileID)
        )
    }
    /// Hermes clamps `days` to 1…365 server-side.
    func usageAnalytics(days: Int) async throws -> [String: Any] { try await client.fetchHTTP("/api/analytics/usage?days=\(days)") }

    func modelAnalytics(days: Int) async throws -> [String: Any] { try await client.fetchHTTP("/api/analytics/models?days=\(days)") }
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
    func respondToClarification(requestID: String, answer: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.clarifyRespond.rawValue, params: ["id": requestID, "result": ["answer": answer]])
    }
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
    func projectsTree(profileID: String? = nil) async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.projectsTree.rawValue, params: Self.profileParams([:], profileID: profileID)) }
    func projectSessions(projectID: String, profileID: String? = nil) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.projectsProjectSessions.rawValue, params: Self.profileParams(["project_id": projectID], profileID: profileID))
    }
    func createProject(name: String, folders: [String], description: String? = nil, profileID: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["name": name, "folders": folders]
        if let description, !description.isEmpty { params["description"] = description }
        return try await client.request(HermesFeatureIDs.ID.projectsCreate.rawValue, params: Self.profileParams(params, profileID: profileID))
    }
    func archiveProject(id: String, restore: Bool = false, profileID: String? = nil) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.projectsArchive.rawValue, params: Self.profileParams(["id": id, "restore": restore], profileID: profileID))
    }
    func deleteProject(id: String, profileID: String? = nil) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.projectsDelete.rawValue, params: Self.profileParams(["id": id], profileID: profileID))
    }
    func setActiveProject(id: String?, profileID: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = [:]
        if let id, !id.isEmpty { params["id"] = id }
        return try await client.request(HermesFeatureIDs.ID.projectsSetActive.rawValue, params: Self.profileParams(params, profileID: profileID))
    }
    func addProjectFolder(id: String, path: String, profileID: String? = nil) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.projectsAddFolder.rawValue, params: Self.profileParams(["id": id, "path": path], profileID: profileID))
    }
    func setSessionHidden(sessionID: String, hidden: Bool, profileID: String? = nil) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.sessionSetHidden.rawValue, params: Self.profileParams(["session_id": sessionID, "hidden": hidden], profileID: profileID))
    }

    private static func profileParams(_ params: [String: Any], profileID: String?) -> [String: Any] {
        guard let profileID, !profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return params }
        var scoped = params
        scoped["profile"] = profileID
        return scoped
    }
    func insights(days: Int = 30) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.insightsGet.rawValue, params: ["days": max(1, min(days, 90))])
    }
    func rollbackList(sessionID: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.rollbackList.rawValue, params: ["session_id": sessionID])
    }
    func rollbackDiff(sessionID: String, hash: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.rollbackDiff.rawValue, params: ["session_id": sessionID, "hash": hash])
    }
    func rollbackRestore(sessionID: String, hash: String, filePath: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["session_id": sessionID, "hash": hash]
        if let filePath, !filePath.isEmpty { params["file_path"] = filePath }
        return try await client.request(HermesFeatureIDs.ID.rollbackRestore.rawValue, params: params)
    }
    /// Checkpoint-specific names keep restore flows explicit while preserving
    /// the verified Hermes rollback.* wire contract.
    func listRestoreCheckpoints(sessionID: String) async throws -> [String: Any] {
        try await rollbackList(sessionID: sessionID)
    }
    func restoreCheckpoint(sessionID: String, hash: String) async throws -> [String: Any] {
        try await rollbackRestore(sessionID: sessionID, hash: hash)
    }
    /// Authenticated, read-only gateway HTTP request used for structured Hermes projections.
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        try await client.fetchHTTP(path)
    }

    /// Authenticated gateway HTTP write. Only for verified plugin REST routes
    /// (for example the Kanban task PATCH the Hermes desktop board uses).
    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        try await client.sendHTTP(method, path: path, body: body)
    }

    /// Structured-command entry point; never accept an arbitrary shell string.
    func runCommand(_ command: HermesCLICommand) async throws -> [String: Any] {
        let rendered = try command.rendered()
        return Self.normalizedShellResult(
            try await client.request(HermesFeatureIDs.ID.shellExec.rawValue, params: ["command": rendered])
        )
    }

    /// Hermes gateways in the field return either the original `stdout` /
    /// `code` form or the terminal relay form used in activity events:
    /// `output` / `exit_code` / `error`. Normalize only this typed shell
    /// boundary so read-only projections consume one honest result contract.
    static func normalizedShellResult(_ raw: [String: Any]) -> [String: Any] {
        var normalized = raw
        if raw["error"] is NSNull {
            normalized.removeValue(forKey: "error")
        }
        if normalized["stdout"] == nil, let output = raw["output"] as? String {
            normalized["stdout"] = output
        }
        if normalized["stderr"] == nil,
           let error = raw["error"] as? String,
           !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized["stderr"] = error
        }
        if normalized["code"] == nil,
           let exitCode = (raw["exit_code"] as? NSNumber)?.intValue ?? raw["exit_code"] as? Int {
            normalized["code"] = exitCode
        }
        if normalized["success"] == nil {
            if let code = (normalized["code"] as? NSNumber)?.intValue ?? normalized["code"] as? Int {
                normalized["success"] = code == 0
            } else if normalized["stdout"] != nil {
                normalized["success"] = true
            }
        }
        return normalized
    }
}
