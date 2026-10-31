import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    func startDelegationMonitoring() {
        delegationMonitoringTask?.cancel()
        guard sessionID != nil else { return }
        delegationMonitoringTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let hasLiveWorkers =
                    self.activeSubagents.contains { AgentActivityPresentation.isActiveStatus($0.status) }
                    || self.sessionAgents.contains { AgentActivityPresentation.isActiveStatus($0.status) }
                    || self.status == .working
                let interval: Duration = hasLiveWorkers ? .seconds(3) : .seconds(15)
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, self.sessionID != nil else { return }
                self.refreshDelegationStatus()
            }
        }
    }

    func refreshDelegationStatus() {
        guard sessionID != nil else { return }
        delegationRefreshRequested = true
        if isRefreshingDelegationStatus { return }
        guard delegationRefreshTask == nil else { return }
        let delay = max(0, 0.25 - Date().timeIntervalSince(lastDelegationRefreshAt))
        delegationRefreshTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.delegationRefreshTask = nil
            self.delegationRefreshRequested = false
            self.lastDelegationRefreshAt = Date()
            self.performDelegationStatusRefresh()
        }
    }

    func performDelegationStatusRefresh() {
        guard !isRefreshingDelegationStatus else { return }
        guard let expectedSessionID = sessionID, !expectedSessionID.isEmpty else { return }
        isRefreshingDelegationStatus = true
        Task {
            do {
                let result = try await gateway.request(
                    HermesFeatureIDs.ID.delegationStatus.rawValue,
                    params: ["session_id": expectedSessionID]
                )
                guard sessionID == expectedSessionID else { return }
                // Hermes can return global live workers even when a session is
                // supplied. An unscoped worker must never animate in the
                // current conversation; showing no activity is safer than
                // attributing another session's work to this one.
                let rows = (result["active"] as? [[String: Any]] ?? []).filter {
                    Self.delegationStatusRow($0, belongsTo: expectedSessionID)
                }
                let projections = rows.compactMap { row -> (row: [String: Any], agent: HermesSubagent)? in
                    guard row["subagent_id"] is String,
                        let agent = self.telemetry(from: row, fallbackStatus: "running")
                    else { return nil }
                    return (row, agent)
                }
                for projection in projections {
                    self.reconcileSyntheticPlaceholder(for: projection.agent)
                    self.recordTelemetryActivityIfChanged(row: projection.row, agent: projection.agent)
                }
                // `active` is Hermes' live-worker projection. Do not retain a
                // native worker after it disappears from this response: doing
                // so leaves a finished agent permanently shown as running.
                // Session history remains in sessionAgents; only locally
                // synthesized placeholders survive until Hermes identifies
                // their native worker ID.
                let rpcAgents = projections.map(\.agent)
                for agent in rpcAgents { upsertSessionAgent(agent) }
                activeSubagents = Self.reconciledLiveAgents(
                    authoritative: rpcAgents.filter { AgentActivityPresentation.isActiveStatus($0.status) },
                    current: activeSubagents,
                    synthesizedIDs: synthesizedSubagentIDs
                )
                cacheCurrentAgentState()
            } catch {
                DebugLog.write(
                    "workspace: delegation status failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
            self.isRefreshingDelegationStatus = false
            if self.delegationRefreshRequested {
                self.refreshDelegationStatus()
            }
        }
    }

    static func isTerminalAgentStatus(_ status: String) -> Bool {
        let lower = status.lowercased()
        return lower.contains("complete") || lower.contains("done") || lower.contains("finish")
            || lower.contains("error") || lower.contains("fail") || lower.contains("interrupt")
    }

    static func delegationStatusRow(_ row: [String: Any], belongsTo sessionID: String) -> Bool {
        guard !sessionID.isEmpty else { return false }
        // Current Hermes registry rows use owner_agent_session_id. The other
        // names are retained only for older gateways that exposed an explicit
        // session owner. `parent_id` is a subagent ID, never a session owner.
        for key in ["owner_agent_session_id", "parent_session_id", "root_session_id", "session_id"] {
            if (row[key] as? String) == sessionID { return true }
        }
        for key in ["parent", "session", "context"] {
            guard let nested = row[key] as? [String: Any] else { continue }
            for sessionKey in ["session_id", "id"] where (nested[sessionKey] as? String) == sessionID {
                return true
            }
        }
        return false
    }

    /// Builds the visible live-worker list from an authoritative Hermes
    /// response. Completed workers remain in session history, not this list.
    static func reconciledLiveAgents(
        authoritative: [HermesSubagent],
        current: [HermesSubagent],
        synthesizedIDs: Set<String>
    ) -> [HermesSubagent] {
        let authoritativeIDs = Set(authoritative.map(\.id))
        let pendingPlaceholders = current.filter {
            synthesizedIDs.contains($0.id) && !authoritativeIDs.contains($0.id)
        }
        return authoritative + pendingPlaceholders
    }

    static func agentStatus(current: String, eventType: String, reportedStatus: String? = nil) -> String {
        let normalizedType = eventType.lowercased()
        let reportedStatus = canonicalAgentStatus(reportedStatus)
        let eventStatus: String? =
            switch normalizedType {
            case "subagent.spawn_requested": "queued"
            case "subagent.start", "subagent.tool", "subagent.progress", "subagent.thinking": "running"
            case "subagent.complete", "subagent.completed", "subagent.done", "subagent.finished", "subagent.finish":
                "complete"
            case "subagent.error", "subagent.failed", "subagent.fail": "error"
            case "subagent.interrupt", "subagent.interrupted": "interrupted"
            default: nil
            }
        let nextStatus = reportedStatus ?? eventStatus
        guard let nextStatus else { return current }
        if isTerminalAgentStatus(current), !isTerminalAgentStatus(nextStatus) { return current }
        return nextStatus
    }

    /// Hermes has used both lifecycle event names and status fields for agent
    /// completion. Normalize the latter before it reaches presentation state so
    /// a completed worker cannot remain visually running after a status update.
    static func canonicalAgentStatus(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        if normalized.contains("complete") || normalized.contains("done") || normalized.contains("finish")
            || normalized.contains("success")
        {
            return "complete"
        }
        if normalized.contains("interrupt") || normalized.contains("cancel") || normalized.contains("abort") {
            return "interrupted"
        }
        if normalized.contains("error") || normalized.contains("fail") { return "error" }
        if normalized.contains("block") { return "blocked" }
        if normalized.contains("queue") || normalized.contains("pending") || normalized.contains("wait") {
            return "queued"
        }
        if normalized.contains("run") || normalized.contains("work") || normalized.contains("active")
            || normalized.contains("start")
        {
            return "running"
        }
        return normalized
    }

    static func eventBelongsToSession(
        type: String,
        envelopeSessionID: String?,
        eventSessionID: String?,
        payload: [String: Any],
        currentSessionID: String,
        agents: [HermesSubagent]
    ) -> Bool {
        guard !currentSessionID.isEmpty else { return false }
        let payloadSessionID = payload["session_id"] as? String

        // If both the event envelope and payload claim a session, they must
        // agree. Treat conflicting attribution as untrusted rather than
        // silently preferring either source.
        if let envelopeSessionID, !envelopeSessionID.isEmpty,
            let payloadSessionID, !payloadSessionID.isEmpty,
            envelopeSessionID != payloadSessionID
        {
            return false
        }

        if eventSessionID == currentSessionID {
            // A parent-session event may declare its parent explicitly, but it
            // may not smuggle in a different parent identity.
            if let parentSessionID = payload["parent_session_id"] as? String,
                parentSessionID != currentSessionID
            {
                return false
            }
            return true
        }

        // A delegated worker has its own child session, but its activity still
        // belongs to the parent session currently shown by the Dock. Require
        // the envelope child identity itself to match a current child agent,
        // and reject every contradictory supplied identifier.
        guard type.hasPrefix("subagent."),
            let envelopeSessionID, !envelopeSessionID.isEmpty,
            let eventSessionID, eventSessionID == envelopeSessionID
        else {
            return false
        }
        if let parentSessionID = payload["parent_session_id"] as? String,
            parentSessionID != currentSessionID
        {
            return false
        }
        if let childSessionID = payload["child_session_id"] as? String,
            !childSessionID.isEmpty,
            childSessionID != envelopeSessionID
        {
            return false
        }
        return agents.contains { $0.childSessionID == envelopeSessionID }
    }

    /// Resolves both native subagent IDs and the child session IDs used by
    /// ordinary events emitted from inside a delegated worker.
    static func agentID(
        explicitAgentID: String?,
        eventSessionID: String?,
        childSessionID: String? = nil,
        goal: String? = nil,
        taskIndex: Int? = nil,
        agents: [HermesSubagent]
    ) -> String? {
        if let explicitAgentID, !explicitAgentID.isEmpty { return explicitAgentID }
        for sessionReference in [childSessionID, eventSessionID].compactMap({ $0 }) where !sessionReference.isEmpty {
            if let match = agents.first(where: {
                $0.id == sessionReference || $0.childSessionID == sessionReference
            }) {
                return match.id
            }
        }
        if let goal {
            let normalizedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matches = agents.filter {
                $0.goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedGoal
            }
            if matches.count == 1 { return matches[0].id }
        }
        if let taskIndex {
            let suffix = ":\(taskIndex)"
            let matches = agents.filter { $0.id.hasSuffix(suffix) }
            if matches.count == 1 { return matches[0].id }
        }
        return nil
    }

    static func agentActivityPayload(_ payload: [String: Any], resolvedAgentID: String?) -> [String: Any] {
        guard payload["subagent_id"] == nil, let resolvedAgentID else { return payload }
        var attributed = payload
        attributed["subagent_id"] = resolvedAgentID
        return attributed
    }

    /// Canonical boundary between raw Hermes JSON-RPC envelopes and the
    /// per-agent activity model consumed by both the map and pipeline.
    static func agentActivityProjection(
        type: String,
        params: [String: Any],
        currentSessionID: String?,
        agents: [HermesSubagent]
    ) -> AgentActivityEnvelopeProjection? {
        let rawPayload = params["payload"] as? [String: Any] ?? [:]
        let eventSessionID = (params["session_id"] as? String) ?? (rawPayload["session_id"] as? String)
        let explicitAgentID =
            (rawPayload["subagent_id"] as? String)
            ?? (params["subagent_id"] as? String)
            ?? (rawPayload["agent_id"] as? String)
            ?? (params["agent_id"] as? String)
        let childSessionID =
            (rawPayload["child_session_id"] as? String)
            ?? (params["child_session_id"] as? String)
        let resolvedAgentID = agentID(
            explicitAgentID: explicitAgentID,
            eventSessionID: eventSessionID,
            childSessionID: childSessionID,
            goal: rawPayload["goal"] as? String,
            taskIndex: (rawPayload["task_index"] as? NSNumber)?.intValue,
            agents: agents
        )
        let parentSessionID =
            (rawPayload["parent_id"] as? String)
            ?? (rawPayload["parent_session_id"] as? String)

        if type.hasPrefix("subagent.") {
            let isKnownAgent = resolvedAgentID.map { id in agents.contains(where: { $0.id == id }) } ?? false
            guard
                eventSessionID == nil || eventSessionID == currentSessionID
                    || parentSessionID == currentSessionID || isKnownAgent
            else { return nil }
            return AgentActivityEnvelopeProjection(
                kind: type,
                payload: agentActivityPayload(rawPayload, resolvedAgentID: resolvedAgentID),
                consumesParentEvent: false
            )
        }

        guard let resolvedAgentID,
            isAgentScopedActivity(
                eventAgentID: resolvedAgentID,
                eventSessionID: eventSessionID,
                parentSessionID: parentSessionID,
                currentSessionID: currentSessionID,
                agents: agents
            ),
            let activityKind = agentActivityKind(for: type)
        else { return nil }
        return AgentActivityEnvelopeProjection(
            kind: activityKind,
            payload: agentActivityPayload(rawPayload, resolvedAgentID: resolvedAgentID),
            consumesParentEvent: true
        )
    }

    /// The parent delegation call can carry a future subagent ID while still
    /// belonging to the current session. It must reach the normal tool handler
    /// so the agent card is created. Only known workers or events explicitly
    /// attached to a child session are diverted into agent activity history.
    static func isAgentScopedActivity(
        eventAgentID: String,
        eventSessionID: String?,
        parentSessionID: String?,
        currentSessionID: String?,
        agents: [HermesSubagent]
    ) -> Bool {
        if agents.contains(where: { $0.id == eventAgentID }) { return true }
        guard let currentSessionID else { return false }
        return parentSessionID == currentSessionID && eventSessionID != currentSessionID
    }

    /// Stream deltas are intentionally omitted: one row per token would drown
    /// out the useful activity. Lifecycle boundaries and complete tool actions
    /// remain visible.
    static func agentActivityKind(for eventType: String) -> String? {
        switch eventType.lowercased() {
        case "tool.call", "tool.start", "tool.use", "tool_use":
            return "subagent.tool"
        case "tool.result", "tool_result", "tool.complete", "tool_complete":
            return "subagent.tool.complete"
        case "reasoning.start", "thinking":
            return "subagent.thinking"
        case "reasoning.complete", "thinking.stop", "thinking.complete":
            return "subagent.thinking.complete"
        case "message.complete":
            // Delegated workers commonly finish through their child session's
            // ordinary response boundary rather than a separate
            // `subagent.complete` envelope. This method is reached only after
            // the event is proven agent-scoped, so the parent conversation's
            // own message completion is unaffected.
            return "subagent.complete"
        case "error":
            return "subagent.error"
        case "message.delta", "reasoning.delta", "thinking.delta":
            return nil
        default:
            return nil
        }
    }

    static func inferRole(from title: String) -> String? {
        let lower = title.lowercased()
        let roles: [(needle: String, label: String)] = [
            ("quality assurance", "QA"), ("security reviewer", "Security Reviewer"),
            ("frontend", "Frontend"), ("front-end", "Frontend"),
            ("backend", "Backend"), ("back-end", "Backend"),
            ("security", "Security"), ("qa", "QA"),
            ("planner", "Planner"), ("implementer", "Implementer"),
            ("reviewer", "Reviewer"), ("verifier", "Verifier"),
            ("investigator", "Investigator"), ("researcher", "Researcher"),
            ("tester", "Tester"), ("testing", "QA"), ("architect", "Architect"),
        ]
        for role in roles where lower.contains(role.needle) {
            return role.label
        }
        return nil
    }

    /// Converts one Hermes `delegate_task` call into the semantic workers the
    /// call represents. Batch delegation is one tool call but many agents, so
    /// the tool-call ID alone is not a sufficient row identity.
    static func projectedDelegationAgents(toolCallID: String, args: [String: Any], startedAt: Date) -> [HermesSubagent]
    {
        let taskRows = args["tasks"] as? [[String: Any]]
        // `delegate_task(action: "list" | "stop" | …)` manages existing workers; it starts none.
        if taskRows == nil, let action = args["action"] as? String,
            !["spawn", "start", "create", "delegate", "run"].contains(action.lowercased())
        {
            return []
        }
        let rows = taskRows?.isEmpty == false ? taskRows! : [args]

        return rows.enumerated().map { index, task in
            func value(_ keys: [String]) -> String? {
                for source in [task, args] {
                    for key in keys {
                        guard let raw = source[key] as? String else { continue }
                        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty { return clean }
                    }
                }
                return nil
            }

            let goal =
                value(["goal", "description", "prompt", "task", "instructions", "title"])
                ?? "Delegated agent"
            let orchestrationRole = value(["role"])
            let humanRole =
                value(["agent_role", "role_label", "specialty", "agent_type"])
                ?? orchestrationRole.flatMap { role in
                    ["leaf", "orchestrator"].contains(role.lowercased()) ? nil : role
                }
                ?? inferRole(from: goal)
            let name = value(["name", "agent_name", "display_name", "label"]) ?? humanRole
            let id = rows.count == 1 ? toolCallID : "\(toolCallID):\(index)"

            return HermesSubagent(
                id: id,
                name: name,
                childSessionID: value(["session_id", "child_session_id"]),
                goal: goal,
                role: humanRole,
                sourceSkill: value(["source_skill", "skill", "workflow"]),
                status: "running",
                model: value(["model"]),
                startedAt: startedAt,
                latestActivity: goal
            )
        }
    }

    static func isBackgroundDelegationDispatch(_ result: String) -> Bool {
        guard let data = result.data(using: .utf8),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        let status = (payload["status"] as? String)?.lowercased()
        let mode = (payload["mode"] as? String)?.lowercased()
        return status == "dispatched" || mode == "background"
    }

    nonisolated static func truncatedForPersistence(_ value: String) -> String {
        // O(1) exit for the common short payload: a String never has more characters than UTF-8 bytes.
        guard value.utf8.count > toolPayloadPersistenceLimit else { return value }
        let prefix = value.prefix(toolPayloadPersistenceLimit)
        guard prefix.endIndex < value.endIndex else { return value }
        // Counting the dropped tail's Characters walked megabytes of tool output per re-read.
        return "\(prefix)\n… [truncated \(value.utf8.count - prefix.utf8.count) bytes]"
    }

    static func eventText(_ value: Any?) -> String {
        if let value = value as? String { return value }
        guard let value,
            JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    /// Extract only Hermes' stable Kanban identifiers. This deliberately does
    /// not attribute a card from conversational prose, profile names, titles,
    /// or assignees; callers must first establish a trusted tool-event and
    /// session boundary.
    /// A tool event naming exactly one card refers to it. One naming several
    /// is a listing (or a card body citing others) and attributes nothing.
    static func kanbanCardReference(in text: String) -> String? {
        let ids = kanbanTaskIDs(in: text)
        return ids.count == 1 ? ids.first : nil
    }

    /// IDs a `kanban <verb> <id>` command targets (never `list`).
    static func kanbanCommandReferences(in text: String) -> Set<String> {
        let pattern = #"(?i)\bkanban[ _-]+(?!list\b)[a-z-]+[ \t]+(t_[A-Za-z0-9][A-Za-z0-9_]*)\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set(
            expression.matches(in: text, range: range).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            })
    }

    static func kanbanTaskIDs(in text: String) -> Set<String> {
        let pattern = #"\bt_[A-Za-z0-9][A-Za-z0-9_]*\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        // Serialized payloads escape newlines; `\nt_ab12` must still split.
        let text = text.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\t", with: " ")
        let range = NSRange(text.startIndex..., in: text)
        return Set(
            expression.matches(in: text, range: range).compactMap {
                Range($0.range, in: text).map { String(text[$0]) }
            })
    }

    /// Hermes emits `inline_diff` for edit tool completions. Some adapters use
    /// `diff`, `patch`, or place the patch in a subagent output tail, so accept
    /// those shapes while refusing ordinary tool output.
    static func diffPreview(from payload: [String: Any]) -> String? {
        for key in ["inline_diff", "diff_preview", "diff", "patch"] {
            if let preview = normalizedDiff(payload[key] as? String, requireMarkers: false) {
                return preview
            }
        }
        if let result = payload["result"] as? [String: Any] {
            for key in ["inline_diff", "diff_preview", "diff", "patch"] {
                if let preview = normalizedDiff(result[key] as? String, requireMarkers: false) {
                    return preview
                }
            }
        }
        if let tail = payload["output_tail"] as? [[String: Any]] {
            for entry in tail.reversed() {
                if let preview = normalizedDiff(entry["preview"] as? String, requireMarkers: true) {
                    return preview
                }
            }
        }
        return nil
    }

    static func normalizedDiff(_ raw: String?, requireMarkers: Bool) -> String? {
        guard let raw else { return nil }
        let clean = HermesRuntimeInspector.stripANSI(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if requireMarkers {
            let lines = clean.split(separator: "\n", omittingEmptySubsequences: false)
            let hasMarkers = lines.contains {
                $0.hasPrefix("+") || $0.hasPrefix("-") || $0.hasPrefix("@@") || $0.hasPrefix("diff --git")
            }
            guard hasMarkers else { return nil }
        }
        return String(clean.prefix(4_000))
    }

    func telemetry(from row: [String: Any], fallbackStatus: String? = nil) -> HermesSubagent? {
        guard let id = row["subagent_id"] as? String else { return nil }
        let goal = row["goal"] as? String ?? "Hermes subagent"
        let rawRole =
            (row["agent_role"] as? String)
            ?? (row["role_label"] as? String)
            ?? (row["role"] as? String)
        let role =
            rawRole.flatMap { value in
                ["leaf", "orchestrator"].contains(value.lowercased()) ? nil : value
            } ?? Self.inferRole(from: goal)
        return HermesSubagent(
            id: id,
            name: (row["name"] as? String) ?? (row["agent_name"] as? String) ?? (row["display_name"] as? String)
                ?? role,
            parentID: (row["parent_subagent_id"] as? String)
                ?? (row["parent_agent_id"] as? String)
                    ?? (row["parent_id"] as? String)
                        ?? (row["parent_session_id"] as? String),
            childSessionID: (row["child_session_id"] as? String)
                ?? (row["session_id"] as? String),
            depth: (row["depth"] as? NSNumber)?.intValue ?? 0,
            goal: goal,
            role: role,
            sourceSkill: row["source_skill"] as? String,
            status: Self.canonicalAgentStatus(row["status"] as? String) ?? fallbackStatus ?? "unknown",
            model: row["model"] as? String,
            startedAt: dateValue(row["started_at"]),
            completedAt: dateValue(row["completed_at"]),
            durationSeconds: (row["duration_seconds"] as? NSNumber)?.doubleValue,
            toolCount: (row["tool_count"] as? NSNumber)?.intValue ?? 0,
            latestActivity: (row["tool_preview"] as? String)
                ?? (row["text"] as? String)
                    ?? (row["last_tool"] as? String),
            summary: row["summary"] as? String,
            inputTokens: (row["input_tokens"] as? NSNumber)?.intValue,
            outputTokens: (row["output_tokens"] as? NSNumber)?.intValue,
            reasoningTokens: (row["reasoning_tokens"] as? NSNumber)?.intValue,
            apiCalls: (row["api_calls"] as? NSNumber)?.intValue,
            filesRead: row["files_read"] as? [String] ?? [],
            filesWritten: row["files_written"] as? [String] ?? []
        )
    }

    func mergeAgentEvent(_ type: String, payload: [String: Any]) {
        guard let id = payload["subagent_id"] as? String else { return }
        var agent =
            sessionAgents.first(where: { $0.id == id })
            ?? activeSubagents.first(where: { $0.id == id })
            ?? HermesSubagent(id: id, goal: payload["goal"] as? String ?? "Hermes subagent", status: "running")
        if let hydrated = telemetry(from: payload.merging(["subagent_id": id]) { current, _ in current }) {
            agent.name = hydrated.name ?? agent.name
            agent.parentID = hydrated.parentID ?? agent.parentID
            agent.childSessionID = hydrated.childSessionID ?? agent.childSessionID
            agent.depth = hydrated.depth
            if !hydrated.goal.isEmpty && hydrated.goal != "Hermes subagent" { agent.goal = hydrated.goal }
            agent.role = hydrated.role ?? agent.role
            agent.sourceSkill = hydrated.sourceSkill ?? agent.sourceSkill
            agent.model = hydrated.model ?? agent.model
            agent.toolCount = max(agent.toolCount, hydrated.toolCount)
            agent.startedAt = hydrated.startedAt ?? agent.startedAt
            agent.durationSeconds = hydrated.durationSeconds ?? agent.durationSeconds
            agent.summary = hydrated.summary ?? agent.summary
            agent.inputTokens = hydrated.inputTokens ?? agent.inputTokens
            agent.outputTokens = hydrated.outputTokens ?? agent.outputTokens
            agent.reasoningTokens = hydrated.reasoningTokens ?? agent.reasoningTokens
            agent.apiCalls = hydrated.apiCalls ?? agent.apiCalls
            agent.filesRead = hydrated.filesRead.isEmpty ? agent.filesRead : hydrated.filesRead
            agent.filesWritten = hydrated.filesWritten.isEmpty ? agent.filesWritten : hydrated.filesWritten
        }
        let previousStatus = agent.status
        agent.status = Self.agentStatus(
            current: agent.status,
            eventType: type,
            reportedStatus: (payload["status"] as? String) ?? (payload["state"] as? String)
        )
        if Self.isTerminalAgentStatus(agent.status) {
            agent.completedAt = dateValue(payload["completed_at"]) ?? Date()
            agent.durationSeconds = (payload["duration_seconds"] as? NSNumber)?.doubleValue ?? agent.durationSeconds
        }
        if let preview = payload["tool_preview"] as? String ?? payload["text"] as? String {
            agent.latestActivity = preview
        }
        if !Self.isTerminalAgentStatus(previousStatus), Self.isTerminalAgentStatus(agent.status),
            voiceState.isNativeConversationActive, voiceRepliesEnabled, voiceSessionID == sessionID
        {
            let outcome = agent.status == "complete" ? "finished" : "stopped with status \(agent.status)"
            voiceCompletionAnnouncements.append("\(agent.name ?? "Background agent") \(outcome).")
        }
        reconcileSyntheticPlaceholder(for: agent)
        upsertSessionAgent(agent)
        upsertActiveAgent(agent)
    }

    func upsertSessionAgent(_ agent: HermesSubagent) {
        if let index = sessionAgents.firstIndex(where: { $0.id == agent.id }) {
            sessionAgents[index] = agent
        } else {
            sessionAgents.append(agent)
        }
    }

    func upsertActiveAgent(_ agent: HermesSubagent) {
        if let index = activeSubagents.firstIndex(where: { $0.id == agent.id }) {
            activeSubagents[index] = agent
        } else {
            activeSubagents.append(agent)
        }
    }

    /// Native subagent events have a stable Hermes ID; synthesized rows only
    /// bridge the short gap before that first event. Remove the matching
    /// placeholder so a batch never renders both identities for one worker.
    func reconcileSyntheticPlaceholder(for nativeAgent: HermesSubagent) {
        guard !synthesizedSubagentIDs.contains(nativeAgent.id) else { return }
        let normalizedGoal = nativeAgent.goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedGoal.isEmpty, normalizedGoal != "hermes subagent" else { return }
        guard
            let placeholder = activeSubagents.first(where: {
                synthesizedSubagentIDs.contains($0.id)
                    && $0.goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedGoal
            })
        else { return }

        synthesizedSubagentIDs.remove(placeholder.id)
        activeSubagents.removeAll { $0.id == placeholder.id }
        sessionAgents.removeAll { $0.id == placeholder.id }
        agentActivities.removeAll { $0.agentID == placeholder.id }
    }

    static func isDelegationTool(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("delegate") || lower == "spawn" || lower == "spawn_agent"
            || lower == "launch_agent" || lower == "create_subagent" || lower == "dispatch_agent"
    }

    func synthesizeSubagent(
        toolCallID: String, args: [String: Any], startedAt: Date = Date(), timing: SessionTraceTiming = .observed
    ) {
        let agents = Self.projectedDelegationAgents(toolCallID: toolCallID, args: args, startedAt: startedAt)
        guard !agents.isEmpty, agents.contains(where: { !synthesizedSubagentIDs.contains($0.id) }) else { return }

        for agent in agents where !synthesizedSubagentIDs.contains(agent.id) {
            synthesizedSubagentIDs.insert(agent.id)
            upsertSessionAgent(agent)
            upsertActiveAgent(agent)
            agentActivities.append(
                AgentActivity(
                    id: UUID(),
                    timestamp: startedAt,
                    agentID: agent.id,
                    kind: "subagent.start",
                    text: agent.goal,
                    toolName: nil,
                    handoffTarget: nil,
                    traceTiming: timing
                ))
        }
        if agentActivities.count > 250 {
            agentActivities.removeFirst(agentActivities.count - 250)
        }
        DebugLog.write("model: synthesized \(agents.count) subagent row(s) for \(toolCallID)")
    }

    func refreshSynthesizedSubagents(toolCallID: String, args: [String: Any]) {
        let matchingIDs = synthesizedSubagentIDs.filter { $0 == toolCallID || $0.hasPrefix("\(toolCallID):") }
        guard !matchingIDs.isEmpty else { return }
        synthesizedSubagentIDs.subtract(matchingIDs)
        activeSubagents.removeAll { matchingIDs.contains($0.id) }
        sessionAgents.removeAll { matchingIDs.contains($0.id) }
        agentActivities.removeAll { activity in
            activity.agentID.map(matchingIDs.contains) == true
        }
        synthesizeSubagent(toolCallID: toolCallID, args: args)
    }

    func completeSynthesizedSubagent(
        toolCallID: String, result: String, payload: [String: Any], completedAt: Date? = nil,
        timing: SessionTraceTiming = .observed
    ) {
        // Modern Hermes returns immediately after background dispatch. Native
        // subagent.complete events, not this acknowledgement, own completion.
        guard !Self.isBackgroundDelegationDispatch(result) else { return }
        let sessionID = (payload["session_id"] as? String) ?? (payload["child_session_id"] as? String)
        let summary = result.isEmpty ? nil : String(result.prefix(400))
        let matchingIDs = synthesizedSubagentIDs.filter { $0 == toolCallID || $0.hasPrefix("\(toolCallID):") }
        for id in matchingIDs {
            guard let index = activeSubagents.firstIndex(where: { $0.id == id }) else { continue }
            activeSubagents[index].status = "complete"
            activeSubagents[index].completedAt = timing == .unavailable ? nil : completedAt ?? Date()
            if let sessionID { activeSubagents[index].childSessionID = sessionID }
            if let summary { activeSubagents[index].summary = summary }
            if let sessionIndex = sessionAgents.firstIndex(where: { $0.id == id }) {
                sessionAgents[sessionIndex] = activeSubagents[index]
            }
            agentActivities.append(
                AgentActivity(
                    id: UUID(),
                    timestamp: completedAt ?? Date(),
                    agentID: id,
                    kind: "subagent.complete",
                    text: summary ?? "Delegated agent finished",
                    toolName: nil,
                    handoffTarget: nil,
                    traceTiming: timing
                ))
        }
        if agentActivities.count > 250 {
            agentActivities.removeFirst(agentActivities.count - 250)
        }
        DebugLog.write("model: completed synthesized subagent \(toolCallID)")
    }

    func recordAgentActivity(_ type: String, params: [String: Any], payload: [String: Any]) {
        let agentID = payload["subagent_id"] as? String
        let toolName =
            (payload["tool_name"] as? String)
            ?? (payload["tool"] as? String)
            ?? (payload["name"] as? String)
        let text = Self.agentActivityText(type: type, payload: payload, toolName: toolName)
        agentActivities.append(
            AgentActivity(
                id: UUID(),
                timestamp: dateValue(params["timestamp"]) ?? dateValue(payload["timestamp"]) ?? Date(),
                agentID: agentID,
                kind: type,
                text: text,
                toolName: toolName,
                handoffTarget: payload["handoff_target"] as? String,
                diffPreview: Self.diffPreview(from: payload),
                parentAgentID: (payload["parent_id"] as? String) ?? (payload["parent_subagent_id"] as? String),
                childSessionID: payload["child_session_id"] as? String,
                traceCallID: (payload["tool_id"] ?? payload["tool_call_id"] ?? payload["tool_use_id"] ?? payload["id"])
                    as? String,
                traceTiming: (dateValue(params["timestamp"]) ?? dateValue(payload["timestamp"])) != nil
                    ? .runtime : params["herm_trace_replayed"] as? Bool == true ? .unavailable : .observed,
                traceDuration: SessionTraceProjection.measuredDuration(payload["duration_s"]),
                traceOutcome: SessionTraceProjection.outcome(payload["result"] ?? payload["output"])
            ))
        if agentActivities.count > 250 { agentActivities.removeFirst(agentActivities.count - 250) }
    }

    static func agentActivityText(type: String, payload: [String: Any], toolName: String?) -> String {
        for key in ["tool_preview", "text", "summary", "message", "description", "question"] {
            if let text = payload[key] as? String,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return text
            }
        }
        for key in ["result", "output", "arguments", "input", "args"] {
            let text = eventText(payload[key])
            if !text.isEmpty { return toolName.map { "\($0): \(text)" } ?? text }
        }
        if let toolName, !toolName.isEmpty { return toolName }
        return type.replacingOccurrences(of: "subagent.", with: "").uppercased()
    }

    func recordTelemetryActivityIfChanged(row: [String: Any], agent: HermesSubagent) {
        let previousAgent =
            sessionAgents.first(where: { $0.id == agent.id })
            ?? activeSubagents.first(where: { $0.id == agent.id })
        guard
            let projection = Self.telemetryActivityProjection(
                row: row,
                agent: agent,
                previous: previousAgent
            )
        else {
            return
        }
        recordAgentActivity(projection.kind, params: [:], payload: projection.payload)
    }

    /// `delegation.status` exposes the latest child action as `last_tool`, not
    /// the `tool_preview` field used by streamed subagent events. Normalize the
    /// snapshot into the same agent-owned activity envelope. An increasing
    /// tool count is significant even when the child invokes the same tool
    /// repeatedly.
    static func telemetryActivityProjection(
        row: [String: Any],
        agent: HermesSubagent,
        previous: HermesSubagent?
    ) -> AgentActivityEnvelopeProjection? {
        let toolName = (row["tool_name"] as? String) ?? (row["last_tool"] as? String)
        let preview =
            (row["tool_preview"] as? String)
            ?? (row["text"] as? String)
            ?? toolName
        guard let preview,
            !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let toolCountAdvanced = agent.toolCount > (previous?.toolCount ?? 0)
        guard previous?.latestActivity != preview || toolCountAdvanced else { return nil }

        var payload = row
        payload["subagent_id"] = agent.id
        payload["text"] = preview
        if let toolName, !toolName.isEmpty {
            payload["tool_name"] = toolName
        }
        return AgentActivityEnvelopeProjection(
            kind: toolName?.isEmpty == false ? "subagent.tool" : "subagent.progress",
            payload: payload,
            consumesParentEvent: false
        )
    }
}
