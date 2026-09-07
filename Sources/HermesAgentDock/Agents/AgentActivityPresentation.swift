import Foundation

enum AgentActivityPhase: String, Equatable {
    case pending
    case running
    case complete
    case failed
    case interrupted
}

enum AgentActivityPresentation {
    struct PipelineActivity: Identifiable, Equatable {
        var id: String
        let timestamp: Date
        let status: String
        let task: String
        let agent: String
        let agentID: String?
        let parentAgentID: String?
        let childSessionID: String?
        let detail: String?
        let diffPreview: String?
        let startedAt: Date?
        let completedAt: Date?
        let durationSeconds: TimeInterval?

        init(
            id: String,
            timestamp: Date,
            status: String,
            task: String,
            agent: String,
            agentID: String? = nil,
            parentAgentID: String? = nil,
            childSessionID: String? = nil,
            detail: String?,
            diffPreview: String?,
            startedAt: Date? = nil,
            completedAt: Date? = nil,
            durationSeconds: TimeInterval? = nil
        ) {
            self.id = id
            self.timestamp = timestamp
            self.status = status
            self.task = task
            self.agent = agent
            self.agentID = agentID
            self.parentAgentID = parentAgentID
            self.childSessionID = childSessionID
            self.detail = detail
            self.diffPreview = diffPreview
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.durationSeconds = durationSeconds
        }

        var isActive: Bool {
            AgentActivityPresentation.isActiveStatus(status)
        }

        func elapsedDuration(at date: Date = Date()) -> TimeInterval? {
            if let durationSeconds {
                return max(0, durationSeconds)
            }
            guard let startedAt else { return nil }
            if let completedAt {
                return max(0, completedAt.timeIntervalSince(startedAt))
            }
            guard isActive else { return nil }
            return max(0, date.timeIntervalSince(startedAt))
        }
    }

    static func phase(for eventKind: String, isActive: Bool = true) -> AgentActivityPhase {
        let lower = eventKind.lowercased()
        if lower.contains("error") || lower.contains("fail") { return .failed }
        if lower.contains("interrupt") { return .interrupted }
        if lower.contains("complete") || lower.contains("finish") { return .complete }
        if lower.contains("queue") || lower.contains("spawn_requested") { return .pending }
        if lower.hasPrefix("subagent.") { return isActive ? .running : .pending }
        return isActive ? .running : .pending
    }

    static func displayStatus(for phase: AgentActivityPhase) -> String {
        switch phase {
        case .pending: return "Pending"
        case .running: return "Running"
        case .complete: return "Complete"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        }
    }

    /// Whether the current runtime still has work in flight. Historical
    /// activity is intentionally excluded: a completed delegation retains its
    /// `subagent.start` and tool records for the board, but must not keep the
    /// conversation's animated activity row on screen.
    static func hasActiveWork(toolCalls: [ActiveToolCall], subagents: [HermesSubagent]) -> Bool {
        toolCalls.contains(where: { !$0.isComplete }) ||
            subagents.contains(where: { isActiveStatus($0.status) })
    }

    static func isActiveStatus(_ status: String) -> Bool {
        let normalized = status
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return ["running", "working", "in_progress", "inprogress", "pending", "queued", "starting", "active"].contains(normalized)
    }

