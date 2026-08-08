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

    func bind(to model: DockModel) {
        dockModel = model
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
                let reminderResult = try await dockModel?.requestControl("shell.exec", params: [
                    "command": "remindctl today --json"
                ])
                if let output = reminderResult?["stdout"] as? String {
                    reminders = Self.parseReminders(output)
                }

                let cronResult = try await dockModel?.requestControl("cron.manage", params: ["action": "list"])
                if let cronResult { cronJobs = Self.parseCronJobs(cronResult) }

                let tools = try await dockModel?.requestControl("tools.list", params: [:])
                let plugins = try await dockModel?.requestControl("plugins.list", params: [:])
                capabilities = Self.capabilities(remindersAvailable: reminderResult != nil, tools: tools, plugins: plugins)
            } catch {
                lastError = error.localizedDescription
                capabilities = Self.capabilities(remindersAvailable: false, tools: nil, plugins: nil)
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
    }

    func rebuildAttention() {
        guard let dockModel else { return }
        var next: [AttentionItem] = []
        if let approval = dockModel.approvalText, let sessionID = dockModel.sessionID {
            next.append(AttentionItem(
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
            next.append(AttentionItem(
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
        attention = next + knownAttention.values.filter { saved in
            saved.state != .resolved && !next.contains(where: { $0.id == saved.id })
        }
    }

    private static func parseReminders(_ output: String) -> [ReminderSummary] {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows: [[String: Any]]
        if let array = object as? [[String: Any]] {
            rows = array
        } else if let dictionary = object as? [String: Any], let nested = dictionary["reminders"] as? [[String: Any]] {
            rows = nested
        } else {
            return []
        }
        return rows.compactMap { row in
            let id = (row["id"] as? String) ?? (row["identifier"] as? String)
            let title = (row["title"] as? String) ?? (row["name"] as? String)
            guard let id, let title, !title.isEmpty else { return nil }
            let due = (row["dueDate"] as? String).flatMap(Self.parseDate)
            return ReminderSummary(id: id, title: title, list: row["list"] as? String, dueDate: due, isOverdue: (row["isOverdue"] as? Bool) ?? false)
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
                nextRun: row["next_run"] as? String ?? row["nextRun"] as? String
            )
        }
    }

    private static func capabilities(remindersAvailable: Bool, tools: [String: Any]?, plugins: [String: Any]?) -> [CapabilityState] {
        let toolsAvailable = tools != nil
        let pluginsAvailable = plugins != nil
        return [
            CapabilityState(id: "reminders", title: "Apple Reminders", detail: remindersAvailable ? "Connected through remindctl" : "remindctl is unavailable or unauthorized", isAvailable: remindersAvailable, recovery: remindersAvailable ? nil : "Install remindctl and authorize Reminders access."),
            CapabilityState(id: "notes", title: "Apple Notes", detail: "Available through the Hermes apple-notes skill", isAvailable: true, recovery: nil),
            CapabilityState(id: "tools", title: "Hermes tools", detail: toolsAvailable ? "Tool catalogue available" : "Tool catalogue unavailable", isAvailable: toolsAvailable, recovery: toolsAvailable ? nil : "Reconnect Hermes and refresh."),
            CapabilityState(id: "plugins", title: "Hermes plugins", detail: pluginsAvailable ? "Plugin catalogue available" : "Plugin catalogue unavailable", isAvailable: pluginsAvailable, recovery: pluginsAvailable ? nil : "Reconnect Hermes and refresh."),
            CapabilityState(id: "calendar", title: "Calendar", detail: "No Hermes Calendar provider is configured", isAvailable: false, recovery: "Calendar integration is planned for a future provider.")
        ]
    }

    private static func parseDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
