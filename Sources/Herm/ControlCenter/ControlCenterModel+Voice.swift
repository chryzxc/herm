import Foundation

/// Voice reads Control Center's projections as they are: a reminder countdown from
/// Hermes' cron list, and briefing facts that name any source that isn't loaded.
extension ControlCenterModel {
    /// Runs before `dockModel` changes, so the previous model stops counting down.
    func bindVoiceAssistant(to model: DockModel) {
        if let previous = dockModel, previous !== model {
            previous.voiceTimers.detach()
            previous.briefingFacts = nil
        }
        let timers = model.voiceTimers
        timers.onDue = { [weak model] timer in model?.announceVoiceTimer(timer) }
        timers.onCancel = { [weak self] timer in self?.cancelVoiceTimer(timer) }
        timers.observeWake()
        model.briefingFacts = { [weak self] in await self?.voiceBriefingFacts() ?? VoiceBriefing.Facts() }
    }

    /// Deletes the reminder's Hermes job; the countdown leaves on the next `cron.changed`.
    func cancelVoiceTimer(_ timer: VoiceTimer) {
        guard timer.canCancel, let job = cronJobs.first(where: { $0.id == timer.id }),
            AssistantTimers.due(job) == timer.due
        else { return }
        removeCron(job, expectedTimerDeadline: timer.due)
    }

    func voiceBriefingFacts(now: Date = .now, calendar: Calendar = .current) async -> VoiceBriefing.Facts {
        var facts = VoiceBriefing.Facts()
        if let events = await SystemCalendarService.todayEvents(now: now, calendar: calendar) {
            facts.calendar = .items(
                events.map { VoiceBriefing.eventLine(title: $0.title, start: $0.start, isAllDay: $0.isAllDay) })
        }
        let dueToday = reminders.filter { reminder in
            reminder.isOverdue || reminder.dueDate.map { calendar.isDate($0, inSameDayAs: now) } == true
        }
        facts.reminders = briefingSection("reminders", dueToday.map(VoiceBriefing.reminderLine))
        facts.automations = briefingSection(
            "cron.jobs", VoiceBriefing.automationLines(cronJobs, now: now, calendar: calendar))
        facts.attention = .items(attention.filter { $0.state == .open }.map(\.title))
        facts.tasks = briefingSection("kanban.global", VoiceBriefing.taskLines(globalKanbanTasks))
        facts.timers = (dockModel?.voiceTimers.timers ?? []).filter { !$0.isDue }.map {
            "\($0.name) at \(HumanDateFormatting.timeOnly($0.due))"
        }
        facts.heldBack = interruptionCoordinator?.entries.count ?? 0
        return facts
    }

    /// A projection that never loaded or failed reads as such, never as "none".
    private func briefingSection(_ projection: String, _ items: [String]) -> VoiceBriefing.Section {
        switch projectionState(for: projection) {
        case .ready, .empty: .items(items)
        case .stale: items.isEmpty ? .unavailable("couldn't refresh") : .items(items + ["this may be out of date"])
        case .unavailable, .failed: .unavailable("not connected")
        case .loading, nil: .unavailable("not loaded")
        }
    }
}

extension ControlCenterModel {
    func voiceWork(_ intent: AssistantIntent, now: Date = .now) async -> AssistantReply {
        guard dockModel?.isHermesConnected == true else { return AssistantReply("Hermes is unavailable.") }
        switch intent {
        case .approvals:
            rebuildAttention()
            let approvals = attention.filter { $0.kind == .approval && $0.state == .open }
            if approvals.isEmpty { return AssistantReply("Control Center has no open approvals.") }
            let titles = approvals.map(\.title)
            return AssistantReply(
                voiceWorkList(titles),
                visual: voiceWorkPreview("Open approvals", columns: ["Request"], rows: titles.map { [$0] }))
        case .activity(let sinceLunch):
            return await voiceActivity(sinceLunch: sinceLunch, now: now)
        case .task(let title, let board):
            return await voiceTask(title: title, board: board)
        default: return AssistantReply("That work command is unavailable.")
        }
    }