    /// Canonical projection shared by the Agent Board pipeline and the chat's
    /// single latest-activity row.
    static func pipeline(
        activities: [AgentActivity],
        toolCalls: [ActiveToolCall],
        subagents: [HermesSubagent]
    ) -> [PipelineActivity] {
        // Restored or reconciled agent lists can briefly carry the same id
        // twice; uniqueKeysWithValues would fatally crash on that.
        var agentByID: [String: HermesSubagent] = [:]
        for agent in subagents where agentByID[agent.id] == nil {
            agentByID[agent.id] = agent
        }
        var rows = activities.map { activity in
            let activityPhase = phase(for: activity.kind)
            let currentAgentStatus = activity.agentID.flatMap { agentByID[$0]?.status }
            // Activity rows are historical, but a terminal agent state is the
            // authoritative lifecycle result. Without this override an old
            // `subagent.start` row remains labelled Running forever after that
            // worker completes.
            let status: String
            if activityPhase == .running,
               let currentAgentStatus,
               !isActiveStatus(currentAgentStatus) {
                status = currentAgentStatus
            } else {
                status = displayStatus(for: activityPhase)
            }
            var details = [activity.text]
            if let toolName = activity.toolName { details.append("Tool: \(toolName)") }
            if let handoffTarget = activity.handoffTarget { details.append("Handoff target: \(handoffTarget)") }
            return PipelineActivity(
                id: "activity:\(activity.id.uuidString)",
                timestamp: activity.timestamp,
                status: status,
                task: activityTitle(for: activity),
                agent: activity.agentID.flatMap { agentByID[$0].map { agentLabel(name: $0.name, role: $0.role) } } ?? "Hermes",
                agentID: activity.agentID,
                parentAgentID: activity.parentAgentID,
                childSessionID: activity.childSessionID,
                detail: details.joined(separator: "\n"),
                diffPreview: activity.diffPreview,
                startedAt: nil,
                completedAt: nil
            )
        }

        rows.append(contentsOf: toolCalls.map { call in
            var details = [call.input.isEmpty ? call.name : "Input: \(call.input)"]
            if let result = call.result, !result.isEmpty { details.append("Result: \(result)") }
            return PipelineActivity(
                id: "tool:\(call.id)",
                timestamp: call.completedAt ?? call.startedAt,
                status: call.isComplete ? "Complete" : "Running",
                task: toolActivityTitle(name: call.name, context: call.context),
                agent: call.agentID.flatMap { agentByID[$0].map { agentLabel(name: $0.name, role: $0.role) } } ?? "Orchestrator",
                agentID: call.agentID,
                parentAgentID: call.parentAgentID,
                childSessionID: call.childSessionID,
                detail: details.joined(separator: "\n"),
                diffPreview: call.diffPreview,
                startedAt: call.startedAt,
                completedAt: call.completedAt
            )
        })

        if !rows.isEmpty {
            // ForEach and the expand toggles key on row id; duplicate ids crash
            // SwiftUI diffing, so later duplicates get a disambiguated id.
            var seen = Set<String>()
            return rows
                .map { row -> PipelineActivity in
                    guard !seen.insert(row.id).inserted else { return row }
                    var occurrence = 2
                    var candidate = "\(row.id)#\(occurrence)"
                    while seen.contains(candidate) {
                        occurrence += 1
                        candidate = "\(row.id)#\(occurrence)"
                    }
                    seen.insert(candidate)
                    var unique = row
                    unique.id = candidate
                    return unique
                }
                .sorted { $0.timestamp > $1.timestamp }
        }

        var seenAgents = Set<String>()
        return subagents
            .filter { seenAgents.insert($0.id).inserted }
            .map { agent in
            PipelineActivity(
                id: "agent:\(agent.id)",
                timestamp: agent.startedAt ?? .distantPast,
                status: agent.status,
                task: agent.goal,
                agent: agentLabel(name: agent.name, role: agent.role),
                agentID: agent.id,
                parentAgentID: agent.parentID,
                childSessionID: agent.childSessionID,
                detail: agent.summary ?? agent.latestActivity ?? agent.goal,
                diffPreview: activities
                    .filter { $0.agentID == agent.id && $0.diffPreview != nil }
                    .sorted { $0.timestamp > $1.timestamp }
                    .first?.diffPreview,
                startedAt: agent.startedAt,
                completedAt: agent.completedAt,
                durationSeconds: agent.durationSeconds
            )
        }
        .sorted { $0.timestamp > $1.timestamp }
    }

    /// Role inference is helpful for generic delegates, but it is not a Bot
    /// identity. Make that boundary visible rather than turning a skill-like
    /// label such as "Security" into an apparently named agent.
    private static func agentLabel(name: String?, role: String?) -> String {
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRole = role?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMeaningfulName = cleanName.map { !$0.isEmpty && $0.caseInsensitiveCompare("agent") != .orderedSame } ?? false
        if hasMeaningfulName,
           cleanName?.caseInsensitiveCompare(cleanRole ?? "") != .orderedSame {
            return cleanName!
        }
        if let cleanRole, !cleanRole.isEmpty {
            return "Unprofiled Delegate · \(cleanRole)"
        }
        return "Unprofiled Delegate"
    }

