import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers

struct WorkspaceActivitySidebar: View {
    static let projectsPageSize = 25
    enum AutomationHistoryScope: String, CaseIterable, Identifiable {
        case selected
        case all

        var id: Self { self }
        var title: String { self == .selected ? "Selected" : "All runs" }
    }

    struct AutomationHistoryPresentation {
        static func selectedJobID(currentID: String?, jobs: [CronSummary]) -> String? {
            guard !jobs.isEmpty else { return nil }
            if let currentID, jobs.contains(where: { $0.id == currentID }) { return currentID }
            return jobs.first?.id
        }

        static func runs(_ runs: [CronRunSummary], scope: AutomationHistoryScope, selectedJobID: String?) -> [CronRunSummary] {
            guard scope == .selected, let selectedJobID else { return runs }
            return runs.filter { $0.jobID == selectedJobID }
        }
    }

    @ObservedObject var model: DockModel
    @ObservedObject var botMode: BotModeModel
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var control: ControlCenterModel
    @ObservedObject var workflow: DeveloperWorkflowModel
    @ObservedObject var dockThemeStore: DockThemeStore
    var onClose: () -> Void = {}
    var onOpenArtifacts: () -> Void = {}
    var onRestartDock: () -> Void = {}
    /// Lets a host with a separate global surface return to the conversation
    /// after a project/session selection has actually been requested.
    var onSessionOpened: (String) -> Void = { _ in }
    var showsHeader = true
    var showsModePicker = true
    @State private var selectedMode: ControlTab = .today
    @State private var selectedAttentionID: String?
    @State private var inboxFilter: InboxFilter = .all
    @State private var isShowingCommandPalette = false
    @State private var searchQuery = ""
    @State private var selectedModelID = ""
    @State private var selectedAgentID: String?
    @State private var selectedRepositoryDiff: RepositoryDiff?
    @State private var codeDocument: RepositoryFileDocument?
    @State private var selectedRepositoryFile: RepositoryFileChange?
    @State private var selectedProjectSessionID: String?
    @State private var codeWorkspaceError: String?
    @State private var isLoadingRepositoryDiff = false
    @State private var isRefreshingRepository = false
    @State private var showingRepositoryPicker = false
    @State private var reminderForConfirmation: ReminderSummary?
    @State private var isShowingReminderConfirmation = false
    @State private var cronRemovalRequest: CronSummary?
    @State private var isShowingCronRemovalConfirmation = false
    @State private var cronRunRequest: CronSummary?
    @State private var isShowingCronRunConfirmation = false
    @State private var isShowingAutomationComposer = false
    @State private var selectedCronJobID: String?
    @State private var automationHistoryScope: AutomationHistoryScope = .selected
    @State private var automationName = ""
    @State private var automationSchedule = ""
    @State private var automationPrompt = ""
    @State private var isShowingAutomationConfirmation = false
    @State private var isShowingMCPReloadConfirmation = false
    @State private var kanbanTitle = ""
    @State private var kanbanBody = ""
    @State private var isShowingKanbanComposer = false
    @State private var isShowingKanbanConfirmation = false
    @State private var kanbanChangeRequest: KanbanChangeRequest?
    @State private var isShowingKanbanChangeConfirmation = false
    @State private var selectedKanbanTask: KanbanTaskSummary?
    @State private var missionControlPicked: Set<String> = []
    @State private var missionControlNote = ""
    @State private var isConfirmingMissionControlArchive = false
    @State private var kanbanInspectorTab: KanbanInspectorTab = .overview
    @State private var kanbanMutationRequest: KanbanMutationRequest?
    @State private var cronEditJob: CronSummary?
    @State private var cronReportRequest: CronReportRequest?
    @State private var clarificationItem: AttentionItem?
    @State private var clarificationResponse = ""
    @State private var expandedCronReportIDs: Set<String> = []
    @State private var isShowingAllSkills = false
    @State private var expandedSettingsCapabilityCategories: Set<CapabilityCategory> = [.core]
    @State private var isAgentUpdateExpanded = true
    @State private var isAppUpdateExpanded = true
    @ObservedObject private var appUpdater = HermAppUpdater.shared
    @State private var isAppearanceExpanded = false
    @State private var isInsightsExpanded = false
    @State private var isCapabilitiesExpanded = true
    @State private var isSetupExpanded = true
    @State private var isVerificationExpanded = false
    @State private var isSessionCockpitExpanded = false
    @State private var isSessionActionsExpanded = false
    @State private var isDiagnosticsExpanded = false
    @State private var isLearningExpanded = false
    @State private var isRuntimeConfigurationExpanded = false
    @State private var kanbanStatusFilter = "All"
    @State private var isShowingKanbanStatusFilter = false
    @State private var kanbanAssigneeFilter = "All"
    @State private var isShowingKanbanAssigneeFilter = false
    @State private var kanbanMineOnly = false
    @State private var kanbanCurrentSessionOnly = false
    @State private var kanbanSort = "updated"
    @State private var kanbanDiagnosticSeverity = "ALL"
    @State private var isKanbanHealthExpanded = false
    @State private var sessionSteerText = ""
    @State private var sessionSteerFeedback: String?
    @State private var backgroundTaskPrompt = ""
    @State private var isStartingBackgroundTask = false
    @State private var sessionRenameText = ""
    @State private var sessionRedirectText = ""
    @State private var sessionBranchName = ""
    @State private var sessionCompressTopic = ""
    @State private var isShowingUndoConfirmation = false
    @State private var isShowingBranchConfirmation = false
    @State private var isShowingCompressConfirmation = false
    @State private var isShowingDelegationConfirmation = false
    @State private var handoffFocus = ""
    @State private var isShowingHandoffConfirmation = false
    @State private var pendingProcess: ProcessSummary?
    @State private var pendingAgentID: String?
    @State private var isShowingAgentUpdateConfirmation = false
    @State private var isAgentUpdateOutputExpanded = false
    @State private var isShowingDockRestartConfirmation = false
    @State private var isShowingEmergencyStopConfirmation = false
    @State private var selectedSettingsCategory: SettingsCategory = .general
    @State private var isShowingEmergencyResumeConfirmation = false
    @State private var checkpointForRestore: RestoreCheckpoint?
    @State private var pendingProjectMutation: ProjectMutation?
    @State private var isShowingProjectMutationConfirmation = false
    @State private var pendingProjectFolder: URL?
    @State private var isShowingProjectCreationConfirmation = false
    @State private var projectsDisplayLimit = WorkspaceActivitySidebar.projectsPageSize
    @StateObject private var commandCenterPreferences = CommandCenterPreferencesStore()
    @AppStorage(SidebarVisibilityKey.kanban) private var showsKanbanInSidebar = true
    @AppStorage(SidebarVisibilityKey.pullRequests) private var showsPullRequestsInSidebar = true
    @AppStorage(SidebarVisibilityKey.issues) private var showsIssuesInSidebar = true
    @AppStorage(SidebarVisibilityKey.office) private var showsOfficeInSidebar = true
    @AppStorage(DoubleTapShortcut.workspaceKey) private var workspaceShortcut = DoubleTapShortcut.command
    @AppStorage(DoubleTapShortcut.notchKey) private var notchShortcut = DoubleTapShortcut.option
    @ObservedObject var agentUpdateService: HermesUpdateService

    init(
        model: DockModel,
        botMode: BotModeModel,
        store: WorkspaceStore,
        control: ControlCenterModel,
        workflow: DeveloperWorkflowModel,
        dockThemeStore: DockThemeStore = .shared,
        onClose: @escaping () -> Void = {},
        onRestartDock: @escaping () -> Void = {},
        onOpenArtifacts: @escaping () -> Void = {},
        onSessionOpened: @escaping (String) -> Void = { _ in },
        showsHeader: Bool = true,
        showsModePicker: Bool = true,
        initialMode: ControlTab = .today,
        agentUpdateService: HermesUpdateService
    ) {
        self.model = model
        self.botMode = botMode
        self.store = store
        self.control = control
        self.workflow = workflow
        self.dockThemeStore = dockThemeStore
        self.onClose = onClose
        self.onRestartDock = onRestartDock
        self.onOpenArtifacts = onOpenArtifacts
        self.onSessionOpened = onSessionOpened
        self.showsHeader = showsHeader
        self.showsModePicker = showsModePicker
        self.agentUpdateService = agentUpdateService
        _selectedMode = State(initialValue: initialMode)
    }

