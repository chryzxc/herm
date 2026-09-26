import SwiftUI

enum SessionActivityOverviewPresentation {
    enum Source: String, Equatable {
        case agent, bot, kanban
    }

    struct AgentRow: Identifiable, Equatable {
        let agent: HermesSubagent
        let eventCount: Int
        let isLive: Bool
        var id: String { agent.id }

        var displayName: String {
            let name = agent.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty { return name }
            let role = agent.role?.trimmingCharacters(in: .whitespacesAndNewlines)
            return role?.isEmpty == false ? role! : "Agent"
        }

        var detail: String {
            let values = [agent.model, agent.sourceSkill, agent.role]
                .compactMap { value -> String? in
                    guard let value else { return nil }
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty || trimmed.caseInsensitiveCompare(displayName) == .orderedSame ? nil : trimmed
                }
            return values.first ?? "Hermes delegate"
        }
    }

    struct WorkRow: Identifiable, Equatable {
        let id: String
        let source: Source
        let title: String
        let status: String
        let actor: String
        let updatedAt: Date?
        let detail: String?
        let result: String?
    }

    struct TimelineRow: Identifiable, Equatable {
        let id: String
        let source: Source
        let title: String
        let status: String
        let actor: String
        let timestamp: Date?
        let detail: String?
        let diffPreview: String?
        let durationSeconds: TimeInterval?
        let startedAt: Date?
        let completedAt: Date?
    }

    struct Snapshot: Equatable {
        let agents: [AgentRow]
        let work: [WorkRow]
        let timeline: [TimelineRow]
        let liveAgentCount: Int
        let blockedWorkCount: Int

        var hasContent: Bool { !agents.isEmpty || !work.isEmpty || !timeline.isEmpty }
    }

    static func makeSnapshot(
        agentSnapshot: AgentPresentationSnapshot,
        botRecords: [BotActivityRecord],
        kanbanTasks: [KanbanTaskSummary]
    ) -> Snapshot {
        let kanbanIDs = Set(kanbanTasks.map(\.id))
        let directBotRecords = botRecords
            .filter { !$0.isKanbanReference && ($0.linkedCardID == nil || !kanbanIDs.contains($0.linkedCardID!)) }

        let agents = uniqueAgents(agentSnapshot.displayedSubagents).map { agent in
            AgentRow(
                agent: agent,
                eventCount: agentSnapshot.activityCountsByAgentID[agent.id] ?? 0,
                isLive: agentSnapshot.activeAgentIDs.contains(agent.id)
            )
        }

        let kanbanWork = kanbanTasks
            .filter { !SessionKanbanActivityPresentation.Status(rawValue: $0.status).isCompleted }
            .map { task in
                WorkRow(
                    id: "kanban:\(task.id)",
                    source: .kanban,
                    title: task.title,
                    status: SessionKanbanActivityPresentation.Status(rawValue: task.status).label,
                    actor: task.assignee ?? "Unassigned",
                    updatedAt: task.latestEventAt ?? task.startedAt,
                    detail: task.detail,
                    result: task.latestEventNote
                )
            }
        let botWork = directBotRecords
            .filter { $0.state != .completed && $0.state != .canceled }
            .map { record in
                WorkRow(
                    id: "bot:\(record.id)",
                    source: .bot,
                    title: record.summary,
                    status: record.state.label,
                    actor: record.botName,
                    updatedAt: record.updatedAt,
                    detail: nil,
                    result: record.result
                )
            }
        let work = (kanbanWork + botWork).sorted { lhs, rhs in
            let lhsDate = lhs.updatedAt ?? .distantPast
            let rhsDate = rhs.updatedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.id < rhs.id
        }

        var timeline = agentSnapshot.pipeline.map { item in
            TimelineRow(
                id: "agent:\(item.id)", source: .agent, title: item.task,
                status: item.status, actor: item.agent, timestamp: item.timestamp,
                detail: item.detail, diffPreview: item.diffPreview,
                durationSeconds: item.durationSeconds, startedAt: item.startedAt,
                completedAt: item.completedAt
            )
        }
        timeline.append(contentsOf: directBotRecords.map { record in
            TimelineRow(
                id: "bot:\(record.id)", source: .bot, title: record.summary,
                status: record.state.label, actor: record.botName,
                timestamp: record.updatedAt, detail: nil, diffPreview: nil,
                durationSeconds: nil, startedAt: record.createdAt,
                completedAt: record.state == .completed ? record.updatedAt : nil
            )
        })
        timeline.append(contentsOf: kanbanTasks.compactMap { task in
            guard let timestamp = task.latestEventAt ?? task.completedAt ?? task.startedAt else { return nil }
            return TimelineRow(
                id: "kanban:\(task.id):\(timestamp.timeIntervalSince1970)", source: .kanban,
                title: task.title,
                status: SessionKanbanActivityPresentation.Status(rawValue: task.status).label,
                actor: task.assignee ?? "Unassigned", timestamp: timestamp,
                detail: task.detail ?? task.latestEventNote, diffPreview: nil,
                durationSeconds: task.startedAt.flatMap { task.completedAt?.timeIntervalSince($0) },
                startedAt: task.startedAt, completedAt: task.completedAt
            )
        })
        timeline.sort {
            let lhsDate = $0.timestamp ?? .distantPast
            let rhsDate = $1.timestamp ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return $0.id < $1.id
        }

        let blockedCount = work.filter {
            let status = $0.status.lowercased()
            return status.contains("blocked") || status.contains("waiting")
        }.count
        return Snapshot(
            agents: agents,
            work: work,
            timeline: timeline,
            liveAgentCount: agentSnapshot.activeAgentIDs.count,
            blockedWorkCount: blockedCount
        )
    }