    private func voiceActivity(sinceLunch: Bool, now: Date) async -> AssistantReply {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let start: Date
        if sinceLunch {
            guard let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: today), noon <= now else {
                return AssistantReply("It's before noon. Ask what finished today.")
            }
            start = noon
        } else {
            start = today
        }
        guard let rpc else { return AssistantReply("I couldn't load recent activity.") }
        let binding = clientBindingGeneration
        let sessionLimit = 24
        let messageLimit = 40
        guard let page = try? await rpc.sessionPages(limit: sessionLimit, order: "recent", timeout: 3),
            let sessions = Self.parseSessions(page),
            sessions.count <= sessionLimit, clientBindingGeneration == binding, !Task.isCancelled,
            (page["storage"] as? [String: String] ?? [:]).isEmpty
        else { return AssistantReply("I couldn't load recent activity.") }

        let window = start...now
        let recentSessions = sessions.filter { ($0.updatedAt ?? now) >= start }
        var partial = Self.parseHasMore(page) != false || recentSessions.contains { $0.updatedAt == nil }
        var stepsBySessionID: [String: [SessionActivityStep]] = [:]
        for index in stride(from: 0, to: recentSessions.count, by: 6) {
            guard !Task.isCancelled, clientBindingGeneration == binding else {
                return AssistantReply("I couldn't load recent activity.")
            }
            let batch = Array(recentSessions[index..<min(index + 6, recentSessions.count)])
            let fetched = await withTaskGroup(
                of: (String, [SessionActivityStep]?, Bool).self,
                returning: [(String, [SessionActivityStep]?, Bool)].self
            ) { group in
                for session in batch {
                    group.addTask { [weak self] in
                        guard let self, !Task.isCancelled else { return (session.id, nil, true) }
                        let (steps, truncated) = await voiceActivitySteps(
                            in: session, from: rpc, window: window, limit: messageLimit)
                        return (session.id, steps, truncated)
                    }
                }

                var values: [(String, [SessionActivityStep]?, Bool)] = []
                for await value in group {
                    values.append(value)
                }
                return values
            }
            for (id, steps, truncated) in fetched {
                partial = partial || truncated
                guard let steps else { continue }
                let replies = steps.filter(\.isCompletedReply)
                let latest = replies.max { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
                stepsBySessionID[id] = sinceLunch ? steps : latest.map { [$0] } ?? []
            }
        }
        guard !Task.isCancelled, clientBindingGeneration == binding,
            recentSessions.isEmpty || !stepsBySessionID.isEmpty
        else { return AssistantReply("I couldn't load recent activity.") }
        let changes = GlobalSessionActivityPresentation.latestActivity(
            recentSessions, stepsBySessionID: stepsBySessionID, limit: .max)
        let coverage = partial ? " I could only check part of the recent history." : ""
        if changes.isEmpty {
            let empty = sinceLunch ? "I found no changes since noon." : "I found no completed replies today."
            return AssistantReply(empty + coverage)
        }
        let title = sinceLunch ? "Changes since noon" : "Completed replies today"
        let visual = voiceWorkPreview(
            partial ? title + " (partial)" : title, columns: ["Conversation", "Activity"],
            rows: changes.prefix(100).map { [$0.sessionTitle, $0.activityName] })
        if !sinceLunch {
            return AssistantReply(
                "Completed replies today. "
                    + voiceWorkList(changes.map(\.sessionTitle), moreLocation: "in the checked history") + coverage,
                visual: visual)
        }
        let lines = changes.map { "\($0.sessionTitle): \($0.activityName)" }
        return AssistantReply(voiceWorkList(lines, moreLocation: "in the checked history") + coverage, visual: visual)
    }

