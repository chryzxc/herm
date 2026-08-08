import Foundation

@MainActor
final class ControlCenterModel: ObservableObject {
    @Published private(set) var attention: [AttentionItem] = []
    @Published private(set) var reminders: [ReminderSummary] = []
    @Published private(set) var cronJobs: [CronSummary] = []
    @Published private(set) var capabilities: [CapabilityState] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?

    private weak var dockModel: DockModel?
    private var knownAttention: [String: AttentionItem] = [:]
    private var eventSubscription: UUID?
    private let capabilityService = HermesCapabilityService()
    private var remindersAdapter: AppleRemindersAdapter?
    private let presentationDefaults = UserDefaults.standard
    private let presentationKey = "hermes.control.attention.presentation.v1"

    init() {
        let stored = presentationDefaults.dictionary(forKey: presentationKey) as? [String: String] ?? [:]
        for (id, rawState) in stored {
            if let state = AttentionState(rawValue: rawState) {
                knownAttention[id] = AttentionItem(
                    id: id,
                    reference: ControlReference(source: .hermesSession, sourceID: id),
                    kind: .completed,
                    title: "Previously reviewed item",
                    detail: "This item will return if Hermes reports it again.",
                    createdAt: Date.distantPast,
                    state: state,
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

                let cronResult = try await dockModel?.requestControl("cron.manage", params: ["action": "list"])
                if let cronResult { cronJobs = Self.parseCronJobs(cronResult) }

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
        guard let dockModel else { return }
        Task {
            do {
                _ = try await dockModel.requestControl("cron.manage", params: [
                    "action": enabled ? "resume" : "pause",
                    "job_id": job.id
                ])
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
                _ = try await dockModel.requestControl("session.activate", params: ["session_id": sessionID])
                dockModel.requestComposerFocus()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func respond(to item: AttentionItem, action: AttentionAction) {
        guard let dockModel else { return }
        let reference = item.reference
        Task {
            do {
                switch action {
                case .approve:
                    _ = try await dockModel.requestControl("approval.respond", params: ["session_id": reference.sessionID ?? "", "choice": "once"])
                case .deny:
                    _ = try await dockModel.requestControl("approval.respond", params: ["session_id": reference.sessionID ?? "", "choice": "deny"])
                case .stop:
                    _ = try await dockModel.requestControl("session.interrupt", params: ["session_id": reference.sessionID ?? reference.sourceID])
                case .resume:
                    _ = try await dockModel.requestControl("session.activate", params: ["session_id": reference.sessionID ?? reference.sourceID])
                case .open:
                    _ = try await dockModel.requestControl("session.activate", params: ["session_id": reference.sessionID ?? reference.sourceID])
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
            ?? "Hermes reported (type)."
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
                actions: [.open, .stop]
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
            guard entry.value.state == .dismissed || entry.value.state == .resolved else { return }
            result[entry.key] = entry.value.state.rawValue
        }
        presentationDefaults.set(values, forKey: presentationKey)
    }

    func rebuildAttention() {
        guard let dockModel else { return }
        var next: [AttentionItem] = []
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
        next = knownAttention.values.filter { saved in
            saved.state != .resolved && saved.state != .dismissed && !next.contains(where: { $0.id == saved.id })
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

}
