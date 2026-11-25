import SwiftUI

private enum OfficePreviewSelection: Equatable {
    case agent(String)
}

struct OfficePreviewView: View {
    let kanbanTasks: [KanbanTaskSummary]
    let bots: [BotSummary]
    let mainSessions: [OfficeMainSession]
    let liveWork: [BotLiveWork]
    let botActivity: BotActivityBoard
    let activityBySession: [ProfileScopedID: [LatestActivityItem]]
    let handoffTitles: [String: String]
    let recentEvents: [OfficeDeskEvent]
    let timelineSessions: Set<ProfileScopedID>
    let onOpenTimeline: (ProfileScopedID) -> Void
    let isOnline: Bool
    let onOpenSession: (String) -> Void
    let avatarImages: [String: Data]
    let canAssignTasks: Bool
    let isDataCurrent: Bool
    let onAssignTask: ((KanbanTaskSummary, String) -> Void)?
    let subtitle: String
    let onRefresh: () -> Void
    let isRefreshing: Bool
    @StateObject private var simulation: OfficePreviewSimulation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dockHostVisible) private var hostVisible
    @State private var selection: OfficePreviewSelection?
    @State private var cameraFocusID: String?
    @State private var cameraResetToken = 0
    @State private var wholeOffice = true
    @State private var showsAgents = true
    @State private var showsDesk = true
    @State private var deskTab: OfficeDeskTab = .work
    @State private var crewQuery = ""
    @State private var eventFilter: OfficeDeskEvent.Kind?
    // Not observed here: only the hover card and the scene read it.
    @State private var music = OfficeMusicService()

    init(
        kanbanTasks: [KanbanTaskSummary] = [], bots: [BotSummary] = [], mainSessions: [OfficeMainSession] = [],
        liveWork: [BotLiveWork] = [], botActivity: BotActivityBoard = BotActivityBoard(),
        activityBySession: [ProfileScopedID: [LatestActivityItem]] = [:], handoffTitles: [String: String] = [:],
        recentEvents: [OfficeDeskEvent] = [], timelineSessions: Set<ProfileScopedID> = [],
        onOpenTimeline: @escaping (ProfileScopedID) -> Void = { _ in }, isOnline: Bool = true,
        onOpenSession: @escaping (String) -> Void = { _ in }, avatarImages: [String: Data] = [:],
        canAssignTasks: Bool = false, isDataCurrent: Bool = true,
        subtitle: String = "Live bot assignments in a simulated 3D office", onRefresh: @escaping () -> Void = {},
        isRefreshing: Bool = false,
        onAssignTask: ((KanbanTaskSummary, String) -> Void)? = nil
    ) {
        self.kanbanTasks = kanbanTasks
        self.bots = bots
        self.mainSessions = mainSessions
        self.liveWork = liveWork
        self.botActivity = botActivity
        self.activityBySession = activityBySession
        self.handoffTitles = handoffTitles
        self.recentEvents = recentEvents
        self.timelineSessions = timelineSessions
        self.onOpenTimeline = onOpenTimeline
        self.isOnline = isOnline
        self.onOpenSession = onOpenSession
        self.avatarImages = avatarImages
        self.canAssignTasks = canAssignTasks
        self.isDataCurrent = isDataCurrent
        self.subtitle = subtitle
        self.onRefresh = onRefresh
        self.isRefreshing = isRefreshing
        self.onAssignTask = onAssignTask
        _simulation = StateObject(
            wrappedValue: OfficePreviewSimulation(
                bots: bots, tasks: kanbanTasks, sessions: mainSessions, liveWork: liveWork, botActivity: botActivity,
                kanbanCurrent: isDataCurrent))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DockPageHeader(
                title: "Office", subtitle: subtitle,
                onRefresh: onRefresh, isRefreshing: isRefreshing, windowBottomPadding: 0
            ) {
                Button(showsDesk ? "Hide desk" : "Show desk") { showsDesk.toggle() }
                    .buttonStyle(.dockSecondary)
            }

            Divider()
            GeometryReader { geometry in
                let compact = geometry.size.width < 760
                HStack(spacing: 0) {
                    if !compact && showsDesk {
                        desk.frame(width: min(364, geometry.size.width * 0.46))
                        Divider()
                    }
                    ZStack {
                        scene
                            .environment(\.dockHostVisible, hostVisible && (!compact || !showsDesk))
                            .opacity(compact && showsDesk ? 0 : 1)
                            .allowsHitTesting(!compact || !showsDesk)
                            .accessibilityHidden(compact && showsDesk)
                        if compact && showsDesk { desk }
                    }
                    .clipped()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await music.poll() }
        .onChange(of: kanbanTasks) { _, _ in updateProjection() }
        .onChange(of: bots) { _, _ in updateProjection() }
        .onChange(of: mainSessions) { _, _ in updateProjection() }
        .onChange(of: liveWork) { _, _ in updateProjection() }
        .onChange(of: botActivity) { _, _ in updateProjection() }
        .onChange(of: isDataCurrent) { _, _ in updateProjection() }
        .onChange(of: simulation.agents.map(\.id)) { _, ids in
            if case .agent(let id) = selection, !ids.contains(id) { selection = nil }
        }
    }

    private var scene: some View {
        OfficePreviewSceneView(
            agents: simulation.agents, avatarImages: avatarImages, reduceMotion: reduceMotion,
            resetToken: cameraResetToken, wholeOffice: wholeOffice, focusAgentID: cameraFocusID,
            onSelectAgent: { select($0) }, onSelectBoard: { openBoard() },
            boardLanes: simulation.board, showsAgents: showsAgents, isDataCurrent: isDataCurrent,
            selectedAgentID: selectedAgentID, palette: .current(isDark: colorScheme == .dark), music: music
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            OfficeToolbar(
                showsAgents: showsAgents, onToggleAgents: { showsAgents.toggle() }, onResetCamera: resetCamera
            )
            .dockPadding(.bottom, 12)
        }
    }

    private var desk: some View {
        VStack(spacing: 0) {
            if let selection {
                inspector(for: selection)
            } else {
                OfficeDeskView(
                    tab: $deskTab, crewQuery: $crewQuery, eventFilter: $eventFilter,
                    agents: rosterAgents, bots: bots, avatarImages: avatarImages, events: recentEvents,
                    lanes: simulation.board, isKanbanCurrent: isDataCurrent, isOnline: isOnline,
                    onFocus: focus
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dockCanvas)
    }

    @ViewBuilder
    private func inspector(for selection: OfficePreviewSelection) -> some View {
        switch selection {
        case .agent(let id):
            if let agent = simulation.agents.first(where: { $0.id == id }) {
                let bot = bots.first(where: { $0.id == id })
                OfficeAgentInspector(
                    agent: agent, bot: bot, avatarData: bot.flatMap { avatarImages[$0.id] },
                    status: OfficeAgentStatus(agent: agent, isDataCurrent: isDataCurrent),
                    isDataCurrent: isDataCurrent, canAssignTasks: canAssignTasks,
                    assignableTasks: assignableTasks, activityBySession: activityBySession,
                    handoffTitles: handoffTitles, timelineSessions: timelineSessions,
                    onOpenTimeline: onOpenTimeline, onOpenSession: onOpenSession,
                    onAssignTask: { onAssignTask?($0, agent.id) },
                    onClose: { self.selection = nil }
                )
            }
        }
    }

    private var selectedAgentID: String? {
        if case .agent(let id) = selection { return id }
        return nil
    }

    private var rosterAgents: [OfficePreviewAgentPresentation] {
        simulation.agents.sorted {
            let left = OfficeAgentStatus(agent: $0, isDataCurrent: isDataCurrent).rawValue
            let right = OfficeAgentStatus(agent: $1, isDataCurrent: isDataCurrent).rawValue
            return left == right ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : left < right
        }
    }

    private var assignableTasks: [KanbanTaskSummary] {
        kanbanTasks.filter {
            ($0.assignee?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                && $0.boardSlug != nil && [.todo, .triage, .ready, .scheduled].contains(OfficePreviewLane($0.status))
        }
    }

    private func updateProjection() {
        simulation.update(
            bots: bots, tasks: kanbanTasks, sessions: mainSessions, liveWork: liveWork, botActivity: botActivity,
            kanbanCurrent: isDataCurrent)
    }

    private func select(_ id: String) {
        selection = .agent(id)
        showsDesk = true
    }

    private func openBoard() {
        deskTab = .kanban
        selection = nil
        showsDesk = true
    }

    private func focus(_ id: String) {
        showsAgents = true
        select(id)
        cameraFocusID = id
        wholeOffice = false
        cameraResetToken += 1
    }

    private func resetCamera() {
        cameraFocusID = nil
        wholeOffice = true
        cameraResetToken += 1
    }
}

// MARK: - HUD components

/// The shared floating panel treatment for everything drawn over the scene.
private struct OfficeHUDPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View { content().dockHUDPanel() }
}

private struct OfficeStatusDot: View {
    let status: OfficeAgentStatus
    var size: CGFloat = 7

    var body: some View { DockStatusDot(tone: status.tone, size: size) }
}

private struct OfficeToolbar: View {
    let showsAgents: Bool
    let onToggleAgents: () -> Void
    let onResetCamera: () -> Void

    var body: some View {
        OfficeHUDPanel {
            HStack(spacing: 4) {
                iconButton(
                    .users, help: showsAgents ? "Hide bots" : "Show bots",
                    isOn: showsAgents, action: onToggleAgents)
                separator
                iconButton(.arrowCounterClockwise, help: "Reset camera", isOn: false, action: onResetCamera)
            }
            .dockPadding(5)
        }
        .fixedSize()
    }

    private var separator: some View {
        Rectangle().fill(Color.dockBorder).frame(width: 1, height: 18).dockPadding(.horizontal, 2)
    }

    private func iconButton(_ symbol: Ph, help: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DockIcon(symbol)
                .dockFont(.navigation, weight: .medium)
                .foregroundStyle(isOn ? Color.dockAccent : Color.dockSecondaryText)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius).fill(isOn ? Color.dockAccentMuted : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Inspectors

private struct OfficeInspectorHeader<Leading: View>: View {
    let title: String
    let subtitle: String
    let onClose: () -> Void
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            leading()
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .dockFont(.navigation, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(2)
                Text(subtitle)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockSecondaryText)
            }
            Spacer()
            Button(action: onClose) {
                DockIcon(.arrowLeft)
                    .dockFont(.metadata, weight: .semibold)
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.dockControlSurface))
            }
            .buttonStyle(.dockHover)
            .help("Back to Office desk")
            .accessibilityLabel("Back to Office desk")
        }
        .dockPadding(.horizontal, 14)
        .dockPadding(.vertical, 12)
    }
}

