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
    func request(_ method: String, params: [String: Any], sharedBrowserTabs: [ChatContext.SharedBrowserTab])
        async throws -> [String: Any]
    func fetchHTTP(_ path: String) async throws -> [String: Any]
    func fetchHTTP(_ path: String, timeout: TimeInterval) async throws -> [String: Any]
    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any]
    func sendHTTP(_ method: String, path: String, body: [String: Any], timeout: TimeInterval) async throws -> [String:
        Any]
    func close()
}

enum PromptAdmissionError: LocalizedError {
    case interrupted, sharedBrowserUnavailable

    var errorDescription: String? {
        switch self {
        case .interrupted: "The connection changed before your message was sent. Try again."
        case .sharedBrowserUnavailable: "Your message wasn’t sent. Reattach the shared browser tab and try again."
        }
    }
}

extension HermesRPCClientProtocol {
    func request(_ method: String, params: [String: Any], sharedBrowserTabs: [ChatContext.SharedBrowserTab])
        async throws -> [String: Any]
    {
        guard sharedBrowserTabs.isEmpty else { throw PromptAdmissionError.sharedBrowserUnavailable }
        return try await request(method, params: params)
    }

    func fetchHTTP(_ path: String, timeout: TimeInterval) async throws -> [String: Any] {
        try await fetchHTTP(path)
    }
    func sendHTTP(_ method: String, path: String, body: [String: Any], timeout: TimeInterval) async throws -> [String:
        Any]
    {
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

    struct Event {
        let type: String
        let params: [String: Any]
        let payload: [String: Any]
        let envelopeSessionID: String?
        let sessionID: String?

        init(type: String, params: [String: Any]) {
            self.type = type
            self.params = params
            payload = params["payload"] as? [String: Any] ?? [:]
            envelopeSessionID = params["session_id"] as? String
            sessionID = envelopeSessionID ?? (payload["session_id"] as? String)
        }
    }

    private struct Subscription {
        let handler: Handler
        let matchesWorker: ((Event) -> Bool)?
        var sessionIDs: Set<String>
    }

    private var global: [UUID: Handler] = [:]
    private var scoped: [UUID: Subscription] = [:]
    private var sessions: [String: Set<UUID>] = [:]
    private var workerObservers: Set<UUID> = []

    @discardableResult
    func subscribe(sessionID: String? = nil, _ handler: @escaping Handler) -> UUID {
        if let sessionID { return subscribeConversation(sessionIDs: [sessionID], handler: handler) }
        let id = UUID()
        global[id] = handler
        return id
    }

    func subscribeConversation(
        sessionIDs: Set<String>, matchesWorker: ((Event) -> Bool)? = nil, handler: @escaping Handler
    ) -> UUID {
        let id = UUID()
        scoped[id] = Subscription(handler: handler, matchesWorker: matchesWorker, sessionIDs: [])
        if matchesWorker != nil { workerObservers.insert(id) }
        updateSessionIDs(sessionIDs, for: id)
        return id
    }

    func updateSessionIDs(_ sessionIDs: Set<String>, for id: UUID) {
        guard let previous = scoped[id]?.sessionIDs, previous != sessionIDs else { return }
        for removed in previous.subtracting(sessionIDs) {
            sessions[removed]?.remove(id)
            if sessions[removed]?.isEmpty == true { sessions[removed] = nil }
        }
        for added in sessionIDs.subtracting(previous) { sessions[added, default: []].insert(id) }
        scoped[id]?.sessionIDs = sessionIDs
    }

    func unsubscribe(_ id: UUID) {
        global[id] = nil
        updateSessionIDs([], for: id)
        scoped[id] = nil
        workerObservers.remove(id)
    }

    func route(type: String, params: [String: Any]) {
        route(Event(type: type, params: params))
    }

    func route(_ event: Event) {
        var recipients = event.sessionID.flatMap { sessions[$0] } ?? []
        if event.type == "gateway.ready" || event.sessionID?.isEmpty != false {
            recipients.formUnion(workerObservers)
        } else if event.type.hasPrefix("subagent.") {
            for id in workerObservers where !recipients.contains(id) && scoped[id]?.matchesWorker?(event) == true {
                recipients.insert(id)
            }
        }
        let matching = recipients.compactMap { scoped[$0]?.handler }
        let broadcast = global.values
        for handler in broadcast { handler(event.type, event.params) }
        for handler in matching { handler(event.type, event.params) }
    }
}

/// Named wrappers for the control-center RPC surface. The raw request method
/// remains available on the protocol for forward-compatible Hermes methods.
@MainActor
final class HermesControlRPC {
    func vault(profileID: String?) -> HermesVaultService { HermesVaultService(client: client, profile: profileID) }
    func workflow(profileID: String?) -> HermesWorkflowRPC { HermesWorkflowRPC(client: client, profileID: profileID) }
    private let client: HermesRPCClientProtocol

