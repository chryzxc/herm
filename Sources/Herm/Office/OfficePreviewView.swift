import SwiftUI

private enum OfficePreviewSelection: Equatable {
    case agent(String)
    case board
}

struct OfficePreviewView: View {
    let kanbanTasks: [KanbanTaskSummary]
    let bots: [BotSummary]
    let mainSessions: [OfficeMainSession]
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
    @State private var selection: OfficePreviewSelection?
    @State private var cameraFocusID: String?
    @State private var cameraResetToken = 0
    @State private var wholeOffice = true
    @State private var showsAgents = true
    @State private var showsRoster = false
    // Not observed here: only the hover card and the scene read it.
    @State private var music = OfficeMusicService()

    init(
        kanbanTasks: [KanbanTaskSummary] = [], bots: [BotSummary] = [], mainSessions: [OfficeMainSession] = [],
        onOpenSession: @escaping (String) -> Void = { _ in }, avatarImages: [String: Data] = [:],
        canAssignTasks: Bool = false, isDataCurrent: Bool = true,
        subtitle: String = "Live bot assignments in a simulated 3D office", onRefresh: @escaping () -> Void = {},
        isRefreshing: Bool = false,
        onAssignTask: ((KanbanTaskSummary, String) -> Void)? = nil
    ) {
        self.kanbanTasks = kanbanTasks
        self.bots = bots
        self.mainSessions = mainSessions
        self.onOpenSession = onOpenSession
        self.avatarImages = avatarImages
        self.canAssignTasks = canAssignTasks
        self.isDataCurrent = isDataCurrent
        self.subtitle = subtitle
        self.onRefresh = onRefresh
        self.isRefreshing = isRefreshing
        self.onAssignTask = onAssignTask
        _simulation = StateObject(
            wrappedValue: OfficePreviewSimulation(bots: bots, tasks: kanbanTasks, sessions: mainSessions))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DockPageHeader(
                title: "Office", subtitle: subtitle,
                onRefresh: onRefresh, isRefreshing: isRefreshing, windowBottomPadding: 0)

            GeometryReader { geometry in
                ZStack {
                    OfficePreviewSceneView(
                        agents: simulation.agents, avatarImages: avatarImages, reduceMotion: reduceMotion,
                        resetToken: cameraResetToken, wholeOffice: wholeOffice,
                        focusAgentID: cameraFocusID,
                        onSelectAgent: { select($0) },
                        onSelectBoard: { selection = .board },
                        boardLanes: simulation.board, showsAgents: showsAgents, isDataCurrent: isDataCurrent,
                        selectedAgentID: selectedAgentID,
                        palette: .current(isDark: colorScheme == .dark),
                        music: music
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    hud(in: geometry.size)
                }
                .clipShape(Rectangle())
                .overlay(Rectangle().stroke(Color.dockBorder, lineWidth: 0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await music.poll() }
        .onChange(of: kanbanTasks) { _, _ in updateProjection() }
        .onChange(of: bots) { _, _ in updateProjection() }
        .onChange(of: mainSessions) { _, _ in updateProjection() }
        .onChange(of: simulation.agents.map(\.id)) { _, ids in
            if case .agent(let id) = selection, !ids.contains(id) { selection = nil }
        }
    }

    // MARK: HUD

    @ViewBuilder
    private func hud(in size: CGSize) -> some View {
        let compact = size.width < 760
        let panelHeight = max(0, size.height - 24 - 56)
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal) {
                    OfficeCrewStatusBar(counts: statusCounts, onSelect: focusNext(in:))
                }
                .scrollIndicators(.hidden)
                .frame(height: 34)
                .frame(maxWidth: max(0, size.width - (selection == nil ? 24 : 376)), alignment: .leading)
                .opacity(compact && selection != nil ? 0 : 1)
                .allowsHitTesting(!compact || selection == nil)
                .accessibilityHidden(compact && selection != nil)
                if showsRoster && showsAgents && !compact && (selection == nil || size.width >= 1000) {
                    OfficeRosterPanel(
                        agents: rosterAgents, isDataCurrent: isDataCurrent,
                        selectedID: selectedAgentID, onSelect: { focus($0) }
                    )
                    .frame(width: 244)
                    .frame(maxHeight: max(0, panelHeight - 42), alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .dockPadding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let selection {
                inspector(for: selection)
                    .frame(width: min(340, max(0, size.width - 24)))
                    .frame(maxHeight: panelHeight, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
                    .dockPadding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            OfficeToolbar(
                showsAgents: showsAgents, showsRoster: showsRoster,
                canShowRoster: !compact && (selection == nil || size.width >= 1000), boardSelected: selection == .board,
                onToggleAgents: { showsAgents.toggle() },
                onToggleRoster: { withAnimation(hudAnimation) { showsRoster.toggle() } },
                onShowBoard: { withAnimation(hudAnimation) { selection = selection == .board ? nil : .board } },
                onResetCamera: resetCamera
            )
            .dockPadding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .animation(hudAnimation, value: selection)
    }

    private var hudAnimation: Animation? { reduceMotion ? nil : .dockEase(duration: 0.2) }

    @ViewBuilder
    private func inspector(for selection: OfficePreviewSelection) -> some View {
        switch selection {
        case .agent(let id):
            if let agent = simulation.agents.first(where: { $0.id == id }) {
                let bot = bots.first(where: { $0.id == id })
                OfficeHUDPanel {
                    OfficeAgentInspector(
                        agent: agent, bot: bot, avatarData: bot.flatMap { avatarImages[$0.id] },
                        status: OfficeAgentStatus(agent: agent, isDataCurrent: isDataCurrent),
                        isDataCurrent: isDataCurrent, canAssignTasks: canAssignTasks,
                        assignableTasks: assignableTasks,
                        onOpenSession: onOpenSession,
                        onAssignTask: { onAssignTask?($0, agent.id) },
                        onClose: { self.selection = nil }
                    )
                }
            }
        case .board:
            OfficeHUDPanel {
                OfficeBoardInspector(lanes: simulation.board, onClose: { self.selection = nil })
            }
        }
    }

    private var selectedAgentID: String? {
        if case .agent(let id) = selection { return id }
        return nil
    }

    private var statusCounts: [(OfficeAgentStatus, Int)] {
        let statuses = simulation.agents.map { OfficeAgentStatus(agent: $0, isDataCurrent: isDataCurrent) }
        return OfficeAgentStatus.allCases.compactMap { status in
            let count = statuses.filter { $0 == status }.count
            // "Not current" appears only when some state is actually stale.
            return status == .stale && count == 0 ? nil : (status, count)
        }
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

    private func updateProjection() { simulation.update(bots: bots, tasks: kanbanTasks, sessions: mainSessions) }

    private func select(_ id: String) {
        withAnimation(hudAnimation) { selection = .agent(id) }
    }

    /// Opens a bot's details and flies the camera to it.
    private func focus(_ id: String) {
        showsAgents = true
        select(id)
        cameraFocusID = id
        wholeOffice = false
        cameraResetToken += 1
    }

    /// Cycles through bots that share a status, like a unit-select hotkey.
    private func focusNext(in status: OfficeAgentStatus) {
        let matches = rosterAgents.filter { OfficeAgentStatus(agent: $0, isDataCurrent: isDataCurrent) == status }
        guard !matches.isEmpty else { return }
        let index = matches.firstIndex { $0.id == cameraFocusID }.map { ($0 + 1) % matches.count } ?? 0
        focus(matches[index].id)
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

/// Live crew counts by status. Each chip jumps to the next bot in that state.
private struct OfficeCrewStatusBar: View {
    let counts: [(OfficeAgentStatus, Int)]
    let onSelect: (OfficeAgentStatus) -> Void

    var body: some View {
        OfficeHUDPanel {
            HStack(spacing: 2) {
                ForEach(counts, id: \.0) { status, count in
                    Button {
                        onSelect(status)
                    } label: {
                        HStack(spacing: 6) {
                            OfficeStatusDot(status: status)
                            Text(status.label)
                                .dockFont(.control)
                                .foregroundStyle(count > 0 ? Color.dockPrimaryText : Color.dockMetadataText)
                            Text("\(count)")
                                .dockFont(.metadata, weight: .semibold).monospacedDigit()
                                .foregroundStyle(count > 0 ? Color.dockSecondaryText : Color.dockMetadataText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.dockCompact)
                    .disabled(count == 0)
                    .help(
                        count > 0
                            ? "Focus the next \(status.label.lowercased()) bot" : "No \(status.label.lowercased()) bots"
                    )
                    .accessibilityLabel("\(status.label): \(count) bots")
                }
            }
            .dockButtonSize(.compact)
            .dockPadding(3)
        }
        .fixedSize()
    }
}

private struct OfficeRosterPanel: View {
    let agents: [OfficePreviewAgentPresentation]
    let isDataCurrent: Bool
    let selectedID: String?
    let onSelect: (String) -> Void

    var body: some View {
        OfficeHUDPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Crew")
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                    Spacer()
                    Text("\(agents.count)")
                        .dockFont(.metadata, weight: .semibold).monospacedDigit()
                        .foregroundStyle(Color.dockMetadataText)
                }
                .dockPadding(.horizontal, 12)
                .frame(height: 34)
                Divider().overlay(Color.dockBorderLight)
                if agents.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No bots in the office")
                            .dockFont(.body, weight: .semibold)
                        Text("Bots appear here when Hermes reports them.")
                            .dockFont(.body)
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                    .dockPadding(12)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(agents) { agent in row(agent) }
                        }
                        .dockPadding(4)
                    }
                }
            }
        }
    }

    private func row(_ agent: OfficePreviewAgentPresentation) -> some View {
        let status = OfficeAgentStatus(agent: agent, isDataCurrent: isDataCurrent)
        let isSelected = agent.id == selectedID
        return Button {
            onSelect(agent.id)
        } label: {
            HStack(spacing: 9) {
                OfficeStatusDot(status: status, size: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1)
                    Text(agent.monitorTitle)
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(status.label)
                    .dockFont(.metadata, weight: .medium)
                    .foregroundStyle(Color.dockMetadataText)
            }
            .dockPadding(.horizontal, 8)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius).fill(
                    isSelected ? Color.dockAccentMuted : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius).stroke(
                    isSelected ? Color.dockAccent.opacity(0.5) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityLabel("\(agent.name), \(status.label), \(agent.monitorTitle)")
    }
}

private struct OfficeToolbar: View {
    let showsAgents: Bool
    let showsRoster: Bool
    let canShowRoster: Bool
    let boardSelected: Bool
    let onToggleAgents: () -> Void
    let onToggleRoster: () -> Void
    let onShowBoard: () -> Void
    let onResetCamera: () -> Void

    var body: some View {
        OfficeHUDPanel {
            HStack(spacing: 4) {
                iconButton(
                    .users, help: showsAgents ? "Hide bots" : "Show bots",
                    isOn: showsAgents, action: onToggleAgents)
                if canShowRoster {
                    iconButton(
                        .sidebarSimple, help: showsRoster ? "Hide crew roster" : "Show crew roster",
                        isOn: showsRoster, action: onToggleRoster)
                }
                iconButton(.kanban, help: "Kanban task board", isOn: boardSelected, action: onShowBoard)
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
                DockIcon(.x)
                    .dockFont(.metadata, weight: .semibold)
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.dockControlSurface))
            }
            .buttonStyle(.dockHover)
            .help("Close details")
            .accessibilityLabel("Close details")
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
    let onOpenSession: (String) -> Void
    let onAssignTask: (KanbanTaskSummary) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OfficeInspectorHeader(
                title: agent.name, subtitle: agent.mainSession != nil ? "Main session" : "Bot",
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
                        text: agent.mainSession != nil || isDataCurrent
                            ? agent.availabilityLabel : "Kanban status not current")
                    if let session = agent.mainSession {
                        sessionContent(session)
                    } else {
                        taskContent
                    }
                }
                .dockPadding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(session.title)
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
                .textSelection(.enabled)
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
    private var taskContent: some View {
        if let task = agent.taskData {
            OfficeCard(title: "Current task") {
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
            }
            OfficeCard(title: "Task details") { OfficeTaskFields(task: task) }
        } else {
            OfficeCard(title: "Current task") {
                Text("No assigned Kanban task.")
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
            }
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
        OfficeCard(title: "In the office") {
            OfficeField(label: "Activity", value: agent.phase.rawValue.capitalized)
            OfficeField(label: "Destination", value: agent.location.rawValue)
            if let work = agent.work { OfficeField(label: "Work", value: "\(work.kind.title) · \(work.evidence)") }
            OfficeField(label: "Bot ID", value: agent.id)
            Text("Ownership and task fields come from Kanban. Office poses and travel illustrate that state.")
                .dockFont(.metadata)
                .foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
        }
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

private struct OfficeBoardInspector: View {
    let lanes: [OfficePreviewBoardLane]
    let onClose: () -> Void
    @State private var expandedLanes: Set<OfficePreviewLane> = [.todo, .running]
    @State private var selectedTaskID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OfficeInspectorHeader(title: "Kanban task board", subtitle: "Live tasks · Read only", onClose: onClose) {
                DockIcon(.kanban)
                    .dockFont(.conversation)
                    .foregroundStyle(Color.dockAccent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.dockControlSurface))
            }
            Divider().overlay(Color.dockBorderLight)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(lanes) { lane in laneCard(lane) }
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
                        .dockPadding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Capsule().fill(Color.dockControlSurface))
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