private struct OfficeAgentInspector: View {
    let agent: OfficePreviewAgentPresentation
    let bot: BotSummary?
    let avatarData: Data?
    let status: OfficeAgentStatus
    let isDataCurrent: Bool
    let canAssignTasks: Bool
    let assignableTasks: [KanbanTaskSummary]
    let activityBySession: [ProfileScopedID: [LatestActivityItem]]
    let handoffTitles: [String: String]
    let timelineSessions: Set<ProfileScopedID>
    let onOpenTimeline: (ProfileScopedID) -> Void
    let onOpenSession: (String) -> Void
    let onAssignTask: (KanbanTaskSummary) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OfficeInspectorHeader(
                title: agent.name, subtitle: bot == nil && agent.mainSession != nil ? "Main session" : "Bot",
                onClose: onClose
            ) {
                ZStack(alignment: .bottomTrailing) {
                    if let bot {
                        BotAvatarView(bot: bot, imageData: avatarData, size: 34)
                    } else {
                        DockIcon(.cpu)
                            .dockFont(size: 15)
                            .foregroundStyle(Color.dockAccent)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.dockControlSurface))
                    }
                    OfficeStatusDot(status: status, size: 10)
                        .overlay(Circle().stroke(Color.dockCanvas, lineWidth: 2))
                }
            }
            Divider().overlay(Color.dockBorderLight)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    OfficeStatusPill(
                        status: status,
                        text: status == .stale ? "Status not current" : agent.availabilityLabel)
                    if let session = agent.mainSession, bot == nil {
                        sessionContent(session)
                    } else {
                        if !agent.reportedWork.isEmpty {
                            OfficeCard(title: "Active work · \(agent.reportedWork.count)") {
                                if agent.liveWork?.title == nil, status == .blocked {
                                    Text("Blocking session details unavailable.")
                                        .dockFont(.metadata)
                                        .foregroundStyle(Color.dockSecondaryText)
                                }
                                ForEach(agent.reportedWork) { work in
                                    if work.id != agent.reportedWork.first?.id { Divider() }
                                    workRow(work)
                                }
                            }
                        } else if agent.liveWork != nil {
                            OfficeCard(title: "Current work") { liveWorkContent }
                        }
                        taskContent
                    }
                }
                .dockPadding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func workRow(_ work: BotLiveWork) -> some View {
        let target = work.sessionID.map { ProfileScopedID(profileID: work.profileID, resourceID: $0) }
        let recent = target.flatMap { activityBySession[$0] } ?? []
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(work.title ?? "Activity details unavailable")
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Text(work.status == .blocked ? "Blocked" : "Working")
                    .dockFont(.metadata, weight: .medium)
                    .foregroundStyle(work.status == .blocked ? OfficeAgentStatus.blocked.color : .dockMetadataText)
            }
            if let detail = work.detail {
                Text(detail)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockSecondaryText)
                    .textSelection(.enabled)
            }
            if let origin = work.originSessionID {
                Label(
                    handoffTitles[origin].map { "Handed off from \($0)" } ?? "Bot handoff",
                    icon: .arrowBendUpRight
                )
                .dockFont(.metadata)
                .foregroundStyle(Color.dockSecondaryText)
            }
            ForEach(recent.prefix(3)) { activity in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(activity.activityName)
                        .foregroundStyle(Color.dockSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(activity.timestamp, style: .time)
                        .monospacedDigit()
                        .foregroundStyle(Color.dockMetadataText)
                }
                .dockFont(.metadata)
            }
            if let target, timelineSessions.contains(target) {
                Button {
                    onOpenTimeline(target)
                } label: {
                    Label("Open session timeline", icon: .arrowUpRight)
                }
                .buttonStyle(.dockLink)
                .accessibilityHint("Opens the conversation and its Timeline inspector")
            }
        }
    }

    @ViewBuilder
    private func sessionContent(_ session: OfficeMainSession) -> some View {
        Button {
            onOpenSession(session.id)
        } label: {
            Label("Open conversation", icon: .chats)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.dockPrimary)
        .tint(Color.dockAccent)
        OfficeCard(title: "Current work") {
            liveWorkContent
            Text(session.isCurrent ? "Current conversation" : "Background conversation")
                .dockFont(.metadata)
                .foregroundStyle(Color.dockSecondaryText)
        }
        OfficeCard(title: "Recent activity") {
            if session.activities.isEmpty {
                Text("No recent activity available.")
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
            }
            ForEach(session.activities) { activity in
                HStack(alignment: .firstTextBaseline) {
                    Text(activity.name)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockPrimaryText)
                    Spacer(minLength: 8)
                    Text(activity.timestamp, style: .time)
                        .dockFont(.metadata).monospacedDigit()
                        .foregroundStyle(Color.dockMetadataText)
                }
            }
        }
    }

    @ViewBuilder
    private var liveWorkContent: some View {
        Text(agent.monitorTitle)
            .dockFont(.body, weight: .semibold)
            .foregroundStyle(Color.dockPrimaryText)
            .textSelection(.enabled)
        if let detail = agent.liveWork?.detail {
            Text(detail)
                .dockFont(.metadata)
                .foregroundStyle(Color.dockSecondaryText)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var taskContent: some View {
        if let task = agent.taskData {
            OfficeCard(title: agent.liveWork == nil ? "Current task" : "Kanban task") {
                Text(task.title)
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let step = task.currentStepKey ?? task.latestEventNote {
                    Label(step.replacingOccurrences(of: "_", with: " "), icon: .arrowBendUpRight)
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockSecondaryText)
                }
                if task.lane == .running, let started = task.startedAt {
                    Label {
                        Text("Running for ") + Text(started, style: .relative)
                    } icon: {
                        DockIcon(.clock)
                    }
                    .dockFont(.metadata).monospacedDigit()
                    .foregroundStyle(Color.dockSecondaryText)
                }
                if let work = agent.work, agent.liveWork == nil {
                    OfficeField(label: "Work", value: "\(work.kind.title) · \(work.evidence)")
                }
            }
            OfficeCard(title: "Task details") { OfficeTaskFields(task: task) }
        }
        DockMenu {
            ForEach(assignableTasks) { task in Button(task.title) { onAssignTask(task) } }
        } label: {
            Label("Assign existing task…", icon: .plusCircle)
        }
        .disabled(!isDataCurrent || !canAssignTasks || assignableTasks.isEmpty)
        .help(
            canAssignTasks
                ? "Choose an unassigned Kanban task; confirm through Hermes."
                : "Task assignment is unavailable through the installed Hermes CLI.")
        if agent.tasks.count > 1 {
            OfficeCard(title: "Other assigned tasks · \(agent.tasks.count - 1)") {
                ForEach(Array(agent.tasks.dropFirst())) { task in
                    DisclosureGroup {
                        OfficeTaskFields(task: task).dockPadding(.top, 6)
                    } label: {
                        Text(task.title)
                            .dockFont(.body)
                            .foregroundStyle(Color.dockPrimaryText)
                            .lineLimit(2)
                    }
                    .disclosureGroupStyle(DockDisclosureGroupStyle())
                }
            }
        }
    }
}

