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
    @State private var selection: OfficePreviewSelection?
    @State private var cameraFocusID: String?
    @State private var cameraResetToken = 0
    @State private var wholeOffice = true
    @State private var showsAgents = true

    init(kanbanTasks: [KanbanTaskSummary] = [], bots: [BotSummary] = [], mainSessions: [OfficeMainSession] = [], onOpenSession: @escaping (String) -> Void = { _ in }, avatarImages: [String: Data] = [:], canAssignTasks: Bool = false, isDataCurrent: Bool = true,
         subtitle: String = "Live bot assignments in a simulated 3D office", onRefresh: @escaping () -> Void = {}, isRefreshing: Bool = false,
         onAssignTask: ((KanbanTaskSummary, String) -> Void)? = nil) {
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
        _simulation = StateObject(wrappedValue: OfficePreviewSimulation(bots: bots, tasks: kanbanTasks, sessions: mainSessions))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    OfficePreviewSceneView(
                        agents: simulation.agents, reduceMotion: reduceMotion,
                        resetToken: cameraResetToken, wholeOffice: wholeOffice,
                        focusAgentID: cameraFocusID,
                        onSelectAgent: { selection = .agent($0) },
                        onSelectBoard: { selection = .board },
                        boardLanes: simulation.board, showsAgents: showsAgents, isDataCurrent: isDataCurrent
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    OfficePreviewHeader(
                        wholeOffice: $wholeOffice,
                        showsAgents: $showsAgents,
                        freeAgentCount: simulation.agents.filter(\.hasNoPendingTasks).count,
                        isDataCurrent: isDataCurrent,
                        isRefreshing: isRefreshing,
                        onRefresh: onRefresh,
                        onViewChange: {
                            cameraFocusID = nil
                            cameraResetToken += 1
                        },
                        onFocusNextFreeAgent: focusNextFreeAgent,
                        onShowBoard: { selection = .board },
                        onResetCamera: {
                            cameraFocusID = nil
                            cameraResetToken += 1
                        }
                    )
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                    if let selection {
                        OfficePreviewInspector(
                            title: inspectorTitle,
                            avatarBot: selectedBot,
                            avatarData: selectedBot.flatMap { avatarImages[$0.id] },
                            width: min(360, max(0, geometry.size.width - 24)),
                            height: min(460, max(0, geometry.size.height - 24)),
                            onClose: { self.selection = nil }
                        ) {
                            switch selection {
                            case .agent(let id):
                                if let agent = simulation.agents.first(where: { $0.id == id }) {
                                    Text(agent.mainSession != nil || isDataCurrent ? agent.availabilityLabel : "Kanban status not current")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(isDataCurrent && agent.hasNoPendingTasks ? Color.dockSuccess : Color.dockSecondaryText)
                                    if let session = agent.mainSession {
                                        Button("Open conversation") { onOpenSession(session.id) }
                                        Text("Nexus orchestrator")
                                            .font(.system(size: 12, weight: .semibold))
                                        OfficePreviewDetail(label: "CURRENT WORK", value: session.title)
                                        Text(session.isCurrent ? "Current conversation" : "Background conversation")
                                        if session.activities.isEmpty { Text("No recent activity available.") }
                                        else { Text("Recent recorded activity").fontWeight(.semibold) }
                                        ForEach(session.activities) { activity in
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(activity.name)
                                                Text(activity.timestamp, style: .time).foregroundStyle(Color.dockSecondaryText)
                                            }
                                        }
                                    } else {
                                    Menu("Assign existing task…") {
                                        ForEach(assignableTasks) { task in
                                            Button(task.title) { onAssignTask?(task, agent.id) }
                                        }
                                    }
                                    .disabled(!isDataCurrent || !canAssignTasks || assignableTasks.isEmpty)
                                    .help(canAssignTasks ? "Choose an unassigned Kanban task; confirm through Hermes." : "Task assignment is unavailable through the installed Hermes CLI.")
                                    OfficePreviewAgentDetails(agent: agent)
                                    }
                                }
                            case .board:
                                OfficePreviewBoardDetails(lanes: simulation.board)
                            }
                        }
                        .padding(12)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.dockAccent.opacity(0.25), lineWidth: 0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: kanbanTasks) { _, _ in updateProjection() }
        .onChange(of: bots) { _, _ in updateProjection() }
        .onChange(of: mainSessions) { _, _ in updateProjection() }
        .onChange(of: simulation.agents.map(\.id)) { _, ids in
            if case .agent(let id) = selection, !ids.contains(id) { selection = nil }
        }
    }

    private var inspectorTitle: String {
        if case .agent(let id) = selection {
            return simulation.agents.first(where: { $0.id == id })?.name ?? "Bot"
        }
        return "Kanban task board"
    }

    private var selectedBot: BotSummary? {
        guard case .agent(let id) = selection else { return nil }
        return bots.first(where: { $0.id == id && !$0.isDefault })
    }

    private var assignableTasks: [KanbanTaskSummary] {
        kanbanTasks.filter {
            ($0.assignee?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                && $0.boardSlug != nil && [.todo, .triage, .ready, .scheduled].contains(OfficePreviewLane($0.status))
        }
    }

    private func updateProjection() { simulation.update(bots: bots, tasks: kanbanTasks, sessions: mainSessions) }

    private func focusNextFreeAgent() {
        let free = simulation.agents.filter(\.hasNoPendingTasks)
        guard !free.isEmpty else { return }
        let index = free.firstIndex { $0.id == cameraFocusID }.map { ($0 + 1) % free.count } ?? 0
        showsAgents = true
        selection = .agent(free[index].id)
        cameraFocusID = free[index].id
        wholeOffice = false
        cameraResetToken += 1
    }

}

