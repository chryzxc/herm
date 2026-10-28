import Combine
import Foundation

extension ControlCenterModel {
    static func parseCronJobs(_ result: [String: Any]) -> [CronSummary] {
        let rows = (result["jobs"] as? [[String: Any]]) ?? (result["cron"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            let id = (row["job_id"] as? String) ?? (row["id"] as? String) ?? (row["name"] as? String)
            guard let id else { return nil }
            var editable: Set<CronEditField> = []
            if row["name"] as? String != nil { editable.insert(.name) }
            if row["schedule"] as? String != nil { editable.insert(.schedule) }
            if (row["prompt"] as? String) != nil || (row["request"] as? String) != nil
                || (row["task"] as? String) != nil
            {
                editable.insert(.prompt)
            }
            // `cron.manage list` only sends a truncated `prompt_preview`; it is display-only, not editable.
            let prompt =
                (row["prompt"] as? String) ?? (row["request"] as? String) ?? (row["task"] as? String)
                ?? (row["prompt_preview"] as? String)
            return CronSummary(
                id: id,
                name: (row["name"] as? String) ?? id,
                // Hermes reports interval jobs as {"kind", "minutes", "display"}.
                schedule: (row["schedule"] as? String)
                    ?? ((row["schedule"] as? [String: Any])?["expr"] as? String)
                        ?? ((row["schedule"] as? [String: Any])?["display"] as? String)
                            ?? (row["schedule_display"] as? String)
                                ?? "Scheduled",
                enabled: (row["enabled"] as? Bool) ?? !(row["paused"] as? Bool ?? false),
                nextRun: row["next_run_at"] as? String ?? row["next_run"] as? String ?? row["nextRun"] as? String,
                sessionID: row["session_id"] as? String ?? row["sessionID"] as? String,
                delivery: row["deliver"] as? String ?? row["delivery"] as? String,
                prompt: prompt,
                report: nil,
                editableFields: editable,
                lastRunAt: row["last_run_at"] as? String,
                lastStatus: row["last_status"] as? String,
                lastError: row["last_error"] as? String,
                details: CronJobDetails(row: row)
            )
        }
    }

    static func attachLatestCronSessions(to jobs: [CronSummary], from result: [String: Any]) -> [CronSummary] {
        let rows = (result["sessions"] as? [[String: Any]]) ?? []
        return jobs.map { job in
            let prefix = "cron_\(job.id)_"
            let sessionID =
                rows.first { row in
                    let source = (row["source"] as? String)?.lowercased()
                    let id = row["id"] as? String
                    return source == "cron" && id?.hasPrefix(prefix) == true
                }?["id"] as? String
            guard let sessionID else { return job }
            return CronSummary(
                id: job.id,
                name: job.name,
                schedule: job.schedule,
                enabled: job.enabled,
                nextRun: job.nextRun,
                sessionID: sessionID,
                delivery: job.delivery,
                prompt: job.prompt,
                report: job.report,
                editableFields: job.editableFields,
                lastRunAt: job.lastRunAt,
                lastStatus: job.lastStatus,
                lastError: job.lastError,
                details: job.details
            )
        }
    }

    static func parseCronReport(_ result: [String: Any], job: CronSummary, sessionID: String) -> CronReportDetail? {
        let rows = (result["data"] ?? result["messages"]) as? [[String: Any]] ?? []
        for row in rows.reversed() {
            let role = (row["role"] as? String)?.lowercased() ?? ""
            guard role == "assistant" || role == "hermes" else { continue }
            let text = cronReportText(row["text"] ?? row["content"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            return CronReportDetail(id: sessionID, jobID: job.id, title: job.name, markdown: text)
        }
        return nil
    }

    static func cronReportText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let parts = value as? [[String: Any]] {
            return parts.compactMap { part in
                (part["text"] as? String) ?? (part["content"] as? String)
            }.joined()
        }
        return ""
    }

    /// Archive enrichment must not delay live agent, capability, or project state.
    func refreshLatestActivityProjection() {
        guard latestActivityRefreshTask == nil, let rpc else { return }
        let generation = refreshGeneration
        let identity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        beginProjectionRefresh("latest.activity")
        latestActivityRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if isCurrentRefresh(generation, clientIdentity: identity) { latestActivityRefreshTask = nil }
            }
            do {
                try await refreshLatestActivities(rpc: rpc, generation: generation, clientIdentity: identity)
                try Task.checkCancellation()
                guard isCurrentRefresh(generation, clientIdentity: identity) else { return }
                recordProjectionSuccess("latest.activity")
            } catch {
                guard !Task.isCancelled, isCurrentRefresh(generation, clientIdentity: identity) else { return }
                recordProjectionFailure(
                    "latest.activity", error: HermesDiagnosticsService.safeSummary(error.localizedDescription))
            }
        }
    }