struct OfficeBoardInspector: View {
    let lanes: [OfficePreviewBoardLane]
    let isCurrent: Bool
    @State private var expandedLanes: Set<OfficePreviewLane> = [.blocked, .running]
    @State private var selectedTaskID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isCurrent {
                Text(lanes.allSatisfy { $0.tasks.isEmpty } ? "Kanban is unavailable" : "Last reported tasks")
                    .dockFont(.body, weight: .medium)
                    .foregroundStyle(Color.dockSecondaryText)
                    .dockPadding(14)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    let populated = lanes.filter { !$0.tasks.isEmpty }.sorted { $0.lane.rank < $1.lane.rank }
                    if isCurrent && populated.isEmpty {
                        Text("No Kanban tasks reported.").dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    }
                    ForEach(populated) { lane in laneCard(lane) }
                }
                .dockPadding(14)
            }
        }
    }

    private func laneCard(_ lane: OfficePreviewBoardLane) -> some View {
        let expanded = expandedLanes.contains(lane.lane)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if expanded { expandedLanes.remove(lane.lane) } else { expandedLanes.insert(lane.lane) }
            } label: {
                HStack(spacing: 8) {
                    OfficeStatusDot(status: Self.status(for: lane.lane))
                    Text(lane.lane.rawValue.capitalized)
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                    Spacer()
                    Text("\(lane.tasks.count)")
                        .dockFont(.metadata, weight: .semibold).monospacedDigit()
                        .foregroundStyle(Color.dockSecondaryText)
                        .dockPill()
                    DockIcon(.caretRight)
                        .dockFont(.compactStatus, weight: .semibold)
                        .foregroundStyle(Color.dockMetadataText)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .dockPadding(.horizontal, 10)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if lane.tasks.isEmpty {
                        Text("No tasks").dockFont(.body).foregroundStyle(Color.dockMetadataText)
                    }
                    ForEach(lane.tasks) { task in
                        Button {
                            selectedTaskID = selectedTaskID == task.id ? nil : task.id
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                    .dockFont(.body, weight: .semibold)
                                    .foregroundStyle(Color.dockPrimaryText)
                                    .lineLimit(2)
                                Text(task.assignee ?? "Unassigned")
                                    .dockFont(.metadata)
                                    .foregroundStyle(Color.dockMetadataText)
                            }
                            .dockPadding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .dockWell()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.dockHover)
                        if selectedTaskID == task.id { OfficeTaskFields(task: task).dockPadding(.horizontal, 8) }
                    }
                }
                .dockPadding([.horizontal, .bottom], 10)
            }
        }
        .dockWell()
    }

    static func status(for lane: OfficePreviewLane) -> OfficeAgentStatus {
        switch lane {
        case .running: .working
        case .review: .reviewing
        case .blocked, .unknown: .blocked
        case .done: .idle
        case .triage, .todo, .ready, .scheduled: .queued
        }
    }
}