private struct OfficePreviewHeader: View {
    @Binding var wholeOffice: Bool
    @Binding var showsAgents: Bool
    let freeAgentCount: Int
    let isDataCurrent: Bool
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onViewChange: () -> Void
    let onFocusNextFreeAgent: () -> Void
    let onShowBoard: () -> Void
    let onResetCamera: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker("Camera view", selection: Binding(get: { wholeOffice }, set: { value in
                wholeOffice = value
                onViewChange()
            })) {
                Text("Workspace").tag(false)
                Text("Whole office").tag(true)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 174)
            Toggle("Show agents", isOn: $showsAgents)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            Menu {
                Button("Next free bot (\(isDataCurrent ? String(freeAgentCount) : "—"))", action: onFocusNextFreeAgent)
                    .disabled(!isDataCurrent || freeAgentCount == 0)
                Button("Task board", action: onShowBoard)
            } label: {
                Label("Inspect", systemImage: "list.bullet.rectangle")
            }
            .menuStyle(.borderlessButton)
            .help("Inspect free bots and the live Kanban board")
            Button(action: onRefresh) {
                Group {
                    if isRefreshing { ProgressView().controlSize(.small) }
                    else { LucideImage(systemName: "refresh-cw").font(.system(size: 14, weight: .medium)) }
                }
                .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .disabled(isRefreshing)
            .help("Refresh Office Preview")
            Button(action: onResetCamera) {
                Image(systemName: "arrow.counterclockwise").frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("Reset camera")
            .accessibilityLabel("Reset camera")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.dockSurface2.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

private struct OfficePreviewInspector<Content: View>: View {
    let title: String
    let avatarBot: BotSummary?
    let avatarData: Data?
    let width: CGFloat
    let height: CGFloat
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let avatarBot {
                    BotAvatarView(bot: avatarBot, imageData: avatarData, size: 28)
                }
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .help("Close details")
                .accessibilityLabel("Close details")
            }.padding(.horizontal, 12)
            Divider()
            ScrollView {
                content()
                    .font(.system(size: 12))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: width, height: height)
        .background(Color.dockCanvas)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.dockAccent.opacity(0.3), lineWidth: 0.5))
    }
}

private struct OfficePreviewAgentDetails: View {
    let agent: OfficePreviewAgentPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OfficePreviewDetail(label: "BOT ID", value: agent.id)
            if let task = agent.taskData {
                OfficePreviewTaskDetails(task: task)
            } else {
                Text("No assigned Kanban task.")
            }
            Divider()
            OfficePreviewDetail(label: "SIMULATED ACTIVITY", value: agent.phase.rawValue)
            OfficePreviewDetail(label: "ASSIGNED DESTINATION", value: agent.location.rawValue)
            Text("Bot ownership and task fields come from Kanban. Office poses and travel illustrate that state.")
                .foregroundStyle(Color.dockMetadataText)
            if agent.tasks.count > 1 {
                Divider()
                Text("OTHER ASSIGNED TASKS (\(agent.tasks.count - 1))").fontWeight(.semibold)
                ForEach(Array(agent.tasks.dropFirst())) { task in
                    DisclosureGroup(task.title) { OfficePreviewTaskDetails(task: task).padding(.top, 8) }
                }
            }
        }
    }
}

private struct OfficePreviewBoardDetails: View {
    let lanes: [OfficePreviewBoardLane]
    @State private var expandedLanes: Set<OfficePreviewLane> = [.todo, .running]
    @State private var selectedTaskID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live Kanban tasks · Read only").foregroundStyle(Color.dockMetadataText)
            ForEach(lanes) { lane in
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedLanes.contains(lane.lane) },
                    set: { if $0 { expandedLanes.insert(lane.lane) } else { expandedLanes.remove(lane.lane) } }
                )) {
                    VStack(alignment: .leading, spacing: 10) {
                        if lane.tasks.isEmpty { Text("No tasks").foregroundStyle(Color.dockMetadataText) }
                        ForEach(lane.tasks) { task in
                            Button {
                                selectedTaskID = selectedTaskID == task.id ? nil : task.id
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.title).fontWeight(.semibold).lineLimit(2)
                                    Text(task.assignee ?? "Unassigned").foregroundStyle(Color.dockMetadataText)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if selectedTaskID == task.id { OfficePreviewTaskDetails(task: task) }
                            Divider()
                        }
                    }.padding(.top, 8)
                } label: {
                    Text("\(lane.lane.rawValue.capitalized) · \(lane.tasks.count)").fontWeight(.semibold)
                }
            }
        }
    }
}

private struct OfficePreviewTaskDetails: View {
    let task: OfficePreviewTaskData
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OfficePreviewDetail(label: "KANBAN TASK", value: task.title)
            OfficePreviewDetail(label: "TASK ID", value: task.id)
            OfficePreviewDetail(label: "STATUS", value: task.status)
            OfficePreviewDetail(label: "ASSIGNEE", value: task.assignee ?? "Unassigned")
            if let value = task.boardSlug { OfficePreviewDetail(label: "BOARD", value: value) }
            if let value = task.priority { OfficePreviewDetail(label: "PRIORITY", value: value) }
            if let value = task.currentStepKey { OfficePreviewDetail(label: "REPORTED STEP", value: value) }
            if let value = task.latestEventKind { OfficePreviewDetail(label: "LATEST EVENT", value: value) }
            if let value = task.latestEventNote { OfficePreviewDetail(label: "EVENT DETAIL", value: value) }
            if let value = task.detail { OfficePreviewDetail(label: "TASK DESCRIPTION", value: value) }
        }
    }
}

private struct OfficePreviewDetail: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dockMetadataText)
            Text(value).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}