    private enum ProjectMutation: String, Identifiable {
        case activate, archive, delete
        var id: Self { self }
    }

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                sidebarHeader
            }

            if showsModePicker {
                modePicker
            }
            if selectedMode == .core {
                settingsWorkspaceContent
            } else if selectedMode == .kanban {
                kanbanContent
            } else if selectedMode == .missionControl {
                missionControlContent
            } else if selectedMode == .officePreview {
                officePreviewContent
            } else if selectedMode == .automations {
                AutomationWorkspaceView(control: control)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        pageHeader

                        Group {
                            switch selectedMode {
                            case .today: nowContent
                            case .session: sessionOverviewContent
                            case .inbox: inboxContent
                            case .activity: activityContent
                            case .changes: changesContent
                            case .verification: verificationContent
                            case .automations: automationsContent
                            case .projects: projectsContent
                            case .search: searchContent
                            case .kanban: kanbanContent
                            case .missionControl: missionControlContent
                            case .officePreview: officePreviewContent
                            case .core: coreContent
                            case .quota: quotaContent
                            case .usage: UsageWorkspaceView(control: control)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                }
            }
        }
        .font(.system(size: 13))
    }

    private var pageHeader: some View {
        if selectedMode == .missionControl {
            AnyView(DockPageHeader(
                title: selectedMode.pageHeaderTitle,
                subtitle: pageHeaderSubtitle,
                onRefresh: { control.refreshMissionControl() },
                isRefreshing: control.isActionPending(control.missionControlRefreshActionID)
            ))
        } else if selectedMode == .kanban {
            AnyView(DockPageHeader(
                title: selectedMode.pageHeaderTitle,
                subtitle: pageHeaderSubtitle,
                onRefresh: { applyKanbanFilters() },
                isRefreshing: control.isKanbanRefreshPending
            ))
        } else if selectedMode == .automations {
            AnyView(DockPageHeader(
                title: selectedMode.pageHeaderTitle,
                subtitle: pageHeaderSubtitle,
                onRefresh: refreshAutomations,
                isRefreshing: automationIsRefreshing,
                trailing: {
                Button(action: { isShowingAutomationComposer = true }) {
                    DockIconLabel("New automation", icon: .plus, iconColor: .dockOnAccentText)
                }
                .buttonStyle(.dockPrimary)
                .font(.system(size: 12, weight: .semibold))
                }
            ))
        } else if selectedMode == .core {
            AnyView(DockPageHeader(
                title: selectedMode.pageHeaderTitle,
                subtitle: pageHeaderSubtitle,
                onRefresh: { control.refresh() },
                isRefreshing: control.isRefreshing
            ))
        } else {
            AnyView(DockPageHeader(
                title: selectedMode.pageHeaderTitle,
                subtitle: pageHeaderSubtitle
            ))
        }
    }

    private var settingsWorkspaceContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader
            GeometryReader { geometry in
                let layout = SettingsLayoutMode.forWidth(geometry.size.width)
                Group {
                    if layout == .rail {
                        HStack(spacing: 0) {
                            settingsCategoryRail
                                .frame(width: 184)
                            Divider().overlay(Color.dockBorderLight)
                            settingsDetailScroll
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            settingsCategoryMenu
                            Divider().overlay(Color.dockBorderLight)
                            settingsDetailScroll
                        }
                    }
                }
            }
        }
        .task {
            model.refreshRuntimeConfiguration()
            model.refreshRuntimeModelOptions()
        }
    }

    private var settingsCategoryRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsCategory.allCases) { category in
                    settingsCategoryRow(category)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.hidden)
    }

    private var settingsCategoryMenu: some View {
        Picker("Settings category", selection: $selectedSettingsCategory) {
            ForEach(SettingsCategory.allCases) { category in
                Text(category.title).tag(category)
            }
        }
        .pickerStyle(.menu)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsCategoryRow(_ category: SettingsCategory) -> some View {
        let badge = settingsCategoryBadge(for: category)
        return DockNavRow(
            title: category.title,
            icon: category.icon,
            isSelected: selectedSettingsCategory == category,
            showsUpdateBadge: badge?.kind == .dot,
            style: DockThemePalette(theme: dockThemeStore.selectedThemeID)
        ) {
            withAnimation(.dockEase(duration: 0.18)) {
                selectedSettingsCategory = category
            }
        }
        .overlay(alignment: .trailing) {
            if let badge, badge.kind != .dot {
                settingsCategoryBadgeView(badge)
                    .padding(.trailing, 10)
                    .allowsHitTesting(false)
            }
        }
        .help(category.subtitle)
    }

    @ViewBuilder
    private func settingsCategoryBadgeView(_ badge: SettingsCategoryBadge) -> some View {
        switch badge.kind {
        case .dot:
            Circle()
                .fill(badge.isWarning ? Color.dockWarning : Color.dockAccent)
                .frame(width: 7, height: 7)
        case .count(let count):
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(badge.isWarning ? Color.dockWarning : Color.dockMetadataText)
        }
    }

    private func settingsCategoryBadge(for category: SettingsCategory) -> SettingsCategoryBadge? {
        switch category {
        case .general:
            return agentUpdateService.phase == .updateAvailable
                ? SettingsCategoryBadge(kind: .dot, isWarning: true)
                : nil
        case .integrations:
            let count = unavailableSetupCapabilities.count
            return count > 0 ? SettingsCategoryBadge(kind: .count(count), isWarning: true) : nil
        case .session:
            let count = control.attention.filter { $0.state == .open }.count
            return count > 0 ? SettingsCategoryBadge(kind: .count(count), isWarning: true) : nil
        case .runtime, .chat, .workspace, .safety, .browser, .memory, .voice, .advanced, .project, .diagnostics:
            return nil
        }
    }

    private var settingsDetailScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                coreContent
                    .frame(maxWidth: 920, alignment: .leading)
                    .padding(.top, 20)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
        }
    }

    private var officeKanbanIsCurrent: Bool {
        control.globalKanbanIsCurrent
    }

    private var officePreviewContent: some View {
        OfficePreviewView(
            kanbanTasks: control.globalKanbanTasks,
            bots: botMode.bots,
            mainSessions: officeMainSessions,
            onOpenSession: { id in
                if let session = model.sessions.first(where: { $0.id == id }) { model.resumeSession(session) }
                else if let session = control.activeSessions.first(where: { $0.id == id }) { control.openLatestActivitySession(session) }
            },
            avatarImages: botMode.avatarImages,
            canAssignTasks: control.capabilityAvailable("kanban.assign"),
            isDataCurrent: officeKanbanIsCurrent,
            subtitle: projectionHeaderSubtitle(control.projectionState(for: "kanban.board"), fallback: selectedMode.pageHeaderSubtitle),
            onRefresh: { control.refreshGlobalKanban(); control.refresh(); botMode.refresh() },
            isRefreshing: control.isKanbanRefreshPending
        ) { task, botID in
                guard control.capabilityAvailable("kanban.assign") else { return }
                kanbanMutationRequest = KanbanMutationRequest(task: task, kind: .assign, value: botID, reclaimFirst: false)
        }
        .task { await botMode.refreshNow(force: true) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var officeMainSessions: [OfficeMainSession] {
        let botIDs = Set(botMode.bots.filter { !$0.isDefault }.map(\.id))
        let sessionsCurrent: Bool
        if case .ready = control.projectionState(for: "sessions") { sessionsCurrent = true }
        else { sessionsCurrent = false }
        var summaries = control.activeSessions.filter { session in
            session.profileID.map { !botIDs.contains($0) } ?? true
        }
        if let id = model.sessionID, !summaries.contains(where: { $0.id == id }),
           model.sessionProfileID.map({ !botIDs.contains($0) }) ?? true {
            summaries.append(.init(id: id, title: model.sessions.first(where: { $0.id == id })?.displayTitle ?? "Current conversation", state: "unknown", preview: nil))
        }
        return summaries.map { session in
            let current = session.id == model.sessionID
            let state: String
            if current {
                switch model.status {
                case .working: state = "working"
                case .needsApproval: state = "needs_approval"
                case .needsClarification: state = "needs_clarification"
                case .idle: state = "idle"
                case .offline: state = "offline"
                }
            } else { state = sessionsCurrent ? session.state : "unknown" }
            let activities = control.latestActivities.filter { $0.sessionID == session.id }.prefix(12).map {
                OfficeMainSession.Activity(id: $0.id, name: $0.activityName, timestamp: $0.timestamp)
            }
            return OfficeMainSession(id: session.id, title: session.title, state: state, isCurrent: current, activities: activities)
        }
    }

    private var pageHeaderSubtitle: String {
        switch selectedMode {
        case .missionControl:
            guard let queue = control.stuckCardQueue else { return selectedMode.pageHeaderSubtitle }
            let stuck = queue.total == 1 ? "1 card not moving" : "\(queue.total) cards not moving"
            return queue.providerWalled ? "\(stuck) · provider rate limited, retries paused" : stuck
        case .today:
            return projectionHeaderSubtitle(
                control.projectionState(for: "sessions"),
                fallback: selectedMode.pageHeaderSubtitle
            )
        case .session:
            return projectionHeaderSubtitle(
                model.sessionProjectionState,
                fallback: selectedMode.pageHeaderSubtitle
            )
        case .kanban:
            return projectionHeaderSubtitle(
                control.projectionState(for: "kanban.board"),
                fallback: kanbanHeaderSubtitle
            )
        case .core:
            return projectionHeaderSubtitle(
                model.runtimeConfigurationProjectionState,
                fallback: selectedMode.pageHeaderSubtitle
            )
        case .automations:
            return projectionHeaderSubtitle(
                control.projectionState(for: "cron.jobs"),
                fallback: selectedMode.pageHeaderSubtitle
            )
        default:
            return selectedMode.pageHeaderSubtitle
        }
    }

    private var kanbanHeaderSubtitle: String {
        let boardName = control.kanbanBoards.first(where: { $0.slug == control.selectedKanbanBoardSlug })?.name
            ?? control.selectedKanbanBoardSlug
            ?? "Current board"
        let total = control.kanbanBoards.first(where: { $0.slug == control.selectedKanbanBoardSlug })?.total
            ?? control.kanbanTasks.count
        return "\(boardName) · \(control.kanbanTasks.count) of \(total) tasks"
    }

    /// A page header reserves one subtitle line, so projection transitions
    /// never insert a temporary row and shift the page underneath the user.
    private func projectionHeaderSubtitle<Value: Equatable & Sendable>(
        _ state: HermesProjectionState<Value>?,
        fallback: String
    ) -> String {
        guard let state else { return fallback }
        switch state {
        case .loading:
            return "Refreshing workspace…"
        case .stale:
            return "Refreshing workspace…"
        case .empty:
            return fallback
        case .unavailable, .failed:
            return "Workspace status is unavailable"
        case .ready:
            return fallback
        }
    }

    private var sidebarHeader: some View {
            HStack {
                Spacer()
                Button { isShowingCommandPalette = true } label: {
                    DockIcon(.command)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockAccent)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .help("Command palette")
                .keyboardShortcut("k", modifiers: [.command])
                Button(action: onClose) {
                    DockIcon(.caretLeft)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockSecondaryText)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.dockSurface4))
                }
                .buttonStyle(.borderless)
                .dockHitTarget()
                .help("Return to chat")
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private var observedSidebar: some View {
        sidebarContent
        .background {
            ZStack {
                Color.dockCanvas
                RadialGradient(
                    colors: [Color.dockAccent.opacity(0.055), .clear],
                    center: UnitPoint(x: 0.9, y: 0),
                    startRadius: 0,
                    endRadius: 300
                )
            }
        }
        .fileImporter(isPresented: $showingRepositoryPicker, allowedContentTypes: [.folder], onCompletion: handleRepositoryImport)
        // Repository loading is owned by DockPopover's shared context-panel
        // task so switching Global/Session cannot let this view clear or race
        // the workflow projection. Manual Refresh actions still use the local
        // refreshRepository() path below.
        .task {
            control.bind(to: model)
            control.refresh()
            // The initial tab does not produce an `onChange` event. Load
            // projections only after binding the CLI client, so a directly
            // opened Quota or Kanban tab never misses its first request.
            if selectedMode == .quota {
                control.refreshProviderQuota()
            } else if selectedMode == .usage {
                control.refreshTokenUsage(days: UsageWorkspaceView.storedDays)
            } else if selectedMode == .kanban {
                applyKanbanFilters()
            } else if selectedMode == .officePreview {
                control.refreshGlobalKanban()
            }
        }
        .onChange(of: model.status) { _, _ in control.rebuildAttention() }
        .onChange(of: model.approvalText) { _, _ in control.rebuildAttention() }
        .onChange(of: model.sessionID) { _, sessionID in
            sessionSteerFeedback = nil
            control.focus(sessionID: sessionID)
            if sessionID != nil {
                control.refresh()
            }
        }
        .onChange(of: control.projectSessions) { _, sessions in
            guard let path = selectedProjectFolderPath, !sessions.isEmpty else { return }
            store.attachProject(at: path, toSessions: sessions)
        }
        .onChange(of: control.cronJobs) { _, _ in
            reconcileSelectedCronJob()
        }
        .onChange(of: control.capabilities) { _, _ in
            guard selectedMode == .kanban, control.capabilityAvailable("kanban") else { return }
            applyKanbanFilters()
        }
        .onChange(of: selectedMode) { _, mode in
            switch mode {
            case .quota:
                control.refreshProviderQuota()
            case .usage:
                control.refreshTokenUsage(days: UsageWorkspaceView.storedDays)
            case .kanban:
                // Re-apply this surface's visible controls. This prevents a
                // session-only query started from Activity from leaking into
                // a separately opened global board.
                applyKanbanFilters()
            case .officePreview:
                // The office reads the same global Kanban projection as the
                // Kanban page; it never creates or mutates a second task store.
                control.refreshGlobalKanban()
            case .automations:
                control.refresh()
                control.refreshCronRuns()
                reconcileSelectedCronJob()
            default:
                break
            }
        }
        .onChange(of: model.runtimeConfiguration) { _, _ in
            guard selectedMode == .quota else { return }
            control.refreshProviderQuota()
        }
        .onChange(of: model.observedKanbanTaskRevision) { _, _ in
            // Keep the board in step with an exact `kanban show <id>` tool
            // event. The task may not carry a durable session_id, so waiting
            // for a session-filtered list would leave the board falsely empty.
            if selectedMode == .officePreview { control.refreshGlobalKanban() }
            else if selectedMode == .kanban { applyKanbanFilters(trigger: .background) }
        }
        .task(id: selectedMode == .quota) {
            guard selectedMode == .quota else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled, selectedMode == .quota else { return }
                control.refreshProviderQuota()
            }
        }
        .onChange(of: model.controlInboxRequest) { _, _ in
            selectedMode = .inbox
            selectedAttentionID = model.requestedAttentionID
        }
        .onChange(of: searchQuery) { _, query in
            guard selectedMode == .search else { return }
            control.search(query)
        }

    }

    var body: some View {
        observedSidebar
        .sheet(isPresented: $isShowingCommandPalette) {
            DockActionPalette(repositoryAvailable: activeRepositoryPath != nil, isWorking: model.status == .working) { command in
                run(command)
                isShowingCommandPalette = false
            }
        }
        .sheet(item: $kanbanMutationRequest) { request in
            KanbanMutationEditor(request: request, assignees: control.kanbanAssignees, isPending: control.isActionPending(control.kanbanActionID(request.kind, task: request.task))) { updated in
                control.mutateKanban(updated)
            }
        }
        .sheet(item: $cronEditJob) { job in
            CronEditEditor(job: job, isPending: control.isActionPending(control.cronActionID("edit", job: job))) { draft in
                control.editCron(job, draft: draft)
            }
        }
        .sheet(item: $cronReportRequest) { request in
            CronReportDetailSheet(request: request, control: control)
        }
        .sheet(isPresented: $isShowingAutomationComposer) {
            automationComposer
        }
        .confirmationDialog("Complete Apple Reminder?", isPresented: $isShowingReminderConfirmation) {
            if let reminder = reminderForConfirmation {
                Button("Complete Reminder") { control.completeReminder(reminder) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let reminder = reminderForConfirmation {
                Text("Hermes will submit a request to complete ‘\(reminder.title)’ through the Apple Reminders skill. No other reminder will be changed.")
            }
        }
        .confirmationDialog("Remove Scheduled Job?", isPresented: $isShowingCronRemovalConfirmation) {
            if let job = cronRemovalRequest {
                Button("Remove Job", role: .destructive) { control.removeCron(job) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let job = cronRemovalRequest {
                Text("Hermes will remove ‘\(job.name)’ from the scheduler.")
            }
        }
        .confirmationDialog("Run Scheduled Job Now?", isPresented: $isShowingCronRunConfirmation) {
            if let job = cronRunRequest {
                Button("Run Job Now") { control.runCronNow(job) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let job = cronRunRequest {
                Text("Hermes will start ‘\(job.name)’ immediately, in addition to its normal schedule.")
            }
        }
        .confirmationDialog("Create Scheduled Job?", isPresented: $isShowingAutomationConfirmation) {
            Button("Create Job") {
                Task {
                    if await control.createCron(name: automationName, schedule: automationSchedule, prompt: automationPrompt) {
                        automationName = ""
                        automationSchedule = ""
                        automationPrompt = ""
                        isShowingAutomationComposer = false
                        control.refresh()
                        control.refreshCronRuns()
                        reconcileSelectedCronJob()
                    }
                }
            }
            .disabled(control.isActionPending("cron.create"))
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will create ‘\(automationName)’ on schedule ‘\(automationSchedule)’." )
        }
        .confirmationDialog("Reload MCP Tools?", isPresented: $isShowingMCPReloadConfirmation) {
            Button("Reload MCP Tools") { control.reloadMCP() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will invalidate the active session's cached MCP tool snapshot and reload configured servers.")
        }
        .confirmationDialog("Create Kanban Task?", isPresented: $isShowingKanbanConfirmation) {
            Button("Create Kanban Task") {
                Task {
                    if await control.createKanbanTask(title: kanbanTitle, body: kanbanBody) {
                        kanbanTitle = ""
                        kanbanBody = ""
                        isShowingKanbanComposer = false
                    }
                }
            }
            .disabled(control.isCreatingKanbanTask)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will create this task in the authoritative Kanban board through its CLI.")
        }
        .confirmationDialog("Change Kanban Task?", isPresented: $isShowingKanbanChangeConfirmation) {
            if let request = kanbanChangeRequest {
                Button(kanbanActionTitle(for: request.action)) {
                    control.updateKanbanTask(request.task, action: request.action)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let request = kanbanChangeRequest {
                let action = request.action.rawValue
                let title = request.task.title
                Text(verbatim: "Hermes will " + action + " ‘" + title + "’ on the authoritative Kanban board.")
            }
        }
        .confirmationDialog("Undo Last Turn?", isPresented: $isShowingUndoConfirmation) {
            Button("Undo Last Turn", role: .destructive) { Task { _ = await control.undoActiveSession() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will remove the latest real user turn and its following output. This cannot be recovered through Herm.")
        }
        .confirmationDialog("Create Session Branch?", isPresented: $isShowingBranchConfirmation) {
            Button("Create Branch") { Task { _ = await control.branchActiveSession(name: sessionBranchName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will create a new session branch from the current conversation.")
        }
        .confirmationDialog("Compress Session Context?", isPresented: $isShowingCompressConfirmation) {
            Button("Compress Context") { Task { _ = await control.compressActiveSession(focusTopic: sessionCompressTopic) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will summarize the current session context. The session remains authoritative.")
        }
        .confirmationDialog("Create Hermes Handoff?", isPresented: $isShowingHandoffConfirmation) {
            Button("Create Handoff") {
                let prompt = workflow.handoffPrompt(focus: handoffFocus, verification: control.verification, review: workflow.review)
                Task {
                    if await control.startBackgroundTask(prompt, kind: .handoff) {
                        handoffFocus = ""
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will prepare a no-edit Markdown handoff in the current session. The result stays in the current Herm runtime until you copy or explicitly send it elsewhere.")
        }
        .confirmationDialog("Change Global Delegation?", isPresented: $isShowingDelegationConfirmation) {
            Button(control.delegationPaused ? "Resume Delegation" : "Pause Delegation") {
                Task { _ = await control.pauseDelegation(!control.delegationPaused) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes delegation for Hermes globally, not only for the current session.")
        }
        .confirmationDialog("Pause New Hermes Work?", isPresented: $isShowingEmergencyStopConfirmation) {
            Button("Pause New Work", role: .destructive) {
                control.engageEmergencyStop(reason: "Paused from Herm")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will stop new cron, Kanban, and gateway turns. In-flight work will continue.")
        }
        .confirmationDialog("Resume New Hermes Work?", isPresented: $isShowingEmergencyResumeConfirmation) {
            Button("Resume New Work") {
                control.releaseEmergencyStop()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will resume accepting new cron, Kanban, and gateway turns globally.")
        }
        .confirmationDialog("Restore Session Checkpoint?", isPresented: Binding(get: { checkpointForRestore != nil }, set: { if !$0 { control.cancelRestoreCheckpoint(); checkpointForRestore = nil } })) {
            if let checkpoint = checkpointForRestore {
                Button("Restore Checkpoint", role: .destructive) {
                    Task {
                        _ = await control.restoreCheckpoint(checkpoint)
                        checkpointForRestore = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) { control.cancelRestoreCheckpoint(); checkpointForRestore = nil }
        } message: {
            if let checkpoint = checkpointForRestore {
                Text("Hermes will restore this session to checkpoint \(checkpoint.hash). Changes after that checkpoint cannot be recovered through Herm.")
            }
        }
        .confirmationDialog("Change Project?", isPresented: $isShowingProjectMutationConfirmation) {
            if let mutation = pendingProjectMutation, let project = control.selectedProject {
                switch mutation {
                case .activate:
                    Button("Set Active Project") { Task { _ = await control.setActiveProject(project) } }
                case .archive:
                    Button("Archive Project", role: .destructive) { Task { _ = await control.archiveProject(project) } }
                case .delete:
                    Button("Delete Project", role: .destructive) { Task { _ = await control.deleteProject(project) } }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let mutation = pendingProjectMutation, let project = control.selectedProject {
                Text(projectMutationMessage(mutation, project: project))
            }
        }
        .confirmationDialog("Create Project?", isPresented: $isShowingProjectCreationConfirmation) {
            if let folder = pendingProjectFolder {
                Button("Create Project") {
                    let name = folder.lastPathComponent
                    Task { _ = await control.createProject(name: name, folder: folder.path) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let folder = pendingProjectFolder {
                Text("Hermes will create a project named \(folder.lastPathComponent) for this folder.")
            }
        }
        .confirmationDialog("Stop Hermes Process?", isPresented: Binding(get: { pendingProcess != nil }, set: { if !$0 { pendingProcess = nil } })) {
            if let process = pendingProcess {
                Button("Stop \(process.name)", role: .destructive) {
                    Task { _ = await control.killProcess(process); pendingProcess = nil }
                }
            }
            Button("Cancel", role: .cancel) { pendingProcess = nil }
        } message: {
            Text("Hermes will terminate only the selected process in the active session.")
        }
        .confirmationDialog("Interrupt Hermes Agent?", isPresented: Binding(get: { pendingAgentID != nil }, set: { if !$0 { pendingAgentID = nil } })) {
            if let agentID = pendingAgentID {
                Button("Interrupt Agent", role: .destructive) {
                    Task { _ = await control.interruptSubagent(agentID); pendingAgentID = nil }
                }
            }
            Button("Cancel", role: .cancel) { pendingAgentID = nil }
        } message: {
            Text("Hermes will interrupt the selected native subagent. Synthesized placeholders are not interruptible.")
        }
        .sheet(item: $clarificationItem, onDismiss: { clarificationResponse = "" }) { item in
            DockModal(icon: .question, title: "Clarification Required", subtitle: "Hermes needs your input to continue.", width: 440) {
                Text(item.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.dockPrimaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let choices = item.choices, !choices.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("SUGGESTED RESPONSES")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(Color.dockMetadataText)
                        ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                            Button {
                                clarificationResponse = choice
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    DockIcon(clarificationResponse == choice ? .checkCircle : .circle)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(choice)
                                        .font(.system(size: 12))
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(clarificationResponse == choice ? Color.dockAccent : Color.dockPrimaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                                        .fill(clarificationResponse == choice ? Color.dockAccent.opacity(0.12) : Color.dockControlSurface)
                                        .stroke(clarificationResponse == choice ? Color.dockAccent.opacity(0.65) : Color.dockBorder, lineWidth: 0.5)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                TextField("Your response", text: $clarificationResponse, axis: .vertical)
                    .textFieldStyle(.dockGlass)
                    .lineLimit(3...6)
            } footer: {
                modalActions(
                    primaryTitle: "Send Response",
                    isDisabled: clarificationResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    isPending: false,
                    onCancel: { clarificationItem = nil }
                ) {
                    control.respond(to: item, action: .respond, response: clarificationResponse)
                    clarificationItem = nil
                }
            }
        }
    }

    private var modePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
            ForEach(compactRailNavigation) { mode in
                compactTabButton(
                    title: mode.globalRailLabel,
                    icon: mode.icon,
                    count: badgeCount(for: mode),
                    isUrgent: badgeIsUrgent(for: mode),
                    isSelected: selectedMode == mode
                ) {
                    select(mode)
                }
            }

            compactTabButton(title: "Artifacts", icon: .fileMagnifyingGlass, isSelected: false) {
                onOpenArtifacts()
            }
            compactTabButton(
                title: "Conversations",
                icon: .chats,
                count: compactUnlinkedSessions.count,
                isUrgent: false,
                isSelected: selectedMode == .session
            ) {
                select(.session)
            }
            compactTabButton(
                title: "Projects",
                icon: .folder,
                count: compactProjectGroups.count,
                isUrgent: false,
                isSelected: selectedMode == .projects
            ) {
                select(.projects)
            }

            Menu {
                Section("More") {
                    ForEach(compactOverflowNavigation) { mode in
                        secondaryModeButton(mode)
                    }
                }
            } label: {
                compactTabLabel(
                    title: "More",
                    icon: .dotsThreeCircle,
                    detail: isToolsModeSelected ? selectedMode.tabLabel : nil,
                    badgeCount: toolsBadgeCount,
                    isUrgent: toolsBadgeIsUrgent,
                    isSelected: isToolsModeSelected
                )
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.borderless)
            .help(isToolsModeSelected ? selectedMode.tabLabel : "More control views")
        }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private func compactTabButton(
        title: String,
        icon: Ph,
        count: Int = 0,
        isUrgent: Bool = false,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            compactTabLabel(
                title: title,
                icon: icon,
                detail: nil,
                badgeCount: count,
                isUrgent: isUrgent,
                isSelected: isSelected
            )
        }
        .buttonStyle(.borderless)
    }

    private func compactTabLabel(
        title: String,
        icon: Ph,
        detail: String?,
        badgeCount: Int,
        isUrgent: Bool,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 6) {
            DockIcon(icon)
                .font(.system(size: 11, weight: .semibold))
            Text(detail ?? title)
                .lineLimit(1)
            if badgeCount > 0 {
                badgeView(count: badgeCount, isUrgent: isUrgent)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(isSelected ? Color.dockPrimaryText : Color.dockSecondaryText)
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(isSelected ? Color.dockAccent.opacity(0.14) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
        .contentShape(Rectangle())
    }

    private struct CompactProjectGroup: Identifiable {
        let id: String
        let title: String
        let sessions: [HermesSession]
    }

    private var compactSortedSessions: [HermesSession] {
        model.sessions.sorted { ($0.lastUpdatedAt ?? .distantPast) > ($1.lastUpdatedAt ?? .distantPast) }
    }

    private var compactProjectGroups: [CompactProjectGroup] {
        control.projects
            .filter { $0.name != "__no_project__" }
            .map { project in
                let sessions = compactSortedSessions.filter {
                    project.sessionIDs.contains($0.id) || control.projectIDBySessionID[$0.id] == project.id
                }
                let name = URL(fileURLWithPath: project.name).lastPathComponent
                return CompactProjectGroup(id: project.id, title: name.isEmpty ? project.name : name, sessions: sessions)
            }
            .filter { !$0.sessions.isEmpty }
            .sorted { ($0.sessions.first?.lastUpdatedAt ?? .distantPast) > ($1.sessions.first?.lastUpdatedAt ?? .distantPast) }
    }

    private var compactUnlinkedSessions: [HermesSession] {
        let linkedIDs = Set(compactProjectGroups.flatMap { $0.sessions.map(\.id) })
        return compactSortedSessions.filter { !linkedIDs.contains($0.id) }
    }

    /// Compact mode mirrors the fullscreen rail's daily operator destinations.
    /// Repository and setup surfaces remain available from More.
    private var compactRailNavigation: [ControlTab] {
        [.today, .inbox, .missionControl, .kanban, .quota, .automations]
    }

    private var compactOverflowNavigation: [ControlTab] {
        [.usage, .projects, .search, .officePreview, .core]
    }

    private var isToolsModeSelected: Bool {
        compactOverflowNavigation.contains(selectedMode)
    }

    private var toolsBadgeCount: Int {
        compactOverflowNavigation.reduce(0) { $0 + badgeCount(for: $1) }
    }

    private var toolsBadgeIsUrgent: Bool {
        compactOverflowNavigation.contains(where: badgeIsUrgent(for:))
    }

    private func navigationMenuLabel(
        title: String,
        detail: String?,
        badgeCount: Int,
        isUrgent: Bool,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 8) {
            DockIcon(.dotsThreeCircle)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, alignment: .center)
            Text(detail ?? title)
                .lineLimit(1)
            if badgeCount > 0 {
                badgeView(count: badgeCount, isUrgent: isUrgent)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isSelected ? Color.dockPrimaryText : Color.dockSecondaryText)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background(isSelected ? Color.dockAccent.opacity(0.14) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
        .contentShape(Rectangle())
    }

    private func secondaryModeButton(_ mode: ControlTab) -> some View {
        Button { select(mode) } label: {
            HStack {
                DockIconLabel(mode.tabLabel, icon: mode.icon)
                if badgeCount(for: mode) > 0 {
                    Text(badgeLabel(for: mode))
                }
                if selectedMode == mode {
                    DockIcon(.check)
                }
            }
        }
    }

    private func modeButton(_ mode: ControlTab) -> some View {
        Button { select(mode) } label: {
            HStack(spacing: 8) {
                DockIcon(mode.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, alignment: .center)
                Text(mode.globalRailLabel)
                    .lineLimit(1)
                if badgeCount(for: mode) > 0 {
                    badgeView(count: badgeCount(for: mode), isUrgent: badgeIsUrgent(for: mode))
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(selectedMode == mode ? Color.dockPrimaryText : Color.dockSecondaryText)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(selectedMode == mode ? Color.dockAccent.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    private func badgeView(count: Int, isUrgent: Bool) -> some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 12, weight: .bold))
            .monospacedDigit()
            .tracking(0)
            .foregroundStyle(isUrgent ? Color.dockOnAccentText : Color.dockPrimaryText)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, 4)
            .background(Capsule().fill(isUrgent ? Color.dockWarning : Color.dockAccent.opacity(0.85)))
    }

    private func select(_ mode: ControlTab) {
        withAnimation(.dockEase(duration: 0.2)) { selectedMode = mode }
        if mode == .core {
            model.refreshRuntimeConfiguration()
            control.refresh(forceCapabilities: true)
        }
        if mode == .automations { control.refresh(); control.refreshCronRuns() }
        if mode == .projects {
            control.refresh()
            Task { await refreshRepository() }
        }
        if mode == .search { control.search(searchQuery) }
        // Always derive the request from this surface's visible controls. A
        // direct refresh can retain the session filter set by Activity, then
        // make the global board look empty while active cards exist.
        if mode == .kanban { applyKanbanFilters() }
        if mode == .missionControl { control.refreshMissionControl() }
        if mode == .verification { control.refreshVerification() }
        if mode == .changes { Task { await refreshRepository() } }
    }

    private func run(_ command: DockAction) {
        switch command {
        case .tab(let tab): select(tab)
        case .newChat: model.newChat(); model.requestComposerFocus()
        case .focusComposer: model.requestComposerFocus()
        case .stop: model.stop()
        case .voice: model.startVoiceConversation()
        case .refresh:
            control.refresh(forceCapabilities: true)
            Task { await refreshRepository() }
        case .artifacts: onOpenArtifacts()
        case .restartDock: isShowingDockRestartConfirmation = true
        case .workflow(let recipe):
            guard !recipe.requiresRepository || activeRepositoryPath != nil else { return }
            let repositoryContext = activeRepositoryPath.map { " Repository: \($0)." } ?? ""
            Task { _ = await control.startBackgroundTask(recipe.prompt + repositoryContext) }
        }
    }

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("BACKGROUND TASKS")
                HStack(spacing: 8) {
                    TextField("Run a task in the background…", text: $backgroundTaskPrompt)
                        .textFieldStyle(.dockGlass)
                    Button(isStartingBackgroundTask ? "STARTING…" : "RUN") {
                        let prompt = backgroundTaskPrompt
                        isStartingBackgroundTask = true
                        Task {
                            if await control.startBackgroundTask(prompt) { backgroundTaskPrompt = "" }
                            isStartingBackgroundTask = false
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.dockAccent)
                    .disabled(isStartingBackgroundTask || backgroundTaskPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(model.currentSessionBackgroundTasks.reversed()) { task in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("PROMPT").foregroundStyle(Color.dockMetadataText)
                            Text(task.prompt).foregroundStyle(Color.dockSecondaryText)
                            if let output = task.output {
                                Text("OUTPUT").foregroundStyle(Color.dockMetadataText).padding(.top, 3)
                                Text(output).foregroundStyle(Color.dockPrimaryText).textSelection(.enabled)
                                if task.kind == .handoff {
                                    Button("OPEN KANBAN DRAFT") {
                                        kanbanTitle = "Handoff follow-up"
                                        kanbanBody = output
                                        select(.kanban)
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(Color.dockAccent)
                                }
                            }
                        }
                        .font(.system(size: 11))
                        .padding(.top, 5)
                    } label: {
                        HStack {
                            Circle().fill(task.status == .completed ? Color.dockSuccess : Color.dockAccent).frame(width: 6, height: 6)
                            Text(task.status == .completed ? "COMPLETE" : "RUNNING")
                            if task.kind != .general { Text(task.kind.rawValue.uppercased()) }
                            Text(task.prompt).lineLimit(1).foregroundStyle(Color.dockSecondaryText)
                            Spacer()
                            Text(HumanDateFormatting.timeOnly(task.startedAt)).foregroundStyle(Color.dockMetadataText)
                        }
                        .font(.system(size: 11))
                    }
                    .foregroundStyle(Color.dockAccent)
                }
            }
            SessionBotActivityView(
                model: model,
                botMode: botMode,
                sessionID: model.kanbanSessionID,
                onOpenBotChat: { bot in model.resumeBotChat(bot) }
            )
            AgentBoardView(model: model, embedded: true)
        }
    }

    private func openSessionKanban() {
        // The left Control Kanban is always global. Session attribution belongs
        // to the Activity projection, not this board surface.
        kanbanCurrentSessionOnly = false
        withAnimation(.dockEase(duration: 0.2)) { selectedMode = .kanban }
        applyKanbanFilters()
    }

    private func openSessionKanbanTask(_ taskID: String) {
        guard let task = control.sessionKanbanTasks.first(where: { $0.id == taskID }) else {
            openSessionKanban()
            return
        }
        openSessionKanban()
        selectedKanbanTask = task
        control.loadKanbanTask(task)
    }

    private var changesContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("CHANGE REVIEW")
            if let codeWorkspaceError {
                Text(codeWorkspaceError)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.dockWarning.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
            }
            if let review = workflow.review {
                HStack(spacing: 8) {
                    todayMetric("BLOCKERS", value: review.blockerCount, color: review.blockerCount > 0 ? .dockDestructive : .dockSuccess)
                    todayMetric("WARNINGS", value: review.warningCount, color: review.warningCount > 0 ? .dockWarning : .dockSuccess)
                    todayMetric("NOTES", value: review.noteCount, color: .dockSecondaryText)
                    Text(review.completeness == .complete ? "COMPLETE" : "PARTIAL")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(review.completeness == .complete ? Color.dockSuccess : Color.dockWarning)
                }
                HStack(spacing: 10) {
                    Button("RUN LOCAL REVIEW") { Task { await workflow.runReview(preferences: commandCenterPreferences) } }
                    Button("SAVE BASELINE") { workflow.saveReviewBaseline(preferences: commandCenterPreferences, acknowledgedFindingIDs: review.findings.map(\.id)) }
                        .disabled(!workflow.canSaveReviewBaseline)
                    Button("REVIEW WITH HERMES") {
                        let prompt = "Review the current repository changes without editing files. Local findings: \(review.blockerCount) blockers, \(review.warningCount) warnings, \(review.noteCount) notes. Inspect safely and report risks, missing tests, and verification scope."
                        Task { _ = await control.startBackgroundTask(prompt, kind: .review) }
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
                switch workflow.baselineStatus {
                case .current(let date):
                    Text("BASELINE CURRENT · \(HumanDateFormatting.dateAndTime(date))").foregroundStyle(Color.dockSuccess)
                case .stale(let date):
                    Text("BASELINE STALE · \(HumanDateFormatting.dateAndTime(date))").foregroundStyle(Color.dockWarning)
                case .partial(let date):
                    Text("PARTIAL BASELINE · \(HumanDateFormatting.dateAndTime(date))").foregroundStyle(Color.dockWarning)
                case .none:
                    EmptyView()
                }
            } else {
                Button("RUN LOCAL REVIEW") { Task { await workflow.runReview(preferences: commandCenterPreferences) } }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
            }
            // The repository browser owns the unloaded/loading state. Once
            // the workflow snapshot matches the session's resolved project,
            // render the browser; otherwise let the branches below explain
            // the repository or loading state instead of treating every
            // snapshot as a match.
            if workflow.repository.path == activeRepositoryPath {
                RepositoryChangesBrowser(
                    model: model,
                    workflow: workflow,
                    projectPath: activeRepositoryPath,
                    onRefresh: { await refreshRepository() },
                    onSelectProjectFolder: { showingRepositoryPicker = true }
                )
            } else if let changes = workflow.changes, workflow.repository.isGitRepository {
                HStack(spacing: 8) {
                    todayMetric("STAGED", value: changes.stagedCount, color: .dockAccent)
                    todayMetric("UNSTAGED", value: changes.unstagedCount, color: .dockWarning)
                    todayMetric("UNTRACKED", value: changes.untrackedCount, color: .dockSecondaryText)
                    todayMetric("CONFLICTS", value: changes.conflictedCount, color: changes.conflictedCount > 0 ? .dockDestructive : .dockSuccess)
                }
                if changes.files.isEmpty {
                    emptyState(icon: .checkCircle, title: "Working tree clean", detail: "No staged, unstaged, or untracked files were found.")
                } else {
                    changeSections(changes)
                }
            } else if let path = activeRepositoryPath {
                let inspecting = isRefreshingRepository || workflow.isRefreshing
                emptyState(
                    icon: inspecting ? .arrowsClockwise : .folder,
                    title: inspecting ? "Inspecting project" : "Project is not a Git repository",
                    detail: inspecting ? path : "\(path) is available as a local project folder, but it has no Git working tree to inspect."
                )
            } else {
                emptyState(icon: .fileMagnifyingGlass, title: "No project selected", detail: "Choose a project from Projects to inspect its local changes.")
                Button("SELECT PROJECT FOLDER") {
                    showingRepositoryPicker = true
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
            }
        }
    }

    @ViewBuilder
    private func changeSections(_ changes: RepositoryChangeSnapshot) -> some View {
        let staged = changes.files.filter(\.isStaged)
        let unstaged = changes.files.filter { !$0.isStaged && $0.status != .untracked }
        let untracked = changes.files.filter { $0.status == .untracked }
        changeSection("STAGED", files: staged, color: .dockAccent)
        changeSection("UNSTAGED", files: unstaged, color: .dockWarning)
        changeSection("UNTRACKED", files: untracked, color: .dockSecondaryText)
    }

    @ViewBuilder
    private func changeSection(_ title: String, files: [RepositoryFileChange], color: Color) -> some View {
        if !files.isEmpty {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 6, height: 6)
                sectionLabel("\(title)  ·  \(files.count)")
            }
            ForEach(files) { file in
                changeFileRow(file)
            }
        }
    }

    private func changeFileRow(_ file: RepositoryFileChange) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if let diff = selectedRepositoryDiff, diff.path == file.path, diff.isStaged == file.isStaged {
                    Text(diff.text.isEmpty ? "No textual diff is available for this file." : diff.text)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockPrimaryText)
                        .textSelection(.enabled)
                    if diff.isTruncated { Text("Diff truncated for safe display.").font(.system(size: 12)).foregroundStyle(Color.dockWarning) }
                    diffAuditSummary(diff)
                } else {
                    Button(isLoadingRepositoryDiff ? "LOADING DIFF…" : "LOAD DIFF") { loadRepositoryDiff(for: file) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.dockAccent)
                        .disabled(isLoadingRepositoryDiff)
                }
                let writers = model.activeSubagents.filter { $0.filesWritten.contains(file.path) }

                if workflow.isReviewCovered(file) {
                    Button(workflow.isReviewed(file) ? "REVIEWED" : "MARK REVIEWED") { workflow.toggleReviewed(file) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(workflow.isReviewed(file) ? Color.dockSuccess : Color.dockAccent)
                }
                Text(writers.isEmpty
                    ? "UNATTRIBUTED LOCAL CHANGE"
                    : "HERMES REPORTED WRITE · " + writers.map { $0.name ?? $0.role ?? $0.id }.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(writers.isEmpty ? Color.dockMetadataText : Color.dockAccent)
            }
            .padding(.top, 5)
        } label: {
            HStack(spacing: 8) {
                DockIcon(file.status == .conflicted ? .warningOctagon : .file)
                    .foregroundStyle(file.status == .conflicted ? Color.dockDestructive : file.isStaged ? Color.dockAccent : Color.dockSecondaryText)
                Text(file.path).lineLimit(1).foregroundStyle(Color.dockPrimaryText)
                Spacer()
                Text(file.isStaged ? "STAGED" : file.status.rawValue.uppercased())
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dockMetadataText)
            }
            .font(.system(size: 12))
        }
        .dockListRow()
    }

    private func loadRepositoryDiff(for file: RepositoryFileChange) {
        Task {
            isLoadingRepositoryDiff = true
            selectedRepositoryDiff = await RepositoryService.diff(path: workflow.repository.path, file: file)
            isLoadingRepositoryDiff = false
        }
    }


    @ViewBuilder
    private func diffAuditSummary(_ diff: RepositoryDiff) -> some View {
        let findings = RepositoryDiffAuditor.audit(diff)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                DockIcon(findings.isEmpty ? .shieldCheck : .shieldWarning)
                Text(findings.isEmpty ? "LOCAL AUDIT · NO OBVIOUS SIGNALS" : "LOCAL AUDIT · \(findings.count) SIGNAL\(findings.count == 1 ? "" : "S")")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(findings.contains(where: { $0.severity == .blocker }) ? Color.dockDestructive : findings.isEmpty ? Color.dockSuccess : Color.dockWarning)

            Text("Checks added lines only. It does not replace repository verification or review.")
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)

            ForEach(findings) { finding in
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(finding.severity == .blocker ? Color.dockDestructive : finding.severity == .warning ? Color.dockWarning : Color.dockAccent)
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(finding.title)\(finding.line.map { " · LINE \($0)" } ?? "")")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.dockPrimaryText)
                        Text(finding.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                }
            }
        }
        .padding(.top, 8)
        .overlay(alignment: .top) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private var verificationContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("VERIFICATION")
            if let facts = control.projectFacts {
                diagnosticRow(label: "MANIFESTS", value: facts.manifests.isEmpty ? "NONE REPORTED" : facts.manifests.joined(separator: " · "), color: Color.dockSecondaryText)
                diagnosticRow(label: "PACKAGE MANAGERS", value: facts.packageManagers.isEmpty ? "NONE REPORTED" : facts.packageManagers.joined(separator: " · "), color: Color.dockSecondaryText)
                let recipes = VerificationRecipeBuilder.make(facts: facts, repository: workflow.repository)
                if !recipes.isEmpty {
                    sectionLabel("VERIFIED RECIPES")
                    ForEach(recipes) { recipe in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(recipe.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dockSecondaryText)
                            Text(recipe.command).font(.system(size: 12)).foregroundStyle(Color.dockPrimaryText).textSelection(.enabled)
                            Button("RUN IN BACKGROUND") {
                                guard let path = activeRepositoryPath else { return }
                                let prompt = "Run this exact verification command in " + path + ": " + recipe.command + ". Do not edit files. Report the result, evidence scope, and exit code."
                                Task { _ = await control.startBackgroundTask(prompt, kind: .verification) }
                            }
                            .buttonStyle(.borderless).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dockAccent)
                        }
                        .dockListRow()
                    }
                }
            }
                if let verification = control.verification {
                let deliveryEvidence = VerificationEvidencePresentation.make(verification: verification, currentFingerprint: workflow.repository.headRevision, evidenceFingerprint: nil, currentRepositoryIdentity: workflow.repository.repositoryID, currentCommitFingerprint: workflow.repository.headRevision, openFailureCount: control.attention.filter { $0.state == .open && $0.kind == .failure }.count, repositoryDirty: workflow.repository.changedFiles > 0)
                diagnosticRow(label: "DELIVERY", value: deliveryEvidence.title.uppercased(), color: deliveryEvidence.state == .current ? .dockSuccess : .dockWarning)
                Text(deliveryEvidence.nextAction)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockMetadataText)
                    .fixedSize(horizontal: false, vertical: true)
                let color: Color = verification.state == .passed ? .dockSuccess : verification.state == .failed ? .dockDestructive : .dockWarning
                diagnosticRow(label: "STATUS", value: verification.state.rawValue.uppercased(), color: color)
                if let evidence = verification.evidence {
                    diagnosticRow(label: "SCOPE", value: evidence.scope?.uppercased() ?? "UNKNOWN", color: evidence.scope?.lowercased() == "targeted" ? .dockWarning : .dockSecondaryText)
                    if let command = evidence.canonicalCommand ?? evidence.command { diagnosticRow(label: "EVIDENCE", value: command, color: .dockMetadataText) }
                    if let adapter = evidence.adapter { diagnosticRow(label: "ADAPTER", value: adapter, color: .dockMetadataText) }
                    if let capturedAt = evidence.capturedAt { diagnosticRow(label: "CAPTURED", value: ISO8601DateFormatter().string(from: capturedAt), color: .dockMetadataText) }
                    if let repository = evidence.repositoryIdentity { diagnosticRow(label: "REPOSITORY", value: repository, color: .dockMetadataText) }
                    if let commit = evidence.commitFingerprint { diagnosticRow(label: "COMMIT", value: commit, color: .dockMetadataText) }
                    if let target = evidence.targetFingerprint { diagnosticRow(label: "TARGET", value: target, color: .dockMetadataText) }
                    if let diff = evidence.diffFingerprint { diagnosticRow(label: "DIFF", value: diff, color: .dockMetadataText) }
                    if let rules = evidence.rulesScopeDetail { diagnosticRow(label: "RULES", value: rules, color: .dockMetadataText) }
                    if let staleReason = deliveryEvidence.staleReason { diagnosticRow(label: "STALE", value: staleReason, color: .dockWarning) }
                }
            } else if control.projectFacts == nil {
                emptyState(icon: .sealCheck, title: "Verification unavailable", detail: "Open a Hermes project session with a local folder, then refresh Settings to request verification facts.")
            }
        }
    }

    private var repositoriesContent: some View {
        let paths = Array(Set(store.tasks.compactMap(\.projectPath) + [store.projectPath].compactMap { $0 })).sorted()
        return VStack(alignment: .leading, spacing: 22) {
            sectionLabel("REPOSITORY FLEET  ·  \(paths.count)")
            Text("Repositories are local read-only references attached to Hermes sessions. No remotes are fetched automatically.")
                .font(.system(size: 12)).foregroundStyle(Color.dockMetadataText)
            if workflow.repository.isGitRepository {
                HStack(spacing: 10) {
                    Button(commandCenterPreferences.isWatchingRepository(workflow.repository.repositoryID) ? "STOP WATCHING" : "WATCH REPOSITORY") {
                        workflow.toggleWatching(preferences: commandCenterPreferences, control: control)
                    }
                    Button("REFRESH FLEET") { Task { await workflow.refresh(preferences: commandCenterPreferences, control: control) } }
                    if case .watching = workflow.watchState {
                        Text("WATCHING").foregroundStyle(Color.dockSuccess)
                    } else if case .stale(let detail) = workflow.watchState {
                        Text(detail).lineLimit(1).foregroundStyle(Color.dockWarning)
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
            }
            if !workflow.notices.isEmpty {
                sectionLabel("RECENT REPOSITORY CHANGES")
                ForEach(workflow.notices) { notice in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(notice.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dockPrimaryText)
                        Text("\(notice.changedFiles) changed file\(notice.changedFiles == 1 ? "" : "s") · \(HumanDateFormatting.dateAndTime(notice.createdAt))")
                            .font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
                        HStack(spacing: 10) {
                            Button("OPEN CHANGES") { select(.changes) }
                            Button("REVIEW WITH HERMES") {
                                let prompt = "Review repository \(notice.displayName) without editing files. Herm detected \(notice.changedFiles) changed files. Report risks, missing tests, and verification scope without quoting suspected credential values."
                                Task { _ = await control.startBackgroundTask(prompt, kind: .review) }
                            }
                            Button("OPEN VERIFICATION") { select(.verification) }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dockAccent)
                    }
                    .dockListRow()
                }
            }
            if paths.isEmpty {
                emptyState(icon: .folder, title: "No repositories attached", detail: "Use Change Repository from Today to attach a local repository to a Hermes session.")
            } else {
                if !workflow.worktrees.isEmpty {
                    DisclosureGroup("WORKTREES  ·  \(workflow.worktrees.count)") {
                        ForEach(workflow.worktrees) { worktree in
                            HStack(spacing: 8) {
                                DockIcon(worktree.snapshot?.conflictedFiles ?? 0 > 0 ? .warningOctagon : .gitBranch)
                                    .foregroundStyle(worktree.snapshot?.conflictedFiles ?? 0 > 0 ? Color.dockDestructive : Color.dockAccent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(worktree.displayName).foregroundStyle(Color.dockPrimaryText)
                                    Text(worktree.branch ?? "DETACHED HEAD").font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
                                }
                                Spacer()
                                Text("\(worktree.snapshot?.changedFiles ?? 0) CHANGED").font(.system(size: 10)).foregroundStyle(Color.dockSecondaryText)
                                Button("USE") { store.attachProject(at: worktree.path, toSessionID: model.sessionID) }
                            }
                            .font(.system(size: 12))
                            .dockListRow()
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
                }
                ForEach(paths, id: \.self) { path in
                    RepositoryFleetRow(path: path, activePath: activeRepositoryPath) { selected in
                        store.attachProject(at: selected, toSessionID: model.sessionID)
                    }
                }
            }
        }
        .task(id: selectedMode == .kanban) {
            guard selectedMode == .kanban else { return }
            while !Task.isCancelled {
                let hasLiveCards = control.kanbanTasks.contains {
                    ["running", "claimed", "in_progress", "blocked", "review", "waiting"].contains($0.status.lowercased())
                }
                try? await Task.sleep(for: hasLiveCards ? .seconds(5) : .seconds(15))
                guard !Task.isCancelled, selectedMode == .kanban else { return }
                applyKanbanFilters(trigger: .background)
            }
        }
    }

    private var automationsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            cronStatusLine
            cronWorkspace
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { reconcileSelectedCronJob() }
    }

    private var automationIsRefreshing: Bool {
        control.isRefreshing || control.refreshState(for: "cron.history")?.isRefreshing == true
    }

    private func refreshAutomations() {
        control.refresh()
        control.refreshCronRuns()
    }

    private func reconcileSelectedCronJob() {
        selectedCronJobID = AutomationHistoryPresentation.selectedJobID(
            currentID: selectedCronJobID,
            jobs: control.cronJobs
        )
    }

    private var cronStatusLine: some View {
        let activeCount = control.cronJobs.filter(\.enabled).count
        let successfulRuns = control.cronRuns.filter(cronRunIsSuccessful).count
        let failedRuns = control.cronRuns.count - successfulRuns
        let successText = control.cronRuns.isEmpty
            ? "No run history"
            : "\(Int((Double(successfulRuns) / Double(control.cronRuns.count)) * 100))% success"
        let nextRun = control.cronJobs.first(where: { $0.nextRun != nil })?.nextRun.map(HumanDateFormatting.dateAndTime)

        return HStack(spacing: 8) {
            Text("\(activeCount) active")
            Text("·")
            Text(successText)
                .foregroundStyle(failedRuns > 0 ? Color.dockWarning : Color.dockMetadataText)
            if let nextRun {
                Text("·")
                Text("Next \(nextRun)")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Color.dockMetadataText)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(minHeight: 24, alignment: .leading)
    }

    private var cronWorkspace: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 22) {
                cronSchedulesColumn
                    .frame(width: 350, alignment: .topLeading)
                cronDetailColumn
                    .frame(minWidth: 280, maxWidth: .infinity, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 22) {
                cronSchedulesColumn
                cronDetailColumn
            }
        }
    }

    private var cronSchedulesColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            cronSectionHeading("Schedules", count: control.cronJobs.count, icon: .calendarDots)
            if control.cronJobs.isEmpty {
                emptyState(icon: .clock, title: "No schedules", detail: "Create an automation when work needs to run without you.")
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(control.cronJobs) { job in
                            cronScheduleRow(job, isSelected: selectedCronJobID == job.id)
                        }
                    }
                }
                .frame(maxHeight: 520)
            }
        }
    }

    private var cronDetailColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let selectedCronJobID,
               let job = control.cronJobs.first(where: { $0.id == selectedCronJobID }) {
                cronDetailSummary(job)
                cronHistorySection
            } else {
                emptyState(icon: .cursorClick, title: "Select a schedule", detail: "Choose a schedule to inspect its cadence, latest result, and run history.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func cronDetailSummary(_ job: CronSummary) -> some View {
        let health = AutomationHealthPresentation.make(
            job: job,
            runs: control.cronRuns,
            capabilityAvailable: true,
            mcpErrorObserved: false
        )
        let latestRun = control.cronRuns.first { $0.jobID == job.id }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(job.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(health.state.rawValue.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(health.state == .healthy ? Color.dockSuccess : health.state == .degraded ? Color.dockWarning : Color.dockMetadataText)
            }
            Text(job.enabled ? "Enabled and scheduled" : "Paused")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(job.enabled ? Color.dockSuccess : Color.dockWarning)

            Divider().overlay(Color.dockBorderLight)
            cronDetailRow("Schedule", value: CronScheduleFormatting.humanReadable(job.schedule))
            cronDetailRow("Expression", value: job.schedule, monospaced: true)
            cronDetailRow("Next run", value: job.nextRun.map(HumanDateFormatting.dateAndTime) ?? "Not reported by Hermes")
            cronDetailRow("Job ID", value: job.id, monospaced: true)
            if let delivery = job.delivery, !delivery.isEmpty {
                cronDetailRow("Delivery", value: delivery.uppercased())
            }
            if let prompt = job.prompt, !prompt.isEmpty {
                cronDetailRow("Request", value: prompt)
            }
            if let latestRun {
                cronDetailRow("Last run", value: latestRun.claimedAt.map(HumanDateFormatting.dateAndTime) ?? latestRun.id)
                HStack(spacing: 6) {
                    Circle().fill(cronRunIsSuccessful(latestRun) ? Color.dockSuccess : Color.dockWarning).frame(width: 5, height: 5)
                    Text("Last status")
                    Text(latestRun.status.uppercased())
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(cronRunIsSuccessful(latestRun) ? Color.dockSuccess : Color.dockWarning)
                if let error = latestRun.error, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockWarning)
                        .lineLimit(3)
                }
            }
            if let latestRun, let request = control.cronReportRequest(for: latestRun) {
                Divider().overlay(Color.dockBorderLight)
                Button("Open latest report") { cronReportRequest = request }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
            }
        }
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private func cronDetailRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .frame(width: 72, alignment: .leading)
                .foregroundStyle(Color.dockMetadataText)
            Text(value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    private var cronHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                DockIcon(.pulse)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
                Text("Run history")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                Text("\(filteredCronRuns.count)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
                Spacer()
                DockTabBar(options: AutomationHistoryScope.allCases, selection: $automationHistoryScope, title: \.title)
            }
            .padding(.bottom, 5)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            if let state = control.refreshState(for: "cron.history"), state.isStale {
                Text("Showing the last successful history while Hermes reconnects.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
            }
            if !control.cronHistoryAvailable && control.cronRuns.isEmpty {
                Text("Hermes automation history is unavailable through the installed CLI.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if filteredCronRuns.isEmpty {
                Text(automationHistoryScope == .selected ? "No runs recorded for this schedule." : "No automation runs recorded.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredCronRuns) { run in
                            if let request = control.cronReportRequest(for: run) {
                                Button { cronReportRequest = request } label: {
                                    cronRunRow(run, canViewReport: true)
                                }
                                .buttonStyle(.plain)
                                .help("View this run's report")
                            } else {
                                cronRunRow(run, canViewReport: false)
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
    }

    private var filteredCronRuns: [CronRunSummary] {
        AutomationHistoryPresentation.runs(
            control.cronRuns,
            scope: automationHistoryScope,
            selectedJobID: selectedCronJobID
        )
    }

    private var cronHistoryColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            cronSectionHeading("Run history", count: control.cronRuns.count, icon: .pulse)
            if let state = control.refreshState(for: "cron.history"), state.isStale {
                Text("Showing the last successful history while Hermes reconnects. \(state.error ?? "")")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 3)
            }
            if !control.cronHistoryAvailable && control.cronRuns.isEmpty {
                Text("Hermes automation history is unavailable through the installed CLI.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if control.cronRuns.isEmpty {
                Text("No automation runs recorded.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(control.cronRuns) { run in
                            if let request = control.cronReportRequest(for: run) {
                                Button {
                                    cronReportRequest = request
                                } label: {
                                    cronRunRow(run, canViewReport: true)
                                }
                                .buttonStyle(.plain)
                                .help("View this run's report")
                            } else {
                                cronRunRow(run, canViewReport: false)
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
    }

    private func cronSectionHeading(_ title: String, count: Int, icon: Ph) -> some View {
        HStack(spacing: 8) {
            DockIcon(icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.dockMetadataText)
            Spacer()
        }
        .padding(.bottom, 5)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private var automationComposer: some View {
        DockModal(icon: .magicWand, title: "New Automation", subtitle: "Set the intent once; Hermes will keep the cadence.", width: 520) {
            HStack(alignment: .top, spacing: 10) {
                labeledField("Name") {
                    TextField("Morning review", text: $automationName).textFieldStyle(.dockGlass)
                }
                labeledField("Schedule", hint: "every 2h · 0 9 * * *") {
                    TextField("When should Hermes run this?", text: $automationSchedule).textFieldStyle(.dockGlass)
                }
            }
            labeledField("Request") {
                TextField("What should Hermes do?", text: $automationPrompt, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.dockGlass)
            }
        } footer: {
            modalActions(
                primaryTitle: "Review and Create",
                isDisabled: !canCreateAutomation || !control.capabilityAvailable("rpc-scheduling"),
                isPending: false,
                onCancel: { isShowingAutomationComposer = false }
            ) {
                isShowingAutomationConfirmation = true
            }
        }
    }

    private func cronScheduleRow(_ job: CronSummary, isSelected: Bool) -> some View {
        let health = AutomationHealthPresentation.make(
            job: job,
            runs: control.cronRuns,
            // A loaded job is not unavailable just because a mutation capability is missing.
            capabilityAvailable: true,
            mcpErrorObserved: false
        )
        return HStack(spacing: 10) {
            Circle()
                .fill(job.enabled ? Color.dockSuccess : Color.dockMetadataText)
                .frame(width: 8, height: 8)
            Button {
                selectedCronJobID = job.id
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(job.name)
                            .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                            .foregroundStyle(Color.dockPrimaryText)
                            .lineLimit(1)
                        if !job.enabled {
                            Text("PAUSED")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.5)
                                .foregroundStyle(Color.dockWarning)
                        }
                    }
                    Text(CronScheduleFormatting.humanReadable(job.schedule))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                    if let nextRun = job.nextRun {
                        Text("Next \(HumanDateFormatting.dateAndTime(nextRun))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.dockMetadataText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Text(health.state.rawValue.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(health.state == .healthy ? Color.dockSuccess : health.state == .degraded ? Color.dockWarning : Color.dockMetadataText)
                .lineLimit(1)

            if control.capabilityAvailable("cron.runNow") {
                Button {
                    cronRunRequest = job
                    isShowingCronRunConfirmation = true
                } label: {
                    Group {
                        if control.isActionPending(control.cronActionID("run", job: job)) {
                            ProgressView().controlSize(.small)
                        } else {
                            DockIcon(.play, weight: .fill)
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .foregroundStyle(Color.dockAccent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(control.isActionPending(control.cronActionID("run", job: job)))
                .help("Run \(job.name) now")
                .accessibilityLabel("Run \(job.name) now")
            }

            Menu { cronContextActions(job) } label: {
                DockIcon(.dotsThree)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("More actions for \(job.name)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(minHeight: 66)
        .background(isSelected ? Color.dockAccent.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
        .contextMenu { cronContextActions(job) }
    }

    @ViewBuilder
    private func cronContextActions(_ job: CronSummary) -> some View {
        if control.capabilityAvailable("cron.runNow") {
            Button("Run now", icon: .play) {
                cronRunRequest = job
                isShowingCronRunConfirmation = true
            }
        }
        if control.capabilityAvailable("cron.edit"), !job.editableFields.isEmpty {
            Button("Edit", icon: .pencilSimple) { cronEditJob = job }
        }
        if control.capabilityAvailable("rpc-scheduling") {
            Divider()
            Button("Remove", icon: .trash, role: .destructive) {
                cronRemovalRequest = job
                isShowingCronRemovalConfirmation = true
            }
        }
    }

    private func cronJobActions(_ job: CronSummary) -> some View {
        HStack(spacing: 14) {
            if control.capabilityAvailable("cron.runNow") {
                Button {
                    cronRunRequest = job
                    isShowingCronRunConfirmation = true
                } label: {
                    DockActionLabel(title: "RUN NOW", pendingTitle: "RUNNING…", isPending: control.isActionPending(control.cronActionID("run", job: job)))
                }
                .disabled(control.isActionPending(control.cronActionID("run", job: job)))
            } else {
                Text("RUN NOW UNAVAILABLE")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dockMetadataText)
                    .help("The installed Hermes CLI does not advertise the run-now automation capability.")
            }
            if control.capabilityAvailable("cron.edit"), !job.editableFields.isEmpty {
                Button { cronEditJob = job } label: {
                    DockActionLabel(title: "EDIT", pendingTitle: "SAVING…", isPending: control.isActionPending(control.cronActionID("edit", job: job)))
                }
                .disabled(control.isActionPending(control.cronActionID("edit", job: job)))
            }
            if control.capabilityAvailable("rpc-scheduling") {
                Button {
                    cronRemovalRequest = job
                    isShowingCronRemovalConfirmation = true
                } label: {
                    DockActionLabel(title: "REMOVE", pendingTitle: "REMOVING…", isPending: control.isActionPending(control.cronActionID("remove", job: job)), tint: Color.dockWarning)
                }
                .foregroundStyle(Color.dockWarning)
                .disabled(control.isActionPending(control.cronActionID("remove", job: job)))
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.dockAccent)
    }

    private func cronReportCard(_ job: CronSummary) -> some View {
        let latestRun = control.cronRuns.first { $0.jobID == job.id }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                DockIcon(job.enabled ? .clock : .clock)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(job.enabled ? Color.dockSuccess : Color.dockWarning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(2)
                    Text(job.enabled ? "ENABLED AND SCHEDULED" : "PAUSED")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.45)
                        .foregroundStyle(job.enabled ? Color.dockSuccess : Color.dockWarning)
                }
                Spacer(minLength: 0)
            }

            Divider()
                .overlay(Color.dockBorderLight)
                .padding(.vertical, 5)

            reportRow("SCHEDULE", value: CronScheduleFormatting.humanReadable(job.schedule))
            reportRow("AUTOMATION", value: job.schedule)
            reportRow("NEXT RUN", value: job.nextRun.map(HumanDateFormatting.dateAndTime) ?? "Not reported by Hermes")
            reportRow("JOB ID", value: job.id)
            if let delivery = job.delivery, !delivery.isEmpty {
                reportRow("DELIVERY", value: delivery.uppercased())
            }
            if let prompt = job.prompt, !prompt.isEmpty {
                reportRow("REQUEST", value: prompt)
            }
            if let latestRun {
                reportRow("LAST RUN", value: latestRun.claimedAt.map(HumanDateFormatting.dateAndTime) ?? latestRun.id)
                HStack(spacing: 6) {
                    Circle().fill(cronRunIsSuccessful(latestRun) ? Color.dockSuccess : Color.dockWarning).frame(width: 5, height: 5)
                    Text("LAST STATUS")
                    Text(latestRun.status.uppercased())
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(cronRunIsSuccessful(latestRun) ? Color.dockSuccess : Color.dockWarning)
                if let error = latestRun.error, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockWarning)
                        .lineLimit(3)
                }
            } else {
                reportRow("LAST RUN", value: "No execution recorded")
            }
            if let report = job.report, !report.isEmpty {
                Divider().overlay(Color.dockBorderLight)
                Button {
                    withAnimation(.dockEase(duration: 0.2)) {
                        if expandedCronReportIDs.contains(job.id) {
                            expandedCronReportIDs.remove(job.id)
                        } else {
                            expandedCronReportIDs.insert(job.id)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        DockIcon(expandedCronReportIDs.contains(job.id) ? .caretDown : .caretRight)
                            .font(.system(size: 10, weight: .bold))
                        Text(expandedCronReportIDs.contains(job.id) ? "HIDE REPORT" : "VIEW LATEST REPORT")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color.dockAccent)
                }
                .buttonStyle(.borderless)
                if expandedCronReportIDs.contains(job.id) {
                    MarkdownMessageView(markdown: report)
                        .padding(10)
                        .background(Color.dockSurface2.opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else if job.sessionID != nil {
                Divider().overlay(Color.dockBorderLight)
                VStack(alignment: .leading, spacing: 6) {
                    Text("REPORT AVAILABLE")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dockSuccess)
                    Text("Hermes saved the full output in this job's latest run session.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("OPEN LATEST REPORT") {
                        if let sessionID = job.sessionID {
                            cronReportRequest = CronReportRequest(job: job, sessionID: sessionID)
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
                }
            } else {
                Divider().overlay(Color.dockBorderLight)
                VStack(alignment: .leading, spacing: 6) {
                    Text("REPORT BODY UNAVAILABLE")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dockMetadataText)
                    Text("Hermes recorded this run, but the installed CLI only provides execution status and delivery metadata—not the response body. " + (job.delivery?.lowercased() == "origin" ? "This job delivers its result to its origin chat." : ""))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("RETURN TO CHAT") {
                        onClose()
                        model.requestComposerFocus()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
                }
            }
        }
    }

    private func reportRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label == label.uppercased() ? label.lowercased().capitalized : label)
                .frame(width: 88, alignment: .leading)
                .foregroundStyle(Color.dockMetadataText)
            Text(value)
                .foregroundStyle(Color.dockSecondaryText)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .font(.system(size: 11))
    }

    private func cronRunIsSuccessful(_ run: CronRunSummary) -> Bool {
        let status = run.status.lowercased()
        return ["ok", "success", "successful", "completed", "complete", "succeeded"].contains(status)
    }

    private func cronRunRow(_ run: CronRunSummary, canViewReport: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(cronRunIsSuccessful(run) ? Color.dockSuccess : Color.dockWarning)
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(run.status.uppercased())
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockPrimaryText)
                    Spacer(minLength: 4)
                    if canViewReport {
                        HStack(spacing: 4) {
                            Text("REPORT")
                            DockIcon(.caretRight)
                                .font(.system(size: 9, weight: .bold))
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.dockAccent)
                    }
                }
                if let claimedAt = run.claimedAt {
                    Text(HumanDateFormatting.dateAndTime(claimedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockMetadataText)
                }
                if let jobID = run.jobID {
                    if let job = control.cronJobs.first(where: { $0.id == jobID }) {
                        Text(job.name)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dockSecondaryText)
                            .lineLimit(1)
                    }
                    Text(jobID)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                }
                if let error = run.error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockWarning)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private func dockTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Color.dockPrimaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .fill(Color.dockSurface)
                    .stroke(Color.dockBorder, lineWidth: 0.5)
            )
    }

    private var canCreateAutomation: Bool {
        !automationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !automationSchedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !automationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var tabBadges: ControlTabBadgeState {
        ControlTabBadgeState.make(
            attention: control.attention,
            activeAgentCount: model.activeSubagents.filter { AgentActivityPresentation.isActiveStatus($0.status) }.count,
            activeToolCount: model.activeToolCalls.filter { !$0.isComplete }.count,
            changeCount: workflow.repository.conflictedFiles > 0 ? workflow.repository.conflictedFiles : workflow.repository.changedFiles,
            verificationCount: control.verification?.state == .failed ? 1 : (control.verification?.evidence?.scope?.lowercased() == "targeted" ? 1 : 0)
        )
    }

    private func badgeCount(for tab: ControlTab) -> Int {
        tabBadges.count(for: tab)
    }

    private func badgeLabel(for tab: ControlTab) -> String {
        let count = badgeCount(for: tab)
        return count > 99 ? "99+" : "\(count)"
    }

    private func badgeIsUrgent(for tab: ControlTab) -> Bool {
        tabBadges.isUrgent(for: tab)
    }

    private var projectsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            projectionRefreshNotice("projects")
            if let project = control.selectedProject {
                HStack {
                    Button {
                        control.closeProject()
                        selectedProjectSessionID = nil
                    } label: {
                        DockIconLabel("PROJECTS", icon: .caretLeft)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
                    Spacer()
                    if let path = selectedProjectFolderPath {
                        Button {
                            startNewChat(in: path)
                        } label: {
                            DockIconLabel("NEW CHAT", icon: .notePencil)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.dockAccent)
                        .disabled(model.isRestoringSession || model.isCreatingSession)
                        .help("Start a new chat in this project")
                    }
                }
                selectedProjectSummary(project)
                let projectSessionsProjectionKey = control.projectSessionsProjectionKey(for: project.id)
                if control.projectSessions.isEmpty {
                    if let refresh = control.refreshState(for: projectSessionsProjectionKey), refresh.isStale {
                        emptyState(icon: .warning, title: "Sessions stale", detail: "The last project session snapshot could not be refreshed. Retry to update it.")
                    } else if let refresh = control.refreshState(for: projectSessionsProjectionKey), refresh.error != nil {
                        emptyState(icon: .warning, title: "Sessions unavailable", detail: "Hermes could not load this project's sessions. Retry to try again.")
                    } else {
                        emptyState(icon: .chats, title: "No sessions in this project", detail: "No grouped sessions were found for this project.")
                    }
                } else {
                    HStack {
                        sectionLabel("SESSIONS")
                        Spacer()
                        Text("\(control.projectSessions.count)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.dockAccent)
                    }
                    ForEach(control.projectSessions) { session in
                        let lifecycle = SessionLifecyclePresentation.status(for: session, refresh: control.refreshState(for: projectSessionsProjectionKey))
                        Button {
                            selectedProjectSessionID = session.id
                            openProjectSession(session)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Circle().fill(sessionLifecycleColor(lifecycle)).frame(width: 6, height: 6)
                                    Text(session.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.dockPrimaryText)
                                        .lineLimit(2)
                                    Spacer()
                                    Text(lifecycle.label.uppercased())
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(sessionLifecycleColor(lifecycle))
                                    DockIcon(.caretRight)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color.dockAccent)
                                }
                                if let preview = session.displayPreview {
                                    Text(preview)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.dockMetadataText)
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .dockListRow()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(SessionLifecyclePresentation.accessibilityLabel(for: session, refresh: control.refreshState(for: projectSessionsProjectionKey)))
                    }
                }
                if selectedProjectSessionID != nil {
                    projectChangesContent
                }
            } else if control.projects.isEmpty {
                HStack {
                    sectionLabel("PROJECTS  ·  0")
                    Spacer()
                    projectDirectoryActions
                }
                emptyState(icon: .folder, title: "No projects", detail: "Projects will appear here when project contexts are available.")
            } else {
                HStack {
                    sectionLabel("PROJECTS  ·  \(control.projects.count)")
                    Spacer()
                    projectDirectoryActions
                }
                ForEach(control.projects.prefix(projectsDisplayLimit)) { project in
                    Button {
                        openProject(project)
                    } label: {
                        HStack(spacing: 10) {
                            DockIcon(project.isActive ? .folder : .folder)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(project.isActive ? Color.dockAccent : Color.dockSecondaryText)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(projectDisplayName(project))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.dockPrimaryText)
                                    .lineLimit(1)
                                Text(projectMetadata(project))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.dockMetadataText)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if project.isActive {
                                Text("ACTIVE")
                                    .font(.system(size: 12, weight: .semibold))
                                    .tracking(0.5)
                                    .foregroundStyle(Color.dockSuccess)
                            }
                            DockIcon(.caretRight)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.dockAccent)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
                if control.projects.count > projectsDisplayLimit {
                    Button {
                        projectsDisplayLimit += Self.projectsPageSize
                    } label: {
                        DockIconLabel("SHOW MORE (\(control.projects.count - projectsDisplayLimit) REMAINING)", icon: .caretDown)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.4)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.dockAccent)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
                }
            }
        }
        .onChange(of: control.projects.count) { _, _ in
            projectsDisplayLimit = max(projectsDisplayLimit, Self.projectsPageSize)
        }
    }

    private var addProjectDirectoryButton: some View {
        Button {
            chooseProjectDirectory()
        } label: {
            DockIconLabel("ADD DIRECTORY", icon: .folderPlus)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.dockAccent)
        .help("Start a new chat in a directory")
    }

    private var projectDirectoryActions: some View {
        HStack(spacing: 10) {
            addProjectDirectoryButton
            if control.capabilityAvailable(HermesFeatureIDs.ID.projectsCreate.rawValue) {
                Button("CREATE PROJECT") { chooseProjectForCreation() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dockAccent)
                    .help("Create a Hermes project from a folder")
            }
        }
    }

    private func startNewChat(in path: String) {
        store.attachProject(at: path)
        control.closeProject()
        selectedMode = .today
        Task { @MainActor in
            await model.startNewChat(in: path)
            if let sessionID = model.sessionID {
                control.selectProject(forPath: path)
                control.focus(sessionID: sessionID)
            }
            model.requestComposerFocus()
        }
    }

    private func chooseProjectDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project directory"
        panel.message = "Select the folder to use as the working directory for a new Hermes chat."
        panel.prompt = "Use Directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        // Hermes itself is a status-bar-level panel. Match that level and
        // explicitly order the picker above it without collapsing Hermes.
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()

        guard panel.runModal() == .OK, let url = panel.url else { return }
        startNewChat(in: url.standardizedFileURL.path)
    }

    private func chooseProjectForCreation() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project directory"
        panel.message = "Select the folder to add as a Hermes project."
        panel.prompt = "Create Project"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingProjectFolder = url.standardizedFileURL
        isShowingProjectCreationConfirmation = true
    }

    private func selectedProjectSummary(_ project: ProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                DockIcon(project.isActive ? .folder : .folder)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(project.isActive ? Color.dockAccent : Color.dockSecondaryText)
                Text(projectDisplayName(project))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
            }
            if project.name != "__no_project__" {
                Text(project.name)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 10) {
                if !project.isActive, control.capabilityAvailable(HermesFeatureIDs.ID.projectsSetActive.rawValue) {
                    Button("SET ACTIVE") { requestProjectMutation(.activate) }
                        .foregroundStyle(Color.dockAccent)
                }
                if control.capabilityAvailable(HermesFeatureIDs.ID.projectsArchive.rawValue) {
                    Button("ARCHIVE") { requestProjectMutation(.archive) }
                        .foregroundStyle(Color.dockWarning)
                }
                if control.capabilityAvailable(HermesFeatureIDs.ID.projectsDelete.rawValue) {
                    Button("DELETE") { requestProjectMutation(.delete) }
                        .foregroundStyle(Color.dockDestructive)
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    private func projectDisplayName(_ project: ProjectSummary) -> String {
        guard project.name != "__no_project__" else { return "Unassigned sessions" }
        let path = URL(fileURLWithPath: project.name)
        return path.lastPathComponent.isEmpty ? project.name : path.lastPathComponent
    }

    private func projectMetadata(_ project: ProjectSummary) -> String {
        let folderLabel = project.repoCount == 1 ? "1 folder" : "\(project.repoCount) folders"
        let sessionLabel = project.sessionCount == 1 ? "1 session" : "\(project.sessionCount) sessions"
        let counts = "\(folderLabel)  ·  \(sessionLabel)"
        guard project.name != "__no_project__" else { return counts }
        return "\(counts)  ·  \(project.name)"
    }

    private func projectMutationMessage(_ mutation: ProjectMutation, project: ProjectSummary) -> String {
        switch mutation {
        case .activate: "Hermes will make \(projectDisplayName(project)) the active project."
        case .archive: "Hermes will archive \(projectDisplayName(project)) and remove it from active project navigation."
        case .delete: "Hermes will permanently delete \(projectDisplayName(project)) from Hermes project storage."
        }
    }

    private func requestProjectMutation(_ mutation: ProjectMutation) {
        pendingProjectMutation = mutation
        isShowingProjectMutationConfirmation = true
    }

    private var selectedProjectFolderPath: String? {
        guard let project = control.selectedProject,
              project.name != "__no_project__",
              project.name.hasPrefix("/"),
              FileManager.default.fileExists(atPath: project.name) else { return nil }
        return project.name
    }

    private func openProject(_ project: ProjectSummary) {
        control.openProject(project)
        guard project.name != "__no_project__",
              project.name.hasPrefix("/"),
              FileManager.default.fileExists(atPath: project.name) else { return }
        store.attachProject(at: project.name)
    }

    private func openProjectSession(_ session: SessionSummary) {
        if let path = selectedProjectFolderPath {
            store.attachProject(at: path, toSessionID: session.id)
        }
        control.openProjectSession(session)
        onSessionOpened(session.id)
    }

    private var projectChangesContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("LOCAL CHANGES")
            if workflow.repository.isGitRepository {
                HStack(spacing: 8) {
                    todayMetric("STAGED", value: workflow.changes?.stagedCount ?? 0, color: .dockAccent)
                    todayMetric("UNSTAGED", value: workflow.changes?.unstagedCount ?? 0, color: .dockWarning)
                    todayMetric("UNTRACKED", value: workflow.changes?.untrackedCount ?? 0, color: .dockSecondaryText)
                    todayMetric("CONFLICTS", value: workflow.changes?.conflictedCount ?? 0, color: (workflow.changes?.conflictedCount ?? 0) > 0 ? .dockDestructive : .dockSuccess)
                }
                Text(workflow.repository.changedFiles == 0 ? "CLEAN WORKING TREE" : "\(workflow.repository.changedFiles) CHANGED FILE\(workflow.repository.changedFiles == 1 ? "" : "S") · \(workflow.repository.branch)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(workflow.repository.changedFiles == 0 ? Color.dockSuccess : Color.dockWarning)
                HStack(spacing: 10) {
                    Button("OPEN CHANGES") { select(.changes) }
                    Button(commandCenterPreferences.isWatchingRepository(workflow.repository.repositoryID) ? "STOP WATCHING" : "WATCH REPOSITORY") {
                        workflow.toggleWatching(preferences: commandCenterPreferences, control: control)
                    }
                    Button("REFRESH") { Task { await refreshRepository() } }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
            } else {
                Text("No local project folder is attached to the active session.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
                Button("SELECT PROJECT FOLDER") {
                    showingRepositoryPicker = true
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
            }
        }
        .padding(12)
        .dockGlassPane()
    }

    private var missionControlContent: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                pageHeader
                    .padding(.horizontal, 16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        missionControlToolbar
                        if let message = control.missionControlMessage {
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.dockWarning)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let queue = control.stuckCardQueue {
                            if queue.groups.isEmpty {
                                attentionRow(icon: .checkCircle, title: "Nothing stuck", detail: "Every card on the board is moving.", color: .dockSuccess)
                            }
                            ForEach(queue.groups) { missionControlGroup($0) }
                        } else if control.missionControlMessage == nil {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text("Loading stuck cards…")
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dockMetadataText)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)

            if let task = selectedKanbanTask {
                kanbanDetailPanel(task, presentation: KanbanBoardPresentation.makeSnapshot(
                    tasks: [],
                    bots: botMode.bots,
                    visibleBots: botMode.visibleBots
                ))
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Archive \(missionControlPickedCards.count) Cards?", isPresented: $isConfirmingMissionControlArchive) {
            Button("Archive", role: .destructive) { missionControlAct(archive: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Archived cards leave the board. The note, if any, is recorded on each card first.")
        }
    }

    private var missionControlPickedCards: [StuckCardQueue.Card] {
        (control.stuckCardQueue?.groups ?? []).flatMap(\.cards).filter { missionControlPicked.contains($0.id) }
    }

    private func missionControlAct(archive: Bool) {
        control.missionControlAct(missionControlPickedCards, archive: archive, note: missionControlNote)
        missionControlPicked = []
        missionControlNote = ""
        selectedKanbanTask = nil
    }

    private var missionControlToolbar: some View {
        let picked = missionControlPickedCards.count
        let busy = control.isActionPending(control.missionControlActActionID)
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Decision or instruction, recorded on each selected card", text: $missionControlNote, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.dockGlass)
            HStack(spacing: 8) {
                Button(action: { missionControlAct(archive: false) }) {
                    DockIconLabel(picked == 0 ? "Continue" : "Continue \(picked)", icon: .play, iconColor: .dockOnAccentText)
                }
                .buttonStyle(.dockPrimary)
                .disabled(picked == 0 || busy)
                Button(picked == 0 ? "Archive" : "Archive \(picked)") { isConfirmingMissionControlArchive = true }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.dockDestructive)
                    .disabled(picked == 0 || busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Text("Continue unblocks, releases triage to todo, or promotes todo.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dockMetadataText)
            }
            .font(.system(size: 12, weight: .semibold))
        }
    }

    private func missionControlGroup(_ group: StuckCardQueue.Group) -> some View {
        let ids = Set(group.cards.map(\.id))
        let allPicked = ids.isSubset(of: missionControlPicked)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                sectionLabel("\(group.heading.uppercased()) · \(group.cards.count)")
                Spacer(minLength: 0)
                Button(allPicked ? "Clear" : "Select all") {
                    if allPicked { missionControlPicked.subtract(ids) } else { missionControlPicked.formUnion(ids) }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .semibold))
            }
            if !group.hint.isEmpty {
                Text(group.hint.replacingOccurrences(of: "`", with: ""))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dockMetadataText)
            }
            ForEach(group.cards) { missionControlRow($0) }
        }
    }

    private func missionControlRow(_ card: StuckCardQueue.Card) -> some View {
        let isSelected = selectedKanbanTask?.id == card.id
        return HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { missionControlPicked.contains(card.id) },
                set: { if $0 { missionControlPicked.insert(card.id) } else { missionControlPicked.remove(card.id) } }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel("Select \(card.title)")
            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if !card.reason.isEmpty {
                    Text(card.reason)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(card.id).font(.system(size: 10, design: .monospaced))
                    kanbanMetadataPill(card.status.capitalized, tint: .dockWarning)
                    if let assignee = card.assignee { Text(assignee) }
                    Text(card.age)
                    if !card.openParents.isEmpty { Text("waits on \(card.openParents.joined(separator: ", "))") }
                }
                .font(.system(size: 10))
                .foregroundStyle(Color.dockMetadataText)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(isSelected ? Color.dockAccent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { selectKanbanTask(card.kanbanTask) }
    }

    private var kanbanContent: some View {
        HSplitView {
            // Header and toolbar stay fixed; the board takes the remaining
            // height so each lane scrolls its own cards.
            VStack(alignment: .leading, spacing: 0) {
                pageHeader

                VStack(alignment: .leading, spacing: 12) {
                        kanbanToolbar

                        if control.capabilityAvailable("kanban.create"), !kanbanCurrentSessionOnly, isShowingKanbanComposer {
                            createKanbanTaskForm
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        } else if kanbanCurrentSessionOnly {
                            DockIconLabel("Session cards must be created by a session-aware Kanban worker. Manual CLI cards are global.", icon: .link)
                                .font(.system(size: 10))
                                .foregroundStyle(Color.dockMetadataText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
            if !control.kanbanDiagnostics.isEmpty {
                DisclosureGroup(isExpanded: $isKanbanHealthExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(control.kanbanDiagnostics) { diagnostic in
                            Button {
                                if let taskID = diagnostic.taskID,
                                   let task = control.kanbanTasks.first(where: { $0.id == taskID }) {
                                    selectKanbanTask(task)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(diagnostic.severity.uppercased())
                                        .foregroundStyle(diagnostic.severity.lowercased() == "error" ? Color.dockDestructive : Color.dockWarning)
                                    Text(diagnostic.title)
                                        .foregroundStyle(Color.dockSecondaryText)
                                        .lineLimit(1)
                                    Spacer()
                                    if diagnostic.taskID != nil { DockIcon(.caretRight) }
                                }
                                .font(.system(size: 11))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                            .disabled(diagnostic.taskID == nil)
                        }
                    }
                    .padding(.top, 5)
                } label: {
                    HStack(spacing: 7) {
                        DockIcon(.stethoscope)
                            .foregroundStyle(Color.dockWarning)
                        Text("Kanban health")
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(control.kanbanDiagnostics.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.dockMetadataText)
                        Spacer()
                        Menu(kanbanDiagnosticSeverity) {
                            ForEach(["ALL", "ERROR", "WARNING", "INFO"], id: \.self) { severity in
                                Button(severity) {
                                    kanbanDiagnosticSeverity = severity
                                    control.refreshKanbanDiagnostics(severity: severity == "ALL" ? nil : severity.lowercased())
                                }
                            }
                        }
                        .font(.system(size: 10))
                        Button {
                            control.refreshKanbanDiagnostics(severity: kanbanDiagnosticSeverity == "ALL" ? nil : kanbanDiagnosticSeverity.lowercased())
                        } label: {
                            DockIcon(.arrowsClockwise)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.dockAccent)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.dockWarning.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
            }

            if control.kanbanTasks.isEmpty, control.refreshState(for: "kanban.board")?.lastSuccess == nil,
               control.isKanbanRefreshPending || control.refreshState(for: "kanban.board")?.isRefreshing == true {
                DockLoadingState(title: "Loading board…", detail: "Reading Kanban tasks from Hermes.")
            } else {
                kanbanBoard
                    .frame(maxHeight: .infinity)
            }
            if let state = control.refreshState(for: "kanban.board"), let error = state.error {
                HStack(alignment: .top, spacing: 8) {
                    DockIcon(.warning)
                        .font(.system(size: 12, weight: .medium))
                    Text(state.isStale ? "Showing the last successful board. \(error)" : error)
                        .font(.system(.body))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color.dockWarning)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(Color.dockWarning.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).stroke(Color.dockWarning.opacity(0.34), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
            }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: control.requestedKanbanTask, initial: true) { _, task in
                guard let task else { return }
                control.requestedKanbanTask = nil
                kanbanStatusFilter = "All"
                kanbanAssigneeFilter = "All"
                kanbanMineOnly = false
                kanbanCurrentSessionOnly = false
                applyKanbanFilters()
                selectKanbanTask(task)
            }
            .onChange(of: control.kanbanTasks.map(\.id)) { _, ids in
                // Board navigation clears the old list while fetching the new
                // board. Keep a notch-selected card through that transition.
                if ids.isEmpty, control.isKanbanRefreshPending { return }
                if let selectedKanbanTask, !ids.contains(selectedKanbanTask.id) {
                    self.selectedKanbanTask = nil
                }
            }

            if let task = selectedKanbanTask {
                // Bot lookup only; card details are not needed by the inspector.
                kanbanDetailPanel(task, presentation: KanbanBoardPresentation.makeSnapshot(
                    tasks: [],
                    bots: botMode.bots,
                    visibleBots: botMode.visibleBots
                ))
                    .animation(.dockEase(duration: 0.2), value: selectedKanbanTask?.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var kanbanBoard: some View {
        KanbanBoardView(
            tasks: control.kanbanTasks,
            bots: botMode.bots,
            visibleBots: botMode.visibleBots,
            avatarImages: botMode.avatarImages,
            selectedTaskID: selectedKanbanTask?.id,
            actions: KanbanCardActionAvailability(
                details: true,
                complete: control.capabilityAvailable("kanban.complete"),
                block: control.capabilityAvailable("kanban.block"),
                unblock: control.capabilityAvailable("kanban.unblock"),
                archive: control.capabilityAvailable("kanban.archive"),
                move: control.canMoveKanbanTasks,
                assign: control.capabilityAvailable("kanban.reassign")
            ),
            pendingActionIDs: control.pendingActionIDs.filter { id in
                Self.kanbanCardActionPrefixes.contains { id.hasPrefix($0) }
            },
            loadingDetailTaskID: control.loadingKanbanDetailTaskID,
            onSelect: { selectKanbanTask($0) },
            onAction: { requestKanbanAction($0, action: $1) },
            onDrop: { dropKanbanTask($0, on: $1) },
            onAssign: { control.assignKanbanTask($0, to: $1) }
        )
        .equatable()
    }

    private var kanbanToolbar: some View {
        HStack(spacing: 8) {
            Menu {
                if control.kanbanBoards.isEmpty {
                    Text("Board inventory unavailable")
                } else {
                    ForEach(control.kanbanBoards.filter { !$0.archived }) { board in
                        Button {
                            control.selectKanbanBoard(board)
                            selectedKanbanTask = nil
                        } label: {
                            HStack {
                                Text(board.name)
                                if board.slug == control.selectedKanbanBoardSlug {
                                    Spacer()
                                    Ph.check.image()
                                }
                            }
                        }
                    }
                }
            } label: {
                kanbanToolbarChip(
                    control.kanbanBoards.first(where: { $0.slug == control.selectedKanbanBoardSlug })?.name
                        ?? control.selectedKanbanBoardSlug
                        ?? "Current board",
                    icon: .kanban
                )
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(control.kanbanBoards.count < 2 || control.isKanbanRefreshPending)
            .help("Select Kanban board")

            kanbanFilterControls

            if kanbanFiltersAreActive {
                Button {
                    kanbanStatusFilter = "All"
                    kanbanAssigneeFilter = "All"
                    kanbanMineOnly = false
                    kanbanSort = "updated"
                    applyKanbanFilters()
                } label: {
                    HStack(spacing: 4) {
                        DockIcon(.xCircle, weight: .fill)
                        Text("Clear")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
                }
                .buttonStyle(.plain)
                .help("Clear Kanban filters")
            }

            Spacer(minLength: 8)

            if control.capabilityAvailable("kanban.create"), !kanbanCurrentSessionOnly {
                Button {
                    withAnimation(.dockEase(duration: 0.2)) {
                        isShowingKanbanComposer.toggle()
                    }
                } label: {
                    DockIconLabel(isShowingKanbanComposer ? "Close" : "Add task", icon: isShowingKanbanComposer ? .x : .plus)
                }
                .buttonStyle(.dockPrimary)
                .font(.system(size: 11, weight: .semibold))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.dockSurface.opacity(0.28))
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private var kanbanFiltersAreActive: Bool {
        kanbanStatusFilter != "All" || kanbanAssigneeFilter != "All" || kanbanMineOnly || kanbanSort != "updated"
    }

    private func kanbanToolbarChip(_ title: String, icon: Ph) -> some View {
        HStack(spacing: 5) {
            DockIcon(icon)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            DockIcon(.caretDown)
                .font(.system(size: 8, weight: .bold))
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.dockSecondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.dockSurface2.opacity(0.76))
        .clipShape(Capsule())
    }

    private var kanbanFilterControls: some View {
        HStack(spacing: 6) {
            Button {
                isShowingKanbanStatusFilter.toggle()
            } label: {
                kanbanFilterChip(kanbanStatusFilter == "All" ? "Status" : kanbanStatusFilter, icon: .funnelSimple)
            }
            .popover(isPresented: $isShowingKanbanStatusFilter, arrowEdge: .bottom) {
                kanbanStatusPopover
            }
            Button {
                isShowingKanbanAssigneeFilter.toggle()
            } label: {
                kanbanFilterChip(kanbanAssigneeFilter == "All" ? "Assignee" : kanbanAssigneeFilter, icon: .users)
            }
            .popover(isPresented: $isShowingKanbanAssigneeFilter, arrowEdge: .bottom) {
                kanbanAssigneePopover
            }
            Button {
                kanbanMineOnly.toggle()
                applyKanbanFilters()
            } label: {
                kanbanFilterChip("Mine", icon: .user, isSelected: kanbanMineOnly)
            }
            Menu {
                ForEach(["updated", "created-desc", "priority-desc", "title"], id: \.self) { value in
                    Button(kanbanSortLabel(value)) { kanbanSort = value; applyKanbanFilters() }
                }
            } label: {
                kanbanFilterChip(kanbanSort == "updated" ? "Sort" : kanbanSortLabel(kanbanSort), icon: .arrowsDownUp)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .disabled(control.isKanbanRefreshPending)
    }

    private var kanbanAssigneeOptions: [String] {
        Set(control.kanbanAssignees + control.kanbanTasks.compactMap { task in
            guard let assignee = task.assignee?.trimmingCharacters(in: .whitespacesAndNewlines), !assignee.isEmpty else { return nil }
            return assignee
        }).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func kanbanSortLabel(_ value: String) -> String {
        switch value {
        case "created-desc": "Created"
        case "priority-desc": "Priority"
        case "title": "Title"
        default: "Updated"
        }
    }

    private func kanbanFilterChip(_ title: String, icon: Ph, isSelected: Bool = false) -> some View {
        HStack(spacing: 6) {
            DockIcon(icon)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .lineLimit(1)
            DockIcon(.caretDown)
                .font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(isSelected ? Color.dockAccent : Color.dockSecondaryText)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(isSelected ? Color.dockAccent.opacity(0.14) : Color.dockSurface.opacity(0.72))
        .clipShape(Capsule())
        .overlay {
            Capsule().stroke(isSelected ? Color.dockAccent.opacity(0.28) : Color.dockBorderLight, lineWidth: 0.5)
        }
    }

    private var kanbanStatusPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                DockIcon(.circlesFour)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
                Text("STATUS")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(Color.dockMetadataText)
                Spacer()
                Text("\(KanbanLane.allCases.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            ScrollView {
                LazyVStack(spacing: 3) {
                    kanbanStatusRow(nil, title: "All statuses", isSelected: kanbanStatusFilter == "All")
                    ForEach(KanbanLane.allCases) { lane in
                        kanbanStatusRow(lane, title: lane.rawValue, isSelected: kanbanStatusFilter == lane.rawValue)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 270)
        .background(Color.dockCanvas)
    }

    private func kanbanStatusRow(_ lane: KanbanLane?, title: String, isSelected: Bool) -> some View {
        Button {
            kanbanStatusFilter = lane?.rawValue ?? "All"
            isShowingKanbanStatusFilter = false
            applyKanbanFilters()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill((lane?.color ?? Color.dockAccent).opacity(0.18))
                    if let lane {
                        DockIcon(lane.icon)
                            .foregroundStyle(lane.color)
                    } else {
                        DockIcon(.circlesFour)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.dockAccent)
                    }
                }
                .frame(width: 30, height: 30)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    DockIcon(.check)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.dockAccent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? Color.dockAccent.opacity(0.11) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var kanbanAssigneePopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                DockIcon(.users)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
                Text("ASSIGNEE")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(Color.dockMetadataText)
                Spacer()
                Text("\(kanbanAssigneeOptions.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            ScrollView {
                LazyVStack(spacing: 3) {
                    kanbanAssigneeRow("All", isSelected: kanbanAssigneeFilter == "All")
                    ForEach(kanbanAssigneeOptions, id: \.self) { assignee in
                        kanbanAssigneeRow(assignee, isSelected: kanbanAssigneeFilter == assignee)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 270)
        .background(Color.dockCanvas)
    }

    private func kanbanAssigneeRow(_ assignee: String, isSelected: Bool) -> some View {
        Button {
            kanbanAssigneeFilter = assignee
            isShowingKanbanAssigneeFilter = false
            applyKanbanFilters()
        } label: {
            HStack(spacing: 10) {
                if assignee == "All" {
                    ZStack {
                        RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous)
                            .fill(Color.dockAccent.opacity(0.18))
                        DockIcon(.users)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.dockAccent)
                    }
                    .frame(width: 30, height: 30)
                } else {
                    if let bot = botMode.visibleBots.first(where: {
                        $0.id.caseInsensitiveCompare(assignee) == .orderedSame
                    }) {
                        BotAvatarView(bot: bot, imageData: botMode.avatarImages[bot.id], size: 30)
                    } else {
                        KanbanAssigneeInitialAvatar(assignee: assignee)
                    }
                }
                Text(assignee == "All" ? "All assignees" : assignee)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    DockIcon(.check)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.dockAccent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? Color.dockAccent.opacity(0.11) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func applyKanbanFilters(
        trigger: ControlCenterModel.KanbanRefreshTrigger = .user
    ) {
        control.refreshVisibleKanban(filter: KanbanListFilter(
            status: kanbanStatusFilter == "All" ? nil : kanbanStatusFilter.lowercased(),
            assignee: kanbanAssigneeFilter == "All" ? nil : kanbanAssigneeFilter,
            mine: kanbanMineOnly,
            sessionID: kanbanCurrentSessionOnly ? model.kanbanSessionID : nil,
            sort: kanbanSort
        ), trigger: trigger)
    }

    private var createKanbanTaskForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                DockIcon(.plus)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.dockAccent)
                Text("ADD TASK")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(Color.dockSecondaryText)
            }
            HStack(spacing: 8) {
                dockTextField("What needs to be done?", text: $kanbanTitle)
                Button {
                    isShowingKanbanConfirmation = true
                } label: {
                    Group {
                        if control.isCreatingKanbanTask {
                            ProgressView().controlSize(.small).tint(Color.dockOnAccentText)
                        } else {
                            DockIcon(.arrowUpRight)
                                .font(.system(size: 13, weight: .bold))
                        }
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .opacity(canCreateKanbanTask && !control.isCreatingKanbanTask ? 1 : 0.42)
                .disabled(!canCreateKanbanTask || control.isCreatingKanbanTask)
                .help("Create task")
            }
            TextField("Add context for Hermes (optional)", text: $kanbanBody, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.dockPrimaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.dockSurface)
                .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
        }
        .padding(12)
        .background(Color.dockSurface2)
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.paneRadius + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DockLayout.paneRadius + 2, style: .continuous).stroke(Color.dockBorder, lineWidth: 0.5))
    }

    private func selectKanbanTask(_ task: KanbanTaskSummary) {
        selectedKanbanTask = task
        kanbanInspectorTab = .overview
        control.loadKanbanTask(task)
    }

    private static let kanbanCardActionPrefixes: [String] =
        KanbanTaskAction.allCases.map { "kanban.\($0.rawValue):" } + ["kanban.move:", "kanban.reassign:"]

    /// Done and Blocked release a worker claim, so a drop there goes through
    /// the same confirmation as the card menu; other lanes move immediately.
    private func dropKanbanTask(_ task: KanbanTaskSummary, on lane: KanbanLane) {
        // Lanes a card cannot enter already refuse the drag with the
        // forbidden cursor, so `.none` and `.refused` never reach here.
        switch KanbanBoardPresentation.dropOutcome(taskStatus: task.status, target: lane) {
        case .move(let lane):
            control.moveKanbanTask(task, to: lane)
        case .confirm(let action):
            requestKanbanAction(task, action: action)
        case .none, .refused:
            break
        }
    }

    private func requestKanbanAction(_ task: KanbanTaskSummary, action: KanbanTaskAction) {
        kanbanChangeRequest = KanbanChangeRequest(task: task, action: action)
        isShowingKanbanChangeConfirmation = true
    }

    private func kanbanMetadataPill(_ value: String, tint: Color) -> some View {
        Text(value)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(tint.opacity(0.10))
            .clipShape(Capsule())
    }

    private func kanbanAssigneePill(
        _ assignee: String,
        presentation: KanbanBoardPresentation.Snapshot
    ) -> some View {
        HStack(spacing: 5) {
            if let bot = presentation.visibleBot(for: assignee) {
                BotAvatarView(bot: bot, imageData: botMode.avatarImages[bot.id], size: 18)
            } else {
                KanbanAssigneeInitialAvatar(assignee: assignee, size: 18)
            }
            Text(assignee)
                .lineLimit(1)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.dockSecondaryText)
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(Color.dockSecondaryText.opacity(0.10))
        .clipShape(Capsule())
    }

    private func kanbanModelMetadataRow(_ metadata: KanbanModelMetadataPresentation) -> some View {
        HStack(spacing: 5) {
            DockIcon(metadata.isOverride ? .arrowsClockwise : .cpu)
                .font(.system(size: 9, weight: .semibold))
            Text(metadata.isOverride ? "OVERRIDE · \(metadata.label)" : metadata.label)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(metadata.isOverride ? Color.dockWarning : Color.dockMetadataText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isRedundantKanbanStatus(_ event: String, for lane: KanbanLane) -> Bool {
        let normalizedEvent = event
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        let normalizedLane = lane.rawValue.lowercased()
        return normalizedEvent == normalizedLane
            || (lane == .done && ["complete", "completed", "archived"].contains(normalizedEvent))
            || (lane == .blocked && ["failed", "error"].contains(normalizedEvent))
    }

    private func kanbanDetailPanel(
        _ task: KanbanTaskSummary,
        presentation: KanbanBoardPresentation.Snapshot
    ) -> some View {
        let lane = KanbanBoardPresentation.lane(for: task.status)
        let laneColor: Color = switch lane {
        case .triage: .dockWarning
        case .todo: .dockSecondaryText
        case .ready: .dockAccent
        case .running: .dockAccent
        case .review: .dockAccent
        case .scheduled: .dockAccent
        case .blocked: .dockDestructive
        case .done: .dockSuccess
        }

        let detail = control.kanbanDetail ?? ControlCenterModel.fallbackKanbanTaskDetail(task, boardSlug: task.boardSlug)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(detail.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(3)
                    HStack(spacing: 7) {
                        Text(detail.status.capitalized)
                            .foregroundStyle(laneColor)
                        Text("·")
                        Text(detail.id)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    Menu {
                        kanbanDetailActions(task, lane: lane)
                    } label: {
                        kanbanDetailHeaderIcon(.dotsThree)
                    }
                    // `.borderlessButton` drops custom labels on macOS, leaving only the indicator.
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Task actions")
                    .accessibilityLabel("Task actions")
                    Button {
                        selectedKanbanTask = nil
                    } label: {
                        kanbanDetailHeaderIcon(.x)
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                    .accessibilityLabel("Close task details")
                }
            }
            .foregroundStyle(Color.dockSecondaryText)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            HStack(spacing: 0) {
                ForEach(KanbanInspectorTab.allCases) { tab in
                    Button(tab.rawValue) { kanbanInspectorTab = tab }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(kanbanInspectorTab == tab ? Color.dockPrimaryText : Color.dockMetadataText)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .overlay(alignment: .bottom) {
                            if kanbanInspectorTab == tab { Color.dockAccent.frame(height: 2) }
                        }
                        .buttonStyle(.plain)
                }
            }
            .overlay(alignment: .top) { Color.dockBorderLight.frame(height: 0.5) }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = control.kanbanDetailError, !error.isEmpty {
                        HStack(spacing: 8) {
                            DockIcon(.warning)
                            Text(error).lineLimit(3)
                            Spacer()
                            Button("Retry") { control.loadKanbanTask(task) }
                                .buttonStyle(.borderless)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockWarning)
                    }
                    if control.loadingKanbanDetailTaskID == task.id {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Refreshing task details…")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockMetadataText)
                    }

                    if kanbanInspectorTab == .overview {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 7) {
                                kanbanMetadataPill(detail.status.capitalized, tint: laneColor)
                                if let priority = detail.priority { kanbanMetadataPill("P\(priority)", tint: .dockWarning) }
                                if let assignee = detail.assignee { kanbanAssigneePill(assignee, presentation: presentation) }
                            }
                            kanbanModelMetadataRow(KanbanModelMetadataPresentation.make(
                                taskModel: detail.modelOverride ?? task.modelOverride,
                                taskProvider: detail.providerOverride ?? task.providerOverride,
                                bot: presentation.bot(for: detail.assignee ?? task.assignee)
                            ))
                            if let why = detail.blockExplanation { kanbanBlockExplanation(why) }
                            if let body = detail.body, !body.isEmpty {
                                MarkdownMessageView(markdown: body)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text("No task description returned.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.dockMetadataText)
                            }
                            kanbanAttachmentSection
                        }
                    } else {
                        kanbanActivitySection(detail)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 360, idealWidth: 400, maxWidth: 460, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dockCanvas)
        .overlay(alignment: .leading) { Color.dockBorderLight.frame(width: 0.5) }
    }

    private var kanbanAttachmentSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("ATTACHMENTS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Color.dockMetadataText)
            if control.kanbanAttachments.isEmpty {
                Text("No attachments")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockMetadataText)
            } else {
                ForEach(control.kanbanAttachments) { attachment in
                    HStack(spacing: 7) {
                        DockIcon(.paperclip)
                        Text(attachment.name).lineLimit(1)
                        Spacer(minLength: 4)
                        if let kind = attachment.kind { Text(kind) }
                        if let size = attachment.sizeBytes {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockSecondaryText)
                    .padding(.vertical, 5)
                    .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
                }
            }
        }
    }

    private func kanbanActivitySection(_ detail: KanbanTaskDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let step = selectedKanbanTask?.currentStepKey, !step.isEmpty {
                kanbanInspectorSection("CURRENT STEP") {
                    Text(step)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.dockAccent)
                }
            }
            if let event = selectedKanbanTask?.latestEventKind, !event.isEmpty {
                kanbanInspectorSection("LATEST EVENT") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.system(size: 13, weight: .medium))
                        if let note = selectedKanbanTask?.latestEventNote, !note.isEmpty {
                            Text(note).font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText)
                        }
                    }
                }
            }
            kanbanInspectorSection("RUN HISTORY · \(detail.runs.count)") {
                if detail.runs.isEmpty {
                    Text("No run history returned by Hermes.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockMetadataText)
                } else {
                    ForEach(detail.runs) { run in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(run.status.capitalized)
                                if let outcome = run.outcome { Text("· \(outcome)") }
                                Spacer()
                                if let elapsed = run.elapsed { Text(elapsed) }
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.dockAccent)
                            if let profile = run.profile { Text(profile).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.dockMetadataText) }
                            if let summary = run.summary { Text(summary).font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText) }
                        }
                        .padding(.vertical, 7)
                        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
                    }
                }
            }
        }
    }

    private func kanbanBlockExplanation(_ why: KanbanTaskDetail.BlockExplanation) -> some View {
        kanbanInspectorSection("WHY BLOCKED" + (why.kind.map { " · \($0.replacingOccurrences(of: "_", with: " "))" } ?? "")) {
            VStack(alignment: .leading, spacing: 6) {
                Text(why.reason ?? "No reason was recorded.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.dockWarning)
                if let error = why.lastError {
                    Text("Last run: \(error)").font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText)
                }
                if let diagnostic = why.diagnostic {
                    Text(diagnostic)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.dockSecondaryText)
                }
            }
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dockWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func kanbanInspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Color.dockMetadataText)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canCreateKanbanTask: Bool {
        !kanbanTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func kanbanDetailHeaderIcon(_ name: Ph) -> some View {
        DockIcon(name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.dockSecondaryText)
            .frame(width: 28, height: 28)
            .background(Color.dockSurface2.opacity(0.6), in: RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous))
            .contentShape(Rectangle())
    }

    /// Same lane rules as the card menu, plus the edit-style mutations.
    @ViewBuilder
    private func kanbanDetailActions(_ task: KanbanTaskSummary, lane: KanbanLane) -> some View {
        let statusActions: [KanbanTaskAction] = switch lane {
        case .done: [.archive]
        case .blocked: [.unblock]
        default: [.complete, .block]
        }
        let available = statusActions.filter { control.capabilityAvailable("kanban.\($0.rawValue)") }
        let mutations = KanbanMutationKind.allCases.filter { control.capabilityAvailable($0.capabilityID) }
        ForEach(available, id: \.self) { action in
            Button(kanbanActionTitle(for: action), icon: kanbanActionIcon(for: action)) {
                requestKanbanAction(task, action: action)
            }
            .disabled(control.isActionPending(control.kanbanActionID(action, task: task)))
        }
        if !available.isEmpty, !mutations.isEmpty { Divider() }
        ForEach(mutations) { kind in
            Button(kind.title) {
                kanbanMutationRequest = KanbanMutationRequest(task: task, kind: kind, value: "", reclaimFirst: false)
            }
        }
        if available.isEmpty, mutations.isEmpty {
            Text("No actions available")
        }
    }

    private func kanbanActionTitle(for action: KanbanTaskAction) -> String {
        switch action {
        case .complete: "Mark Done"
        case .block: "Block"
        case .unblock: "Unblock"
        case .archive: "Archive"
        }
    }

    private func kanbanActionIcon(for action: KanbanTaskAction) -> Ph {
        switch action {
        case .complete: .check
        case .block: .pause
        case .unblock: .arrowUUpLeft
        case .archive: .archive
        }
    }

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("SEARCH SOURCES")
            HStack(spacing: 8) {
                DockIcon(.magnifyingGlass)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.dockAccent)
                    .frame(width: 16)
                TextField("Sessions, projects, Inbox, reminders", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.dockPrimaryText)
                if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        DockIcon(.xCircle, weight: .fill)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .fill(Color.dockControlSurface)
                    .stroke(Color.dockBorder, lineWidth: 0.5)
            )
            if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Search across the sources already connected to Hermes.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockPrimaryText)
                    Text("Sessions  ·  projects  ·  Inbox  ·  Apple Reminders")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockMetadataText)
                }
                .padding(.top, 2)
            } else if control.isSearching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("SEARCHING HERMES SOURCES…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockSecondaryText)
                }
            } else if control.searchResults.isEmpty {
                emptyState(icon: .question, title: "No matches", detail: "Try a session title, project name, reminder, or Inbox detail.")
            } else {
                sectionLabel("RESULTS  ·  \(control.searchResults.count)")
                ForEach(control.searchResults) { result in
                    let canOpen = result.reference.source != .appleReminder && result.reference.source != .hermesCronJob
                    if canOpen {
                        Button { control.openSearchResult(result) } label: {
                            searchResultRow(result)
                        }
                        .buttonStyle(.borderless)
                    } else {
                        searchResultRow(result)
                    }
                }
            }
        }
    }

    private func searchResultRow(_ result: ControlSearchResult) -> some View {
        HStack(alignment: .top, spacing: 9) {
            DockIcon(result.reference.source == .appleReminder ? .listChecks : .circleDashed)
                .font(.system(size: 12))
                .foregroundStyle(Color.dockAccent)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(result.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text(result.sourceLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockSecondaryText)
                }
                Text(result.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(2)
            }
            if result.reference.source != .appleReminder && result.reference.source != .hermesCronJob {
                DockIcon(.caretRight)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockMetadataText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockListRow()
        .contentShape(Rectangle())
    }

    private var inboxContent: some View {
        let visibleItems = control.attention.filter { $0.state == .open && inboxFilter.includes($0) }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionLabel("ATTENTION  ·  \(visibleItems.count)")
                Spacer()
                Picker("Inbox filter", selection: $inboxFilter) {
                    ForEach(InboxFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
                }
                .labelsHidden()
                .font(.system(size: 11))
            }
            if visibleItems.isEmpty {
                emptyState(icon: .checkCircle, title: "Nothing needs your attention", detail: "Approvals, failures, clarifications, and due reminders will appear here.")
            } else {
                ForEach(visibleItems) { item in
                    attentionItemRow(item, isSelected: selectedAttentionID == item.id)
                }
            }
        }
    }

    private func attentionItemRow(_ item: AttentionItem, isSelected: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                DockIcon(item.kind == .approval ? .warning : .circleDashed)
                    .font(.system(size: 12)).foregroundStyle(item.kind == .approval ? Color.dockWarning : Color.dockAccent)
                    .frame(width: 15)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dockPrimaryText)
                    Text(item.detail).font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText).lineLimit(4)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                ForEach(item.actions.filter { $0 != .dismiss }, id: \.self) { action in
                    let isPending = control.isActionPending(control.attentionActionID(action, item: item))
                    Button {
                        if action == .complete, let reminder = control.reminder(withID: item.reference.sourceID) {
                            reminderForConfirmation = reminder
                            isShowingReminderConfirmation = true
                        } else if action == .respond {
                            clarificationItem = item
                        } else {
                            control.respond(to: item, action: action)
                        }
                    } label: {
                        DockActionLabel(
                            title: action.rawValue.uppercased(),
                            pendingTitle: action == .stop ? "STOPPING…" : "WORKING…",
                            isPending: isPending,
                            tint: action == .deny || action == .stop ? Color.dockWarning : Color.dockAccent
                        )
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(action == .deny || action == .stop ? Color.dockWarning : Color.dockAccent)
                    .disabled(isPending)
                }
                Button("DISMISS") { control.dismiss(item.id) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockMetadataText)
                Button("SNOOZE") { control.snooze(item.id) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockMetadataText)
            }
        }
        .padding(12)
        .dockGlassPane()
        .overlay(RoundedRectangle(cornerRadius: DockLayout.paneRadius + 4, style: .continuous).stroke(isSelected ? Color.dockAccent : .clear, lineWidth: 0.5))
    }

    /// Global operations overview. It deliberately excludes the active chat's
    /// focus, readiness, handoff, and runtime transcript; those live in the
    /// Session overview.
    /// Global cross-session Control Center overview dashboard.
    /// Aggregates state across all sessions including active agents, processes,
    /// tasks, reminders, automations, and global operational controls.
    private var nowContent: some View {
        // Collect cross-session metrics and states
        let openAttention = control.attention.filter { $0.state == .open }
        let activeSessions = control.activeSessions
        let totalRunningCount = WorkspaceOverviewMetrics.runningCount(
            activeSessions: activeSessions,
            agents: control.activeAgents,
            processes: control.processes,
            backgroundTasks: model.backgroundTasks
        )
        let setupCapabilities = unavailableSetupCapabilities

        return VStack(alignment: .leading, spacing: 20) {
            // Banner if delegation is globally paused
            if control.delegationPaused {
                HStack(spacing: 8) {
                    DockIcon(.pauseCircle, weight: .fill)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.dockWarning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DELEGATION PAUSED")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.dockWarning)
                        Text("Subagent auto-dispatch is currently paused globally.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    Spacer(minLength: 0)
                    Button("RESUME") {
                        Task { _ = await control.pauseDelegation(false) }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
                }
                .padding(10)
                .dockGlassPane()
                .overlay(RoundedRectangle(cornerRadius: DockLayout.paneRadius + 4, style: .continuous).stroke(Color.dockWarning.opacity(0.55), lineWidth: 0.5))
            }

            todayOverviewHeader(
                attentionCount: openAttention.count,
                runningCount: totalRunningCount,
                scheduledCount: control.cronJobs.count
            )

            // Triage section for items needing immediate user action
            sectionLabel(openAttention.isEmpty ? "CLEAR TO PROCEED" : "NEEDS YOUR ATTENTION")
            if let attention = openAttention.first {
                attentionItemRow(attention)
                if openAttention.count > 1 {
                    Button("VIEW ALL IN INBOX  ·  \(openAttention.count) ITEMS") { select(.inbox) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockAccent)
                }
            } else {
                attentionRow(icon: .checkCircle, title: "All clear", detail: "No approvals, clarifications, or failures need a response.", color: .dockSuccess)
            }

            // The feed is flattened across every persisted session, then sorted
            // globally so one session can contribute multiple recent steps.
            let latestActivities = control.latestActivities
            if latestActivities.isEmpty,
               let state = control.refreshState(for: "latest.activity"),
               state.isStale {
                Text("Latest activity is unavailable. \(state.error ?? "Retry when Hermes reconnects.")")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .dockGlassPane()
            }
            if !latestActivities.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        DockIcon(.pulse)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.dockAccent)
                        Text("Recent activity  ·  \(latestActivities.count)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.dockAccent)
                        Spacer(minLength: 0)
                        Button("VIEW ALL") { select(.activity) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.dockAccent)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    if let state = control.refreshState(for: "latest.activity"), state.isStale {
                        Text("Showing the last successful activity snapshot. \(state.error ?? "Retry when Hermes reconnects.")")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dockWarning)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 6)
                    }

                    ForEach(latestActivities.prefix(4)) { activity in
                        Button {
                            control.openLatestActivitySession(activity)
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(activity.sessionID == model.sessionID ? Color.dockAccent : sessionStateColor(activity.state))
                                    .frame(width: 5, height: 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    if let project = control.project(forSessionID: activity.sessionID),
                                       !project.name.isEmpty,
                                       project.name != "__no_project__" {
                                        Text(projectDisplayName(project))
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Color.dockPrimaryText)
                                            .lineLimit(1)
                                        MarkdownMessageView(
                                            markdown: LatestActivityPresentation.boundedMarkdown(activity.sessionTitle)
                                        )
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.dockMetadataText)
                                        .frame(maxHeight: 20, alignment: .top)
                                        .clipped()
                                        .accessibilityLabel(activity.sessionTitle)
                                    } else {
                                        MarkdownMessageView(
                                            markdown: LatestActivityPresentation.boundedMarkdown(activity.sessionTitle)
                                        )
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.dockPrimaryText)
                                        .frame(maxHeight: 20, alignment: .top)
                                        .clipped()
                                        .accessibilityLabel(activity.sessionTitle)
                                    }
                                    MarkdownMessageView(
                                        markdown: LatestActivityPresentation.boundedMarkdown(activity.activityName)
                                    )
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.dockMetadataText)
                                    .frame(maxHeight: 42, alignment: .top)
                                    .clipped()
                                    .accessibilityLabel(activity.activityName)
                                }
                                Spacer(minLength: 0)
                                DockIcon(.caretRight)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.dockAccent)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .dockListRow()
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .dockGlassPane()
            }

            // Cross-session active agents, processes, and running background tasks
            let hasRunningWork = !control.activeAgents.isEmpty
                || !control.processes.isEmpty
                || model.backgroundTasks.contains(where: { $0.status == .running })
            if hasRunningWork {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        DockIcon(.lightning)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.dockAccent)
                        Text("Running Now")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.dockAccent)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 0) {
                        // Display active subagents across all sessions
                        ForEach(control.activeAgents) { agent in
                            HStack(spacing: 8) {
                                DockIcon(.users)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.dockAccent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(agent.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.dockPrimaryText)
                                        .lineLimit(1)
                                    Text(agent.sessionID.map { "\($0)  ·  \(agent.state.uppercased())" } ?? agent.state.uppercased())
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.dockMetadataText)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .dockListRow()
                        }

                        // Display active processes
                        ForEach(control.processes) { process in
                            HStack(spacing: 8) {
                                DockIcon(.gearSix)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.dockSecondaryText)
                                Text(process.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.dockPrimaryText)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text(process.state.uppercased())
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.dockMetadataText)
                            }
                            .dockListRow()
                        }

                        // Display running background tasks
                        ForEach(model.backgroundTasks.filter { $0.status == .running }) { bgTask in
                            HStack(spacing: 8) {
                                DockIcon(.terminal)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.dockAccent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bgTask.prompt)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.dockPrimaryText)
                                        .lineLimit(1)
                                    Text(bgTask.id)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.dockMetadataText)
                                }
                                Spacer(minLength: 0)
                                Text("RUNNING")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.dockAccent)
                            }
                            .dockListRow()
                        }
                    }
                }
                .dockGlassPane()
            }

            // List of active sessions with state indicator badges
            if !activeSessions.isEmpty {
                sectionLabel("ACTIVE SESSIONS  ·  \(activeSessions.count)")
                ForEach(activeSessions.prefix(4)) { session in
                    let lifecycle = SessionLifecyclePresentation.status(for: session, refresh: control.refreshState(for: "sessions"))
                    Button {
                        if session.id != model.sessionID {
                            openProjectSession(session)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(sessionLifecycleColor(lifecycle)).frame(width: 5, height: 5)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                                HStack(spacing: 6) {
                                    if let projectID = control.projectIDBySessionID[session.id] {
                                        Text(projectID.uppercased())
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(Color.dockAccent)
                                    }
                                    Text(session.displayPreview ?? lifecycle.label).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Text(SessionLifecyclePresentation.rowLabel(for: session, isCurrent: session.id == model.sessionID, refresh: control.refreshState(for: "sessions")).uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(sessionLifecycleColor(lifecycle))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dockListRow()
                        .accessibilityLabel(SessionLifecyclePresentation.accessibilityLabel(for: session, isCurrent: session.id == model.sessionID, refresh: control.refreshState(for: "sessions")))
                    }
                    .buttonStyle(.borderless)
                }
                if activeSessions.count > 4 {
                    Button("VIEW ALL CONVERSATIONS") { select(.session) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dockAccent)
                        .padding(.top, 4)
                }
            }

            // Scheduled automations
            if !control.cronJobs.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        DockIcon(.calendarDots)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.dockSecondaryText)
                        Text("Scheduled Work  ·  \(control.cronJobs.count)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.dockSecondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(control.cronJobs.prefix(2)) { job in
                            HStack(spacing: 8) {
                                Circle().fill(job.enabled ? Color.dockAccent : Color.dockMetadataText)
                                    .frame(width: 5, height: 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.dockPrimaryText)
                                    Text(CronScheduleFormatting.humanReadable(job.schedule))
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.dockMetadataText)
                                }
                                Spacer(minLength: 0)
                                if job.sessionID != nil {
                                    Button("OPEN") { control.openCronSession(job) }
                                        .buttonStyle(.borderless)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Color.dockAccent)
                                }
                            }
                            .dockListRow()
                        }
                    }

                    Button("VIEW ALL AUTOMATIONS") { select(.automations) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dockAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .dockGlassPane()
            }

            // Reminders section
            if !control.reminders.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        DockIcon(.listChecks)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.dockSecondaryText)
                        Text("REMINDERS  ·  \(control.reminders.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(Color.dockSecondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(control.reminders.prefix(2)) { reminder in
                            Button {
                                reminderForConfirmation = reminder
                                isShowingReminderConfirmation = true
                            } label: {
                                HStack(spacing: 8) {
                                    DockIcon(reminder.isOverdue ? .warningCircle : .listChecks)
                                        .font(.system(size: 12))
                                        .foregroundStyle(reminder.isOverdue ? Color.dockWarning : Color.dockAccent)
                                    Text(reminder.title)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.dockPrimaryText)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .dockListRow()
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .dockGlassPane()
            }

            // Integration & capability setup warning banner
            if !setupCapabilities.isEmpty {
                Button { select(.core) } label: {
                    HStack(spacing: 9) {
                        DockIcon(.warning)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockWarning)
                            .frame(width: 15)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SETUP  ·  \(setupCapabilities.count)")
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.7)
                                .foregroundStyle(Color.dockPrimaryText)
                            Text("Review integrations and required permissions in Settings.")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.dockMetadataText)
                        }
                        Spacer(minLength: 0)
                        DockIcon(.caretRight)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.dockAccent)
                    }
                    .padding(12)
                    .dockGlassPane()
                    .overlay(RoundedRectangle(cornerRadius: DockLayout.paneRadius + 4, style: .continuous).stroke(Color.dockWarning.opacity(0.55), lineWidth: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// The active-chat dashboard. All focus, readiness, and runtime details
    /// below are scoped to `model.sessionID`.
    private var sessionOverviewContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            let openAttention = control.attention.filter { $0.state == .open }
            let mission = MissionControlSnapshotBuilder.make(
                sessionTitle: model.currentSessionTitle,
                repository: workflow.repository.isGitRepository ? workflow.repository : nil,
                model: model.runtimeConfiguration?.model,
                context: control.sessionContext,
                attention: control.attention,
                sessions: control.activeSessions,
                activeSessionID: model.sessionID,
                agents: control.activeAgents,
                processes: control.processes,
                backgroundTasks: model.backgroundTasks,
                activities: model.agentActivities,
                cronRuns: control.cronRuns,
                verification: control.verification
            )

            sessionWorkspaceHeader
            missionFocusStrip(mission.focus)
            readinessCard(mission.readiness)
            sessionHandoffCard(mission: mission)

            HStack(spacing: 8) {
                todayMetric("ATTENTION", value: openAttention.count, color: openAttention.isEmpty ? Color.dockSuccess : Color.dockWarning)
                todayMetric("RUNNING", value: control.activeAgents.count + control.processes.count, color: Color.dockAccent)
                todayMetric("SCHEDULED", value: control.cronJobs.count, color: Color.dockSuccess)
            }

            sectionLabel("NEEDS ME")
            if !openAttention.isEmpty {
                attentionItemRow(openAttention.first!, isSelected: false)
                if openAttention.count > 1 {
                    Button("VIEW ALL IN INBOX  ·  \(openAttention.count) ITEMS") { select(.inbox) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockAccent)
                        .padding(.top, 2)
                }
            } else {
                attentionRow(
                    icon: .checkCircle,
                    title: "All clear",
                    detail: "No approvals, clarifications, or failures need a response.",
                    color: .dockSuccess
                )
            }

            let backgroundSessions = control.activeSessions.filter { $0.id != model.sessionID }
            let hasRunningWork = !backgroundSessions.isEmpty || !control.activeAgents.isEmpty || !control.processes.isEmpty
            if hasRunningWork {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        DockIcon(.lightning)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.dockAccent)
                        Text("Running Now")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.dockAccent)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(control.activeAgents) { agent in
                            HStack(spacing: 8) {
                                DockIcon(.users)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.dockAccent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(agent.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.dockPrimaryText)
                                        .lineLimit(1)
                                    Text(agent.sessionID.map { "\($0)  ·  \(agent.state.uppercased())" } ?? agent.state.uppercased())
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.dockMetadataText)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .dockListRow()
                        }

                        ForEach(backgroundSessions) { session in
                            Button {
                                Task {
                                    _ = try? await model.requestControl(HermesFeatureIDs.ID.sessionActivate, params: ["session_id": session.id])
                                    model.requestComposerFocus()
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Circle().fill(Color.dockAccent).frame(width: 5, height: 5)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.title)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(Color.dockPrimaryText)
                                            .lineLimit(1)
                                        Text(session.displayPreview ?? session.state.uppercased())
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.dockMetadataText)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    DockIcon(.caretRight)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.dockAccent)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .dockListRow()
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                        }

                        ForEach(control.processes) { process in
                            HStack(spacing: 8) {
                                DockIcon(.gearSix)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.dockSecondaryText)
                                Text(process.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.dockPrimaryText)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text(process.state.uppercased())
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.dockMetadataText)
                            }
                            .dockListRow()
                        }
                    }
                }
                .dockGlassPane()
            }

            if !model.agentActivities.isEmpty || !control.cronRuns.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        DockIcon(.clockCounterClockwise)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.dockSecondaryText)
                        Text("CHANGED · CURRENT RUNTIME WINDOW")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(Color.dockSecondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.agentActivities.suffix(3).reversed())) { activity in
                            todayActivityRow(
                                timestamp: HumanDateFormatting.timeOnly(activity.timestamp),
                                label: activity.kind.replacingOccurrences(of: "subagent.", with: "").uppercased(),
                                detail: activity.text,
                                color: Color.dockAccent
                            )
                        }
                        ForEach(control.cronRuns.prefix(3)) { run in
                            todayActivityRow(
                                timestamp: run.claimedAt.map(HumanDateFormatting.dateAndTime) ?? "Recent",
                                label: "AUTOMATION  ·  \(run.status.uppercased())",
                                detail: run.jobID ?? "Scheduled job execution",
                                color: cronRunIsSuccessful(run) ? Color.dockSuccess : Color.dockWarning
                            )
                        }
                    }
                }
                .dockGlassPane()
            }

            if !control.cronJobs.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        DockIcon(.calendarDots)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.dockSecondaryText)
                        Text("Scheduled Work  ·  \(control.cronJobs.count)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.dockSecondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(control.cronJobs.prefix(3)) { job in
                            HStack(spacing: 8) {
                                Circle().fill(job.enabled ? Color.dockAccent : Color.dockMetadataText)
                                    .frame(width: 5, height: 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.dockPrimaryText)
                                    Text(CronScheduleFormatting.humanReadable(job.schedule))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.dockPrimaryText)
                                    Text(job.schedule)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.dockMetadataText)
                                }
                                Spacer(minLength: 0)
                                if job.sessionID != nil {
                                    Button("OPEN") { control.openCronSession(job) }
                                        .buttonStyle(.borderless)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.dockAccent)
                                }
                            }
                            .dockListRow()
                        }
                    }

                    Button("VIEW ALL AUTOMATIONS") { select(.automations) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .dockGlassPane()
            }

            if !control.reminders.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        DockIcon(.listChecks)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.dockSecondaryText)
                        Text("REMINDERS  ·  \(control.reminders.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(Color.dockSecondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(control.reminders.prefix(3)) { reminder in
                            Button {
                                reminderForConfirmation = reminder
                                isShowingReminderConfirmation = true
                            } label: {
                                HStack(spacing: 8) {
                                    DockIcon(reminder.isOverdue ? .warningCircle : .listChecks)
                                        .font(.system(size: 12))
                                        .foregroundStyle(reminder.isOverdue ? Color.dockWarning : Color.dockAccent)
                                    Text(reminder.title)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.dockPrimaryText)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .dockListRow()
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .dockGlassPane()
            }

            let setupCapabilities = unavailableSetupCapabilities
            if !setupCapabilities.isEmpty {
                Button { select(.core) } label: {
                    HStack(spacing: 9) {
                        DockIcon(.warning)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockWarning)
                            .frame(width: 15)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SETUP  ·  \(setupCapabilities.count)")
                                .font(.system(size: 12, weight: .semibold))
                                .tracking(0.7)
                                .foregroundStyle(Color.dockPrimaryText)
                            Text("Review integrations and required permissions in Settings.")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.dockMetadataText)
                        }
                        Spacer(minLength: 0)
                        DockIcon(.caretRight)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.dockAccent)
                    }
                    .padding(12)
                    .dockGlassPane()
                    .overlay(RoundedRectangle(cornerRadius: DockLayout.paneRadius + 4, style: .continuous).stroke(Color.dockWarning.opacity(0.55), lineWidth: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }

            if activeRepositoryPath != nil {
                repositoryContent
            }
        }
    }

    private var sessionWorkspaceHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                select(.today)
            } label: {
                DockIconLabel("WORKSPACE", icon: .caretLeft)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.dockAccent)

            Rectangle().fill(Color.dockBorderLight).frame(width: 0.5, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentSessionTitle ?? "Untitled session")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Menu {
                ForEach(ControlTab.sessionNavigation) { mode in
                    secondaryModeButton(mode)
                }
            } label: {
                HStack(spacing: 5) {
                    Text(selectedMode.tabLabel.uppercased())
                    if badgeCount(for: selectedMode) > 0 {
                        badgeView(count: badgeCount(for: selectedMode), isUrgent: badgeIsUrgent(for: selectedMode))
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.65)
                .foregroundStyle(Color.dockAccent)
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.borderless)
            .help("Session view")
        }
        .padding(.bottom, 2)
    }

    /// Returns the color indicator matching a session's current operational state.
    private func sessionStateColor(_ state: String) -> Color {
        switch state.lowercased() {
        case "running", "active": Color.dockAccent
        case "blocked", "error", "failed": Color.dockWarning
        case "completed", "idle", "done": Color.dockSuccess
        default: Color.dockSecondaryText
        }
    }

    private func sessionLifecycleColor(_ status: SessionLifecycleStatus) -> Color {
        switch status {
        case .active: Color.dockAccent
        case .completed: Color.dockSuccess
        case .failed: Color.dockDestructive
        case .stale: Color.dockWarning
        case .unavailable: Color.dockSecondaryText
        }
    }

    /// A compact orientation point for the global Today surface.  The counts
    /// remain actionable, but avoid turning the opening of the page into a
    /// dashboard of equally weighted metric cards.
    private func todayOverviewHeader(
        attentionCount: Int,
        runningCount: Int,
        scheduledCount: Int
    ) -> some View {
        HStack(spacing: 0) {
            todayPulseMetric(
                value: "\(attentionCount)",
                label: "NEEDS YOU",
                icon: .warningCircle,
                tint: attentionCount > 0 ? .dockWarning : .dockSuccess
            ) { select(.inbox) }
            todayPulseMetric(
                value: "\(runningCount)",
                label: "IN FLIGHT",
                icon: .lightning,
                tint: runningCount > 0 ? .dockAccent : .dockSecondaryText
            ) { select(.session) }
            todayPulseMetric(
                value: "\(control.activeSessions.count)",
                label: "SESSIONS",
                icon: .chats,
                tint: control.activeSessions.isEmpty ? .dockSecondaryText : .dockAccent
            ) { select(.session) }
            todayPulseMetric(
                value: "\(scheduledCount)",
                label: "SCHEDULED",
                icon: .calendarDots,
                tint: scheduledCount > 0 ? .dockSuccess : .dockSecondaryText
            ) { select(.automations) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.paneRadius + 2, style: .continuous)
                .fill(Color.dockSurface.opacity(0.34))
        )
        .overlay {
            RoundedRectangle(cornerRadius: DockLayout.paneRadius + 2, style: .continuous)
                .stroke(Color.dockBorderLight, lineWidth: 0.5)
        }
    }

    private func todayPulseMetric(
        value: String,
        label: String,
        icon: Ph,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    DockIcon(icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dockOnAccentText)
                    Text(value)
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(tint)
                Text(label)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Color.dockMetadataText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .overlay(alignment: .trailing) {
            Color.dockBorderLight.frame(width: 0.5, height: 30)
        }
    }

    /// Renders a metric card in the workspace overview, with an optional tap action to switch tabs.
    private func todayMetric(_ label: String, value: Int, color: Color, action: (() -> Void)? = nil) -> some View {
        let cardContent = VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color == Color.dockWarning || color == Color.dockDestructive ? color : Color.dockPrimaryText)
            Text(label == label.uppercased() ? label.lowercased().capitalized : label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.dockMetadataText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .fill(Color.dockSurface.opacity(0.34))
        )
        .overlay {
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .stroke(Color.dockBorderLight, lineWidth: 0.5)
        }

        return Group {
            if let action {
                Button(action: action) {
                    cardContent
                }
                .buttonStyle(.borderless)
            } else {
                cardContent
            }
        }
    }

    private var workspaceOverviewMetricColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 8, alignment: .leading)]
    }

    private func missionFocusStrip(_ focus: MissionControlFocus) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                DockIcon(.crosshair).foregroundStyle(Color.dockAccent)
                Text("MISSION CONTROL")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8).foregroundStyle(Color.dockAccent)
                Spacer()
                if focus.runningCount > 0 { Text("\(focus.runningCount) RUNNING").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dockAccent) }
            }
            Text([focus.sessionTitle, focus.branch, focus.model].compactMap { $0 }.joined(separator: "  ·  "))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(1)
            let telemetry = [
                focus.contextPercent.map { "Context \(Int($0.rounded()))%" },
                focus.changedFiles.map { "\($0) changed" }
            ].compactMap { $0 }
            if !telemetry.isEmpty {
                Text(telemetry.joined(separator: "  ·  "))
                    .font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
            }
        }
        .padding(12)
        .dockGlassPane()
    }

    private func readinessCard(_ readiness: ReadinessSummary) -> some View {
        let color: Color
        switch readiness.state {
        case .ready: color = .dockSuccess
        case .blocked: color = .dockDestructive
        case .needsReview: color = .dockWarning
        case .notApplicable: color = .dockSecondaryText
        }
        return HStack(alignment: .top, spacing: 9) {
            DockIcon(readiness.state == .ready ? .sealCheck : readiness.state == .blocked ? .xCircle : .warningCircle)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text("READINESS · \(readiness.state.rawValue.uppercased())")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                Text(readiness.detail).font(.system(size: 12)).foregroundStyle(Color.dockMetadataText)
                if let scope = readiness.verificationScope { Text("EVIDENCE · \(scope.uppercased())").font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .dockGlassPane()
    }

    private func sessionHandoffCard(mission: MissionControlSnapshot) -> some View {
        let sessionID = model.sessionID
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SESSION HANDOFF")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.7).foregroundStyle(Color.dockAccent)
                Spacer()
                let isPinned = sessionID.map(model.isSessionPinned) ?? false
                if isPinned {
                    Text("PINNED").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dockAccent)
                }
                if let session = (model.sessions + model.pinnedSessions).first(where: { $0.id == sessionID }) {
                    Button(isPinned ? "UNPIN" : "PIN") { Task { await model.toggleSessionPinned(session) } }
                        .buttonStyle(.borderless).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dockAccent)
                        .disabled(model.pinningSessionID != nil)
                }
            }
            if let title = mission.focus.sessionTitle { Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dockPrimaryText).lineLimit(1) }
            if let activity = model.agentActivities.last {
                Text("LAST ACTIVITY · " + activity.text)
                    .font(.system(size: 11)).foregroundStyle(Color.dockMetadataText).lineLimit(2)
            } else {
                Text("No Hermes activity in the current runtime window.")
                    .font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
            }
            let files = Array(Set(model.activeSubagents.flatMap(\.filesWritten))).sorted()
            if !files.isEmpty { Text("FILES WRITTEN · " + files.prefix(3).joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText).lineLimit(1) }
        }
        .padding(12)
        .dockGlassPane()
        .onAppear { if let sessionID { commandCenterPreferences.markSeen("session:\(sessionID)") } }
    }

    private func todayActivityRow(timestamp: String, label: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 5, height: 5).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(color)
                    Text(timestamp)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockMetadataText)
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockListRow()
    }

    private var repositoryContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                DockIcon(workflow.repository.isGitRepository ? .gitBranch : .folder)
                    .foregroundStyle(workflow.repository.isGitRepository ? Color.dockSuccess : Color.dockSecondaryText)
                VStack(alignment: .leading, spacing: 3) {
                    Text(workflow.repository.isGitRepository ? workflow.repository.branch : "No project folder selected")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1)
                    if workflow.repository.isGitRepository {
                        Text(workflow.repository.changedFiles == 0 ? "CLEAN WORKING TREE" : "\(workflow.repository.changedFiles) CHANGED FILE\(workflow.repository.changedFiles == 1 ? "" : "S")")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(workflow.repository.changedFiles == 0 ? Color.dockSuccess : Color.dockWarning)
                    } else if let path = activeRepositoryPath {
                        Text(path).font(.system(size: 12)).foregroundStyle(Color.dockMetadataText).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isRefreshingRepository { ProgressView().controlSize(.small) }
            }
            if workflow.repository.isGitRepository {
                Menu {
                    if workflow.branches.isEmpty {
                        Text("No local branches found")
                    } else {
                        ForEach(workflow.branches, id: \.self) { branch in
                            Button {
                                Task {
                                    _ = await workflow.switchBranch(branch, preferences: commandCenterPreferences, control: control)
                                }
                            } label: {
                                if branch == workflow.repository.branch {
                                    DockIconLabel(branch, icon: .check)
                                } else {
                                    Text(branch)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        DockIcon(.gitBranch)
                        Text("SWITCH BRANCH")
                        DockIcon(.caretDown)
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
                .disabled(isRefreshingRepository || workflow.isRefreshing)
            }
            if workflow.repository.isGitRepository, !workflow.repository.latestCommit.isEmpty {
                Text(workflow.repository.latestCommit)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(2)
            }
            HStack(spacing: 14) {
                Button("CHANGE PROJECT FOLDER") {
                    showingRepositoryPicker = true
                }
                Button {
                    Task { await refreshRepository() }
                } label: {
                    DockActionLabel(
                        title: "REFRESH",
                        pendingTitle: "REFRESHING…",
                        isPending: isRefreshingRepository
                    )
                }
                .disabled(isRefreshingRepository)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.dockAccent)
        }
        .padding(12)
        .dockGlassPane()
    }

    private func providerSetupCard(_ capability: CapabilityState) -> some View {
        HStack(alignment: .top, spacing: 8) {
            DockIcon(.warning)
                .font(.system(size: 12))
                .foregroundStyle(Color.dockWarning)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 3) {
                Text(capability.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                Text(capability.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(2)
                if let recovery = capability.recovery {
                    Text(recovery)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockWarning)
                        .lineLimit(2)
                }
                if let command = capability.recoveryCommand {
                    Button("COPY \(command)") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .dockGlassPane()
        .overlay(RoundedRectangle(cornerRadius: DockLayout.paneRadius + 4, style: .continuous).stroke(Color.dockWarning.opacity(0.55), lineWidth: 0.5))
    }

    private var unavailableSetupCapabilities: [CapabilityState] {
        control.capabilities.filter {
            ["reminders", "notes", "calendar", "messaging", "email"].contains($0.id) && !$0.isAvailable
        }
    }

    private func attentionRow(icon: Ph, title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            DockIcon(icon).font(.system(size: 12)).foregroundStyle(color).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dockPrimaryText)
                Text(detail).font(.system(size: 12)).foregroundStyle(Color.dockMetadataText).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .dockListRow()
    }

    private var currentTask: WorkspaceTask? {
        if let sessionID = model.sessionID {
            return store.task(forSessionID: sessionID)
        }
        return store.activeTask
    }

    private var activeRepositoryPath: String? {
        store.resolvedProjectPath(
            forSessionID: model.sessionID,
            hermesProjectPath: model.sessionID.flatMap { control.project(forSessionID: $0)?.name }
        )
    }

    /// A repository path can be shared by multiple sessions. The task identity
    /// therefore includes the stable Hermes session ID so a session switch
    /// always refreshes Today’s contextual repository projection.
    private var activeRepositoryIdentity: String? {
        guard let sessionID = model.sessionID, let path = activeRepositoryPath else { return nil }
        return "\(sessionID):\(path)"
    }

    private func taskColor(_ status: WorkspaceTaskStatus) -> Color {
        switch status {
        case .todo: .dockSecondaryText
        case .inProgress: .dockAccent
        case .awaitingApproval: .dockWarning
        case .readyForReview: .dockSuccess
        case .done: .dockMetadataText
        }
    }

    private func refreshRepository() async {
        guard let path = activeRepositoryPath else {
            selectedRepositoryDiff = nil
            await workflow.setActiveRepository(path: nil, preferences: commandCenterPreferences, control: control)
            control.setDevelopmentContextProjection(nil)
            isRefreshingRepository = false
            return
        }
        isRefreshingRepository = true
        defer {
            if path == activeRepositoryPath || activeRepositoryPath == nil {
                isRefreshingRepository = false
            }
        }
        await workflow.setActiveRepository(path: path, preferences: commandCenterPreferences, control: control)
        await workflow.refresh(preferences: commandCenterPreferences, control: control)
        guard path == activeRepositoryPath else { return }
        selectedRepositoryDiff = nil
    }

    private func handleRepositoryImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let sessions = control.projectSessions
        let currentSessionIsInSelectedProject = model.sessionID.map { id in
            sessions.contains { $0.id == id }
        } ?? false
        if currentSessionIsInSelectedProject, !sessions.isEmpty {
            store.attachProject(at: url.path, toSessions: sessions)
        } else {
            store.attachProject(at: url.path, toSessionID: model.sessionID)
        }
    }


    private var agentRoster: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                rosterTile(title: "ALL", subtitle: "Hermes", status: model.status.title, color: statusColor, id: nil)
                ForEach(model.displayedSubagents) { agent in
                    rosterTile(title: agent.role ?? initials(for: agent.goal), subtitle: shortGoal(agent.goal), status: agent.status, color: nativeAgentColor(agent.status), id: agent.id)
                }
            }
        }
    }

    private func rosterTile(title: String, subtitle: String, status: String, color: Color, id: String?) -> some View {
        Button {
            selectedAgentID = id
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    AgentAvatar(identity: id ?? "hermes", statusColor: color)
                        .frame(width: 28, height: 28)
                    Circle().fill(color).frame(width: 5, height: 5)
                }
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
            }
            .frame(width: 82, alignment: .leading)
            .padding(8)
            .background(selectedAgentID == id ? color.opacity(0.12) : Color.dockSurface4)
            .overlay(RoundedRectangle(cornerRadius: DockLayout.controlRadius + 1).stroke(selectedAgentID == id ? color.opacity(0.5) : Color.dockBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius + 1))
        }
        .buttonStyle(.borderless)
        .help(status)
    }

    private func activityRow(_ activity: AgentActivity) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(HumanDateFormatting.timeOnly(activity.timestamp))
                .font(.system(size: 12))
                .foregroundStyle(Color.dockMetadataText)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.kind.replacingOccurrences(of: "subagent.", with: "").uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Color.dockAccent)
                Text(activity.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(2)
            }
        }
    }

    private func initials(for value: String) -> String {
        let words = value.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "-" })
        return words.prefix(2).compactMap { $0.first.map(String.init) }.joined()
    }

    private func shortGoal(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > 22 ? String(clean.prefix(22)) + "…" : clean
    }

    private func capabilityStatusRow(_ capability: CapabilityState) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(capabilityReadinessColor(capability)).frame(width: 6, height: 6).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(capability.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dockPrimaryText)
                    Text(capabilityReadinessLabel(capability).uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(capabilityReadinessColor(capability))
                    Text(capabilityAccessLabel(capability).uppercased())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.dockSecondaryText)
                }
                Text(capability.detail).font(.system(size: 12)).foregroundStyle(Color.dockMetadataText).lineLimit(2)
                if let recovery = capability.recovery {
                    Text(recovery).font(.system(size: 12)).foregroundStyle(Color.dockWarning).lineLimit(2)
                }
                if let command = capability.recoveryCommand {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        DockIconLabel("COPY \(command)", icon: .copy)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func capabilityReadinessLabel(_ capability: CapabilityState) -> String {
        switch capability.probeState {
        case .verified: "Verified"
        case .unverified: "Needs review"
        case .missing: "Missing"
        case .unsupported: "Unsupported"
        }
    }

    private func capabilityReadinessColor(_ capability: CapabilityState) -> Color {
        switch capability.probeState {
        case .verified: Color.dockSuccess
        case .unverified: Color.dockAccent
        case .missing, .unsupported: Color.dockWarning
        }
    }

    private func capabilityAccessLabel(_ capability: CapabilityState) -> String {
        switch capability.accessClassification {
        case .safeReadOnly: "Read-only"
        case .confirmedMutation: "Confirmed mutation"
        case .externalSetup: "External setup"
        }
    }

    private var capabilityInventorySnapshot: CapabilitySnapshot {
        control.capabilitySnapshot
    }

    private func capabilityStates(for category: CapabilityCategory) -> [CapabilityState] {
        (capabilityInventorySnapshot.statesByCategory[category] ?? []).filter { !unavailableSetupCapabilities.contains($0) }
    }

    private var capabilityInventorySummary: some View {
        HStack(spacing: 8) {
            Text("\(capabilityInventorySnapshot.totalCount) TOTAL")
            Text("\(capabilityInventorySnapshot.verifiedCount) READY").foregroundStyle(Color.dockPrimaryText)
            Text("\(capabilityInventorySnapshot.unverifiedCount) REVIEW")
            Text("\(capabilityInventorySnapshot.missingCount + capabilityInventorySnapshot.unsupportedCount) MISSING/UNSUPPORTED")
                .foregroundStyle(Color.dockWarning)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.dockSecondaryText)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var appUpdateSection: some View {
        let (status, color): (String, Color) = switch appUpdater.phase {
        case .idle: ("Updates are checked automatically every few hours.", .dockMetadataText)
        case .unavailable(let reason): (reason, .dockMetadataText)
        case .checking: ("Checking \(HermAppUpdater.repository)…", .dockSecondaryText)
        case .upToDate: ("Up to date", .dockSecondaryText)
        case .downloading: ("Downloading Herm \(appUpdater.latest?.version ?? "")…", .dockSecondaryText)
        case .readyToInstall(let version): ("Herm \(version) is ready. It installs and restarts once the current turn finishes.", .dockWarning)
        case .installing: ("Installing and restarting…", .dockWarning)
        case .failed(let reason): (reason, .dockWarning)
        }
        let isUnavailable = if case .unavailable = appUpdater.phase { true } else { false }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if case .readyToInstall = appUpdater.phase {
                    Button("Restart now") { appUpdater.installNow() }
                        .buttonStyle(.dockPrimary)
                        .controlSize(.small)
                } else if appUpdater.canCheck && !isUnavailable {
                    Button("Check for updates") { appUpdater.checkForUpdates() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockAccent)
                }
            }
            Text("Source  ·  \(HermAppUpdater.repository)" + (appUpdater.lastChecked.map { "  ·  checked " + HumanDateFormatting.timeOnly($0) } ?? ""))
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)
        }
    }

    private var agentUpdateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Hermes Agent")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.dockPrimaryText)
                Spacer()
                Button("Restart Herm") { isShowingDockRestartConfirmation = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.dockSecondaryText)
                    .disabled(agentUpdateService.isBusy)
                if agentUpdateService.phase == .checking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking…")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                } else {
                    Button("Check for updates") { agentUpdateService.checkForUpdates() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockAccent)
                        .disabled(!agentUpdateService.canCheck)
                }
            }
            .task {
                if agentUpdateService.phase == .idle {
                    agentUpdateService.checkForUpdates()
                }
            }

            switch agentUpdateService.phase {
            case .idle: agentUpdateIdleContent
            case .checking: agentUpdateIdleContent
            case .upToDate: agentUpdateCheckedContent(statusText: "UP TO DATE", statusColor: .dockSecondaryText, showsUpdateButton: false)
            case .updateAvailable: agentUpdateCheckedContent(statusText: "UPDATE AVAILABLE", statusColor: .dockWarning, showsUpdateButton: true)
            case .checkFailed(let reason): agentUpdateCheckFailedContent(reason)
            case .updating: agentUpdateProgressContent
            case .updateSucceeded: agentUpdateSucceededContent
            case .updateFailed(let reason): agentUpdateFailedContent(reason)
            }
        }
        .confirmationDialog("Update Hermes Agent?", isPresented: $isShowingAgentUpdateConfirmation) {
            Button("Update Hermes Agent") {
                isAgentUpdateOutputExpanded = false
                agentUpdateService.performUpdate()
            }
                .disabled(agentUpdateService.isBusy)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: "Herm will run the allow-listed command `\(HermesUpdateService.updateCommandDisplay)`. It pulls the latest code from NousResearch/hermes-agent, reinstalls dependencies, and may migrate new configuration options. Running Hermes sessions keep the current version until Hermes restarts.")
        }
        .confirmationDialog("Restart Herm?", isPresented: $isShowingDockRestartConfirmation) {
            Button("Restart Herm", role: .destructive) { onRestartDock() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This closes the current Hermes backend and relaunches Herm. Unsaved draft text and the current session view will be cleared; the next chat will load the currently selected Codex account and global model.")
        }
    }

    private var agentUpdateIdleContent: some View {
        Text("Compares the installed Hermes agent with the latest release from NousResearch/hermes-agent.")
            .font(.system(size: 12))
            .foregroundStyle(Color.dockMetadataText)
    }

    private func agentUpdateCheckedContent(statusText: String, statusColor: Color, showsUpdateButton: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let installed = agentUpdateService.installed {
                HStack(spacing: 8) {
                    Text("Installed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockSecondaryText)
                        .frame(width: 76, alignment: .leading)
                    Text(installed.displayVersion)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockPrimaryText)
                    if let method = agentUpdateService.installMethod {
                        Text("·  \(method)")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockMetadataText)
                    }
                }
                .lineLimit(1)
            }
            if let latest = agentUpdateService.latest {
                HStack(spacing: 8) {
                    Text("Latest release")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockSecondaryText)
                        .frame(width: 76, alignment: .leading)
                    Text(latest.displayVersion + (latest.publishedAt.map { "  ·  " + HumanDateFormatting.dateAndTime($0) } ?? ""))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let page = latest.pageURL, let url = URL(string: page) {
                        Button("Release notes") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.dockAccent)
                    }
                }
            }
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusText.lowercased().capitalized)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusColor)
                if showsUpdateButton,
                   let installed = agentUpdateService.installed,
                   let latest = agentUpdateService.latest {
                    Text("\(installed.displayVersion) → \(latest.displayVersion)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                if showsUpdateButton {
                    Button("Update Hermes") { isShowingAgentUpdateConfirmation = true }
                        .buttonStyle(.dockPrimary)
                        .controlSize(.small)
                        .disabled(!agentUpdateService.canStartUpdate)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(statusColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous))
            Text("Source  ·  NousResearch/hermes-agent" + (agentUpdateService.lastChecked.map { "  ·  checked " + HumanDateFormatting.timeOnly($0) } ?? ""))
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)
        }
    }

    private func agentUpdateCheckFailedContent(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let installed = agentUpdateService.installed {
                diagnosticRow(label: "INSTALLED", value: installed.displayVersion, color: Color.dockMetadataText)
            }
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(Color.dockWarning).frame(width: 6, height: 6).padding(.top, 5)
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var agentUpdateProgressContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                DockStatusDot(tone: .working, size: 7, pulses: true)
                Text("Updating Hermes Agent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                Spacer()
                TimelineView(.periodic(from: agentUpdateService.updateStartedAt ?? Date(), by: 1)) { context in
                    Text(agentUpdateElapsedText(until: context.date))
                        .font(DockTypography.machineMetadata.monospacedDigit())
                        .foregroundStyle(Color.dockMetadataText)
                }
            }
            DockShimmerTrack(tone: .working)
            if let latestLine = agentUpdateService.logLines.last {
                Text(latestLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            agentUpdateLogTail
        }
    }

    private var agentUpdateSucceededContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DockIcon(.checkCircle, weight: .fill)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockSuccess)
                Text("HERMES AGENT UPDATED")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockSuccess)
                Spacer()
            }
            if let installed = agentUpdateService.installed {
                diagnosticRow(label: "INSTALLED", value: installed.displayVersion, color: Color.dockSuccess)
            }
            Text("Herm will restart automatically so new sessions run the updated agent.")
                .font(.system(size: 12))
                .foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
            agentUpdateLogTail
        }
    }

    private func agentUpdateFailedContent(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                DockIcon(.warning)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockDestructive)
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Herm never retries an update automatically. Review the output below and run CHECK before trying again.")
                .font(.system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let latestLine = agentUpdateService.logLines.last {
                Text(latestLine)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            agentUpdateLogTail
        }
    }

    private var agentUpdateLogTail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.dockEase(duration: 0.18)) { isAgentUpdateOutputExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    DockIcon(isAgentUpdateOutputExpanded ? .caretDown : .caretRight)
                        .font(.system(size: 10, weight: .semibold))
                    Text(isAgentUpdateOutputExpanded ? "Hide output" : "Show output")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color.dockSecondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isAgentUpdateOutputExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(agentUpdateService.logLines.suffix(120).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.dockSecondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 150)
            }
        }
    }

    private func agentUpdateElapsedText(until now: Date) -> String {
        guard let started = agentUpdateService.updateStartedAt else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(started)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var coreContent: some View {
        VStack(alignment: .leading, spacing: 17) {
            if selectedSettingsCategory == .general {
                generalPreferencesSection
                settingsDisclosure(title: "Appearance", subtitle: "", icon: .sparkle, isExpanded: $isAppearanceExpanded) {
                    appearanceSection
                }
                settingsDisclosure(title: "Herm update", subtitle: "Herm \(appUpdater.currentVersion ?? "dev build")", icon: .arrowsClockwise, isExpanded: $isAppUpdateExpanded) {
                    appUpdateSection
                }
                settingsDisclosure(title: "Agent update", subtitle: "Version and updates", icon: .arrowsClockwise, isExpanded: $isAgentUpdateExpanded) {
                    agentUpdateSection
                }
            }

            HermesConfigCategoryView(editor: control.configEditor, category: selectedSettingsCategory)

            if selectedSettingsCategory == .diagnostics, let insights = control.insightsSummary {
                settingsDisclosure(title: "Usage insights", subtitle: "Last \(insights.days) days", icon: .chartBar, isExpanded: $isInsightsExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        diagnosticRow(label: "Sessions", value: "\(insights.sessions)", color: Color.dockMetadataText)
                        diagnosticRow(label: "Messages", value: "\(insights.messages)", color: .dockMetadataText)
                    }
                }
            }

            if selectedSettingsCategory == .runtime {
                SettingsSection(title: "Dispatch", subtitle: "Pause or resume new work", tint: .dockAccent) {
                    emergencyStopSection
                }
            }

            if selectedSettingsCategory == .integrations, !unavailableSetupCapabilities.isEmpty {
                settingsDisclosure(title: "Setup needed", subtitle: "\(unavailableSetupCapabilities.count) integrations need attention", icon: .warning, isExpanded: $isSetupExpanded, tint: .dockWarning) {
                    ForEach(unavailableSetupCapabilities) { capability in
                        providerSetupCard(capability)
                    }
                }
            }

            if selectedSettingsCategory == .integrations {
            settingsDisclosure(title: "Capabilities", subtitle: "Permission and integration readiness", icon: .shieldCheck, isExpanded: $isCapabilitiesExpanded) {
                projectionRefreshNotice("core")
                capabilityInventorySummary
                if capabilityInventorySnapshot.states.isEmpty {
                    emptyState(
                        icon: .arrowsClockwise,
                        title: "Settings capabilities not yet available",
                        detail: "Refresh Settings or reconnect Hermes to request capability facts."
                    )
                } else {
                    ForEach(CapabilityCategory.allCases, id: \.self) { category in
                        let states = capabilityStates(for: category)
                        if !states.isEmpty {
                            settingsCategoryDisclosure(title: category.rawValue.uppercased(), count: states.count, readyCount: states.filter { $0.probeState == .verified }.count, isExpanded: capabilityCategoryExpansionBinding(for: category)) {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(states) { capability in
                                        capabilityStatusRow(capability)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            }
            if selectedSettingsCategory == .project {
            if control.projectFacts != nil || control.verification != nil {
                settingsDisclosure(title: "Verification", subtitle: "Project facts and delivery evidence", icon: .sealCheck, isExpanded: $isVerificationExpanded) {
                    if let facts = control.projectFacts {
                    diagnosticRow(label: "Project", value: facts.manifests.joined(separator: ", ").isEmpty ? "Code workspace" : facts.manifests.joined(separator: ", "), color: Color.dockMetadataText)
                    if !facts.packageManagers.isEmpty { diagnosticRow(label: "Tools", value: facts.packageManagers.joined(separator: ", "), color: Color.dockMetadataText) }
                    if !facts.contextFiles.isEmpty { diagnosticRow(label: "Context", value: facts.contextFiles.joined(separator: ", "), color: Color.dockMetadataText) }
                    ForEach(VerificationRecipeBuilder.make(facts: facts, repository: workflow.repository)) { recipe in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recipe.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dockSecondaryText)
                                Text(recipe.command).font(.system(size: 11)).foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                            }
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(recipe.command, forType: .string)
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.dockAccent)
                            Button("Ask Hermes") {
                                let repoPath = control.developmentContext?.path ?? "the selected repository"
                                let prompt = "Run this exact verification command in " + repoPath + ": " + recipe.command + ". Do not edit files. Report the result and exit code."
                                Task { _ = await control.startBackgroundTask(prompt, kind: .verification) }
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.dockAccent)
                        }
                    }
                }
                    if let verification = control.verification {
                    let deliveryEvidence = VerificationEvidencePresentation.make(verification: verification, currentFingerprint: workflow.repository.headRevision, evidenceFingerprint: nil, currentRepositoryIdentity: workflow.repository.repositoryID, currentCommitFingerprint: workflow.repository.headRevision, openFailureCount: control.attention.filter { $0.state == .open && $0.kind == .failure }.count, repositoryDirty: workflow.repository.changedFiles > 0)
                    let stateColor: Color = verification.state == .passed ? .dockSecondaryText : (verification.state == .failed ? .dockDestructive : .dockWarning)
                    diagnosticRow(label: "Delivery", value: deliveryEvidence.title.uppercased(), color: deliveryEvidence.state == .current ? .dockSecondaryText : .dockWarning)
                    diagnosticRow(label: "Status", value: verification.state.rawValue.uppercased(), color: stateColor)
                    if let evidence = verification.evidence {
                        if let command = evidence.canonicalCommand ?? evidence.command { diagnosticRow(label: "Evidence", value: command, color: Color.dockMetadataText) }
                        if let scope = evidence.scope { diagnosticRow(label: "Scope", value: scope.uppercased(), color: scope == "targeted" ? Color.dockWarning : Color.dockMetadataText) }
                        if let exitCode = evidence.exitCode { diagnosticRow(label: "Exit", value: String(exitCode), color: exitCode == 0 ? Color.dockSecondaryText : Color.dockDestructive) }
                        if let adapter = evidence.adapter { diagnosticRow(label: "Adapter", value: adapter, color: Color.dockMetadataText) }
                        if let capturedAt = evidence.capturedAt { diagnosticRow(label: "Captured", value: ISO8601DateFormatter().string(from: capturedAt), color: Color.dockMetadataText) }
                        if let repository = evidence.repositoryIdentity { diagnosticRow(label: "Repository", value: repository, color: Color.dockMetadataText) }
                        if let commit = evidence.commitFingerprint { diagnosticRow(label: "Commit", value: commit, color: Color.dockMetadataText) }
                        if let target = evidence.targetFingerprint { diagnosticRow(label: "Target", value: target, color: Color.dockMetadataText) }
                        if let diff = evidence.diffFingerprint { diagnosticRow(label: "Diff", value: diff, color: Color.dockMetadataText) }
                        if let rules = evidence.rulesScopeDetail { diagnosticRow(label: "Rules", value: rules, color: Color.dockMetadataText) }
                        if let staleReason = deliveryEvidence.staleReason { diagnosticRow(label: "Stale", value: staleReason, color: Color.dockWarning) }
                    }
                    }
                }
            }
            }
            let canSteerSession = model.status == .working && model.sessionID != nil
            if selectedSettingsCategory == .session, control.sessionUsage != nil || control.sessionContext != nil || canSteerSession || !control.restoreCheckpoints.isEmpty || control.isLoadingCheckpoints {
                settingsDisclosure(title: "Session cockpit", subtitle: "Context, usage, and active-turn controls", icon: .pulse, isExpanded: $isSessionCockpitExpanded) {
                    if let usage = control.sessionUsage {
                    diagnosticRow(label: "Tokens", value: "\(usage.totalTokens) total  ·  \(usage.inputTokens) in  ·  \(usage.outputTokens) out", color: Color.dockMetadataText)
                    if let model = usage.model { diagnosticRow(label: "Model", value: model, color: Color.dockMetadataText) }
                }
                if let context = control.sessionContext {
                    if let percent = context.contextPercent {
                        diagnosticRow(label: "Context", value: String(format: "%.1f%%", percent), color: percent >= 90 ? Color.dockDestructive : percent >= 80 ? Color.dockWarning : Color.dockSecondaryText)
                    }
                    if !context.categories.isEmpty {
                        ForEach(context.categories.prefix(6)) { category in
                            diagnosticRow(label: category.label.uppercased(), value: "\(category.tokens) tokens", color: Color.dockMetadataText)
                        }
                    }
                }
                let pressure = SessionContextPressure.make(percent: control.sessionContext?.contextPercent)
                if pressure != .unavailable {
                    let color: Color = pressure == .critical ? .dockDestructive : pressure == .warning ? .dockWarning : .dockSecondaryText
                    diagnosticRow(label: "Context pressure", value: pressure.rawValue.uppercased(), color: color)
                    if pressure == .warning || pressure == .critical {
                        Text("Create a handoff or branch before context pressure grows. Compression remains an explicit confirmed action.")
                            .font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
                        HStack(spacing: 8) {
                            TextField("Handoff focus (optional)", text: $handoffFocus).textFieldStyle(.dockGlass)
                            Button("Handoff") { isShowingHandoffConfirmation = true }
                                .buttonStyle(.borderless).foregroundStyle(Color.dockAccent)
                                .disabled(!control.capabilityAvailable("gateway"))
                        }
                    }
                }
                    if control.isLoadingCheckpoints {
                        Text("Loading session checkpoints…")
                            .font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
                    } else if !control.restoreCheckpoints.isEmpty {
                        Text("CHECKPOINTS")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dockSecondaryText)
                        ForEach(control.restoreCheckpoints) { checkpoint in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(checkpoint.message.isEmpty ? checkpoint.hash : checkpoint.message)
                                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                                    Text(checkpoint.timestamp.isEmpty ? checkpoint.hash : checkpoint.timestamp)
                                        .font(.system(size: 10)).foregroundStyle(Color.dockMetadataText).lineLimit(1)
                                }
                                Spacer()
                                Button("Diff") { control.loadCheckpointDiff(checkpoint) }
                                    .buttonStyle(.borderless).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dockAccent)
                                Button("Restore") { checkpointForRestore = checkpoint }
                                    .buttonStyle(.borderless).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dockDestructive)
                                    .disabled(model.status == .working || control.restoreCheckpointState.isPending)
                            }
                        }
                        if let checkpointDiff = control.checkpointDiff, !checkpointDiff.isEmpty {
                            Text(checkpointDiff)
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.dockMetadataText)
                                .lineLimit(12)
                                .textSelection(.enabled)
                        }
                    }
                    if canSteerSession, let sessionID = model.sessionID {
                    Text("Hermes will apply this guidance after the next tool-result boundary without restarting the turn.")
                        .font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
                    HStack(spacing: 8) {
                    TextField("Steer the active turn…", text: $sessionSteerText)
                        .textFieldStyle(.dockGlass)
                    Button("Steer") {
                        let text = sessionSteerText
                        Task {
                            guard let result = await control.steerActiveSession(text) else { return }
                            if result.wasAccepted {
                                sessionSteerText = ""
                                sessionSteerFeedback = "GUIDANCE QUEUED"
                            } else {
                                sessionSteerFeedback = "GUIDANCE REJECTED — text retained"
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.dockAccent)
                    .disabled(sessionSteerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || control.isActionPending(control.sessionSteerActionID(sessionID)))
                    }
                    if let sessionSteerFeedback {
                        Text(sessionSteerFeedback)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(sessionSteerFeedback.contains("REJECTED") ? Color.dockWarning : Color.dockSecondaryText)
                    }
                    }
                }
            }
            if selectedSettingsCategory == .session, let budget = control.promptBudget {
                SettingsSection(title: "Prompt budget", subtitle: "Tokens sent with the next request", tint: .dockAccent) {
                let percent = budget.percent ?? 0
                let color: Color = percent >= 95 ? .dockDestructive : (percent >= 85 ? .dockWarning : .dockAccent)
                diagnosticRow(label: "Tokens", value: "\(budget.totalTokens)" + (budget.tokenLimit.map { " / \($0)" } ?? ""), color: color)
                if budget.percent != nil { diagnosticRow(label: "Used", value: String(format: "%.1f%%", percent), color: color) }
                if let model = budget.model { diagnosticRow(label: "Model", value: model, color: Color.dockMetadataText) }
                }
            }
            if selectedSettingsCategory == .session {
            settingsDisclosure(title: "Session actions", subtitle: "Rename, redirect, branch, or pause the active session", icon: .lightning, isExpanded: $isSessionActionsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("New session title", text: $sessionRenameText)
                            .textFieldStyle(.dockGlass)
                        Button("Rename") {
                            Task { if await control.renameActiveSession(sessionRenameText) { sessionRenameText = "" } }
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.dockAccent)
                        .disabled(sessionRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    HStack(spacing: 8) {
                        TextField("Redirect the active turn…", text: $sessionRedirectText)
                            .textFieldStyle(.dockGlass)
                        Button("Redirect") {
                            let text = sessionRedirectText
                            Task {
                                if let result = await control.redirectActiveSession(text), result.wasAccepted { sessionRedirectText = "" }
                            }
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.dockAccent)
                        .disabled(sessionRedirectText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    HStack(spacing: 8) {
                        TextField("Optional branch name", text: $sessionBranchName)
                            .textFieldStyle(.dockGlass)
                        Button("Branch") { isShowingBranchConfirmation = true }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.dockAccent)
                            .disabled(!control.capabilityAvailable("rpc-sessions"))
                        TextField("Compression focus (optional)", text: $sessionCompressTopic)
                            .textFieldStyle(.dockGlass)
                        Button("Compress") { isShowingCompressConfirmation = true }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.dockAccent)
                            .disabled(!control.capabilityAvailable("rpc-sessions"))
                    }
                    HStack(spacing: 8) {
                        Button("Undo last turn") { isShowingUndoConfirmation = true }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.dockWarning)
                        Button(control.delegationPaused ? "Resume delegation" : "Pause delegation") { isShowingDelegationConfirmation = true }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.dockWarning)
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
            }
            }
            if selectedSettingsCategory == .session, !control.activeAgents.isEmpty || !control.processes.isEmpty {
                SettingsSection(title: "Running work", subtitle: "Subagents and processes", tint: .dockAccent) {
                ForEach(control.activeAgents) { agent in
                    HStack {
                        DockIcon(.users).foregroundStyle(Color.dockAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.name).foregroundStyle(Color.dockPrimaryText)
                            Text(agent.state.uppercased()).foregroundStyle(Color.dockMetadataText)
                        }
                        Spacer()
                        if let native = model.activeSubagents.first(where: { $0.id == agent.id }), !model.isSyntheticSubagent(native.id) {
                            Button("Interrupt") { pendingAgentID = native.id }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Color.dockWarning)
                        }
                    }
                    .font(.system(size: 11))
                }
                ForEach(control.processes) { process in
                    HStack {
                        DockIcon(.gearSix).foregroundStyle(Color.dockSecondaryText)
                        Text(process.name).foregroundStyle(Color.dockPrimaryText)
                        Spacer()
                        Button("Stop") { pendingProcess = process }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.dockWarning)
                    }
                    .font(.system(size: 11))
                }
                }
            }
            if selectedSettingsCategory == .diagnostics, !control.diagnostics.isEmpty {
                settingsDisclosure(title: "Read-only diagnostics", subtitle: "Observed runtime detail", icon: .stethoscope, isExpanded: $isDiagnosticsExpanded) {
                    ForEach(control.diagnostics) { diagnostic in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(diagnostic.isAvailable ? Color.dockSecondaryText : Color.dockWarning)
                            .frame(width: 6, height: 6)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(diagnostic.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.dockPrimaryText)
                            Text(diagnostic.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.dockMetadataText)
                                .lineLimit(3)
                        }
                        Spacer(minLength: 0)
                    }
                    }
                }
            }
            if selectedSettingsCategory == .diagnostics, !control.journeyNodes.isEmpty || control.sessionStoreStatus != nil || control.memoryHealthStatus != nil {
                settingsDisclosure(title: "Learning & storage", subtitle: "Session store, memory, and journey state", icon: .hardDrive, isExpanded: $isLearningExpanded) {
                    ForEach([control.sessionStoreStatus, control.memoryHealthStatus].compactMap { $0 }) { status in
                    diagnosticRow(label: status.title.uppercased(), value: status.detail, color: status.isAvailable ? Color.dockSecondaryText : Color.dockWarning)
                }
                if !control.journeyNodes.isEmpty {
                    Text("JOURNEY  ·  \(control.journeyNodes.count) NODES")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dockMetadataText)
                    ForEach(control.journeyNodes.prefix(8)) { node in
                        HStack(spacing: 7) {
                            Circle().fill(node.state == "active" ? Color.dockSecondaryText : Color.dockSecondaryText).frame(width: 5, height: 5)
                            Text(node.label).font(.system(size: 12)).foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                            Spacer()
                            Text([node.kind, node.useCount.map { "\($0)x" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
                        }
                    }
                    }
                }
            }
            if selectedSettingsCategory == .runtime {
            settingsDisclosure(title: "Runtime configuration", subtitle: "Default model, tools, skills, and plugins", icon: .gearSix, isExpanded: $isRuntimeConfigurationExpanded) {
            HStack {
                settingsSubheading("Default model")
                Spacer()
                Button(action: { model.refreshRuntimeConfiguration() }) {
                    if model.isLoadingRuntimeConfiguration {
                        ProgressView().controlSize(.small).tint(Color.dockAccent)
                    } else {
                        DockIcon(.arrowsClockwise)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.dockAccent)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(model.isLoadingRuntimeConfiguration)
            }

            if model.isLoadingRuntimeConfiguration && model.runtimeConfiguration == nil {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("READING HERMES RUNTIME…").font(.system(size: 12)).tracking(0.6).foregroundStyle(Color.dockSecondaryText)
                }
            } else if let configuration = model.runtimeConfiguration {
                diagnosticRow(label: "Model", value: configuration.model ?? "Not configured", color: configuration.model == nil ? Color.dockWarning : Color.dockSecondaryText)
                diagnosticRow(label: "Provider", value: configuration.provider ?? "Not configured", color: configuration.provider == nil ? Color.dockWarning : Color.dockSecondaryText)
                if model.runtimeModelOptions.isEmpty {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("LOADING HERMES MODEL CATALOG…").font(.system(size: 12)).tracking(0.5).foregroundStyle(Color.dockSecondaryText)
                    }
                } else {
                    Menu {
                        ForEach(model.runtimeModelOptions) { option in
                            Button {
                                selectedModelID = option.id
                            } label: {
                                HStack {
                                    Text(option.displayName)
                                    if option.id == selectedModelID {
                                        Ph.check.image()
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(selectedModelDisplayName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.dockPrimaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            DockIcon(.caretUpDown)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.dockSecondaryText)
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 36)
                        .background(Color.dockControlSurface)
                        .overlay(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).stroke(Color.dockBorder, lineWidth: 0.5))
                        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(model.isLoadingRuntimeConfiguration)
                    .onChange(of: selectedModelID) { _, id in
                        guard let option = model.runtimeModelOptions.first(where: { $0.id == id }),
                              option.model != configuration.model || option.provider != configuration.provider else { return }
                        model.updateRuntimeModel(option)
                    }
                }
                Text("Selection updates the saved default for new sessions. Use the session model picker in the chat header to override one conversation. During a running turn, Hermes applies changes to the next turn.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
                if let error = model.runtimeConfigurationError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockWarning)
                }
                if let path = configuration.configPath {
                    Text(path)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Divider().overlay(Color.dockBorderLight)
                settingsSubheading("EXECUTION")
                if let turns = configuration.maxTurns {
                    diagnosticRow(label: "Max turns", value: turns, color: Color.dockSecondaryText)
                }
                if let timeout = configuration.terminalTimeout {
                    diagnosticRow(label: "Terminal timeout", value: "\(timeout)S", color: Color.dockSecondaryText)
                }

                Divider().overlay(Color.dockBorderLight)
                settingsSubheading("INSTALLED SKILLS  ·  \(configuration.skills.count)")
                configurationList(
                    configuration.skills,
                    empty: "No enabled skills reported by Hermes.",
                    isExpanded: isShowingAllSkills,
                    onToggle: { isShowingAllSkills.toggle() }
                )

                Divider().overlay(Color.dockBorderLight)
                settingsSubheading("MCP SERVERS  ·  \(control.mcpInventoryAvailable ? control.mcpServers.count : configuration.mcpServers.count)")
                if control.mcpInventoryAvailable {
                    if control.mcpServers.isEmpty {
                        Text("No MCP servers configured in Hermes.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockMetadataText)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(control.mcpServers) { server in
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(server.name)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Color.dockPrimaryText)
                                        Text(server.tools == "all" ? server.transport : "\(server.transport)  ·  \(server.tools)")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.dockMetadataText)
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text(server.isEnabled ? "Enabled" : "Disabled")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.dockSecondaryText)
                                        if control.capabilityAvailable("mcp.test") {
                                            Button { control.testMCP(server) } label: {
                                                DockActionLabel(
                                                    title: "Test",
                                                    pendingTitle: "Testing…",
                                                    isPending: control.isActionPending(control.mcpTestActionID(server))
                                                )
                                            }
                                                .buttonStyle(.borderless)
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(Color.dockAccent)
                                                .disabled(control.isActionPending(control.mcpTestActionID(server)))
                                        }
                                    }
                                }
                                if let result = control.mcpTestResults[server.id] {
                                    Text(result)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.dockMetadataText)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                } else {
                    configurationList(configuration.mcpServers, empty: "No MCP servers configured in Hermes.")
                }
                if model.sessionID != nil {
                    Button { isShowingMCPReloadConfirmation = true } label: {
                        DockActionLabel(
                            title: "Reload MCP tools",
                            pendingTitle: "Reloading…",
                            isPending: control.isActionPending(control.reloadMCPActionID)
                        )
                    }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockAccent)
                        .disabled(control.isActionPending(control.reloadMCPActionID))
                }

                Divider().overlay(Color.dockBorderLight)
                settingsSubheading("COMMAND ALLOWLIST  ·  \(control.commandAllowlistEntries?.count ?? 0)")
                if let entries = control.commandAllowlistEntries {
                    if entries.isEmpty {
                        Text("No always-allowed commands.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockMetadataText)
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(entries, id: \.self) { pattern in
                                Text(pattern)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.dockPrimaryText)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    Text("Manage with: hermes config edit")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockMetadataText)
                        .textSelection(.enabled)
                } else {
                    Text("Command allowlist is temporarily unavailable.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockMetadataText)
                }

                if !configuration.plugins.isEmpty {
                    Divider().overlay(Color.dockBorderLight)
                    settingsSubheading("ENABLED PLUGINS  ·  \(configuration.plugins.count)")
                    configurationList(configuration.plugins, empty: "")
                }
            } else {
                emptyState(icon: .warning, title: "Runtime unavailable", detail: "Hermes configuration could not be read. Start Hermes, then refresh.")
            }
            }
            }

            if selectedSettingsCategory == .session,
               control.sessionUsage == nil,
               control.sessionContext == nil,
               control.restoreCheckpoints.isEmpty,
               control.activeAgents.isEmpty,
               control.processes.isEmpty,
               model.sessionID == nil {
                emptyState(icon: .pulse, title: "Session data unavailable", detail: "Open a Hermes session or refresh Settings to load session controls.")
            }
            if selectedSettingsCategory == .project,
               control.projectFacts == nil,
               control.verification == nil {
                emptyState(icon: .sealCheck, title: "Project data unavailable", detail: "Select a repository and refresh Settings to load project facts and verification evidence.")
            }
            if selectedSettingsCategory == .diagnostics,
               control.insightsSummary == nil,
               control.diagnostics.isEmpty,
               control.journeyNodes.isEmpty,
               control.sessionStoreStatus == nil,
               control.memoryHealthStatus == nil {
                emptyState(icon: .stethoscope, title: "Diagnostics unavailable", detail: "Refresh Settings or reconnect Hermes to request read-only diagnostics.")
            }
        }
        .task {
            model.refreshRuntimeConfiguration()
            model.refreshRuntimeModelOptions()
        }
        .onChange(of: model.runtimeConfiguration) { _, configuration in
            guard let configuration,
                  let matching = model.runtimeModelOptions.first(where: { $0.model == configuration.model && $0.provider == configuration.provider }) else { return }
            selectedModelID = matching.id
        }
        .onChange(of: model.runtimeModelOptions) { _, options in
            guard let configuration = model.runtimeConfiguration else { return }
            let matching = options.first { option in
                option.model == configuration.model && option.provider == configuration.provider
            }
            guard let matching else { return }
            selectedModelID = matching.id
        }
    }

    private var generalPreferencesSection: some View {
        SettingsSection(title: "Preferences", subtitle: "", tint: .dockAccent) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsPreferenceRow(title: "Launch in expanded view", detail: "Open the full workspace instead of the compact popup.") {
                    settingsSwitch(isOn: Binding(
                        get: { commandCenterPreferences.launchesExpandedByDefault },
                        set: { commandCenterPreferences.setLaunchesExpandedByDefault($0) }
                    ))
                }
                Divider().overlay(Color.dockBorderLight)
                SettingsPreferenceRow(title: "Completion alerts", detail: "Notify when Hermes finishes a request while Herm is hidden.") {
                    settingsSwitch(isOn: Binding(
                        get: { model.completionNotificationsEnabled },
                        set: { model.setCompletionNotificationsEnabled($0) }
                    ))
                }
                Divider().overlay(Color.dockBorderLight)
                SettingsPreferenceRow(title: "Repository watch notifications", detail: "Notify when watched repository state changes.") {
                    settingsSwitch(isOn: Binding(
                        get: { commandCenterPreferences.repositoryNotificationsEnabled },
                        set: { enabled in
                            commandCenterPreferences.setRepositoryNotificationsEnabled(enabled)
                            workflow.setRepositoryNotificationsEnabled(enabled)
                        }
                    ))
                }
                Divider().overlay(Color.dockBorderLight)
                SettingsPreferenceRow(title: "Show Kanban in sidebar", detail: "List the Kanban board in the workspace side panel.") {
                    settingsSwitch(isOn: $showsKanbanInSidebar)
                }
                Divider().overlay(Color.dockBorderLight)
                SettingsPreferenceRow(title: "Show Pull requests in sidebar", detail: "List pull requests in the workspace side panel.") {
                    settingsSwitch(isOn: $showsPullRequestsInSidebar)
                }
                Divider().overlay(Color.dockBorderLight)
                SettingsPreferenceRow(title: "Show Issues in sidebar", detail: "List GitHub issues in the workspace side panel.") {
                    settingsSwitch(isOn: $showsIssuesInSidebar)
                }
                Divider().overlay(Color.dockBorderLight)
                SettingsPreferenceRow(title: "Show Office in sidebar", detail: "List the Office in the workspace side panel.") {
                    settingsSwitch(isOn: $showsOfficeInSidebar)
                }
                Divider().overlay(Color.dockBorderLight)
                SettingsPreferenceRow(title: "Open workspace", detail: "Open or hide the workspace from any app. It reopens compact or fullscreen, whichever you used last.") {
                    shortcutPicker($workspaceShortcut, excluding: notchShortcut)
                }
                Divider().overlay(Color.dockBorderLight)
                SettingsPreferenceRow(title: "Notch quick view", detail: "Peek at tasks and quota in the notch from any app.") {
                    shortcutPicker($notchShortcut, excluding: workspaceShortcut)
                }
            }
            .padding(.vertical, -8)
        }
    }

    /// Each modifier drives at most one shortcut, so the other's choice is hidden.
    private func shortcutPicker(_ selection: Binding<DoubleTapShortcut>, excluding other: DoubleTapShortcut) -> some View {
        Picker("", selection: selection) {
            ForEach(DoubleTapShortcut.allCases.filter { $0 == .off || $0 != other }) { option in
                Text(option.keycap.map { "\(option.title)  \($0)" } ?? option.title).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    private func settingsSwitch(isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Color.dockAccent)
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 8)], spacing: 8) {
                let skins = control.appearanceProjection?.skins ?? []
                let hermOptions = DockThemeID.hermOnly.map { DockAppearanceOption(themeID: $0, hermesSkin: nil) }
                ForEach(hermOptions + DockAppearanceCatalog.installedOptions(installedSkins: skins)) { option in
                    themeOption(option)
                }
            }
            if !control.appearanceProjectionAvailable {
                SettingsInlineNotice(text: "Hermes skin status unavailable. Refresh Settings to retry.", tint: Color.dockWarning)
            } else if let projection = control.appearanceProjection {
                if !projection.installedPets.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        settingsSubheading("Hermes companion")
                        ForEach(projection.installedPets, id: \.id) { pet in
                            HStack(spacing: 8) {
                                Circle().fill(pet.isActive ? Color.dockAccent : Color.dockMetadataText).frame(width: 6, height: 6)
                                Text(pet.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dockPrimaryText)
                                Spacer()
                                Text(pet.isActive ? "Active" : "Installed")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.dockMetadataText)
                            }
                            .frame(minHeight: 36)
                        }
                    }
                }
                let unknownSkins = DockAppearanceCatalog.unknownSkins(projection.skins)
                if !unknownSkins.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        settingsSubheading("Other Hermes skins")
                        ForEach(unknownSkins, id: \.id) { skin in
                            HStack(spacing: 8) {
                                Circle().fill(skin.isActive ? Color.dockAccent : Color.dockMetadataText).frame(width: 6, height: 6)
                                Text(skin.name).font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText).lineLimit(1)
                                Spacer()
                                Text("No Herm palette")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.dockMetadataText)
                            }
                            .frame(minHeight: 36)
                        }
                    }
                }
            }
        }
    }

    private func themeOption(_ option: DockAppearanceOption) -> some View {
        let theme = option.themeID
        let selected = dockThemeStore.selectedThemeID == theme
        let modeLabel = theme.appearance == .light ? "Light" : theme.appearance == .dark ? "Dark" : "System"
        return Button {
            withAnimation(.dockEase(duration: 0.16)) { dockThemeStore.selectedThemeID = theme }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 3) {
                    ForEach(Array(DockThemePalette(theme: theme).swatches.enumerated()), id: \.offset) { _, color in
                        Circle()
                            .fill(color)
                            .overlay(Circle().stroke(Color.dockBorderLight, lineWidth: 0.5))
                            .frame(width: 10, height: 10)
                    }
                    Spacer(minLength: 0)
                    if selected {
                        DockIcon(.check)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.dockAccent)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(modeLabel)
                        if option.isHermesActive {
                            Text("·")
                            Text("Active in Hermes").foregroundStyle(Color.dockSecondaryText)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .fill(selected ? Color.dockSurface4 : Color.dockSurface2.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .stroke(selected ? Color.dockAccent.opacity(0.6) : Color.dockBorderLight, lineWidth: selected ? 1 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(theme.detail)
        .accessibilityLabel("\(theme.title), \(modeLabel)\(option.isHermesActive ? ", active in Hermes" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var emergencyStopSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DockIcon(control.emergencyStopActive == true ? .pauseCircle : .playCircle)
                    .foregroundStyle(control.emergencyStopActive == true ? Color.dockWarning : Color.dockSecondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(control.emergencyStopActive == true ? "New work paused" : control.emergencyStopActive == false ? "Dispatch resumed" : "Dispatch status unknown")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                    Text(control.emergencyStopMessage ?? "Pause or resume records this Herm action; Hermes does not expose a stable ESTOP status contract.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button {
                    if control.emergencyStopActive == true {
                        isShowingEmergencyResumeConfirmation = true
                    } else {
                        isShowingEmergencyStopConfirmation = true
                    }
                } label: {
                    DockActionLabel(
                        title: control.emergencyStopActive == true ? "Resume" : "Pause",
                        pendingTitle: "Updating…",
                        isPending: control.isActionPending(control.emergencyStopActionID),
                        tint: control.emergencyStopActive == true ? .dockSecondaryText : .dockWarning
                    )
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(control.emergencyStopActive == true ? Color.dockSecondaryText : Color.dockWarning)
                .disabled(control.isActionPending(control.emergencyStopActionID))
            }
        }
    }

    private var coreOverview: some View {
        HStack(spacing: 0) {
            coreSummaryMetric(
                title: "READY",
                value: capabilityInventorySnapshot.states.isEmpty ? "—" : "\(capabilityInventorySnapshot.verifiedCount)/\(capabilityInventorySnapshot.totalCount)",
                color: capabilityInventorySnapshot.states.isEmpty ? .dockSecondaryText : .dockSuccess
            )
            coreSummaryMetric(
                title: "SESSION",
                value: model.sessionID == nil ? "None" : "Active",
                color: model.sessionID == nil ? .dockSecondaryText : .dockAccent
            )
            coreSummaryMetric(
                title: "NEEDS YOU",
                value: "\(control.attention.filter { $0.state == .open }.count)",
                color: control.attention.contains(where: { $0.state == .open }) ? .dockWarning : .dockSuccess
            )
        }
        .padding(.vertical, 2)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private var settingsCommandBar: some View {
        HStack(spacing: 12) {
            Text("Control surface")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.dockMetadataText)
                .tracking(0.7)
            Spacer()
            Toggle("Repository watch notifications", isOn: Binding(
                get: { commandCenterPreferences.repositoryNotificationsEnabled },
                set: { enabled in
                    commandCenterPreferences.setRepositoryNotificationsEnabled(enabled)
                    workflow.setRepositoryNotificationsEnabled(enabled)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Color.dockAccent)
            Button { control.refresh() } label: {
                DockIcon(.arrowsClockwise)
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.dockAccent)
            .accessibilityLabel("Refresh Settings")
        }
        .padding(.vertical, 2)
    }

    private func coreSummaryMetric(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.dockMetadataText)
                .tracking(0.6)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }

    private func settingsDisclosure<Content: View>(
        title: String,
        subtitle: String,
        icon: Ph,
        isExpanded: Binding<Bool>,
        tint: Color = .dockAccent,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        SettingsSection(title: title, subtitle: subtitle, tint: tint) {
            content()
        }
    }

    private func settingsCategoryDisclosure<Content: View>(
        title: String,
        count: Int,
        readyCount: Int,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.dockEase(duration: 0.18)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.dockMetadataText)
                    Spacer()
                    Text("\(readyCount) ready")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(readyCount == count ? Color.dockMetadataText : Color.dockWarning)
                    DockIcon(isExpanded.wrappedValue ? .caretUp : .caretDown)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.dockSecondaryText)
                        .frame(width: 18, height: 26)
                }
                .foregroundStyle(Color.dockPrimaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded.wrappedValue {
                content()
                    .padding(.top, 10)
                    .padding(.bottom, 8)
            }
        }
    }

    private func capabilityCategoryExpansionBinding(for category: CapabilityCategory) -> Binding<Bool> {
        Binding(
            get: { expandedSettingsCapabilityCategories.contains(category) },
            set: { isExpanded in
                if isExpanded {
                    expandedSettingsCapabilityCategories.insert(category)
                } else {
                    expandedSettingsCapabilityCategories.remove(category)
                }
            }
        )
    }

    private var quotaContent: some View {
        QuotaWorkspaceView(control: control)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title == title.uppercased() ? title.lowercased().capitalized : title)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.dockSectionText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) {
                Color.dockBorderLight.frame(height: 0.5)
            }
    }

    /// In-card subheading. Groups inside a settings card separate with a
    /// divider above; the label itself stays quiet.
    private func settingsSubheading(_ title: String) -> some View {
        Text(title == title.uppercased() ? title.lowercased().capitalized : title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.dockSecondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    @ViewBuilder
    private func projectionRefreshNotice(_ projection: String) -> some View {
        if let state = control.refreshState(for: projection) {
            if state.isRefreshing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(state.isStale ? "Refreshing — showing last successful data" : "Refreshing…")
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)
            } else if let error = state.error {
                Text(state.isStale ? "Showing last successful data. \(error)" : error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func agentRow(_ agent: HermesSubagent, expanded: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(nativeAgentColor(agent.status))
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.goal)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(expanded ? 4 : 2)
                if let role = agent.role {
                    Text("ROLE  \(role.uppercased())\(agent.sourceSkill.map { "  ·  \($0)" } ?? "")")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.35)
                        .foregroundStyle(Color.dockAccent)
                }
                Text("\(agent.status.uppercased())  ·  \(agent.toolCount) TOOLS\(agent.model.map { "  ·  \($0.uppercased())" } ?? "")")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(nativeAgentColor(agent.status))
                if expanded, let latest = agent.latestActivity {
                    Text(latest)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Color.dockBorderLight.opacity(0.7).frame(height: 0.5) }
    }

    private func eventRow(_ event: AgentEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.dockAccent.opacity(0.75))
                .frame(width: 13)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.type.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(0.35).foregroundStyle(Color.dockSecondaryText)
                Text(event.detail).font(.system(size: 12)).foregroundStyle(Color.dockMetadataText).lineLimit(2)
            }
        }
    }

    private func diagnosticRow(label: String, value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label == label.uppercased() ? label.prefix(1) + label.dropFirst().lowercased() : label)
                .font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(value).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dockPrimaryText).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var selectedModelDisplayName: String {
        model.runtimeModelOptions.first(where: { $0.id == selectedModelID })?.displayName
            ?? model.runtimeConfiguration.map { "\($0.provider ?? "provider")  /  \($0.model ?? "model")" }
            ?? "Select Hermes model"
    }

    private func configurationList(
        _ values: [String],
        empty: String,
        isExpanded: Bool = false,
        onToggle: (() -> Void)? = nil
    ) -> some View {
        let visibleValues = isExpanded ? values : Array(values.prefix(8))

        return VStack(alignment: .leading, spacing: 6) {
            if values.isEmpty {
                Text(empty)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 0), alignment: .leading),
                        GridItem(.flexible(minimum: 0), alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(Array(visibleValues.enumerated()), id: \.offset) { _, value in
                        HStack(spacing: 7) {
                            Circle().fill(Color.dockAccent.opacity(0.65)).frame(width: 4, height: 4)
                            Text(value)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.dockPrimaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if values.count > 8 {
                    if let onToggle {
                        Button(action: onToggle) {
                            HStack(spacing: 4) {
                                DockIcon(isExpanded ? .caretUp : .caretDown)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(isExpanded ? "SHOW FEWER" : "SHOW ALL \(values.count) SKILLS")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.dockAccent)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(isExpanded ? "Show fewer skills" : "Show all \(values.count) skills")
                    } else {
                        Text("+ \(values.count - 8) MORE")
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(0.65)
                            .foregroundStyle(Color.dockMetadataText)
                    }
                }
            }
        }
    }

    private func capabilityRow(icon: Ph, title: String, detail: String, state: String, color: Color) -> some View {
        HStack(spacing: 8) {
            DockIcon(icon).font(.system(size: 12)).foregroundStyle(color).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dockPrimaryText)
                Text(detail).font(.system(size: 12)).foregroundStyle(Color.dockMetadataText)
            }
            Spacer(minLength: 3)
            Text(state).font(.system(size: 12, weight: .semibold)).tracking(0.45).foregroundStyle(color)
        }
    }

    private var latestModelName: String? {
        model.messages.reversed().compactMap(\.modelName).first
    }

    private func emptyState(icon: Ph, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DockIcon(icon).foregroundStyle(Color.dockMetadataText)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dockPrimaryText)
            Text(detail).font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nativeAgentColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "running", "finalizing": .dockAccent
        case "complete", "completed": .dockSuccess
        case "blocked", "stalled", "error": .dockWarning
        default: .dockSecondaryText
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: .dockSuccess
        case .working: .dockAccent
        case .needsApproval: .dockWarning
        case .needsClarification: .dockWarning
        case .offline: .dockDestructive
        }
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case runtime
    case chat
    case workspace
    case safety
    case browser
    case memory
    case voice
    case advanced
    case integrations
    case session
    case project
    case diagnostics

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .runtime: "Runtime"
        case .chat: "Chat"
        case .workspace: "Workspace"
        case .safety: "Safety"
        case .browser: "Browser"
        case .memory: "Memory & Context"
        case .voice: "Voice"
        case .advanced: "Advanced"
        case .integrations: "Integrations"
        case .session: "Session"
        case .project: "Project"
        case .diagnostics: "Diagnostics"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Herm preferences and appearance"
        case .runtime: "Models, dispatch, and tools"
        case .chat: "Personality, timezone, and attachments"
        case .workspace: "Working directory, shell, and file access"
        case .safety: "Approvals, privacy, and checkpoints"
        case .browser: "Browser profile and private URLs"
        case .memory: "Persistent memory and context compression"
        case .voice: "Voice chat, speech to text, and text to speech"
        case .advanced: "Agent limits, tools, terminal, and subagents"
        case .integrations: "Permissions and connected services"
        case .session: "Active session controls and context"
        case .project: "Repository facts and verification"
        case .diagnostics: "Observed health and storage"
        }
    }

    var icon: Ph {
        switch self {
        case .general: .slidersHorizontal
        case .runtime: .gearSix
        case .chat: .chatText
        case .workspace: .folder
        case .safety: .shieldWarning
        case .browser: .link
        case .memory: .brain
        case .voice: .microphone
        case .advanced: .cpu
        case .integrations: .shieldCheck
        case .session: .pulse
        case .project: .sealCheck
        case .diagnostics: .stethoscope
        }
    }
}