private struct OfficeStatusPill: View {
    let status: OfficeAgentStatus
    let text: String

    var body: some View { DockStatusPill(tone: status.tone, text: text, symbol: status.symbol) }
}

private struct OfficeCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .dockFont(.metadata, weight: .semibold)
                .tracking(0.4)
                .foregroundStyle(Color.dockMetadataText)
            content()
        }
        .dockPadding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockWell()
    }
}

private struct OfficeTaskFields: View {
    let task: OfficePreviewTaskData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            OfficeField(label: "Status", value: task.status)
            OfficeField(label: "Task ID", value: task.id)
            OfficeField(label: "Assignee", value: task.assignee ?? "Unassigned")
            if let value = task.boardSlug { OfficeField(label: "Board", value: value) }
            if let value = task.priority { OfficeField(label: "Priority", value: value) }
            if let value = task.currentStepKey { OfficeField(label: "Reported step", value: value) }
            if let value = task.latestEventKind { OfficeField(label: "Latest event", value: value) }
            if let value = task.latestEventNote { OfficeField(label: "Event detail", value: value) }
            if let value = task.detail {
                Text(value)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .dockPadding(.top, 2)
            }
        }
    }
}

private struct OfficeField: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .dockFont(.metadata)
                .foregroundStyle(Color.dockMetadataText)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .dockFont(.body)
                .foregroundStyle(Color.dockPrimaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
