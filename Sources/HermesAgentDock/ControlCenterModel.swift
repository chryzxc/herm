import Foundation

@MainActor
final class ControlCenterModel: ObservableObject {
    @Published private(set) var attention: [AttentionItem] = []
    @Published private(set) var reminders: [ReminderSummary] = []
    @Published private(set) var cronJobs: [CronSummary] = []
    @Published private(set) var activeSessions: [SessionSummary] = []
    @Published private(set) var activeAgents: [AgentSummary] = []
    @Published private(set) var processes: [ProcessSummary] = []
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var searchResults: [ControlSearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var kanbanTasks: [KanbanTaskSummary] = []
    @Published private(set) var projectSessions: [SessionSummary] = []
    @Published private(set) var selectedProjectID: String?
    @Published private(set) var capabilities: [CapabilityState] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?

    private weak var dockModel: DockModel?
    private var rpc: HermesControlRPC?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var knownAttention: [String: AttentionItem] = [:]
    private var eventSubscription: UUID?
    private let capabilityService = HermesCapabilityService()
    private var remindersAdapter: AppleRemindersAdapter?
    private let presentationDefaults = UserDefaults.standard
    private let presentationKey = "hermes.control.attention.presentation.v1"
    private let snoozeKey = "hermes.control.attention.snooze.v1"

    init() {
        let stored = presentationDefaults.dictionary(forKey: presentationKey) as? [String: String] ?? [:]
        let storedSnoozes = presentationDefaults.dictionary(forKey: snoozeKey) as? [String: Double] ?? [:]
        for (id, rawState) in stored {
            if let state = AttentionState(rawValue: rawState) {
                let snoozedUntil = storedSnoozes[id].map(Date.init(timeIntervalSince1970:))
                let effectiveState: AttentionState = state == .snoozed && (snoozedUntil ?? .distantPast) <= .now ? .open : state
                knownAttention[id] = AttentionItem(
                    id: id,
                    reference: ControlReference(source: .hermesSession, sourceID: id),
                    kind: .completed,
                    title: "Previously reviewed item",
                    detail: "This item will return if Hermes reports it again.",
                    createdAt: Date.distantPast,
                    state: effectiveState,
                    actions: [.open]
                )
            }
        }
    }

    func bind(to model: DockModel) {
        if dockModel !== model, let eventSubscription {
            dockModel?.eventRouter.unsubscribe(eventSubscription)
            self.eventSubscription = nil
        }
        dockModel = model
        rpc = HermesControlRPC(client: model.controlRPCClient)
        remindersAdapter = AppleRemindersAdapter(client: model.controlRPCClient)
        if eventSubscription == nil {
            eventSubscription = model.eventRouter.subscribe { [weak self] type, params in
                self?.ingestEvent(type, params: params)
            }
        }
        rebuildAttention()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        rebuildAttention()

        Task { [weak self] in
            guard let self else { return }
            defer { isRefreshing = false }
            do {
                var remindersAvailable = false
                if let remindersAdapter {
                    do {
                        reminders = try await remindersAdapter.today()
                        remindersAvailable = true
                    } catch {
                        lastError = error.localizedDescription
                    }
                }

                let cronResult = try await rpc?.cron(action: "list")
                if let cronResult { cronJobs = Self.parseCronJobs(cronResult) }

                let sessionResult = try await rpc?.activeSessions()
                if let sessionResult { activeSessions = Self.parseSessions(sessionResult) }

                let delegationResult = try await rpc?.delegationStatus()
                if let delegationResult { activeAgents = Self.parseAgents(delegationResult) }

                let processResult = try await rpc?.processes()
                if let processResult { processes = Self.parseProcesses(processResult) }

                let projectResult = try await rpc?.projectsTree()
                if let projectResult { projects = Self.parseProjects(projectResult) }

                if let dockModel {
                    capabilities = await capabilityService.probe(client: dockModel.controlRPCClient, remindersAvailable: remindersAvailable)
                }
            } catch {
                lastError = error.localizedDescription
                if let dockModel {
                    capabilities = await capabilityService.probe(client: dockModel.controlRPCClient, remindersAvailable: false)
                }
            }
        }
    }

    func completeReminder(_ reminder: ReminderSummary) {
        guard let dockModel else { return }
        Task {
            do {
                try await dockModel.submitControlPrompt("Using the apple-reminders skill, complete exactly this Apple Reminder and no other reminder. Reminder id: \(reminder.id). Title: \(reminder.title). Report the result after the source confirms completion.")
                try? await Task.sleep(for: .milliseconds(600))
                refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func setCron(_ job: CronSummary, enabled: Bool) {
        guard rpc != nil else { return }
        Task {
            do {
                guard let rpc else { return }
                _ = try await rpc.setCron(jobID: job.id, enabled: enabled)
                refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func createCron(name: String, schedule: String, prompt: String) {
        guard rpc != nil else { return }
        Task {
            do {
                guard let rpc else { return }
                _ = try await rpc.createCron(name: name, schedule: schedule, prompt: prompt)
                refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func removeCron(_ job: CronSummary) {
        guard rpc != nil else { return }
        Task {
            do {
                guard let rpc else { return }
                _ = try await rpc.removeCron(jobID: job.id)
                refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func openCronSession(_ job: CronSummary) {
        guard let sessionID = job.sessionID, let dockModel else { return }
        Task {
            do {
                guard let rpc else { return }
                _ = try await rpc.activate(sessionID: sessionID)
                dockModel.requestComposerFocus()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func openProject(_ project: ProjectSummary) {
        guard rpc != nil else { return }
        selectedProjectID = project.id
        projectSessions = []
        Task {
            do {
                let result = try await rpc?.projectSessions(projectID: project.id)
                guard let result else { throw HermesGateway.GatewayError.malformedResponse }
                projectSessions = Self.parseProjectSessions(result)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func closeProject() {
        selectedProjectID = nil
        projectSessions = []
    }

    func search(_ query: String) {
        searchGeneration = UUID()
        let generation = searchGeneration
        searchTask?.cancel()
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            isSearching = false
            searchResults = []
            return
        }

        let localSessions = activeSessions
        let localAttention = attention
        let localReminders = reminders
        let localProjects = projects
        isSearching = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            var sessions = localSessions
            if let rpc = self.rpc, let result = try? await rpc.sessions(limit: 100) {
                sessions = Self.parseSessions(result)
            }
            guard !Task.isCancelled, self.searchGeneration == generation else { return }
            self.searchResults = Self.makeSearchResults(
                query: normalized,
                sessions: sessions,
                attention: localAttention,
                reminders: localReminders,
                projects: localProjects
            )
            self.isSearching = false
        }
    }

    func openSearchResult(_ result: ControlSearchResult) {
        switch result.reference.source {
        case .hermesSession, .hermesApproval, .hermesClarification, .hermesAgentRun:
            guard let rpc else { return }
            Task {
                do {
                    _ = try await rpc.activate(sessionID: result.reference.sessionID ?? result.reference.sourceID)
                    dockModel?.requestComposerFocus()
                } catch {
                    lastError = error.localizedDescription
                }
            }
        case .hermesProject:
            if let project = projects.first(where: { $0.id == result.reference.sourceID }) {
                openProject(project)
            }
        case .hermesCronJob, .appleReminder:
            break
        }
    }

    func reloadMCP() {
        guard let rpc, let sessionID = dockModel?.sessionID else {
            lastError = "Open a Hermes session before reloading MCP tools."
            return
        }
        Task {
            do {
                _ = try await rpc.reloadMCP(sessionID: sessionID)
                dockModel?.refreshRuntimeConfiguration()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func refreshKanban() {
        guard let rpc else { return }
        Task {
            do {
                let result = try await rpc.shell("hermes kanban list --json")
                guard AppleRemindersAdapter.shellResultSucceeded(result), let output = result["stdout"] as? String else {
                    kanbanTasks = []
                    return
                }
                kanbanTasks = Self.parseKanbanTasks(output)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func createKanbanTask(title: String, body: String) {
        guard let rpc else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        var command = "hermes kanban create --json \(Self.shellQuote(cleanTitle))"
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanBody.isEmpty { command = "hermes kanban create --json --body \(Self.shellQuote(cleanBody)) \(Self.shellQuote(cleanTitle))" }
        Task {
            do {
                let result = try await rpc.shell(command)
                guard AppleRemindersAdapter.shellResultSucceeded(result) else {
                    lastError = (result["stderr"] as? String) ?? "Hermes Kanban could not create the task."
                    return
                }
                refreshKanban()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func openProjectSession(_ session: SessionSummary) {
        guard let dockModel else { return }
        Task {
            do {
                guard let rpc else { return }
                _ = try await rpc.activate(sessionID: session.id)
                dockModel.requestComposerFocus()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func respond(to item: AttentionItem, action: AttentionAction, response: String? = nil) {
        guard let dockModel else { return }
        let reference = item.reference
        Task {
            do {
                switch action {
                case .approve:
                    guard let rpc else { return }
                    _ = try await rpc.respondToApproval(sessionID: reference.sessionID ?? "", choice: "once")
                case .deny:
                    guard let rpc else { return }
                    _ = try await rpc.respondToApproval(sessionID: reference.sessionID ?? "", choice: "deny")
                case .respond:
                    let response = response?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !response.isEmpty else { return }
                    guard let rpc else { return }
                    _ = try await rpc.respondToClarification(sessionID: reference.sessionID ?? reference.sourceID, response: response)
                case .stop:
                    guard let rpc else { return }
                    _ = try await rpc.interrupt(sessionID: reference.sessionID ?? reference.sourceID)
                case .resume:
                    guard let rpc else { return }
                    _ = try await rpc.activate(sessionID: reference.sessionID ?? reference.sourceID)
                case .open:
                    guard let rpc else { return }
                    _ = try await rpc.activate(sessionID: reference.sessionID ?? reference.sourceID)
                    dockModel.requestComposerFocus()
                default:
                    break
                }
                markResolved(item.id)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func markResolved(_ id: String) {
        guard let index = attention.firstIndex(where: { $0.id == id }) else { return }
        attention[index].state = .resolved
        knownAttention[id] = attention[index]
        persistPresentationState()
    }

    func dismiss(_ id: String) {
        guard let index = attention.firstIndex(where: { $0.id == id }) else { return }
        attention[index].state = .dismissed
        knownAttention[id] = attention[index]
        persistPresentationState()
    }

    func snooze(_ id: String, for duration: TimeInterval = 60 * 60) {
        guard let index = attention.firstIndex(where: { $0.id == id }) else { return }
        attention[index].state = .snoozed
        knownAttention[id] = attention[index]
        let until = Date().addingTimeInterval(duration)
        var snoozes = presentationDefaults.dictionary(forKey: snoozeKey) as? [String: Double] ?? [:]
        snoozes[id] = until.timeIntervalSince1970
        presentationDefaults.set(snoozes, forKey: snoozeKey)
        persistPresentationState()
        rebuildAttention()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, let item = self.knownAttention[id], item.state == .snoozed else { return }
            var reopened = item
            reopened.state = .open
            self.knownAttention[id] = reopened
            var current = self.presentationDefaults.dictionary(forKey: self.snoozeKey) as? [String: Double] ?? [:]
            current.removeValue(forKey: id)
            self.presentationDefaults.set(current, forKey: self.snoozeKey)
            self.persistPresentationState()
            self.rebuildAttention()
        }
    }

    /// Converts the shared Hermes event stream into stable attention records.
    /// The event's session/source identifier is the identity; display text may
    /// be enriched by later partial events without creating another row.
    func ingestEvent(_ type: String, params: [String: Any]) {
        let payload = params["payload"] as? [String: Any] ?? [:]
        let sessionID = (params["session_id"] as? String)
            ?? (payload["session_id"] as? String)
            ?? dockModel?.sessionID
        guard let sessionID, !sessionID.isEmpty else { return }

        let detail = (payload["message"] as? String)
            ?? (payload["description"] as? String)
            ?? (payload["question"] as? String)
            ?? (payload["text"] as? String)
            ?? "Hermes reported \(type)."
        switch type {
        case "approval.request":
            upsertAttention(AttentionItem(
                id: "approval:\(sessionID)",
                reference: ControlReference(source: .hermesApproval, sourceID: sessionID, sessionID: sessionID),
                kind: .approval,
                title: "Hermes needs approval",
                detail: (payload["command"] as? String) ?? (payload["description"] as? String) ?? detail,
                createdAt: Date(),
                state: .open,
                actions: [.approve, .deny, .stop]
            ))
        case "clarification.request", "clarify.request":
            upsertAttention(AttentionItem(
                id: "clarification:\(sessionID)",
                reference: ControlReference(source: .hermesClarification, sourceID: sessionID, sessionID: sessionID),
                kind: .clarification,
                title: "Hermes needs clarification",
                detail: detail,
                createdAt: Date(),
                state: .open,
                actions: [.respond, .open, .stop]
            ))
        case "error":
            upsertAttention(AttentionItem(
                id: "failure:\(sessionID)",
                reference: ControlReference(source: .hermesSession, sourceID: sessionID, sessionID: sessionID),
                kind: .failure,
                title: "Hermes work failed",
                detail: detail,
                createdAt: Date(),
                state: .open,
                actions: [.resume, .stop]
            ))
        case "message.complete":
            if let existing = knownAttention["failure:\(sessionID)"] {
                var resolved = existing
                resolved.state = .resolved
                knownAttention[resolved.id] = resolved
            }
            upsertAttention(AttentionItem(
                id: "completed:\(sessionID)",
                reference: ControlReference(source: .hermesSession, sourceID: sessionID, sessionID: sessionID),
                kind: .completed,
                title: "Hermes completed work",
                detail: "Review the latest response and decide what to do next.",
                createdAt: Date(),
                state: .open,
                actions: [.open, .dismiss]
            ))
        default:
            break
        }
        if ["message.complete", "sessions.changed", "cron.changed", "process.changed"].contains(type) {
            refresh()
        }
        rebuildAttention()
    }

    private func upsertAttention(_ item: AttentionItem) {
        if let existing = knownAttention[item.id], existing.state == .dismissed || existing.state == .resolved {
            var preserved = item
            preserved.state = existing.state
            knownAttention[item.id] = preserved
        } else if let existing = knownAttention[item.id] {
            var enriched = item
            enriched.createdAt = existing.createdAt
            knownAttention[item.id] = enriched
        } else {
            knownAttention[item.id] = item
        }
    }

    private func persistPresentationState() {
        let values = knownAttention.reduce(into: [String: String]()) { result, entry in
            guard entry.value.state == .dismissed || entry.value.state == .resolved || entry.value.state == .snoozed else { return }
            result[entry.key] = entry.value.state.rawValue
        }
        presentationDefaults.set(values, forKey: presentationKey)
    }

    func rebuildAttention() {
        var next: [AttentionItem] = []
        if let dockModel {
            if dockModel.status != .offline {
                knownAttention.removeValue(forKey: "failure:hermes")
            }
            if let sessionID = dockModel.sessionID, dockModel.approvalText == nil {
                knownAttention.removeValue(forKey: "approval:\(sessionID)")
            }
            if let approval = dockModel.approvalText, let sessionID = dockModel.sessionID,
               knownAttention["approval:\(sessionID)"]?.state != .resolved,
               knownAttention["approval:\(sessionID)"]?.state != .dismissed {
                upsertAttention(AttentionItem(
                    id: "approval:\(sessionID)",
                    reference: ControlReference(source: .hermesApproval, sourceID: sessionID, sessionID: sessionID),
                    kind: .approval,
                    title: "Hermes needs approval",
                    detail: approval,
                    createdAt: Date(),
                    state: .open,
                    actions: [.approve, .deny, .stop]
                ))
            }
            if dockModel.status == .offline {
                upsertAttention(AttentionItem(
                    id: "failure:hermes",
                    reference: ControlReference(source: .hermesSession, sourceID: dockModel.sessionID ?? "hermes"),
                    kind: .failure,
                    title: "Hermes is offline",
                    detail: "Reconnect Hermes to continue the active conversation.",
                    createdAt: Date(),
                    state: .open,
                    actions: [.open]
                ))
            }
        }
        next = knownAttention.values.filter { saved in
            saved.state != .resolved && saved.state != .dismissed && saved.state != .snoozed && !next.contains(where: { $0.id == saved.id })
        }
        attention = next.sorted { lhs, rhs in
            if lhs.kind == .approval && rhs.kind != .approval { return true }
            if lhs.kind != .approval && rhs.kind == .approval { return false }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private static func parseCronJobs(_ result: [String: Any]) -> [CronSummary] {
        let rows = (result["jobs"] as? [[String: Any]]) ?? (result["cron"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            let id = (row["id"] as? String) ?? (row["name"] as? String)
            guard let id else { return nil }
            return CronSummary(
                id: id,
                name: (row["name"] as? String) ?? id,
                schedule: (row["schedule"] as? String) ?? "Scheduled",
                enabled: (row["enabled"] as? Bool) ?? !(row["paused"] as? Bool ?? false),
                nextRun: row["next_run"] as? String ?? row["nextRun"] as? String,
                sessionID: row["session_id"] as? String ?? row["sessionID"] as? String
            )
        }
    }

    private static func parseSessions(_ result: [String: Any]) -> [SessionSummary] {
        let rows = (result["sessions"] as? [[String: Any]]) ?? (result["active"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return SessionSummary(
                id: id,
                title: (row["title"] as? String) ?? (row["name"] as? String) ?? "Hermes session",
                state: (row["state"] as? String) ?? (row["status"] as? String) ?? "active",
                preview: row["preview"] as? String ?? row["last_message"] as? String
            )
        }
    }

    private static func parseProcesses(_ result: [String: Any]) -> [ProcessSummary] {
        let rows = (result["processes"] as? [[String: Any]]) ?? (result["items"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let id = (row["id"] as? String) ?? (row["pid"] as? String) else { return nil }
            return ProcessSummary(
                id: id,
                name: (row["name"] as? String) ?? (row["command"] as? String) ?? "Hermes process",
                state: (row["state"] as? String) ?? (row["status"] as? String) ?? "running",
                detail: row["detail"] as? String ?? row["command"] as? String
            )
        }
    }

    static func parseAgents(_ result: [String: Any]) -> [AgentSummary] {
        let rows = (result["active"] as? [[String: Any]]) ?? (result["agents"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            let id = (row["subagent_id"] as? String) ?? (row["id"] as? String)
            guard let id else { return nil }
            return AgentSummary(
                id: id,
                name: (row["name"] as? String) ?? (row["role"] as? String) ?? id,
                state: (row["status"] as? String) ?? (row["state"] as? String) ?? "running",
                sessionID: row["session_id"] as? String ?? row["sessionID"] as? String
            )
        }
    }

    static func makeSearchResults(
        query: String,
        sessions: [SessionSummary],
        attention: [AttentionItem],
        reminders: [ReminderSummary],
        projects: [ProjectSummary]
    ) -> [ControlSearchResult] {
        let normalized = query.localizedLowercase
        var results: [ControlSearchResult] = []
        func matches(_ title: String, _ detail: String) -> Bool {
            title.localizedLowercase.contains(normalized) || detail.localizedLowercase.contains(normalized)
        }

        results += sessions.compactMap { session in
            guard matches(session.title, session.preview ?? session.state) else { return nil }
            return ControlSearchResult(
                id: "session:\(session.id)",
                reference: ControlReference(source: .hermesSession, sourceID: session.id, sessionID: session.id),
                title: session.title,
                detail: session.preview ?? session.state,
                sourceLabel: "HERMES SESSION"
            )
        }
        results += attention.compactMap { item in
            guard matches(item.title, item.detail) else { return nil }
            return ControlSearchResult(id: "attention:\(item.id)", reference: item.reference, title: item.title, detail: item.detail, sourceLabel: "INBOX")
        }
        results += reminders.compactMap { reminder in
            let detail = reminder.list ?? "Apple Reminder"
            guard matches(reminder.title, detail) else { return nil }
            return ControlSearchResult(
                id: "reminder:\(reminder.id)",
                reference: ControlReference(source: .appleReminder, sourceID: reminder.id),
                title: reminder.title,
                detail: detail,
                sourceLabel: "APPLE REMINDER"
            )
        }
        results += projects.compactMap { project in
            guard matches(project.name, project.preview ?? "Hermes project") else { return nil }
            return ControlSearchResult(
                id: "project:\(project.id)",
                reference: ControlReference(source: .hermesProject, sourceID: project.id, projectID: project.id),
                title: project.name,
                detail: project.preview ?? "Hermes project",
                sourceLabel: "HERMES PROJECT"
            )
        }
        return results.sorted { lhs, rhs in
            if lhs.sourceLabel != rhs.sourceLabel { return lhs.sourceLabel < rhs.sourceLabel }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    static func parseKanbanTasks(_ output: String) -> [KanbanTaskSummary] {
        guard let data = output.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = (row["id"] as? String) ?? (row["task_id"] as? String),
                  let title = row["title"] as? String else { return nil }
            return KanbanTaskSummary(
                id: id,
                title: title,
                status: (row["status"] as? String) ?? "unknown",
                detail: (row["body"] as? String) ?? (row["description"] as? String),
                priority: row["priority"] as? String,
                assignee: (row["assignee"] as? String) ?? (row["assigned_to"] as? String)
            )
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func parseProjects(_ result: [String: Any]) -> [ProjectSummary] {
        let activeID = result["active_id"] as? String
        let rows = (result["projects"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let repos = (row["repos"] as? [[String: Any]]) ?? (row["repositories"] as? [[String: Any]]) ?? []
            let sessions = (row["sessions"] as? [[String: Any]]) ?? (row["preview_sessions"] as? [[String: Any]]) ?? []
            return ProjectSummary(
                id: id,
                name: (row["name"] as? String) ?? id,
                repoCount: (row["repo_count"] as? NSNumber)?.intValue ?? repos.count,
                sessionCount: (row["session_count"] as? NSNumber)?.intValue ?? sessions.count,
                preview: (sessions.first?["preview"] as? String) ?? (sessions.first?["title"] as? String),
                isActive: (row["active"] as? Bool) ?? (id == activeID)
            )
        }
    }

    static func parseProjectSessions(_ result: [String: Any]) -> [SessionSummary] {
        var rows: [[String: Any]] = []

        func walk(_ value: Any) {
            if let row = value as? [String: Any] {
                let looksLikeSession = row["state"] != nil || row["status"] != nil || row["preview"] != nil || row["last_message"] != nil
                if row["id"] is String && looksLikeSession {
                    rows.append(row)
                }
                row.values.forEach(walk)
            } else if let values = value as? [Any] {
                values.forEach(walk)
            }
        }

        walk(result)
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let id = row["id"] as? String, seen.insert(id).inserted else { return nil }
            return SessionSummary(
                id: id,
                title: (row["title"] as? String) ?? (row["name"] as? String) ?? "Hermes session",
                state: (row["state"] as? String) ?? (row["status"] as? String) ?? "active",
                preview: row["preview"] as? String ?? row["last_message"] as? String
            )
        }
    }

}