    func refreshLatestActivities(
        rpc: HermesControlRPC,
        generation: UInt64,
        clientIdentity: ObjectIdentifier?
    ) async throws {
        var sessionRows: [[String: Any]] = []
        var offset = 0
        var pageCount = 0
        var seenPageSignatures = Set<String>()
        var seenSessionIDs = Set<String>()
        let maximumPageCount = 1_000
        repeat {
            try Task.checkCancellation()
            guard isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
            guard pageCount < maximumPageCount else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            let page = try await rpc.sessionPages(limit: 100, offset: offset)
            guard let rows = page["data"] as? [[String: Any]] else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            guard let hasMore = Self.parseHasMore(page) else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            if rows.isEmpty, hasMore {
                throw HermesGateway.GatewayError.malformedResponse
            }
            pageCount += 1
            if !rows.isEmpty,
                Self.paginationPageIsRepeated(
                    rows, seenSignatures: &seenPageSignatures, seenSessionIDs: &seenSessionIDs)
            {
                throw HermesGateway.GatewayError.malformedResponse
            }
            sessionRows.append(contentsOf: rows)
            offset += rows.count
            if rows.isEmpty || !hasMore { break }
        } while true

        guard let sessions = Self.parseSessions(["data": sessionRows]) else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        var stepsBySessionID: [String: [SessionActivityStep]] = [:]
        var failedSessionCount = 0
        let revisions = Dictionary(
            sessionRows.compactMap { row -> (String, LatestActivityRevision)? in
                guard let id = row["id"] as? String, let revision = LatestActivityRevision(row) else { return nil }
                return (id, revision)
            }, uniquingKeysWith: { first, _ in first })
        var nextCache: [String: LatestActivityCacheEntry] = [:]
        var cachedStepCount = 0

        for start in stride(from: 0, to: sessions.count, by: 8) {
            try Task.checkCancellation()
            guard isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
            let end = min(start + 8, sessions.count)
            let batch = Array(sessions[start..<end])
            let fetched = await withTaskGroup(
                of: (String, [SessionActivityStep], Bool).self, returning: [(String, [SessionActivityStep], Bool)].self
            ) { group in
                for session in batch {
                    if let revision = revisions[session.id], let cached = latestActivityCache[session.id],
                        cached.revision == revision
                    {
                        stepsBySessionID[session.id] = cached.steps
                        if cachedStepCount + cached.steps.count <= 10_000, nextCache.count < 512 {
                            nextCache[session.id] = cached
                            cachedStepCount += cached.steps.count
                        }
                        continue
                    }
                    group.addTask { [weak self] in
                        guard let self, !Task.isCancelled else { return (session.id, [], false) }
                        let result = await self.fetchActivitySteps(rpc: rpc, sessionID: session.id)
                        return (session.id, result.steps, result.succeeded)
                    }
                }

                var values: [(String, [SessionActivityStep], Bool)] = []
                for await value in group {
                    values.append(value)
                }
                return values
            }
            for (sessionID, steps, succeeded) in fetched {
                stepsBySessionID[sessionID] = steps
                if !succeeded { failedSessionCount += 1 }
                if succeeded, let revision = revisions[sessionID],
                    cachedStepCount + steps.count <= 10_000, nextCache.count < 512
                {
                    nextCache[sessionID] = LatestActivityCacheEntry(revision: revision, steps: steps)
                    cachedStepCount += steps.count
                }
            }
        }
        try Task.checkCancellation()
        guard isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
        latestActivityCache = nextCache

        let projectedActivities = GlobalSessionActivityPresentation.latestActivity(
            sessions,
            stepsBySessionID: stepsBySessionID
        )
        if failedSessionCount > 0 {
            throw NSError(
                domain: "HermesControl",
                code: 206,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Latest activity is partial: unable to read activity from \(failedSessionCount) session\(failedSessionCount == 1 ? "" : "s")."
                ]
            )
        }
        guard isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
        latestActivities = projectedActivities
    }

    func fetchActivitySteps(rpc: HermesControlRPC, sessionID: String) async -> (
        steps: [SessionActivityStep], succeeded: Bool
    ) {
        do {
            let result = try await rpc.sessionMessages(sessionID: sessionID)
            guard let steps = Self.parseActivityStepsEnvelope(result) else {
                return ([], false)
            }
            return (steps, true)
        } catch HermesGateway.GatewayError.httpError(404) {
            // A session can be pruned after its list page was read. Omit it
            // from this optional activity timeline rather than failing Today
            // or showing an unrelated Inbox warning.
            return ([], true)
        } catch {
            return ([], false)
        }
    }

    static func parseActivityStepsEnvelope(_ result: [String: Any]) -> [SessionActivityStep]? {
        guard result["messages"] == nil,
            let rows = result["data"] as? [[String: Any]]
        else {
            return nil
        }
        var steps: [SessionActivityStep] = []
        var seenActivityIDs = Set<String>()
        for row in rows {
            let id: String
            if let stringID = row["id"] as? String {
                id = stringID
            } else if let numericID = row["id"] as? NSNumber, !(row["id"] is Bool) {
                id = numericID.stringValue
            } else {
                return nil
            }
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                seenActivityIDs.insert(id).inserted
            else { return nil }
            if let role = row["role"], !(role is String) { return nil }
            if let timestamp = row["timestamp"], activityDate(timestamp) == nil { return nil }
            if let toolName = row["tool_name"], !(toolName is String) { return nil }

            var names: [String] = []
            if let rawToolCalls = row["tool_calls"] {
                guard let toolCalls = rawToolCalls as? [[String: Any]] else { return nil }
                for call in toolCalls {
                    if let function = call["function"] {
                        guard let function = function as? [String: Any] else { return nil }
                        if let name = function["name"], !(name is String) { return nil }
                    }
                    if let name = call["name"], !(name is String) { return nil }
                    let function = call["function"] as? [String: Any]
                    if let name = (function?["name"] as? String) ?? (call["name"] as? String) {
                        names.append(name)
                    }
                }
            }
            if let toolName = row["tool_name"] as? String, !toolName.isEmpty {
                names.append(toolName)
            }
            if names.isEmpty, (row["role"] as? String) == "assistant" {
                names = ["Response"]
            }

            let timestamp = activityDate(row["timestamp"]) ?? .distantPast
            steps.append(
                contentsOf: names.enumerated().map { nameIndex, name in
                    SessionActivityStep(id: "\(id)-\(nameIndex)", name: name, timestamp: timestamp)
                })
        }
        return steps
    }

    static func parseHasMore(_ page: [String: Any]) -> Bool? {
        guard let value = page["has_more"] else { return nil }
        return value as? Bool
    }

    static func paginationPageIsRepeated(
        _ rows: [[String: Any]],
        seenSignatures: inout Set<String>
    ) -> Bool {
        var seenSessionIDs = Set<String>()
        return paginationPageIsRepeated(rows, seenSignatures: &seenSignatures, seenSessionIDs: &seenSessionIDs)
    }

    static func paginationPageIsRepeated(
        _ rows: [[String: Any]],
        seenSignatures: inout Set<String>,
        seenSessionIDs: inout Set<String>
    ) -> Bool {
        guard let signature = paginationPageSignature(rows) else { return false }
        let repeatedPage = !seenSignatures.insert(signature).inserted
        let ids = rows.compactMap { $0["id"] as? String }
        let overlaps = ids.contains { seenSessionIDs.contains($0) }
        seenSessionIDs.formUnion(ids)
        return repeatedPage || overlaps
    }

    static func paginationPageSignature(_ rows: [[String: Any]]) -> String? {
        guard rows.allSatisfy({ $0["id"] is String }) else { return nil }
        return "\(rows.count):" + rows.compactMap { $0["id"] as? String }.joined(separator: "\u{1F}")
    }

    nonisolated static func activityDate(_ value: Any?) -> Date? {
        if let value, !(value is Bool), let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let string = value as? String {
            return ISO8601DateFormatter().date(from: string)
        }
        return nil
    }

    static func parseSessions(_ result: [String: Any]) -> [SessionSummary]? {
        let rows: [[String: Any]]
        if let value = result["sessions"] {
            guard let parsed = value as? [[String: Any]] else { return nil }
            rows = parsed
        } else if let value = result["active"] {
            guard let parsed = value as? [[String: Any]] else { return nil }
            rows = parsed
        } else if let value = result["data"] {
            guard let parsed = value as? [[String: Any]] else { return nil }
            rows = parsed
        } else {
            return nil
        }

        var sessions: [SessionSummary] = []
        for row in rows {
            guard let id = row["id"] as? String,
                !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                isOptionalString(row["title"]),
                isOptionalString(row["name"]),
                isOptionalString(row["state"]),
                isOptionalString(row["status"]),
                isOptionalString(row["preview"]),
                isOptionalString(row["last_message"])
            else {
                return nil
            }
            let title = (row["title"] as? String) ?? (row["name"] as? String) ?? "Hermes session"
            let state = (row["state"] as? String) ?? (row["status"] as? String) ?? "active"
            let preview = row["preview"] as? String ?? row["last_message"] as? String
            let updatedAt =
                activityDate(row["updated_at"])
                ?? activityDate(row["last_active"])
                ?? activityDate(row["last_message_at"])
                ?? activityDate(row["started_at"])
            sessions.append(
                SessionSummary(
                    id: id, title: title, state: state, preview: preview, updatedAt: updatedAt,
                    profileID: nonEmpty(row["profile_id"] as? String) ?? nonEmpty(row["profile"] as? String),
                    storedSessionID: nonEmpty(row["session_key"] as? String)))
        }
        return sessions
    }

    static func isOptionalString(_ value: Any?) -> Bool {
        value == nil || value is String
    }

    static func parseProcesses(_ result: [String: Any]) -> [ProcessSummary] {
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
            let state =
                DockModel.canonicalAgentStatus(
                    (row["status"] as? String) ?? (row["state"] as? String)
                ) ?? "running"
            guard AgentActivityPresentation.isActiveStatus(state) else { return nil }
            return AgentSummary(
                id: id,
                name: (row["name"] as? String) ?? (row["role"] as? String) ?? id,
                state: state,
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
            return ControlSearchResult(
                id: "attention:\(item.id)", reference: item.reference, title: item.title, detail: item.detail,
                sourceLabel: "INBOX")
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

    static func parseSessionUsage(_ result: [String: Any]) -> SessionUsageSummary {
        SessionUsageSummary(
            calls: intValue(result["calls"]),
            inputTokens: intValue(result["input"] ?? result["input_tokens"]),
            outputTokens: intValue(result["output"] ?? result["output_tokens"]),
            totalTokens: intValue(result["total"] ?? result["total_tokens"]),
            contextUsed: optionalIntValue(result["context_used"]),
            contextMax: optionalIntValue(result["context_max"]),
            contextPercent: doubleValue(result["context_percent"]),
            model: result["model"] as? String,
            reasoningTokens: intValue(result["reasoning"] ?? result["reasoning_tokens"]),
            cacheHitPercent: optionalIntValue(result["cache_hit_pct"]),
            compactions: intValue(result["compressions"]),
            averageLatencySeconds: doubleValue(result["avg_latency_s"]),
            tokensPerSecond: doubleValue(result["avg_tps"])
        )
    }

    /// `/api/analytics/models` supplies per-provider accounting; never split model totals by provider names.
    static func parseTokenUsage(_ result: [String: Any], models modelResult: [String: Any] = [:]) -> TokenUsageReport {
        let totals = result["totals"] as? [String: Any] ?? [:]
        let rows = { (key: String, source: [String: Any]) in source[key] as? [[String: Any]] ?? [] }
        var providers: [String: [String]] = [:]
        for row in rows("models", modelResult) {
            guard let model = row["model"] as? String,
                let provider = row["provider"] as? String, !provider.isEmpty,
                providers[model]?.contains(provider) != true
            else { continue }
            providers[model, default: []].append(provider)
        }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        // Hermes emits the same task once per model/provider pair; the
        // dashboard reads a task as one line, so merge by name.
        func tasks(_ raw: [[String: Any]]) -> [TokenUsageReport.Task] {
            var order: [String] = []
            var merged: [String: TokenUsageReport.Task] = [:]
            for row in raw {
                let name = (row["task"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "other"
                let previous = merged[name]
                if previous == nil { order.append(name) }
                merged[name] = TokenUsageReport.Task(
                    task: name,
                    inputTokens: (previous?.inputTokens ?? 0) + intValue(row["input_tokens"]),
                    outputTokens: (previous?.outputTokens ?? 0) + intValue(row["output_tokens"]),
                    estimatedCost: (previous?.estimatedCost ?? 0) + (doubleValue(row["estimated_cost"]) ?? 0),
                    apiCalls: (previous?.apiCalls ?? 0) + intValue(row["api_calls"])
                )
            }
            return order.compactMap { merged[$0] }.sorted { $0.totalTokens > $1.totalTokens }
        }
        let skills = result["skills"] as? [String: Any] ?? [:]
        let skillSummary = skills["summary"] as? [String: Any] ?? [:]
        return TokenUsageReport(
            days: intValue(result["period_days"]),
            inputTokens: intValue(totals["total_input"]),
            outputTokens: intValue(totals["total_output"]),
            cacheReadTokens: intValue(totals["total_cache_read"]),
            reasoningTokens: intValue(totals["total_reasoning"]),
            estimatedCost: doubleValue(totals["total_estimated_cost"]) ?? 0,
            actualCost: doubleValue(totals["total_actual_cost"]) ?? 0,
            sessions: intValue(totals["total_sessions"]),
            apiCalls: intValue(totals["total_api_calls"]),
            daily: rows("daily", result).compactMap { row in
                guard let day = (row["day"] as? String).flatMap(dayFormatter.date(from:)) else { return nil }
                return TokenUsageReport.Day(
                    day: day,
                    inputTokens: intValue(row["input_tokens"]),
                    outputTokens: intValue(row["output_tokens"]),
                    cacheReadTokens: intValue(row["cache_read_tokens"]),
                    reasoningTokens: intValue(row["reasoning_tokens"]),
                    estimatedCost: doubleValue(row["estimated_cost"]) ?? 0,
                    sessions: intValue(row["sessions"]),
                    apiCalls: intValue(row["api_calls"])
                )
            },
            models: rows("by_model", result).map { row in
                TokenUsageReport.Model(
                    model: (row["model"] as? String) ?? "unknown",
                    inputTokens: intValue(row["input_tokens"]),
                    outputTokens: intValue(row["output_tokens"]),
                    estimatedCost: doubleValue(row["estimated_cost"]) ?? 0,
                    sessions: intValue(row["sessions"]),
                    apiCalls: intValue(row["api_calls"]),
                    tasks: tasks(rows("aux_tasks", row)),
                    providers: providers[(row["model"] as? String) ?? ""] ?? []
                )
            },
            tasks: tasks(rows("by_task", result)),
            tools: rows("tools", result).map {
                TokenUsageReport.Share(
                    name: ($0["tool"] as? String) ?? "unknown", count: intValue($0["count"]),
                    percentage: doubleValue($0["percentage"]) ?? 0)
            },
            skills: rows("top_skills", skills).map {
                TokenUsageReport.Share(
                    name: ($0["skill"] as? String) ?? "unknown", count: intValue($0["total_count"]),
                    percentage: doubleValue($0["percentage"]) ?? 0)
            },
            skillLoads: intValue(skillSummary["total_skill_loads"]),
            distinctSkills: intValue(skillSummary["distinct_skills_used"]),
            costRankedProviders: parseProviderCosts(modelResult, days: intValue(result["period_days"]))
        )
    }

    static func parseProviderCosts(_ result: [String: Any], days: Int) -> [TokenUsageReport.Provider]? {
        guard days > 0, intValue(result["period_days"]) == days,
            let rows = result["models"] as? [[String: Any]]
        else { return nil }
        var grouped: [String: TokenUsageReport.Provider] = [:]
        for row in rows {
            guard let cost = doubleValue(row["estimated_cost"]), cost.isFinite, cost >= 0,
                let input = optionalIntValue(row["input_tokens"]), input >= 0,
                let output = optionalIntValue(row["output_tokens"]), output >= 0
            else { return nil }
            let provider = (row["provider"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let previous = grouped[provider]
            grouped[provider] = TokenUsageReport.Provider(
                provider: provider,
                inputTokens: (previous?.inputTokens ?? 0) + input,
                outputTokens: (previous?.outputTokens ?? 0) + output,
                estimatedCost: (previous?.estimatedCost ?? 0) + cost)
        }
        return grouped.values.sorted {
            if $0.estimatedCost != $1.estimatedCost { return $0.estimatedCost > $1.estimatedCost }
            return $0.provider < $1.provider
        }
    }

    static func parseCheckpoints(_ result: [String: Any]) -> [HermesCheckpointSummary] {
        guard result["enabled"] as? Bool == true,
            let rows = result["checkpoints"] as? [[String: Any]], rows.count <= 50
        else { return [] }
        return rows.compactMap { row in
            guard let hash = row["hash"] as? String, !hash.isEmpty, hash.count <= 128 else { return nil }
            let timestamp = (row["timestamp"] as? String ?? "").prefix(128)
            let message = (row["message"] as? String ?? "").prefix(512)
            return HermesCheckpointSummary(hash: hash, timestamp: String(timestamp), message: String(message))
        }
    }

    static func parseSessionContext(_ result: [String: Any]) -> SessionContextSummary {
        let rows = (result["categories"] as? [[String: Any]] ?? []).enumerated().map { index, row in
            SessionContextCategory(
                id: (row["id"] as? String) ?? (row["name"] as? String) ?? "category-\(index)",
                label: (row["label"] as? String) ?? (row["name"] as? String) ?? "Category \(index + 1)",
                tokens: intValue(row["tokens"] ?? row["count"]),
                percent: doubleValue(row["percent"])
            )
        }
        return SessionContextSummary(
            categories: rows,
            contextUsed: intValue(result["context_used"]),
            contextMax: intValue(result["context_max"]),
            contextPercent: doubleValue(result["context_percent"]),
            estimatedTotal: intValue(result["estimated_total"]),
            model: result["model"] as? String,
            compressionThresholdTokens: optionalIntValue(result["compression_threshold_tokens"]).flatMap {
                $0 > 0 ? $0 : nil
            },
            compressionEnabled: result["compression_enabled"] as? Bool,
            contextEstimated: result["context_estimated"] as? Bool ?? false,
            files: (result["context_files"] as? [[String: Any]])?.compactMap { row in
                guard let label = row["label"] as? String, !label.isEmpty else { return nil }
                let status = row["status"] as? String ?? ""
                return SessionContextFile(
                    label: label, path: row["path"] as? String ?? "", estimatedTokens: intValue(row["est_tokens"]),
                    status: status, loaded: row["loaded"] as? Bool ?? (status == "loaded"))
            }
        )
    }

    static func parseProviderQuota(_ result: [String: Any]) -> ProviderQuotaSnapshot? {
        guard let provider = (result["provider"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !provider.isEmpty,
            let updatedString = result["updated_at"] as? String,
            let updatedAt = QuotaJSON.iso8601Date(updatedString)
        else { return nil }
        let displayName = ((result["display_name"] as? String) ?? provider).trimmingCharacters(
            in: .whitespacesAndNewlines)
        let rows = (result["windows"] as? [[String: Any]] ?? []).prefix(5).compactMap { row -> ProviderQuotaWindow? in
            guard let id = (row["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !id.isEmpty,
                let label = (row["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !label.isEmpty
            else { return nil }
            let rawPercent = doubleValue(row["remaining_percent"])
            if row["remaining_percent"] != nil && (rawPercent == nil || !(0...100).contains(rawPercent!)) { return nil }
            let percent = rawPercent
            let resetsAt = (row["resets_at"] as? String).flatMap(QuotaJSON.iso8601Date)
            return ProviderQuotaWindow(
                id: id,
                label: label,
                remainingPercent: percent,
                remainingDisplay: boundedQuotaText(row["remaining_display"]),
                limitDisplay: boundedQuotaText(row["limit_display"]),
                resetsAt: resetsAt,
                resetsDisplay: boundedQuotaText(row["resets_display"]),
                amount: doubleValue(row["amount"])
            )
        }
        var unique: [ProviderQuotaWindow] = []
        var seen = Set<String>()
        for row in rows where seen.insert(row.id).inserted { unique.append(row) }
        return ProviderQuotaSnapshot(
            provider: provider,
            displayName: displayName,
            model: boundedQuotaText(result["model"]),
            updatedAt: updatedAt,
            windows: unique,
            safeDetail: boundedQuotaText(result["safe_detail"]),
            hermesCredential: hermesPooledCredential(result["hermes_credential"])
        )
    }

    static func hermesPooledCredential(_ value: Any?) -> HermesPooledCredential? {
        guard let object = value as? [String: Any],
            let provider = object["provider"] as? String, !provider.isEmpty,
            let id = object["id"] as? String, !id.isEmpty
        else { return nil }
        return HermesPooledCredential(
            provider: provider,
            id: id,
            label: (object["label"] as? String) ?? id,
            position: (object["position"] as? Int) ?? 0
        )
    }

    static func boundedQuotaText(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 160 else { return nil }
        return clean
    }

    static func intValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    static func optionalIntValue(_ value: Any?) -> Int? {
        guard value != nil else { return nil }
        return intValue(value)
    }

    static func optionalVerificationExitCode(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let value = value as? Int { return value }
        if let value = value as? NSNumber {
            let type = String(cString: value.objCType)
            guard type != "c" && type != "B", value.doubleValue.rounded() == value.doubleValue else { return nil }
            return value.intValue
        }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    /// Large boards take tens of milliseconds to scan and decode; polling on
    /// the main actor made every refresh a visible scroll hitch.
    nonisolated static func parseKanbanTasksOffMain(_ output: String, boardSlug: String?) async -> [KanbanTaskSummary]?
    {
        await Task.detached(priority: .utility) {
            parseKanbanTasksStrict(output, boardSlug: boardSlug)
        }.value
    }

    static func parseKanbanTasks(_ output: String, boardSlug: String? = nil) -> [KanbanTaskSummary] {
        parseKanbanTasksStrict(output, boardSlug: boardSlug) ?? []
    }

    /// Returns nil when the CLI response is not a top-level task array. The
    /// optional result distinguishes malformed output from a genuine empty
    /// board, whose valid `[]` response must still replace the projection.
    nonisolated static func parseKanbanTasksStrict(_ output: String, boardSlug: String? = nil) -> [KanbanTaskSummary]? {
        // A JSON value starting at a bracket can only end at its matching
        // bracket, so parse one candidate per start. Trying every later
        // closing bracket was quadratic and stalled the main thread for
        // seconds on large boards.
        // Fast path: the Kanban adapter emits a bare JSON array, so skip the
        // byte scan below when the whole output already decodes.
        if let data = output.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data),
            let rows = kanbanTaskRows(from: value)
        {
            return rows.compactMap { parseKanbanTaskSummary($0, boardSlug: boardSlug) }
        }
        let bytes = Array(output.utf8)
        var validEmptyRows: [[String: Any]]?
        for start in bytes.indices where bytes[start] == UInt8(ascii: "[") || bytes[start] == UInt8(ascii: "{") {
            guard let end = matchingJSONBracket(in: bytes, from: start),
                let value = try? JSONSerialization.jsonObject(with: Data(bytes[start...end])),
                let rows = kanbanTaskRows(from: value)
            else { continue }
            if !rows.isEmpty { return rows.compactMap { parseKanbanTaskSummary($0, boardSlug: boardSlug) } }
            validEmptyRows = rows
        }
        return validEmptyRows?.compactMap { parseKanbanTaskSummary($0, boardSlug: boardSlug) }
    }

    /// Index of the bracket closing the one at `start`, skipping JSON strings.
    nonisolated static func matchingJSONBracket(in bytes: [UInt8], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        for index in start..<bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    nonisolated static func kanbanTaskRows(from value: Any) -> [[String: Any]]? {
        if let rows = value as? [[String: Any]] { return rows }
        if let encoded = value as? String,
            let data = encoded.data(using: .utf8),
            let nested = try? JSONSerialization.jsonObject(with: data)
        {
            return kanbanTaskRows(from: nested)
        }
        guard let envelope = value as? [String: Any] else { return nil }
        // Accept only known Hermes relay/list envelopes. Arbitrary objects must
        // remain malformed instead of silently becoming an empty board.
        for key in ["tasks", "items", "data", "result", "payload", "stdout", "output"] {
            if let rows = kanbanTaskRows(from: envelope[key] as Any) { return rows }
        }
        return nil
    }

    static func parseKanbanTaskSummary(
        _ output: String,
        boardSlug: String? = nil,
        sessionID: String? = nil
    ) -> KanbanTaskSummary? {
        guard let data = output.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        let row: [String: Any]
        if let dictionary = value as? [String: Any], let task = dictionary["task"] as? [String: Any] {
            row = task
        } else if let dictionary = value as? [String: Any] {
            row = dictionary
        } else {
            return nil
        }
        guard let base = parseKanbanTaskSummary(row, boardSlug: boardSlug, sessionID: sessionID) else { return nil }
        let event = parseLatestKanbanEvent((value as? [String: Any])?["events"])
        return KanbanTaskSummary(
            id: base.id,
            boardSlug: base.boardSlug,
            title: base.title,
            status: base.status,
            detail: base.detail,
            priority: base.priority,
            assignee: base.assignee,
            sessionID: base.sessionID,
            startedAt: base.startedAt,
            completedAt: base.completedAt,
            currentStepKey: base.currentStepKey,
            latestEventKind: event.kind,
            latestEventNote: event.note,
            latestEventAt: event.date,
            modelOverride: base.modelOverride,
            providerOverride: base.providerOverride,
            skills: base.skills,
            workflowTemplateID: base.workflowTemplateID,
            workspacePath: base.workspacePath
        )
    }

    nonisolated static func parseKanbanTaskSummary(
        _ row: [String: Any],
        boardSlug: String?,
        sessionID: String? = nil
    ) -> KanbanTaskSummary? {
        guard let id = (row["id"] as? String) ?? (row["task_id"] as? String),
            let title = (row["title"] as? String) ?? (row["t"] as? String)
        else { return nil }
        return KanbanTaskSummary(
            id: id,
            boardSlug: boardSlug
                ?? (row["board_slug"] as? String)
                    ?? (row["boardSlug"] as? String)
                        ?? (row["board"] as? String),
            title: title,
            status: (row["status"] as? String) ?? (row["s"] as? String) ?? "unknown",
            detail: (row["body"] as? String) ?? (row["description"] as? String),
            priority: Self.stringValue(row["priority"] ?? row["p"]),
            assignee: (row["assignee"] as? String) ?? (row["assigned_to"] as? String) ?? (row["a"] as? String),
            sessionID: sessionID ?? (row["session_id"] as? String) ?? (row["sessionID"] as? String),
            startedAt: activityDate(row["started_at"] ?? row["startedAt"]),
            completedAt: activityDate(row["completed_at"] ?? row["completedAt"]),
            currentStepKey: (row["current_step_key"] as? String) ?? (row["currentStepKey"] as? String),
            modelOverride: (row["model_override"] as? String) ?? (row["modelOverride"] as? String)
                ?? (row["model"] as? String),
            providerOverride: (row["provider_override"] as? String) ?? (row["providerOverride"] as? String)
                ?? (row["provider"] as? String),
            skills: kanbanStringList(row["skills"]),
            workflowTemplateID: (row["workflow_template_id"] as? String) ?? (row["workflowTemplateID"] as? String),
            workspacePath: row["workspace_path"] as? String
        )
    }

    static func parseLatestKanbanEvent(_ value: Any?) -> (kind: String?, note: String?, date: Date?) {
        guard let events = value as? [[String: Any]], !events.isEmpty else { return (nil, nil, nil) }
        let latest =
            events.max { lhs, rhs in
                (activityDate(lhs["created_at"] ?? lhs["createdAt"]) ?? .distantPast)
                    < (activityDate(rhs["created_at"] ?? rhs["createdAt"]) ?? .distantPast)
            } ?? [:]
        return (
            (latest["kind"] as? String) ?? (latest["type"] as? String),
            (latest["note"] as? String)
                ?? ((latest["payload"] as? [String: Any])?["note"] as? String)
                    ?? (latest["payload"] as? String),
            activityDate(latest["created_at"] ?? latest["createdAt"])
        )
    }

    /// The session Activity projection is a privacy boundary. Even when the
    /// CLI request carries a session filter, publish only rows that return a
    /// present, exact canonical session identifier.
    static func filterSessionKanbanTasks(
        _ tasks: [KanbanTaskSummary], sessionID: String, aliases: Set<String> = [], observedIDs: Set<String> = []
    ) -> [KanbanTaskSummary] {
        guard !sessionID.isEmpty else { return [] }
        let ids = aliases.union([sessionID])
        return tasks.filter { $0.sessionID.map(ids.contains) ?? observedIDs.contains($0.id) }
    }

    static func parseKanbanTaskDetail(_ output: String, fallback: KanbanTaskSummary, boardSlug: String? = nil)
        -> KanbanTaskDetail?
    {
        guard let data = output.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data),
            let source = kanbanTaskDetailRow(from: value)
        else { return nil }
        guard let id = (source["id"] as? String) ?? (source["task_id"] as? String) else { return nil }
        let resolvedBoardSlug = boardSlug ?? fallback.boardSlug
        var detail = KanbanTaskDetail(
            id: id,
            boardSlug: resolvedBoardSlug,
            title: (source["title"] as? String) ?? fallback.title,
            body: (source["body"] as? String) ?? (source["description"] as? String),
            status: (source["status"] as? String) ?? fallback.status,
            priority: Self.stringValue(source["priority"]) ?? fallback.priority,
            assignee: (source["assignee"] as? String) ?? (source["assigned_to"] as? String) ?? fallback.assignee,
            runs: [],
            modelOverride: (source["model_override"] as? String) ?? (source["modelOverride"] as? String)
                ?? (source["model"] as? String) ?? fallback.modelOverride,
            providerOverride: (source["provider_override"] as? String) ?? (source["providerOverride"] as? String)
                ?? (source["provider"] as? String) ?? fallback.providerOverride
        )
        // `show --json` wraps the task with its history; the history may also
        // arrive inline on the task row from relay transports.
        let history = kanbanShowEnvelope(from: value) ?? source
        detail.latestSummary = Self.nonEmpty(history["latest_summary"] as? String)
        detail.result = Self.nonEmpty(source["result"] as? String)
        detail.lastFailureError = Self.nonEmpty(source["last_failure_error"] as? String)
        detail.skills = kanbanStringList(source["skills"])
        detail.workflowTemplateID = Self.nonEmpty(source["workflow_template_id"] as? String)
        detail.currentStepKey = Self.nonEmpty(source["current_step_key"] as? String) ?? fallback.currentStepKey
        detail.workspaceKind = Self.nonEmpty(source["workspace_kind"] as? String)
        detail.workspacePath = Self.nonEmpty(source["workspace_path"] as? String)
        detail.branchName = Self.nonEmpty(source["branch_name"] as? String)
        detail.sessionID = Self.nonEmpty(source["session_id"] as? String) ?? fallback.sessionID
        detail.createdBy = Self.nonEmpty(source["created_by"] as? String)
        detail.createdAt = activityDate(source["created_at"])
        detail.startedAt = activityDate(source["started_at"]) ?? fallback.startedAt
        detail.completedAt = activityDate(source["completed_at"]) ?? fallback.completedAt
        detail.parents = kanbanStringList(history["parents"])
        detail.children = kanbanStringList(history["children"])
        detail.comments = ((history["comments"] as? [[String: Any]]) ?? []).enumerated().compactMap { index, row in
            guard let body = Self.nonEmpty(row["body"] as? String) else { return nil }
            let createdAt = activityDate(row["created_at"])
            return KanbanCommentSummary(
                id: Self.stringValue(row["id"]) ?? "comment-\(index)",
                author: Self.nonEmpty(row["author"] as? String) ?? "Unknown",
                body: body,
                createdAt: createdAt
            )
        }
        detail.events = ((history["events"] as? [[String: Any]]) ?? []).enumerated().compactMap { index, row in
            guard let kind = Self.nonEmpty((row["kind"] as? String) ?? (row["type"] as? String)) else { return nil }
            return KanbanEventSummary(
                id: Self.stringValue(row["id"]) ?? "event-\(index)",
                kind: kind,
                note: kanbanEventNote(row["note"] ?? row["payload"]),
                runID: Self.stringValue(row["run_id"]),
                createdAt: activityDate(row["created_at"]),
                assignee: (row["payload"] as? [String: Any]).flatMap { Self.nonEmpty($0["assignee"] as? String) }
            )
        }
        detail.runs = ((history["runs"] as? [[String: Any]]) ?? []).enumerated().compactMap { index, row in
            kanbanRunSummary(row, index: index, boardSlug: resolvedBoardSlug)
        }
        return detail
    }

    /// The `show --json` object that carries `task` plus its history.
    static func kanbanShowEnvelope(from value: Any) -> [String: Any]? {
        if let rows = value as? [[String: Any]] { return rows.first.flatMap { kanbanShowEnvelope(from: $0) } }
        guard let dictionary = value as? [String: Any] else { return nil }
        if dictionary["task"] is [String: Any] { return dictionary }
        for key in ["data", "result", "payload", "output", "stdout"] {
            if let envelope = dictionary[key].flatMap({ kanbanShowEnvelope(from: $0) }) { return envelope }
        }
        return nil
    }

    /// Hermes stores skills and links as JSON arrays; older rows may hold a
    /// comma-separated string.
    nonisolated static func kanbanStringList(_ value: Any?) -> [String] {
        if let values = value as? [Any] {
            return values.compactMap { stringValue($0).flatMap(nonEmpty) }
        }
        if let string = value as? String {
            if let data = string.data(using: .utf8),
                let decoded = try? JSONSerialization.jsonObject(with: data) as? [Any]
            {
                return kanbanStringList(decoded)
            }
            return string.split(separator: ",").compactMap { nonEmpty(String($0)) }
        }
        return []
    }

    /// Events carry either a plain note or a payload object/JSON string.
    static func kanbanEventNote(_ value: Any?) -> String? {
        if let string = value as? String {
            if let data = string.data(using: .utf8),
                let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                return kanbanEventNote(decoded)
            }
            return nonEmpty(string)
        }
        guard let payload = value as? [String: Any] else { return nil }
        for key in ["note", "reason", "summary", "message", "text", "error"] {
            if let note = nonEmpty(payload[key] as? String) { return note }
        }
        return nil
    }

    nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func fallbackKanbanTaskDetail(_ task: KanbanTaskSummary, boardSlug: String? = nil) -> KanbanTaskDetail {
        KanbanTaskDetail(
            id: task.id,
            boardSlug: boardSlug ?? task.boardSlug,
            title: task.title,
            body: task.detail,
            status: task.status,
            priority: task.priority,
            assignee: task.assignee,
            runs: [],
            modelOverride: task.modelOverride,
            providerOverride: task.providerOverride
        )
    }

    static func enrichedKanbanTaskDetail(
        _ detail: KanbanTaskDetail?,
        runs: [KanbanRunSummary],
        boardSlug: String?
    ) -> KanbanTaskDetail? {
        guard var detail else { return nil }
        detail.boardSlug = boardSlug
        detail.runs = runs
        return detail
    }

    /// Hermes versions and relay transports have returned task details as a
    /// task object, a one-item array, or a known result envelope. Keep this
    /// normalization local to the parser so the UI does not need to know
    /// which transport shape produced the response.
    static func kanbanTaskDetailRow(from value: Any) -> [String: Any]? {
        if let rows = value as? [[String: Any]] {
            return rows.first.flatMap { kanbanTaskDetailRow(from: $0) }
        }
        guard let dictionary = value as? [String: Any] else { return nil }
        if let task = dictionary["task"] {
            if let row = kanbanTaskDetailRow(from: task) { return row }
        }
        for key in ["data", "result", "payload", "output", "stdout"] {
            if let row = dictionary[key].flatMap({ kanbanTaskDetailRow(from: $0) }) {
                return row
            }
        }
        return dictionary["id"] != nil || dictionary["task_id"] != nil ? dictionary : nil
    }

    static func parseKanbanRuns(_ output: String, boardSlug: String? = nil) -> [KanbanRunSummary] {
        guard let data = output.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        let rows: [[String: Any]]
        if let array = value as? [[String: Any]] {
            rows = array
        } else if let dictionary = value as? [String: Any], let array = dictionary["runs"] as? [[String: Any]] {
            rows = array
        } else {
            return []
        }
        return rows.enumerated().compactMap { index, row in
            kanbanRunSummary(row, index: index, boardSlug: boardSlug)
        }
    }

    /// Hermes run ids are integers; relays may send strings.
    static func kanbanRunSummary(_ row: [String: Any], index: Int, boardSlug: String?) -> KanbanRunSummary? {
        guard let status = (row["status"] as? String) ?? (row["state"] as? String) else { return nil }
        return KanbanRunSummary(
            id: stringValue(row["id"] ?? row["run_id"]) ?? "run-\(index)",
            boardSlug: boardSlug,
            status: status,
            outcome: row["outcome"] as? String,
            profile: (row["profile"] as? String) ?? (row["assignee"] as? String),
            summary: (row["summary"] as? String) ?? (row["message"] as? String),
            elapsed: (row["elapsed"] as? String) ?? (row["duration"] as? String),
            stepKey: nonEmpty(row["step_key"] as? String),
            error: nonEmpty(row["error"] as? String),
            startedAt: activityDate(row["started_at"]),
            endedAt: activityDate(row["ended_at"])
        )
    }

    static func parseKanbanStats(_ output: String) -> KanbanStatsSummary? {
        guard let data = output.data(using: .utf8),
            let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let source =
            (row["counts"] as? [String: Any])
            ?? (row["by_status"] as? [String: Any])
            ?? row
        let counts = source.reduce(into: [String: Int]()) { result, entry in
            if let number = entry.value as? NSNumber { result[entry.key] = number.intValue }
        }
        return counts.isEmpty ? nil : KanbanStatsSummary(counts: counts)
    }

    static func parseKanbanBoards(_ output: String) -> [KanbanBoardSummary] {
        guard let data = output.data(using: .utf8),
            let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let slug = row["slug"] as? String, !slug.isEmpty else { return nil }
            let rawCounts = row["counts"] as? [String: Any] ?? [:]
            let counts = rawCounts.reduce(into: [String: Int]()) { result, entry in
                if let number = entry.value as? NSNumber { result[entry.key] = number.intValue }
            }
            return KanbanBoardSummary(
                slug: slug,
                name: (row["name"] as? String) ?? slug,
                description: (row["description"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                isCurrent: row["is_current"] as? Bool ?? false,
                archived: row["archived"] as? Bool ?? false,
                total: (row["total"] as? NSNumber)?.intValue ?? counts.values.reduce(0, +),
                counts: counts
            )
        }
    }

    static func parseKanbanAssignees(_ output: String) -> [String] {
        guard let data = output.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        let rows: [Any]
        if let array = value as? [Any] {
            rows = array
        } else if let dictionary = value as? [String: Any] {
            rows = (dictionary["assignees"] as? [Any]) ?? []
        } else {
            return []
        }
        return Array(
            Set(
                rows.compactMap { row in
                    if let value = row as? String { return value }
                    guard let row = row as? [String: Any] else { return nil }
                    return (row["name"] as? String) ?? (row["profile"] as? String) ?? (row["id"] as? String)
                })
        ).sorted()
    }

    static func parseKanbanDiagnostics(_ output: String, boardSlug: String?, severity: String? = nil)
        -> [KanbanDiagnosticSummary]
    {
        guard let data = output.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        let rows = (value as? [[String: Any]]) ?? ((value as? [String: Any])?["diagnostics"] as? [[String: Any]]) ?? []
        return rows.enumerated().compactMap { index, row in
            let rowSeverity = (row["severity"] as? String) ?? "warning"
            guard severity == nil || severity == rowSeverity else { return nil }
            let taskID = row["task_id"] as? String ?? row["taskID"] as? String
            let title = (row["title"] as? String) ?? "Kanban diagnostic"
            let fallback = [boardSlug ?? "default", taskID ?? "all", rowSeverity, title, String(index)].joined(
                separator: ":")
            return KanbanDiagnosticSummary(
                id: (row["id"] as? String) ?? fallback,
                severity: rowSeverity,
                title: title,
                detail: (row["detail"] as? String) ?? (row["message"] as? String) ?? "",
                taskID: taskID
            )
        }
    }

    static func parseProjectFacts(_ result: [String: Any]) -> ProjectFactsSummary? {
        guard let facts = result["facts"] as? [String: Any] else { return nil }
        return ProjectFactsSummary(
            root: facts["root"] as? String,
            manifests: facts["manifests"] as? [String] ?? [],
            packageManagers: (facts["packageManagers"] as? [String]) ?? (facts["package_managers"] as? [String]) ?? [],
            verifyCommands: (facts["verifyCommands"] as? [String]) ?? (facts["verify_commands"] as? [String]) ?? [],
            contextFiles: (facts["contextFiles"] as? [String]) ?? (facts["context_files"] as? [String]) ?? []
        )
    }

    static func parseVerification(_ result: [String: Any]) -> VerificationSummary {
        guard let verification = result["verification"] as? [String: Any] else {
            return VerificationSummary(state: .unknown, evidence: nil)
        }
        let state = VerificationState(rawValue: (verification["status"] as? String ?? "unknown")) ?? .unknown
        let evidenceRow = verification["evidence"] as? [String: Any]
        let evidence = evidenceRow.map {
            let row = $0
            let staleReasonValue = row["stale_reason"] as? String ?? row["staleReason"] as? String
            let hasInvalidStaleReason = ["stale_reason", "staleReason"].contains { key in
                guard let rawValue = row[key] else { return false }
                guard let stringValue = rawValue as? String else { return true }
                return VerificationEvidenceText.bounded(stringValue) == nil
            }
            return VerificationEvidenceSummary(
                command: row["command"] as? String,
                canonicalCommand: row["canonical_command"] as? String ?? row["canonicalCommand"] as? String,
                kind: row["kind"] as? String,
                scope: row["scope"] as? String,
                status: row["status"] as? String,
                exitCode: Self.optionalVerificationExitCode(row["exit_code"] ?? row["exitCode"]),
                outputSummary: row["output_summary"] as? String ?? row["outputSummary"] as? String,
                adapter: VerificationEvidenceText.bounded(
                    row["adapter"] as? String ?? row["tool_identifier"] as? String ?? row["toolIdentifier"] as? String),
                capturedAt: Self.optionalISO8601Date(row["captured_at"] ?? row["capturedAt"]),
                repositoryIdentity: VerificationEvidenceText.bounded(
                    row["repository_identity"] as? String ?? row["repositoryIdentity"] as? String),
                commitFingerprint: VerificationEvidenceText.bounded(
                    row["commit_fingerprint"] as? String ?? row["commitFingerprint"] as? String),
                targetFingerprint: VerificationEvidenceText.bounded(
                    row["target_fingerprint"] as? String ?? row["targetFingerprint"] as? String),
                diffFingerprint: VerificationEvidenceText.bounded(
                    row["diff_fingerprint"] as? String ?? row["diffFingerprint"] as? String),
                rulesScopeDetail: VerificationEvidenceText.bounded(
                    row["rules_scope_detail"] as? String ?? row["rulesScopeDetail"] as? String ?? row["rules"]
                        as? String),
                staleReason: VerificationEvidenceText.bounded(staleReasonValue),
                hasInvalidStaleReason: hasInvalidStaleReason
            )
        }
        return VerificationSummary(state: state, evidence: evidence)
    }

    static func optionalISO8601Date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    static func parseKanbanAttachments(_ value: Any, boardSlug: String?, taskID: String) -> [KanbanAttachmentSummary] {
        let rows = (value as? [[String: Any]]) ?? ((value as? [String: Any])?["attachments"] as? [[String: Any]]) ?? []
        return rows.enumerated().map { index, row in
            let name = (row["name"] as? String) ?? (row["filename"] as? String) ?? "Attachment"
            let fallback = [boardSlug ?? "default", taskID, name, String(index)].joined(separator: ":")
            return KanbanAttachmentSummary(
                id: Self.stringValue(row["id"]) ?? fallback,
                name: name,
                kind: row["kind"] as? String ?? row["mime_type"] as? String ?? row["content_type"] as? String,
                sizeBytes: Self.optionalIntValue(row["size"] ?? row["size_bytes"]),
                uploadedBy: Self.nonEmpty(row["uploaded_by"] as? String),
                createdAt: activityDate(row["created_at"]),
                storedPath: Self.nonEmpty(row["stored_path"] as? String)
            )
        }
    }

    static func parseJourneyNodes(_ output: String) -> [HermesJourneyNode] {
        guard let data = output.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = value["nodes"] as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return HermesJourneyNode(
                id: id,
                label: (row["label"] as? String) ?? id,
                kind: (row["kind"] as? String) ?? "node",
                category: row["category"] as? String,
                state: row["state"] as? String,
                useCount: (row["useCount"] as? NSNumber)?.intValue
            )
        }
    }

    static func readOnlyStatus(id: String, title: String, result: HermesCLIResult) -> HermesReadOnlyStatus {
        let output = result.succeeded ? result.stdout : Self.safeUserDiagnostic(result.stderr)
        let detail = HermesDiagnosticsService.safeSummary(output)
        return HermesReadOnlyStatus(
            id: id,
            title: title,
            detail: detail.isEmpty ? (result.succeeded ? "Available" : "Unavailable") : detail,
            isAvailable: result.succeeded
        )
    }

    nonisolated static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func parseCronRuns(_ output: String) -> [CronRunSummary] {
        var runs: [CronRunSummary] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            if raw.hasPrefix(" ") || raw.hasPrefix("\t") {
                guard !runs.isEmpty else { continue }
                let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else { continue }
                let current = runs.removeLast()
                let error = [current.error, message].compactMap { $0 }.joined(separator: "\n")
                runs.append(
                    CronRunSummary(
                        id: current.id,
                        status: current.status,
                        jobID: current.jobID,
                        source: current.source,
                        claimedAt: current.claimedAt,
                        error: error,
                        sessionID: current.sessionID
                    ))
                continue
            }
            let columns = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 2,
                !raw.localizedCaseInsensitiveContains("No cron execution attempts")
            else { continue }
            let metadata = columns.dropFirst(2)
            let jobID = metadata.first(where: { $0.hasPrefix("job=") }).map { String($0.dropFirst(4)) }
            let source = metadata.first(where: { $0.hasPrefix("source=") }).map { String($0.dropFirst(7)) }
            let claimedAt = metadata.first(where: { !$0.contains("=") }).map(String.init)
            runs.append(
                CronRunSummary(
                    id: String(columns[0]),
                    status: String(columns[1]),
                    jobID: jobID,
                    source: source,
                    claimedAt: claimedAt,
                    error: nil,
                    sessionID: nil
                ))
        }
        return runs
    }

    static func parseStructuredCronRuns(_ result: [String: Any], jobID: String) throws -> [CronRunSummary] {
        guard let rows = result["runs"] as? [[String: Any]], rows.count <= 50 else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        var seen = Set<String>()
        return try rows.map { row in
            guard let id = row["id"] as? String, !id.isEmpty, seen.insert(id).inserted,
                let source = row["source"] as? String, ["cron", "cron_output"].contains(source),
                let started = row["started_at"] as? NSNumber, started.doubleValue.isFinite,
                id.hasPrefix(source == "cron" ? "cron_\(jobID)_" : "cron_output:\(jobID):")
            else { throw HermesGateway.GatewayError.malformedResponse }
            let status: String
            if let reported = row["status"] as? String {
                status = reported
            } else if row["scheduler_owned"] as? Bool == true
                || (row["scheduler_owned"] == nil && row["is_active"] as? Bool == true)
            {
                status = "running"
            } else {
                status = row["ended_at"] is NSNumber ? "finished" : "unknown"
            }
            return CronRunSummary(
                id: id, status: status, jobID: jobID, source: source,
                claimedAt: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: started.doubleValue)),
                error: row["error"] as? String, sessionID: source == "cron" ? id : nil,
                outputPreview: source == "cron_output" ? row["preview"] as? String : nil)
        }
    }

    static func parseMCPServers(_ output: String) -> [MCPServerSummary] {
        let clean = output.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
        return clean.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                !text.localizedCaseInsensitiveContains("MCP Servers:"),
                !text.localizedCaseInsensitiveContains("No MCP servers configured"),
                !text.hasPrefix("─")
            else { return nil }

            let columns = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard columns.count >= 4,
                columns[0].lowercased() != "name",
                let toolMarkerIndex = columns.firstIndex(where: { $0 == "all" || $0 == "selected" || $0 == "excluded" })
            else { return nil }

            let toolIndex = columns[toolMarkerIndex] == "all" ? toolMarkerIndex : toolMarkerIndex - 1
            guard toolIndex > 1, toolMarkerIndex + 1 < columns.count else { return nil }

            let name = columns[0]
            let transport = columns[1..<toolIndex].joined(separator: " ")
            let tools = columns[toolIndex...toolMarkerIndex].joined(separator: " ")
            let status = columns[(toolMarkerIndex + 1)...].joined(separator: " ").lowercased()
            return MCPServerSummary(
                id: name,
                name: name,
                transport: transport,
                tools: tools,
                isEnabled: !status.contains("disabled")
            )
        }
    }

    static func reminderAttention(for reminder: ReminderSummary) -> AttentionItem {
        let detail = [reminder.isOverdue ? "OVERDUE" : nil, reminder.list].compactMap { $0 }.joined(separator: "  ·  ")
        return AttentionItem(
            id: "reminder:\(reminder.id)",
            reference: ControlReference(source: .appleReminder, sourceID: reminder.id),
            kind: .reminder,
            title: reminder.title,
            detail: detail.isEmpty ? "Apple Reminder" : detail,
            createdAt: reminder.dueDate ?? Date(),
            state: .open,
            actions: [.complete, .dismiss]
        )
    }

    static func parseProjects(_ result: [String: Any]) -> [ProjectSummary] {
        let activeID = result["active_id"] as? String
        let rows = (result["projects"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let repos = (row["repos"] as? [[String: Any]]) ?? (row["repositories"] as? [[String: Any]]) ?? []
            let sessions = (row["sessions"] as? [[String: Any]]) ?? (row["preview_sessions"] as? [[String: Any]]) ?? []
            let declaredSessionCount = (row["session_count"] as? NSNumber)?.intValue
            // Projects can return session records inside their repository lanes,
            // while `session_count` is absent or stale. Preserve a larger
            // declared total but never hide the sessions that are present.
            let projectSessions = parseProjectSessions(row)
            let sessionCount = max(max(declaredSessionCount ?? 0, sessions.count), projectSessions.count)
            return ProjectSummary(
                id: id,
                name: projectPath(row, repos: repos) ?? (row["name"] as? String) ?? id,
                repoCount: (row["repo_count"] as? NSNumber)?.intValue ?? repos.count,
                sessionCount: sessionCount,
                sessionIDs: Set(projectSessions.map(\.id)),
                preview: (sessions.first?["preview"] as? String) ?? (sessions.first?["title"] as? String),
                isActive: (row["active"] as? Bool) ?? (id == activeID)
            )
        }
    }

    /// The sidebar treats `ProjectSummary.name` as the repository path, but projects
    /// created through `projects.create` carry a display name. Prefer the first
    /// repository's path whenever the declared name is not already a path.
    static func projectPath(_ row: [String: Any], repos: [[String: Any]]) -> String? {
        if let name = row["name"] as? String, name.hasPrefix("/") { return name }
        for repo in repos {
            for key in ["path", "root", "repo_path", "folder", "cwd"] {
                if let path = repo[key] as? String, path.hasPrefix("/") { return path }
            }
        }
        return nil
    }

    static func parseProjectSessions(_ result: [String: Any]) -> [SessionSummary] {
        var rows: [[String: Any]] = []

        func walk(_ value: Any) {
            if let row = value as? [String: Any] {
                let looksLikeSession =
                    row["state"] != nil || row["status"] != nil || row["preview"] != nil || row["last_message"] != nil
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
            let title = (row["title"] as? String) ?? (row["name"] as? String) ?? "Hermes session"
            let state = (row["state"] as? String) ?? (row["status"] as? String) ?? "active"
            let preview = row["preview"] as? String ?? row["last_message"] as? String
            let updatedAt =
                activityDate(row["updated_at"])
                ?? activityDate(row["last_active"])
                ?? activityDate(row["last_message_at"])
                ?? activityDate(row["started_at"])
            return SessionSummary(id: id, title: title, state: state, preview: preview, updatedAt: updatedAt)
        }
    }
}
