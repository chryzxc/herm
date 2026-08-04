import AppKit
import SwiftUI

/// First workspace slice: the existing conversation remains the command surface,
/// while this inspector makes Hermes' current work legible at a glance.
struct WorkspaceWindowView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var store: WorkspaceStore
    @State private var selectedTab: WorkspaceTab = .now
    @State private var selectedTaskID: UUID?
    @State private var repository = RepositorySnapshot.empty
    @State private var isRefreshingRepository = false

    enum WorkspaceTab: String, CaseIterable, Identifiable {
        case now = "Now"
        case activity = "Activity"
        case tasks = "Tasks"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .now: "scope"
            case .activity: "list.bullet.rectangle"
            case .tasks: "checklist"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            HStack(spacing: 0) {
                DockPopover(model: model)
                    .frame(minWidth: 540, idealWidth: 680, maxWidth: .infinity)
                    .layoutPriority(1)
                Rectangle().fill(Color.scifiBorderLight).frame(width: 0.5)
                inspector.frame(minWidth: 300, idealWidth: 380, maxWidth: 440)
            }
        }
        .background(Color.scifiBg)
        .environment(\.colorScheme, .dark)
        .onAppear { ensureActiveTask() }
        .task { await refreshRepository() }
        .onChange(of: model.status) { _, status in syncTaskStatus(status) }
        .onChange(of: model.currentSessionTitle) { _, _ in ensureActiveTask() }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("HERMES WORKSPACE")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.6)
                    .foregroundStyle(Color.scifiAccent)
                Text(activeTaskTitle)
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.scifiFg)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(model.status.title.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(0.7)
                    .foregroundStyle(Color.scifiMuted)
            }
        }
        .padding(.horizontal, 20).frame(height: 58)
        .background(Color.scifiSurface2)
        .overlay(alignment: .bottom) { Color.scifiBorderLight.frame(height: 0.5) }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            tabBar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch selectedTab {
                    case .now: nowContent
                    case .activity: activityContent
                    case .tasks: tasksContent
                    }
                }.padding(20)
            }
        }.background(Color.scifiSurface)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(WorkspaceTab.allCases) { tab in
                Button {
                    withAnimation(.scifiEase(duration: 0.2)) { selectedTab = tab }
                } label: {
                    Label(tab.rawValue, systemImage: tab.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selectedTab == tab ? Color.scifiFg : Color.scifiMuted)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(selectedTab == tab ? Color.scifiSurface6 : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }.buttonStyle(.plain)
            }
        }.padding(8).overlay(alignment: .bottom) { Color.scifiBorderLight.frame(height: 0.5) }
    }

    private var nowContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel("CURRENT TASK")
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Image(systemName: isTaskInProgress ? "circle.dotted" : "checkmark.circle.fill")
                        .foregroundStyle(isTaskInProgress ? Color.scifiAccent : Color.scifiSuccess)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(activeTaskTitle).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.scifiFg)
                        Text("Linked to the active Hermes conversation").font(.system(size: 11)).foregroundStyle(Color.scifiMuted)
                    }
                    Spacer()
                }
                HStack {
                    Text(isTaskInProgress ? "IN PROGRESS" : "READY")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(0.8)
                        .foregroundStyle(isTaskInProgress ? Color.scifiAccent : Color.scifiSuccess)
                    Spacer(); Text("Live").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.scifiTertiary)
                }
            }
            .padding(14).background(Color.scifiSurface4)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.scifiBorder, lineWidth: 0.5))

            sectionLabel("AGENT STATE")
            VStack(alignment: .leading, spacing: 10) {
                stateRow(icon: "cpu", title: "Hermes", detail: model.status.title, color: statusColor)
                stateRow(icon: "wrench.and.screwdriver", title: "Active tools", detail: model.activeToolCalls.isEmpty ? "None" : "\(model.activeToolCalls.count) running", color: model.activeToolCalls.isEmpty ? Color.scifiMuted : Color.scifiAccent)
                stateRow(icon: "bubble.left.and.bubble.right", title: "Conversation", detail: "\(model.messages.count) messages", color: Color.scifiMuted)
            }

            if let approval = model.approvalText {
                sectionLabel("DECISION REQUIRED")
                Text(approval).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.scifiWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            sectionLabel("REPOSITORY")
            repositoryContent
        }
    }

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("LIVE ACTIVITY")
            if model.activeToolCalls.isEmpty && model.recentEvents.isEmpty {
                emptyState(icon: "waveform", title: "No activity yet", detail: "Hermes events will appear here while it works.")
            } else {
                ForEach(Array(model.recentEvents.suffix(12).reversed())) { event in
                    activityRow(title: event.type, detail: event.detail, icon: eventIcon(for: event.type))
                }
                ForEach(model.activeToolCalls) { call in
                    activityRow(title: call.name, detail: call.isComplete ? "Completed" : "Running", icon: "wrench.and.screwdriver")
                }
            }
        }
    }

    private var repositoryContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: repository.isGitRepository ? "arrow.triangle.branch" : "folder")
                    .foregroundStyle(repository.isGitRepository ? Color.scifiSuccess : Color.scifiMuted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(repository.isGitRepository ? repository.branch : (store.projectPath == nil ? "No repository selected" : repository.branch))
                        .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Color.scifiFg)
                    if repository.isGitRepository {
                        Text(repository.changedFiles == 0 ? "Clean working tree" : "\(repository.changedFiles) changed file\(repository.changedFiles == 1 ? "" : "s")")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(repository.changedFiles == 0 ? Color.scifiSuccess : Color.scifiWarning)
                    } else if let path = store.projectPath {
                        Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.scifiMuted).lineLimit(1)
                    }
                }
                Spacer()
                if isRefreshingRepository { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 12) {
                Button("Choose Repo") { chooseRepository() }
                if repository.isGitRepository {
                    Button { Task { await refreshRepository() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh repository")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.bordered)
            .tint(Color.scifiAccent)
        }
        .padding(12)
        .background(Color.scifiSurface4)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.scifiBorder, lineWidth: 0.5))
    }

    private var tasksContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionLabel("TASKS"); Spacer()
                Button { toggleActiveTask() } label: {
                    Image(systemName: isTaskInProgress ? "checkmark.circle" : "arrow.uturn.backward.circle").foregroundStyle(Color.scifiMuted)
                }.buttonStyle(.plain).help(isTaskInProgress ? "Mark task ready" : "Reopen task")
            }
            ForEach(store.tasks) { task in
                taskRow(task: task)
            }
            Button { createTaskFromConversation() } label: {
                Label("Create task from conversation", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.scifiAccent)
            }
            .buttonStyle(.plain)
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(Color.scifiMuted)
    }

    private func stateRow(icon: String, title: String, detail: String, color: Color) -> some View {
        return HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color).frame(width: 20)
            Text(title).font(.system(size: 12)).foregroundStyle(Color.scifiFg)
            Spacer(); Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.scifiMuted).lineLimit(1)
        }
    }

    private func activityRow(title: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Color.scifiAccent).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Color.scifiFg)
                Text(detail.isEmpty ? "No details" : detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.scifiMuted).lineLimit(2)
            }; Spacer()
        }.padding(.vertical, 3)
    }

    private func taskRow(task: WorkspaceTask) -> some View {
        let color = taskColor(task.status)
        return HStack(spacing: 10) {
            Circle().fill(color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.scifiFg).lineLimit(2)
                Text(task.status.rawValue.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(0.7).foregroundStyle(color)
            }; Spacer()
        }.padding(12).background(Color.scifiSurface4)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.scifiBorder, lineWidth: 0.5))
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon).foregroundStyle(Color.scifiTertiary)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.scifiFg)
            Text(detail).font(.system(size: 11)).foregroundStyle(Color.scifiMuted).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 8)
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: .scifiSuccess
        case .working: .scifiAccent
        case .needsApproval: .scifiWarning
        case .offline: .scifiDestructive
        }
    }

    private func eventIcon(for type: String) -> String {
        let value = type.lowercased()
        if value.contains("error") { return "xmark.octagon" }
        if value.contains("approval") || value.contains("permission") { return "exclamationmark.triangle" }
        if value.contains("tool") { return "wrench.and.screwdriver" }
        if value.contains("message") { return "bubble.left" }
        return "circle.dotted"
    }

    private var activeTask: WorkspaceTask? {
        if let selectedTaskID, let task = store.tasks.first(where: { $0.id == selectedTaskID }) { return task }
        return store.activeTask
    }

    private var activeTaskTitle: String {
        activeTask?.title ?? model.currentSessionTitle ?? "Current Hermes task"
    }

    private var isTaskInProgress: Bool {
        activeTask?.status == .inProgress
    }

    private func ensureActiveTask() {
        guard activeTask == nil, model.currentSessionTitle != nil || !model.messages.isEmpty else { return }
        let title = model.currentSessionTitle ?? model.messages.first(where: { $0.role == .user })?.text ?? "Current Hermes task"
        let task = store.createTask(title: String(title.prefix(100)), sessionID: nil)
        selectedTaskID = task.id
    }

    private func createTaskFromConversation() {
        let title = model.currentSessionTitle ?? model.messages.last(where: { $0.role == .user })?.text ?? "Current Hermes task"
        let task = store.createTask(title: String(title.prefix(100)), sessionID: nil)
        selectedTaskID = task.id
    }

    private func syncTaskStatus(_ status: HermesStatus) {
        guard let task = activeTask else { return }
        switch status {
        case .working: store.updateStatus(.inProgress, for: task.id)
        case .needsApproval: store.updateStatus(.awaitingApproval, for: task.id)
        case .idle where task.status == .inProgress: store.updateStatus(.readyForReview, for: task.id)
        default: break
        }
    }

    private func toggleActiveTask() {
        guard let task = activeTask else {
            createTaskFromConversation()
            return
        }
        store.updateStatus(task.status == .done || task.status == .readyForReview ? .inProgress : .readyForReview, for: task.id)
    }

    private func taskColor(_ status: WorkspaceTaskStatus) -> Color {
        switch status {
        case .todo: .scifiMuted
        case .inProgress: .scifiAccent
        case .awaitingApproval: .scifiWarning
        case .readyForReview: .scifiSuccess
        case .done: .scifiTertiary
        }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.attachProject(at: url.path)
        Task { await refreshRepository() }
    }

    private func refreshRepository() async {
        guard let path = store.projectPath else {
            repository = .empty
            return
        }
        isRefreshingRepository = true
        let snapshot = await RepositoryService.inspect(path: path)
        guard !Task.isCancelled else { return }
        repository = snapshot
        isRefreshingRepository = false
    }
}