    private static func uniqueAgents(_ agents: [HermesSubagent]) -> [HermesSubagent] {
        var seen = Set<String>()
        return agents.filter { seen.insert($0.id).inserted }
    }
}

struct SessionActivityOverviewView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var control: ControlCenterModel
    @ObservedObject var botMode: BotModeModel
    let sessionID: String?

    private enum AgentScope: String, CaseIterable, Identifiable {
        case live = "Live"
        case all = "All"
        var id: Self { self }
    }

    private enum AgentView: String, CaseIterable, Identifiable {
        case list = "List"
        case map = "Map"
        var id: Self { self }
    }

    @State private var agentScope = AgentScope.live
    @State private var agentView = AgentView.list
    @State private var expandedAgentID: String?
    @State private var expandedTimelineIDs: Set<String> = []
    @State private var expandedWorkIDs: Set<String> = []
    @State private var timelineLimit = 20
    @State private var selectedAgentID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var botRecords: [BotActivityRecord] {
        _ = model.botActivityRevision
        var records = model.botActivityBySessionID.values.flatMap { $0 }
        let sessionIDs = Set(model.botActivitySessionIDs.compactMap { $0 }.filter { !$0.isEmpty })
        let knownResults = Set(records.filter { sessionIDs.contains($0.originSessionID) }.compactMap(\.result))
        if let originSessionID = model.kanbanSessionID ?? sessionID {
            for (index, message) in model.messages.enumerated() {
                guard let botID = message.botProfileID,
                      message.role == .hermes,
                      !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !knownResults.contains(message.text) else { continue }
                let request = index > 0 && model.messages[index - 1].role == .user ? model.messages[index - 1].text : "Bot response"
                records.append(BotActivityRecord(
                    originSessionID: originSessionID, botID: botID,
                    botName: message.botDisplayName ?? botID, summary: request,
                    state: .completed, createdAt: message.timestamp,
                    updatedAt: message.timestamp, result: message.text
                ))
            }
        }
        let sessionSet = Set(model.botActivitySessionIDs.compactMap { $0 })
        return records.filter { sessionSet.isEmpty || sessionSet.contains($0.originSessionID) }
    }

    private var snapshot: SessionActivityOverviewPresentation.Snapshot {
        SessionActivityOverviewPresentation.makeSnapshot(
            agentSnapshot: model.agentPresentationSnapshot,
            botRecords: botRecords,
            kanbanTasks: sessionID == nil || control.sessionKanbanSessionID != sessionID ? [] : control.sessionKanbanTasks
        )
    }

    private var visibleAgents: [SessionActivityOverviewPresentation.AgentRow] {
        agentScope == .all ? snapshot.agents : snapshot.agents.filter(\.isLive)
    }

    private var visibleMapAgents: [HermesSubagent] {
        let ids = Set(visibleAgents.map(\.id))
        return model.agentPresentationSnapshot.displayedSubagents.filter { ids.contains($0.id) }
    }

    private var refreshState: ProjectionRefreshState? { control.refreshState(for: "kanban.session") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            pageHeader
            if !snapshot.hasContent, refreshState?.isRefreshing == true, refreshState?.lastSuccess == nil {
                DockLoadingState(title: "Loading session activity…")
            } else if !snapshot.hasContent {
                unifiedEmptyState
            } else {
                if !snapshot.work.isEmpty || refreshState?.error != nil { currentWorkSection }
                if !snapshot.agents.isEmpty { agentsSection }
                if !snapshot.timeline.isEmpty { recentActivitySection }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task(id: sessionID) { await refreshActivity() }
    }

    private var pageHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(refreshState?.error != nil ? "Couldn’t refresh activity" : "Session activity")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(refreshState?.error != nil ? Color.dockWarning : Color.dockSecondaryText)
            Spacer(minLength: 8)
            Button { Task { await refreshActivity() } } label: {
                Group {
                    if botMode.isRefreshing || refreshState?.isRefreshing == true {
                        ProgressView().controlSize(.small)
                    } else {
                        DockIcon(.arrowsClockwise)
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .foregroundStyle(Color.dockSecondaryText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(botMode.isRefreshing || refreshState?.isRefreshing == true)
            .help("Refresh session activity")
            .accessibilityLabel("Refresh session activity")
        }
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Agents", detail: "") {
                Menu {
                    Picker("Scope", selection: $agentScope) {
                        ForEach(AgentScope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Divider()
                    ForEach(AgentView.allCases) { view in
                        Button(view.rawValue) { agentView = view }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(agentView.rawValue)
                        DockIcon(.caretDown)
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(minWidth: 58, minHeight: 32)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Agent view: \(agentView.rawValue)")
            }
            if agentView == .map {
                AgentHandoffMapView(
                    model: model,
                    selectedAgentID: $selectedAgentID,
                    allowsContinuousAnimation: !reduceMotion,
                    agents: visibleMapAgents
                )
                .frame(minHeight: 320, maxHeight: 460)
            } else if visibleAgents.isEmpty {
                compactEmpty("No agents in this scope.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(visibleAgents) { row in agentRow(row) }
                }
            }
        }
    }

    private func agentRow(_ row: SessionActivityOverviewPresentation.AgentRow) -> some View {
        let selected = expandedAgentID == row.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .dockEase(duration: 0.16)) {
                    expandedAgentID = selected ? nil : row.id
                }
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(agentColor(for: row.id).opacity(0.2))
                        .overlay {
                            Circle().stroke(agentColor(for: row.id), lineWidth: 1.2)
                            Text(String(row.displayName.prefix(1)).uppercased())
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.dockPrimaryText)
                        }
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.dockPrimaryText)
                            .lineLimit(1)
                        Text(row.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dockSecondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text("\(row.eventCount) EVENTS")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.dockMetadataText)
                    Circle().fill(row.isLive ? Color.dockSuccess : Color.dockMetadataText).frame(width: 6, height: 6)
                    Text(row.agent.status.capitalized)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(row.isLive ? Color.dockSuccess : Color.dockSecondaryText)
                    DockIcon(selected ? .caretUp : .caretDown)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.dockMetadataText)
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            if selected {
                agentHistory(for: row)
                    .padding(.leading, 52)
                    .padding(.bottom, 10)
            }
            Color.dockBorderLight.frame(height: 0.5)
        }
        .background(selected ? Color.dockAccent.opacity(0.08) : Color.clear)
    }

    private func agentHistory(for row: SessionActivityOverviewPresentation.AgentRow) -> some View {
        let items = snapshot.timeline.filter { $0.actor == row.displayName || $0.actor.contains(row.displayName) }.prefix(5)
        return VStack(alignment: .leading, spacing: 5) {
            if items.isEmpty {
                Text("No recorded activity for this agent yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockMetadataText)
            } else {
                ForEach(Array(items)) { item in timelineText(item) }
            }
        }
        .padding(.top, 2)
    }

    private var currentWorkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("In progress", detail: "") { EmptyView() }
            if snapshot.work.isEmpty {
                compactEmpty(refreshState?.error == nil ? "No session-attributed work is active." : "Session work is unavailable; retry to refresh.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(snapshot.work) { workRow($0) }
                }
                if let error = refreshState?.error {
                    Text(refreshState?.isStale == true ? "STALE · \(error)" : error)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockWarning)
                        .padding(.top, 6)
                }
            }
        }
    }

    private func workRow(_ row: SessionActivityOverviewPresentation.WorkRow) -> some View {
        let expanded = expandedWorkIDs.contains(row.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if expanded { expandedWorkIDs.remove(row.id) } else { expandedWorkIDs.insert(row.id) }
            } label: {
                HStack(spacing: 8) {
                    statusDot(row.status)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                        Text("\(row.status) · \(row.actor)").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(statusColor(row.status)).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if let updatedAt = row.updatedAt { Text(HumanDateFormatting.timeOnly(updatedAt)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.dockMetadataText) }
                    DockIcon(expanded ? .caretUp : .caretDown).font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.dockMetadataText)
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    if let detail = row.detail { Text(detail).textSelection(.enabled) }
                    if let result = row.result { Text(result).textSelection(.enabled) }
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.dockSecondaryText)
                .padding(.leading, 25)
                .padding(.bottom, 9)
            }
            Color.dockBorderLight.frame(height: 0.5)
        }
    }

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Recent", detail: "") { EmptyView() }
            if snapshot.timeline.isEmpty {
                compactEmpty("No activity events have been received yet.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(snapshot.timeline.prefix(timelineLimit))) { timelineRow($0) }
                }
                if snapshot.timeline.count > 20 {
                    Button {
                        withAnimation(reduceMotion ? nil : .dockEase(duration: 0.16)) {
                            timelineLimit = timelineLimit >= snapshot.timeline.count ? 20 : min(timelineLimit + 20, snapshot.timeline.count)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(timelineLimit >= snapshot.timeline.count ? "Show recent" : "Show \(min(20, snapshot.timeline.count - timelineLimit)) more")
                            DockIcon(timelineLimit >= snapshot.timeline.count ? .caretUp : .caretDown)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.dockAccent)
                        .frame(minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func timelineRow(_ row: SessionActivityOverviewPresentation.TimelineRow) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            timelineRowContent(row, now: context.date)
        }
    }

    private func timelineRowContent(_ row: SessionActivityOverviewPresentation.TimelineRow, now: Date) -> some View {
        let expanded = expandedTimelineIDs.contains(row.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if expanded { expandedTimelineIDs.remove(row.id) } else { expandedTimelineIDs.insert(row.id) }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    statusDot(row.status).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                        HStack(spacing: 5) {
                            Text(row.status)
                            Text("·")
                            Text(row.actor).lineLimit(1)
                            if let timestamp = row.timestamp { Text("·"); Text(HumanDateFormatting.timeOnly(timestamp)).monospacedDigit() }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockMetadataText)
                    }
                    Spacer(minLength: 4)
                    DockIcon(expanded ? .caretUp : .caretDown).font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.dockMetadataText)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let detail = row.detail { Text(detail).textSelection(.enabled) }
                    if let diff = row.diffPreview { Text(diff).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    if let duration = duration(for: row, now: now) { Text("Duration · \(formatDuration(duration))").font(.system(size: 10, design: .monospaced)) }
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.dockSecondaryText)
                .padding(.leading, 24)
                .padding(.bottom, 9)
            }
            Color.dockBorderLight.frame(height: 0.5)
        }
    }

    private func timelineText(_ row: SessionActivityOverviewPresentation.TimelineRow) -> some View {
        HStack(spacing: 5) {
            statusDot(row.status)
            Text(row.title).lineLimit(1)
        }
        .font(.system(size: 10))
        .foregroundStyle(Color.dockSecondaryText)
    }

    private func sectionHeader<T: View>(_ title: String, detail: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dockSecondaryText)
            Spacer(minLength: 4)
            Text(detail).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.dockMetadataText)
            trailing()
        }
    }

    private var unifiedEmptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            DockIcon(.pulse).foregroundStyle(Color.dockMetadataText)
            Text("No session activity yet.").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dockPrimaryText)
            Text("Hermes activity will appear here when agents or session-linked work begin.").font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
        }
        .padding(.vertical, 12)
    }

    private func compactEmpty(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    }

    private func statusDot(_ status: String) -> some View { Circle().fill(statusColor(status)).frame(width: 7, height: 7) }

    private func statusColor(_ status: String) -> Color {
        let value = status.lowercased()
        if value.contains("complete") || value.contains("done") { return .dockSuccess }
        if value.contains("fail") || value.contains("error") { return .dockDestructive }
        if value.contains("block") || value.contains("wait") || value.contains("interrupt") { return .dockWarning }
        if value.contains("queue") || value.contains("pending") { return .dockMetadataText }
        return .dockAccent
    }

    private func agentColor(for id: String) -> Color {
        let palette: [Color] = [.dockAccent, .purple, .orange, .mint, .yellow, .blue]
        let hash = id.utf8.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1) }
        return palette[Int(hash % UInt64(palette.count))]
    }

    private func duration(for row: SessionActivityOverviewPresentation.TimelineRow, now: Date) -> TimeInterval? {
        if let duration = row.durationSeconds { return duration }
        guard let started = row.startedAt else { return nil }
        if let completed = row.completedAt { return completed.timeIntervalSince(started) }
        guard isActiveStatus(row.status) else { return nil }
        return now.timeIntervalSince(started)
    }

    private func isActiveStatus(_ status: String) -> Bool {
        let value = status.lowercased()
        return !value.contains("complete") && !value.contains("done") &&
            !value.contains("fail") && !value.contains("error") &&
            !value.contains("block") && !value.contains("wait")
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded(.down)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }

    private func refreshActivity() async {
        await botMode.refreshNow(force: true)
        if let sessionID { control.refreshSessionKanban(for: sessionID) }
    }
}