    private func voiceActivitySteps(
        in session: SessionSummary, from rpc: HermesControlRPC, window: ClosedRange<Date>, limit: Int
    ) async -> ([SessionActivityStep]?, Bool) {
        guard
            let page = try? await rpc.sessionMessages(
                sessionID: session.id, profileID: session.profileID, latest: true, limit: limit, inlineImages: false,
                timeout: 3),
            let rows = page["data"] as? [[String: Any]],
            let steps = Self.parseActivityStepsEnvelope(page)
        else { return (nil, true) }
        let timestamps = rows.compactMap { Self.activityDate($0["timestamp"]) }
        let truncated =
            timestamps.count != rows.count
            || (rows.count >= limit && timestamps.min().map { $0 >= window.lowerBound } != false)
        return (steps.filter { window.contains($0.timestamp) }, truncated)
    }

    private func voiceTask(title: String, board: String?) async -> AssistantReply {
        guard !isCreatingKanbanTask else { return AssistantReply("A Kanban task is already being created.") }
        if !capabilityAvailable("kanban.create") {
            refreshSidebarCapabilities()
            await sidebarCapabilityTask?.value
            if !capabilityAvailable("kanban.create") { await refreshTask?.value }
        }
        guard capabilityAvailable("kanban.create"), let boards = await readVoiceBoards() else {
            return AssistantReply("Kanban task capture is unavailable.")
        }
        let selectedSlug = selectedKanbanBoardSlug ?? boards.first(where: \.isCurrent)?.slug ?? "default"
        let matches = boards.filter { candidate in
            guard let board else { return candidate.slug == selectedSlug }
            let name = AssistantIntent.normalized(board)
            return AssistantIntent.normalized(candidate.name) == name
                || AssistantIntent.normalized(candidate.slug) == name
        }
        if matches.count == 1, let selected = matches.first {
            return confirmVoiceTask(title: title, slug: selected.slug, name: selected.name)
        }
        if !matches.isEmpty {
            return .choose("Which Kanban board?", choices: matches.map { ("\($0.name), \($0.slug)", $0) }) {
                [weak self] chosen in
                self?.confirmVoiceTask(title: title, slug: chosen.slug, name: chosen.name)
                    ?? AssistantReply("Kanban is unavailable.")
            }
        }
        return AssistantReply("I couldn't identify the board. Say the name of an active Kanban board.")
    }

    private func readVoiceBoards() async -> [KanbanBoardSummary]? {
        guard let cli else { return nil }
        let binding = clientBindingGeneration
        let result: HermesCLIResult?
        if let http = try? await cli.kanbanBoardsOverHTTP() {
            result = http
        } else if capabilityAvailable("kanban.boards") {
            result = try? await cli.kanbanBoards()
        } else {
            return nil
        }
        guard !Task.isCancelled, clientBindingGeneration == binding, let result, result.succeeded else { return nil }
        return Self.parseKanbanBoards(result.stdout).filter { !$0.archived }
    }

    private func confirmVoiceTask(title: String, slug: String, name: String) -> AssistantReply {
        let binding = clientBindingGeneration
        return .confirm("Add “\(title)” to \(name)?") { [weak self] in
            guard let self, clientBindingGeneration == binding, let boards = await readVoiceBoards(),
                clientBindingGeneration == binding, !isCreatingKanbanTask,
                boards.contains(where: { $0.slug == slug && $0.name == name })
            else { return "That board is no longer available." }
            try Task.checkCancellation()
            return await createKanbanTask(title: title, body: "", boardSlug: slug)
                ? "Added “\(title)” to \(name)."
                : "I couldn't verify the task was added. Check \(name) before trying again."
        }
    }

    private func voiceWorkPreview(_ title: String, columns: [String], rows: [[String]]) -> String? {
        guard GenerativeUIIntegration.isEnabled else { return nil }
        return VoicePassiveVisual.table(title: title, columns: columns, rows: Array(rows.prefix(100)))
    }

    private func voiceWorkList(_ lines: [String], moreLocation: String = "in Control Center") -> String {
        let shown = lines.prefix(4).joined(separator: ". ")
        return shown + "." + (lines.count > 4 ? " \(lines.count - 4) more \(moreLocation)." : "")
    }
}
