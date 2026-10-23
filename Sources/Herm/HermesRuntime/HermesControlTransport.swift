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
    func fetchHTTP(_ path: String, timeout: TimeInterval) async throws -> [String: Any]
    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any]
    func sendHTTP(_ method: String, path: String, body: [String: Any], timeout: TimeInterval) async throws -> [String: Any]
    func close()
}

extension HermesRPCClientProtocol {
    func fetchHTTP(_ path: String, timeout: TimeInterval) async throws -> [String: Any] {
        try await fetchHTTP(path)
    }
    func sendHTTP(_ method: String, path: String, body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        try await sendHTTP(method, path: path, body: body)
    }
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
    func workflow(profileID: String?) -> HermesWorkflowRPC { HermesWorkflowRPC(client: client, profileID: profileID) }
    private let client: HermesRPCClientProtocol

    init(client: HermesRPCClientProtocol) {
        self.client = client
    }

    func activeSessions() async throws -> [String: Any] { try await client.request(HermesFeatureIDs.ID.sessionActiveList.rawValue, params: [:]) }
    func sessions(limit: Int = 50, profileID: String? = nil) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.sessionList.rawValue, params: Self.profileParams(["limit": limit], profileID: profileID))
    }
    func sessionPages(limit: Int = 100, offset: Int = 0, order: String? = nil) async throws -> [String: Any] {
        let result = try await client.fetchHTTP("/api/sessions?limit=\(limit)&offset=\(offset)" + (order.map { "&order=\($0)" } ?? ""))
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
    func sessionMessages(sessionID: String, profileID: String? = nil, latest: Bool = false, limit: Int = 500, offset: Int = 0, includeCompacted: Bool = false) async throws -> [String: Any] {
        let disallowed = CharacterSet(charactersIn: "/")
        let allowed = CharacterSet.urlPathAllowed.subtracting(disallowed)
        guard let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw NSError(domain: "HermesControl", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid session ID."])
        }
        let profile = profileID?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).map { "&profile=\($0)" } ?? ""
        var path = "/api/sessions/\(encoded)/messages?limit=\(limit)\(latest ? "&order=latest" : "")\(profile)"
        if offset > 0 || includeCompacted { path += "&offset=\(offset)" }
        if includeCompacted {
            if !latest { path += "&order=oldest" }
            path += "&include_compacted=true"
        }
        let result = try await client.fetchHTTP(path)
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
    /// Artifacts use the archive, independently of the sidebar's recent-session window.
    func artifactSessions() async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await client.fetchHTTP("/api/profiles/sessions?limit=100&offset=\(offset)&min_messages=1&archived=exclude&order=recent&profile=all")
            guard let sessions = page["sessions"] as? [[String: Any]],
                  let total = page["total"] as? Int,
                  (page["errors"] as? [[String: Any]] ?? []).isEmpty,
                  (page["storage"] as? [String: String] ?? [:]).isEmpty else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            rows.append(contentsOf: sessions)
            offset += min(100, sessions.count) // Hermes may back-fill pinned rows beyond the page window.
            if offset >= total { return rows }
            guard !sessions.isEmpty else { throw HermesGateway.GatewayError.malformedResponse }
        }
    }

    /// Sessions whose ID or message text matches `query` (Hermes FTS).
    func searchSessions(query: String, limit: Int = 20, profileID: String? = nil) async throws -> [[String: Any]] {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(max(1, min(limit, 20))))]
        if let profileID { components.queryItems?.append(URLQueryItem(name: "profile", value: profileID)) }
        guard let encoded = components.percentEncodedQuery else { return [] }
        let result = try await client.fetchHTTP("/api/sessions/search?\(encoded)")
        guard let rows = result["results"] as? [[String: Any]] else { throw HermesGateway.GatewayError.malformedResponse }
        return rows
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
    func usageAnalytics(days: Int) async throws -> [String: Any] { try await client.fetchHTTP("/api/analytics/usage?days=\(days)", timeout: 60) }

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
    /// A user's mention is a user turn in the recipient's canonical Bot Chat.
    func submitBotMessage(profileID: String, message: String, chatSessionID: String?,
                          beforeSubmit: (String) throws -> Void) async throws -> String {
        let requested = chatSessionID ?? BotService.canonicalBotChatTitle
        let result = try await client.request(HermesFeatureIDs.ID.sessionResume.rawValue,
            params: ["session_id": requested, "profile": profileID, "source": "herm", "omit_messages": true])
        let info = result["info"] as? [String: Any] ?? [:]
        let profile = result["profile"] as? String ?? info["profile_name"] as? String ?? info["profile"] as? String
        guard let runtime = result["session_id"] as? String, !runtime.isEmpty,
              profile == profileID,
              DockModel.resumeResponseProvesSessionOwnership(requestedSessionID: requested, resolvedSessionID: runtime, result: result) else {
            throw QuickDraftError.message("Hermes did not confirm the mentioned Bot’s conversation. The message was not sent.")
        }
        guard result["running"] as? Bool != true, info["running"] as? Bool != true else {
            throw QuickDraftError.message("The mentioned Bot is busy. Wait for its current turn before sending again.")
        }
        try beforeSubmit(runtime)
        let submitted: [String: Any]
        do {
            submitted = try await client.request(HermesFeatureIDs.ID.promptSubmit.rawValue,
                params: ["session_id": runtime, "profile": profileID, "text": message])
        } catch {
            throw QuickDraftError.message("The Bot’s submission was not confirmed. Check its Bot Chat before resending. "
                + HermesDiagnosticsService.safeSummary(error.localizedDescription))
        }
        guard submitted["status"] as? String == "streaming" else {
            throw QuickDraftError.message("Hermes did not confirm the Bot’s turn. Check its Bot Chat before resending.")
        }
        return runtime
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
    func cron(action: String, jobID: String? = nil, profileID: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["action": action, "include_disabled": true]
        if let jobID { params["name"] = jobID }
        let result = try await client.request(HermesFeatureIDs.ID.cronManage.rawValue, params: Self.profileParams(params, profileID: profileID))
        if action == "list" {
            guard result["success"] as? Bool != false, result["jobs"] is [[String: Any]] else {
                throw QuickDraftError.message(result["error"] as? String ?? "Hermes did not return an automation inventory.")
            }
            if let profileID, result["scoped"] as? String != profileID { throw HermesGateway.GatewayError.malformedResponse }
        }
        return result
    }
    func createCron(name: String, schedule: String, prompt: String, profileID: String? = nil) async throws -> [String: Any] {
        let result = try await client.request(HermesFeatureIDs.ID.cronManage.rawValue, params: Self.profileParams([
            "action": "add", "name": name, "schedule": schedule, "prompt": prompt
        ], profileID: profileID))
        try Self.validateCronAcknowledgment(result)
        guard result["job_id"] as? String != nil else { throw HermesGateway.GatewayError.malformedResponse }
        return result
    }
    func removeCron(jobID: String, profileID: String? = nil) async throws -> [String: Any] {
        let result = try await cron(action: "remove", jobID: jobID, profileID: profileID)
        try Self.validateCronAcknowledgment(result)
        guard (result["removed_job"] as? [String: Any])?["id"] as? String == jobID else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        return result
    }

    private static func validateCronAcknowledgment(_ result: [String: Any]) throws {
        guard result["success"] as? Bool == true else {
            throw QuickDraftError.message(result["error"] as? String ?? "Hermes did not confirm the automation change.")
        }
    }

    static func cronPath(jobID: String? = nil, suffix: String = "", profileID: String?) throws -> String {
        var path = "/api/cron/jobs"
        if let jobID {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            guard !jobID.isEmpty, jobID != ".", jobID != "..", let encoded = jobID.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            path += "/" + encoded
        }
        var components = URLComponents()
        components.queryItems = profileID.map { [URLQueryItem(name: "profile", value: $0)] }
        let query = components.percentEncodedQuery.map { "?" + $0.replacingOccurrences(of: "+", with: "%2B") } ?? ""
        return path + suffix + query
    }

    func cronJob(_ job: CronSummary, profileID: String?) async throws -> CronSummary {
        let row = try await client.fetchHTTP(Self.cronPath(jobID: job.id, profileID: profileID))
        return try Self.parseCronJobDetail(row, expectedID: job.id, profileID: profileID)
    }

    private static func parseCronJobDetail(_ row: [String: Any], expectedID: String, profileID: String?) throws -> CronSummary {
        guard var job = ControlCenterModel.parseCronJobs(["jobs": [row]]).first, job.id == expectedID,
              row["id"] as? String == expectedID, row["prompt"] is String, row["schedule"] != nil else { throw HermesGateway.GatewayError.malformedResponse }
        if let reportedProfile = row["profile"] as? String, let profileID, reportedProfile != profileID {
            throw HermesGateway.GatewayError.malformedResponse
        }
        job.owner = CronOwner(profileID: profileID)
        return job
    }

    func cronJobRuns(jobID: String, profileID: String?) async throws -> [CronRunSummary] {
        let path = try Self.cronPath(jobID: jobID, suffix: "/runs", profileID: profileID) + (profileID == nil ? "?" : "&") + "limit=50"
        return try ControlCenterModel.parseStructuredCronRuns(try await client.fetchHTTP(path), jobID: jobID)
    }

    func updateCron(_ job: CronSummary, draft: CronEditDraft, profileID: String?) async throws {
        let changes = draft.changes(comparedTo: job)
        var updates: [String: Any] = [:]
        for (field, value) in changes {
            if value.isEmpty && [.model, .provider, .workdir].contains(field) {
                updates[field.rawValue] = NSNull()
            } else { updates[field.rawValue] = value }
        }
        let result = try await client.sendHTTP("PUT", path: Self.cronPath(jobID: job.id, profileID: profileID), body: ["updates": updates])
        _ = try Self.parseCronJobDetail(result, expectedID: job.id, profileID: profileID)
    }

    func createCron(name: String, schedule: String, prompt: String, configuration: CronConfigurationDraft, profileID: String?) async throws -> CronSummary {
        var body = configuration.parameters
        body["name"] = name; body["schedule"] = schedule; body["prompt"] = prompt
        let result = try await client.sendHTTP("POST", path: Self.cronPath(profileID: profileID), body: body)
        guard let id = result["id"] as? String else { throw HermesGateway.GatewayError.malformedResponse }
        return try Self.parseCronJobDetail(result, expectedID: id, profileID: profileID)
    }

    func triggerCron(jobID: String, profileID: String?) async throws {
        let result = try await client.sendHTTP("POST", path: Self.cronPath(jobID: jobID, suffix: "/trigger", profileID: profileID), body: [:], timeout: 24 * 60 * 60)
        _ = try Self.parseCronJobDetail(result, expectedID: jobID, profileID: profileID)
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