    /// Converts a raw agent event into the same operator-friendly activity
    /// title used by the pipeline. This keeps map cards and pipeline rows in
    /// sync instead of letting a card fall back to a generic lifecycle label.
    static func activityTitle(for activity: AgentActivity) -> String {
        let text = compact(activity.text)
        guard let toolName = activity.toolName, !toolName.isEmpty else {
            return text
        }

        let normalizedTool = toolName.lowercased().replacingOccurrences(of: "-", with: "_")
        let normalizedText = text.lowercased().replacingOccurrences(of: "-", with: "_")
        let context = normalizedText == normalizedTool ? "" : text
        return toolActivityTitle(name: toolName, context: context)
    }

    static func conversationTitle(
        latestPipelineActivity: PipelineActivity?,
        recentEvents: [AgentEvent]
    ) -> String {
        let latestStatusEvent = recentEvents.last(where: isConversationStatusEvent)
        let pipelineTimestamp = latestPipelineActivity?.timestamp ?? .distantPast

        if let latestStatusEvent,
           latestStatusEvent.timestamp > pipelineTimestamp,
           ["reasoning.delta", "thinking.delta"].contains(latestStatusEvent.type.lowercased()) {
            return "Thinking"
        }

        if let task = latestPipelineActivity?.task.trimmingCharacters(in: .whitespacesAndNewlines),
           !task.isEmpty {
            return task
        }

        switch latestStatusEvent?.type.lowercased() {
        case "reasoning.delta", "thinking.delta":
            return "Thinking"
        case "message.delta", "message.interim":
            return "Responding"
        case "reasoning.start", "thinking":
            return "Preparing reasoning"
        case "reasoning.complete", "thinking.stop", "thinking.complete":
            return "Preparing next step"
        default:
            return "Starting response"
        }
    }

    private static func isConversationStatusEvent(_ event: AgentEvent) -> Bool {
        let type = event.type.lowercased()
        return type.hasPrefix("tool.") ||
            type == "tool_use" ||
            type == "tool_result" ||
            type.contains("reason") ||
            type.contains("think") ||
            type.hasPrefix("message.") ||
            type.hasPrefix("approval.") ||
            type == "error"
    }

    static func toolActivityTitle(name: String, context: String) -> String {
        let normalizedName = name.lowercased().replacingOccurrences(of: "-", with: "_")
        let cleanContext = compact(context)

        switch normalizedName {
        case "terminal", "shell", "exec", "exec_command":
            let command = commandWithoutEnvironmentAssignments(cleanContext)
            return command.isEmpty ? "Run command" : "Run \(command)"
        case "patch", "apply_patch", "edit_file", "write_file":
            return cleanContext.isEmpty ? "Edit files" : "Edit \(cleanContext)"
        case "read_file":
            return cleanContext.isEmpty ? "Read file" : "Read \(cleanContext)"
        case "search_files", "search", "grep":
            return cleanContext.isEmpty ? "Search files" : "Search \(cleanContext)"
        case "view_image":
            return cleanContext.isEmpty ? "Inspect image" : "Inspect \(cleanContext)"
        default:
            let label = normalizedName
                .split(separator: "_")
                .map { $0.capitalized }
                .joined(separator: " ")
            return cleanContext.isEmpty ? label : "\(label): \(cleanContext)"
        }
    }

    private static func compact(_ value: String) -> String {
        let singleLine = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(singleLine.prefix(140))
    }

    private static func commandWithoutEnvironmentAssignments(_ command: String) -> String {
        let pattern = #"^(?:[A-Za-z_][A-Za-z0-9_]*=(?:'[^']*'|"[^"]*"|\S+)\s*)+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return command }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        return expression.stringByReplacingMatches(in: command, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