    init(client: HermesRPCClientProtocol) {
        self.client = client
    }

    func setBrowser(cdpURL: String?, profile: String?, isCurrent: @MainActor () -> Bool = { true }) async throws {
        var scope: [String: Any] = [:]
        if let profile, !profile.isEmpty { scope["profile"] = profile }
        var statusParams = scope
        statusParams["action"] = "status"
        let method = HermesFeatureIDs.ID.browserManage.rawValue
        if let cdpURL {
            let status = try await client.request(method, params: statusParams)
            guard isCurrent() else { throw CancellationError() }
            if status["connected"] as? Bool == true, status["url"] as? String == cdpURL { return }
        }
        var params = scope
        params["action"] = cdpURL == nil ? "disconnect" : "connect"
        if let cdpURL { params["url"] = cdpURL }
        let result = try await client.request(method, params: params)
        guard let cdpURL else { return }
        guard isCurrent() else { throw CancellationError() }
        if result["connected"] as? Bool == true {
            if let url = result["url"] {
                if url as? String == cdpURL { return }
            } else {
                let status = try await client.request(method, params: statusParams)
                guard isCurrent() else { throw CancellationError() }
                if status["connected"] as? Bool == true, status["url"] as? String == cdpURL { return }
            }
        }
        let detail =
            (result["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "Hermes could not connect to the browser."
        throw NSError(domain: "Herm.AgentBrowser", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }

    func sessionControl(sessionID: String, profileID: String?) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.sessionControlRead.rawValue,
            params: Self.profileParams(["session_id": sessionID], profileID: profileID))
    }

    func completedPromptRoute(sessionID: String, admissionID: String, profileID: String?) async throws
        -> HermesModelOption?
    {
        let receipt = try await client.request(
            HermesFeatureIDs.ID.promptReceipt.rawValue,
            params: Self.profileParams(
                ["session_id": sessionID, "admission_id": admissionID, "include_result": true], profileID: profileID))
        guard receipt["admission_id"] as? String == admissionID,
            (receipt["ref"] as? [String: Any])?["session_id"] as? String == sessionID,
            receipt["status"] as? String == "terminal", receipt["outcome"] as? String == "completed",
            let result = receipt["result"] as? [String: Any],
            let provider = (result["provider"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !provider.isEmpty,
            let model = (result["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !model.isEmpty
        else { return nil }
        return HermesModelOption(provider: provider, model: model)
    }

    /// Runs one allowlisted `session.control` action (for example `goal.pause`).
    func sessionControlAction(
        _ action: HermesSessionControl.Action, sessionID: String, profileID: String?
    ) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.sessionControlAction.rawValue,
            params: Self.profileParams(["session_id": sessionID, "action": action.rawValue], profileID: profileID))
    }

    func activeSessions(profileID: String? = nil) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.sessionActiveList.rawValue, params: Self.profileParams([:], profileID: profileID))
    }
    func sessions(limit: Int = 50, profileID: String? = nil) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.sessionList.rawValue, params: Self.profileParams(["limit": limit], profileID: profileID)
        )
    }
    /// Resolve the canonical chat even when it is hidden or has a newer conversation segment.
    func existingBotChat(profileID: String) async throws -> HermesSession? {
        let title = BotService.canonicalBotChatTitle
        let result = try await client.request(
            HermesFeatureIDs.ID.sessionList.rawValue, params: ["title": title, "profile": profileID])
        guard let rows = result["sessions"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        guard rows.count == 1, let row = rows.first,
            row["title"] as? String == title || row["root_title"] as? String == title,
            let id = row["resolved_id"] as? String ?? row["session_id"] as? String ?? row["id"] as? String,
            !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id != title
        else { return nil }
        return HermesSession(
            id: id, profileID: profileID, title: title, preview: "", startedAt: nil,
            messageCount: row["message_count"] as? Int ?? 0, source: row["source"] as? String ?? "hermes-bot")
    }
    func sessionPages(limit: Int = 100, offset: Int = 0, order: String? = nil, timeout: TimeInterval? = nil)
        async throws -> [String: Any]
    {
        let path = "/api/sessions?limit=\(limit)&offset=\(offset)" + (order.map { "&order=\($0)" } ?? "")
        let result = try await fetchSessionHistory(path, timeout: timeout)
        // Hermes Agent's REST endpoint uses `sessions`/`total`; the Dock's
        // activity projection predates that endpoint and uses `data`/`has_more`.
        // Adapt at the transport boundary so both forms remain supported.
        guard result["data"] == nil else { return result }
        guard let sessions = result["sessions"] as? [[String: Any]],
            let total = result["total"] as? Int,
            total >= offset + sessions.count
        else {
            return result
        }
        var canonical = result
        canonical["data"] = sessions
        canonical["has_more"] = offset + sessions.count < total
        return canonical
    }
    func sessionMessages(
        sessionID: String, profileID: String? = nil, latest: Bool = false, limit: Int = 500, offset: Int = 0,
        includeCompacted: Bool = false, inlineImages: Bool = true, timeout: TimeInterval? = nil
    ) async throws -> [String: Any] {
        let disallowed = CharacterSet(charactersIn: "/")
        let allowed = CharacterSet.urlPathAllowed.subtracting(disallowed)
        guard let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw NSError(
                domain: "HermesControl", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid session ID."])
        }
        let profile =
            profileID?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).map { "&profile=\($0)" } ?? ""
        var path = "/api/sessions/\(encoded)/messages?limit=\(limit)\(latest ? "&order=latest" : "")\(profile)"
        if offset > 0 || includeCompacted { path += "&offset=\(offset)" }
        if includeCompacted {
            if !latest { path += "&order=oldest" }
            path += "&include_compacted=true"
        }
        if !inlineImages { path += "&inline_images=false" }
        let result = try await fetchSessionHistory(path, timeout: timeout)
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
    private func fetchSessionHistory(_ path: String, timeout: TimeInterval?) async throws -> [String: Any] {
        if let timeout { return try await client.fetchHTTP(path, timeout: timeout) }
        return try await client.fetchHTTP(path)
    }

    /// Artifacts use the archive, independently of the sidebar's recent-session window.
    /// Returns whether any part of the archive was unavailable.
    func artifactSessions(onPage: @MainActor ([[String: Any]]) async -> Void) async throws -> Bool {
        var offset = 0
        var isIncomplete = false
        while true {
            try Task.checkCancellation()
            do {
                let page = try await client.fetchHTTP(
                    "/api/profiles/sessions?limit=100&offset=\(offset)&min_messages=1&archived=exclude&order=recent&profile=all"
                )
                guard let sessions = page["sessions"] as? [[String: Any]],
                    let total = page["total"] as? Int, total >= 0
                else {
                    throw HermesGateway.GatewayError.malformedResponse
                }
                isIncomplete =
                    isIncomplete || !(page["errors"] as? [[String: Any]] ?? []).isEmpty
                    || !(page["storage"] as? [String: String] ?? [:]).isEmpty
                if sessions.isEmpty { return isIncomplete || offset < total }
                await onPage(sessions)
                try Task.checkCancellation()
                offset += min(100, sessions.count)  // Hermes may back-fill pinned rows beyond the page window.
                if offset >= total { return isIncomplete }
            } catch {
                try Task.checkCancellation()
                guard offset > 0 else { throw error }
                return true
            }
        }
    }

    func hasPendingSidebarApproval(runtimeID: String, profileID: String) async throws -> Bool {
        let result = try await client.request(
            HermesFeatureIDs.ID.approvalPending.rawValue, params: ["session_id": runtimeID, "profile": profileID])
        guard let approvals = result["approvals"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        return !approvals.isEmpty
    }

    func sidebarLiveStatus(
        for sections: Set<SessionRailSection>, profiles: [String]
    ) async -> [SessionRailSection: SessionSidebarLiveStatus] {
        var statuses = Dictionary(uniqueKeysWithValues: sections.map { ($0, SessionSidebarLiveStatus()) })
        for profile in profiles {
            guard !Task.isCancelled else { break }
            do {
                // Hermes routes explicit profile requests to that profile's session authority.
                let result = try await activeSessions(profileID: profile)
                guard let rows = ControlCenterModel.parseSessions(result) else {
                    throw HermesGateway.GatewayError.malformedResponse
                }
                for row in rows where row.profileID == nil || row.profileID == profile {
                    guard !Task.isCancelled else { break }
                    let key = ProfileScopedID(profileID: profile, resourceID: row.storedSessionID ?? row.id)
                    if sections.contains(.running), SessionSidebarFilterInventory.isRunning(row) {
                        statuses[.running]?.ids.insert(key)
                    } else if sections.contains(.needsYou), row.state.lowercased() == "waiting" {
                        do {
                            if try await hasPendingSidebarApproval(runtimeID: row.id, profileID: profile) {
                                statuses[.needsYou]?.ids.insert(key)
                            }
                        } catch {
                            statuses[.needsYou]?.isIncomplete = true
                        }
                    }
                }
            } catch {
                for section in sections { statuses[section]?.isIncomplete = true }
            }
        }
        return statuses
    }

    func archivedSidebarSessions(scope: SessionSidebarArchive.Scope) async throws -> SessionSidebarArchive {
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "profile", value: scope.queryValue)]
        // A literal plus must not be decoded as a space by the server.
        let profile = query.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
        let pageSize = 100
        var offset = 0
        var incomplete = false
        var sessions: [HermesSession] = []
        var seen = Set<ProfileScopedID>()
        while true {
            try Task.checkCancellation()
            do {
                let path =
                    "/api/profiles/sessions?\(profile)&archived=only&order=recent"
                    + "&limit=\(pageSize)&offset=\(offset)"
                let page = try await client.fetchHTTP(path)
                try Task.checkCancellation()
                guard let rows = page["sessions"] as? [[String: Any]],
                    let total = page["total"] as? Int, total >= 0
                else { throw HermesGateway.GatewayError.malformedResponse }

                incomplete =
                    incomplete || !(page["errors"] as? [[String: Any]] ?? []).isEmpty
                    || !(page["storage"] as? [String: String] ?? [:]).isEmpty
                let archivedRows = rows.filter { $0["archived"] as? Bool == true }
                for row in archivedRows {
                    guard let owner = row["profile"] as? String, !owner.isEmpty, scope.includes(owner),
                        let session = DockModel.parseSession(row, profileID: owner)
                    else {
                        incomplete = true
                        continue
                    }
                    if seen.insert(session.scopedID).inserted { sessions.append(session) }
                }
                // The server can append live pinned rows outside its archive window.
                offset += min(pageSize, archivedRows.count)
                if offset >= total { break }
                if archivedRows.count < pageSize {
                    incomplete = true
                    break
                }
            } catch {
                try Task.checkCancellation()
                guard offset > 0 else { throw error }
                incomplete = true
                break
            }
        }
        return SessionSidebarArchive(sessions: sessions, isIncomplete: incomplete)
    }

