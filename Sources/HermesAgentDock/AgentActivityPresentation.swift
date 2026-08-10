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
        let id: String
        let timestamp: Date
        let status: String
        let task: String
        let agent: String
        let detail: String?
        let diffPreview: String?

        var isActive: Bool {
            let normalized = status
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_")
            return ["running", "in_progress", "inprogress", "pending", "queued"].contains(normalized)
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

    /// Canonical projection shared by the Agent Board pipeline and the chat's
    /// single latest-activity row.
    static func pipeline(
        activities: [AgentActivity],
        toolCalls: [ActiveToolCall],
        subagents: [HermesSubagent]
    ) -> [PipelineActivity] {
        var rows = activities.map { activity in
            let status = displayStatus(for: phase(for: activity.kind))
            var details = [activity.text]
            if let toolName = activity.toolName { details.append("Tool: \(toolName)") }
            if let handoffTarget = activity.handoffTarget { details.append("Handoff target: \(handoffTarget)") }
            return PipelineActivity(
                id: "activity:\(activity.id.uuidString)",
                timestamp: activity.timestamp,
                status: status,
                task: activity.text,
                agent: activity.agentID.flatMap { id in
                    subagents.first(where: { $0.id == id }).map { $0.name ?? $0.role ?? "Agent" }
                } ?? "Hermes",
                detail: details.joined(separator: "\n"),
                diffPreview: activity.diffPreview
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
                agent: "Hermes",
                detail: details.joined(separator: "\n"),
                diffPreview: call.diffPreview
            )
        })

        if !rows.isEmpty {
            return rows.sorted { $0.timestamp > $1.timestamp }
        }

        return subagents.map { agent in
            PipelineActivity(
                id: "agent:\(agent.id)",
                timestamp: agent.startedAt ?? .distantPast,
                status: agent.status,
                task: agent.goal,
                agent: agent.name ?? agent.role ?? "Agent",
                detail: agent.summary ?? agent.latestActivity ?? agent.goal,
                diffPreview: activities
                    .filter { $0.agentID == agent.id && $0.diffPreview != nil }
                    .sorted { $0.timestamp > $1.timestamp }
                    .first?.diffPreview
            )
        }
        .sorted { $0.timestamp > $1.timestamp }
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