enum SettingsLayoutMode: Equatable {
    case rail
    case menu

    static func forWidth(_ width: CGFloat) -> Self {
        width >= 760 ? .rail : .menu
    }
}

struct SettingsCategoryBadge: Equatable {
    enum Kind: Equatable {
        case dot
        case count(Int)
    }

    let kind: Kind
    let isWarning: Bool
}

struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        // Grouped-card pattern: the heading sits outside a single quiet card so
        // a page reads as a short list of groups, not a stack of hairlines.
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint == .dockWarning ? Color.dockWarning : Color.dockPrimaryText)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous)
                    .fill(Color.dockSurface.opacity(0.34))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous)
                    .stroke(Color.dockBorderLight, lineWidth: 0.5)
            )
        }
    }
}

struct SettingsPreferenceRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.dockPrimaryText)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .frame(minHeight: 52)
    }
}

private struct SettingsStatusRow: View {
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dockPrimaryText)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
    }
}

private struct SettingsActionRow<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let actions: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dockPrimaryText)
                if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText).lineLimit(2) }
            }
            Spacer(minLength: 12)
            actions()
        }
        .frame(minHeight: 52)
    }
}

private struct SettingsInlineNotice: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(tint).frame(width: 7, height: 7).padding(.top, 4)
            Text(text).font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

private struct SettingsInventoryList<Content: View>: View {
    let emptyMessage: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let emptyMessage, !emptyMessage.isEmpty {
                Text(emptyMessage).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
            } else {
                content()
            }
        }
    }
}

/// The session inspector is deliberately a separate surface from the workspace.
/// Workspace navigation answers "what needs attention overall?"; this panel
/// answers "what is happening in this conversation?".