    /// Every profile's recent sessions in one read. Hermes single-flights and
    /// briefly caches this scan, so overlapping refreshes share one pass.
    /// Cron and messaging slices are unused here; ask for the minimum.
    func allProfileSidebarSessions(limit: Int) async throws -> [String: Any] {
        try await client.fetchHTTP(
            "/api/profiles/sessions/sidebar?recents_profile=all&recents_limit=\(limit)&cron_limit=1&messaging_limit=1")
    }

    /// Sessions whose ID or message text matches `query` (Hermes FTS).
    func searchSessions(query: String, limit: Int = 20, profileID: String? = nil) async throws -> [[String: Any]] {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(max(1, min(limit, 20)))),
        ]
        if let profileID { components.queryItems?.append(URLQueryItem(name: "profile", value: profileID)) }
        guard let encoded = components.percentEncodedQuery else { return [] }
        let result = try await client.fetchHTTP("/api/sessions/search?\(encoded)")
        guard let rows = result["results"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        return rows
    }
    func activate(sessionID: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.sessionActivate.rawValue, params: ["session_id": sessionID])
    }
    func resume(sessionID: String, profileID: String? = nil) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.sessionResume.rawValue,
            params: Self.profileParams(
                ["session_id": sessionID, "source": HermesFeatureIDs.sessionSource], profileID: profileID))
    }
    func delete(sessionID: String, profileID: String? = nil) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.sessionDelete.rawValue,
            params: Self.profileParams(["session_id": sessionID], profileID: profileID))
    }
    func interrupt(sessionID: String, profileID: String? = nil) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.sessionInterrupt.rawValue,
            params: Self.profileParams(["session_id": sessionID], profileID: profileID)
        )
    }
    /// Hermes clamps `days` to 1…365 server-side.
    func usageAnalytics(days: Int) async throws -> [String: Any] {
        try await client.fetchHTTP("/api/analytics/usage?days=\(days)", timeout: 60)
    }

    func modelAnalytics(days: Int) async throws -> [String: Any] {
        try await client.fetchHTTP("/api/analytics/models?days=\(days)")
    }
    func sessionUsage(sessionID: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.sessionUsage.rawValue, params: ["session_id": sessionID])
    }
    func sessionContextBreakdown(sessionID: String) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.sessionContextBreakdown.rawValue, params: ["session_id": sessionID])
    }
    func projectFacts(cwd: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.projectFacts.rawValue, params: ["cwd": cwd])
    }
    func verificationStatus(sessionID: String?, cwd: String) async throws -> [String: Any] {
        var params: [String: Any] = ["cwd": cwd]
        if let sessionID, !sessionID.isEmpty { params["session_id"] = sessionID }
        return try await client.request(HermesFeatureIDs.ID.verificationStatus.rawValue, params: params)
    }
    func startBackgroundPrompt(sessionID: String, text: String) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.promptBackground.rawValue, params: ["session_id": sessionID, "text": text])
    }
    /// A user's mention is a user turn in the recipient's canonical Bot Chat.
    func submitBotMessage(
        profileID: String, message: String, chatSessionID: String?,
        beforeSubmit: (String) throws -> Void
    ) async throws -> String {
        let requested = chatSessionID ?? BotService.canonicalBotChatTitle
        let result = try await client.request(
            HermesFeatureIDs.ID.sessionResume.rawValue,
            params: [
                "session_id": requested, "profile": profileID, "source": HermesFeatureIDs.sessionSource,
                "omit_messages": true,
            ])
        let info = result["info"] as? [String: Any] ?? [:]
        let profile = result["profile"] as? String ?? info["profile_name"] as? String ?? info["profile"] as? String
        guard let runtime = result["session_id"] as? String, !runtime.isEmpty,
            profile == profileID,
            DockModel.resumeResponseProvesSessionOwnership(
                requestedSessionID: requested, resolvedSessionID: runtime, result: result)
        else {
            throw QuickDraftError.message(
                "Hermes did not confirm the mentioned Bot’s conversation. The message was not sent.")
        }
        guard result["running"] as? Bool != true, info["running"] as? Bool != true else {
            throw QuickDraftError.message("The mentioned Bot is busy. Wait for its current turn before sending again.")
        }
        try beforeSubmit(runtime)
        let submitted: [String: Any]
        do {
            submitted = try await client.request(
                HermesFeatureIDs.ID.promptSubmit.rawValue,
                params: ["session_id": runtime, "profile": profileID, "text": message])
        } catch {
            throw QuickDraftError.message(
                "The Bot’s submission was not confirmed. Check its Bot Chat before resending. "
                    + HermesDiagnosticsService.safeSummary(error.localizedDescription))
        }
        guard submitted["status"] as? String == "streaming" else {
            throw QuickDraftError.message("Hermes did not confirm the Bot’s turn. Check its Bot Chat before resending.")
        }
        return runtime
    }
    func sessionTitle(sessionID: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.sessionTitle.rawValue, params: ["session_id": sessionID])
    }
    func setSessionTitle(sessionID: String, title: String) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.sessionTitle.rawValue, params: ["session_id": sessionID, "title": title])
    }
    func steer(sessionID: String, text: String) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.sessionSteer.rawValue, params: ["session_id": sessionID, "text": text])
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
        try await client.request(
            HermesFeatureIDs.ID.sessionRedirect.rawValue, params: ["session_id": sessionID, "text": text])
    }
    func pauseDelegation(_ paused: Bool) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.delegationPause.rawValue, params: ["paused": paused])
    }
    func interruptSubagent(subagentID: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.subagentInterrupt.rawValue, params: ["subagent_id": subagentID])
    }
    func killProcess(sessionID: String, processID: String) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.processKill.rawValue, params: ["session_id": sessionID, "process_id": processID])
    }
    func respondToApproval(sessionID: String, choice: String) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.approvalRespond.rawValue, params: ["session_id": sessionID, "choice": choice])
    }
    func respondToClarification(requestID: String, answer: String) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.clarifyRespond.rawValue, params: ["id": requestID, "result": ["answer": answer]])
    }
    func delegationStatus() async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.delegationStatus.rawValue, params: [:])
    }
    func cron(action: String, jobID: String? = nil, profileID: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["action": action, "include_disabled": true]
        if let jobID { params["name"] = jobID }
        let result = try await client.request(
            HermesFeatureIDs.ID.cronManage.rawValue, params: Self.profileParams(params, profileID: profileID))
        if action == "list" {
            guard result["success"] as? Bool != false, result["jobs"] is [[String: Any]] else {
                throw QuickDraftError.message(
                    result["error"] as? String ?? "Hermes did not return an automation inventory.")
            }
            if let profileID, result["scoped"] as? String != profileID {
                throw HermesGateway.GatewayError.malformedResponse
            }
        }
        return result
    }
    func createCron(name: String, schedule: String, prompt: String, profileID: String? = nil) async throws -> [String:
        Any]
    {
        let result = try await client.request(
            HermesFeatureIDs.ID.cronManage.rawValue,
            params: Self.profileParams(
                [
                    "action": "add", "name": name, "schedule": schedule, "prompt": prompt,
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
            guard !jobID.isEmpty, jobID != ".", jobID != "..",
                let encoded = jobID.addingPercentEncoding(withAllowedCharacters: allowed)
            else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            path += "/" + encoded
        }
        var components = URLComponents()
        components.queryItems = profileID.map { [URLQueryItem(name: "profile", value: $0)] }
        let query = components.percentEncodedQuery.map { "?" + $0.replacingOccurrences(of: "+", with: "%2B") } ?? ""
        return path + suffix + query
    }

    func cronDeliveryTargets(profileID: String?) async throws -> [CronDeliveryTarget] {
        let path = try Self.cronPath(profileID: profileID).replacingOccurrences(
            of: "/api/cron/jobs", with: "/api/cron/delivery-targets")
        guard let rows = try await client.fetchHTTP(path)["targets"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return CronDeliveryTarget(
                id: id, name: row["name"] as? String ?? id, homeTargetSet: row["home_target_set"] as? Bool ?? true)
        }
    }

    func cronBlueprints(profileID: String?) async throws -> [CronBlueprint] {
        let path = try Self.cronPath(profileID: profileID).replacingOccurrences(
            of: "/api/cron/jobs", with: "/api/cron/blueprints")
        guard let rows = try await client.fetchHTTP(path)["blueprints"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        return rows.compactMap { row in
            guard let key = row["key"] as? String, let title = row["title"] as? String else { return nil }
            let fields = (row["fields"] as? [[String: Any]] ?? []).compactMap { field -> CronBlueprintField? in
                guard let name = field["name"] as? String else { return nil }
                return CronBlueprintField(
                    name: name, kind: (field["type"] as? String).flatMap(CronBlueprintField.Kind.init) ?? .text,
                    label: field["label"] as? String ?? name, defaultValue: field["default"] as? String,
                    options: field["options"] as? [String] ?? [], help: field["help"] as? String ?? "")
            }
            return CronBlueprint(
                key: key, title: title, description: row["description"] as? String ?? "",
                plugin: row["plugin"] as? String, fields: fields)
        }
    }

    /// Hermes fills the blueprint's slots into a prompt and schedule, then creates the job in `profileID`.
    func instantiateCronBlueprint(key: String, values: [String: String], profileID: String?) async throws
        -> CronSummary
    {
        let path = try Self.cronPath(profileID: profileID ?? "default").replacingOccurrences(
            of: "/api/cron/jobs", with: "/api/cron/blueprints/instantiate")
        let result = try await client.sendHTTP("POST", path: path, body: ["blueprint": key, "values": values])
        guard let id = result["id"] as? String else { throw HermesGateway.GatewayError.malformedResponse }
        return try Self.parseCronJobDetail(result, expectedID: id, profileID: profileID)
    }

    func cronModelProviders() async throws -> [CronModelProvider] {
        let result = try await client.request(
            HermesFeatureIDs.ID.modelOptions.rawValue, params: ["explicit_only": true])
        return (result["providers"] as? [[String: Any]] ?? []).compactMap { row in
            guard let slug = row["slug"] as? String ?? row["name"] as? String else { return nil }
            let models = row["models"] as? [String] ?? []
            return models.isEmpty
                ? nil : CronModelProvider(slug: slug, name: row["name"] as? String ?? slug, models: models)
        }
    }

    func subagentModelProviders(profileID: String) async throws -> [CronModelProvider] {
        let result = try await client.request(
            HermesFeatureIDs.ID.modelOptions.rawValue, params: ["profile": profileID, "explicit_only": true])
        guard let rows = result["providers"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        return rows.compactMap { row in
            guard let slug = row["slug"] as? String, let models = row["models"] as? [String], !models.isEmpty else {
                return nil
            }
            return CronModelProvider(slug: slug, name: row["name"] as? String ?? slug, models: models)
        }
    }

    func cronJob(_ job: CronSummary, profileID: String?) async throws -> CronSummary {
        let row = try await client.fetchHTTP(Self.cronPath(jobID: job.id, profileID: profileID))
        return try Self.parseCronJobDetail(row, expectedID: job.id, profileID: profileID)
    }

    private static func parseCronJobDetail(_ row: [String: Any], expectedID: String, profileID: String?) throws
        -> CronSummary
    {
        guard var job = ControlCenterModel.parseCronJobs(["jobs": [row]]).first, job.id == expectedID,
            row["id"] as? String == expectedID, row["prompt"] is String, row["schedule"] != nil
        else { throw HermesGateway.GatewayError.malformedResponse }
        if let reportedProfile = row["profile"] as? String, let profileID, reportedProfile != profileID {
            throw HermesGateway.GatewayError.malformedResponse
        }
        job.owner = CronOwner(profileID: profileID)
        return job
    }

    func cronJobRuns(jobID: String, profileID: String?) async throws -> [CronRunSummary] {
        let path =
            try Self.cronPath(jobID: jobID, suffix: "/runs", profileID: profileID) + (profileID == nil ? "?" : "&")
            + "limit=50"
        return try ControlCenterModel.parseStructuredCronRuns(try await client.fetchHTTP(path), jobID: jobID)
    }

    func updateCron(_ job: CronSummary, draft: CronEditDraft, profileID: String?) async throws {
        let changes = draft.changes(comparedTo: job)
        var updates: [String: Any] = [:]
        for (field, value) in changes {
            if value.isEmpty && [.model, .provider, .workdir].contains(field) {
                updates[field.rawValue] = NSNull()
            } else {
                updates[field.rawValue] = value
            }
        }
        let result = try await client.sendHTTP(
            "PUT", path: Self.cronPath(jobID: job.id, profileID: profileID), body: ["updates": updates])
        _ = try Self.parseCronJobDetail(result, expectedID: job.id, profileID: profileID)
    }

    func createCron(
        name: String, schedule: String, prompt: String, configuration: CronConfigurationDraft, profileID: String?
    ) async throws -> CronSummary {
        var body = configuration.parameters
        body["name"] = name
        body["schedule"] = schedule
        body["prompt"] = prompt
        let result = try await client.sendHTTP("POST", path: Self.cronPath(profileID: profileID), body: body)
        guard let id = result["id"] as? String else { throw HermesGateway.GatewayError.malformedResponse }
        return try Self.parseCronJobDetail(result, expectedID: id, profileID: profileID)
    }

    func createAssistantTimer(name: String, schedule: String, profileID: String) async throws -> CronSummary {
        let body: [String: Any] = [
            "name": name, "schedule": schedule, "prompt": "", "deliver": "local",
            "repeat": 1, "no_agent": true, "script": AssistantTimers.scriptName,
        ]
        let result = try await client.sendHTTP("POST", path: Self.cronPath(profileID: profileID), body: body)
        guard let id = result["id"] as? String else { throw HermesGateway.GatewayError.malformedResponse }
        return try Self.parseCronJobDetail(result, expectedID: id, profileID: profileID)
    }

    func triggerCron(jobID: String, profileID: String?) async throws {
        let result = try await client.sendHTTP(
            "POST", path: Self.cronPath(jobID: jobID, suffix: "/trigger", profileID: profileID), body: [:],
            timeout: 24 * 60 * 60)
        _ = try Self.parseCronJobDetail(result, expectedID: jobID, profileID: profileID)
    }
    func reloadMCP(sessionID: String) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.reloadMCP.rawValue, params: ["session_id": sessionID, "confirm": true])
    }
    func processes(sessionID: String) async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.processList.rawValue, params: ["session_id": sessionID])
    }
    func tools() async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.toolsList.rawValue, params: [:])
    }
    func plugins() async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.pluginsList.rawValue, params: [:])
    }
    func configuration() async throws -> [String: Any] {
        try await client.request(HermesFeatureIDs.ID.configShow.rawValue, params: [:])
    }
    func projectsTree(profileID: String? = nil) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.projectsTree.rawValue, params: Self.profileParams([:], profileID: profileID))
    }
    func projectSessions(projectID: String, profileID: String? = nil) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.projectsProjectSessions.rawValue,
            params: Self.profileParams(["project_id": projectID], profileID: profileID))
    }
    func createProject(name: String, folders: [String], description: String? = nil, profileID: String? = nil)
        async throws -> [String: Any]
    {
        var params: [String: Any] = ["name": name, "folders": folders]
        if let description, !description.isEmpty { params["description"] = description }
        return try await client.request(
            HermesFeatureIDs.ID.projectsCreate.rawValue, params: Self.profileParams(params, profileID: profileID))
    }
    func archiveProject(id: String, restore: Bool = false, profileID: String? = nil) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.projectsArchive.rawValue,
            params: Self.profileParams(["id": id, "restore": restore], profileID: profileID))
    }
    func deleteProject(id: String, profileID: String? = nil) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.projectsDelete.rawValue, params: Self.profileParams(["id": id], profileID: profileID))
    }
    func setActiveProject(id: String?, profileID: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = [:]
        if let id, !id.isEmpty { params["id"] = id }
        return try await client.request(
            HermesFeatureIDs.ID.projectsSetActive.rawValue, params: Self.profileParams(params, profileID: profileID))
    }
    func addProjectFolder(id: String, path: String, profileID: String? = nil) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.projectsAddFolder.rawValue,
            params: Self.profileParams(["id": id, "path": path], profileID: profileID))
    }
    func setSessionHidden(sessionID: String, hidden: Bool, profileID: String? = nil) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.sessionSetHidden.rawValue,
            params: Self.profileParams(["session_id": sessionID, "hidden": hidden], profileID: profileID))
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
        try await client.request(
            HermesFeatureIDs.ID.rollbackDiff.rawValue, params: ["session_id": sessionID, "hash": hash])
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
            !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            normalized["stderr"] = error
        }
        if normalized["code"] == nil,
            let exitCode = (raw["exit_code"] as? NSNumber)?.intValue ?? raw["exit_code"] as? Int
        {
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
