import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers
struct WorkspaceActivitySidebar: View {
    @ObservedObject var model: DockModel
    @ObservedObject var botMode: BotModeModel
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var control: ControlCenterModel
    @ObservedObject var workflow: DeveloperWorkflowModel
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
    @State private var connectTarget: QuotaProviderDescriptor?
    @State private var selectedCronJobID: String?
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
    @State private var kanbanMutationRequest: KanbanMutationRequest?
    @State private var cronEditJob: CronSummary?
    @State private var cronReportRequest: CronReportRequest?
    @State private var clarificationItem: AttentionItem?
    @State private var clarificationResponse = ""
    @State private var expandedCronReportIDs: Set<String> = []
    @State private var isShowingAllSkills = false
    @State private var expandedSettingsCapabilityCategories: Set<CapabilityCategory> = [.core]
    @State private var isAgentUpdateExpanded = true
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
    @State private var isShowingDockRestartConfirmation = false
    @State private var isShowingEmergencyStopConfirmation = false
    @State private var isShowingEmergencyResumeConfirmation = false
    @State private var checkpointForRestore: RestoreCheckpoint?
    @State private var pendingProjectMutation: ProjectMutation?
    @State private var isShowingProjectMutationConfirmation = false
    @State private var pendingProjectFolder: URL?
    @State private var isShowingProjectCreationConfirmation = false
    @State private var quotaProviderOrder = QuotaProviderCatalog.orderedProviderIDs()
    @State private var draggingQuotaProviderID: String?
    @StateObject private var commandCenterPreferences = CommandCenterPreferencesStore()
    @ObservedObject var agentUpdateService: HermesUpdateService

    init(
        model: DockModel,
        botMode: BotModeModel,
        store: WorkspaceStore,
        control: ControlCenterModel,
        workflow: DeveloperWorkflowModel,
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
        self.onClose = onClose
        self.onRestartDock = onRestartDock
        self.onOpenArtifacts = onOpenArtifacts
        self.onSessionOpened = onSessionOpened
        self.showsHeader = showsHeader
        self.showsModePicker = showsModePicker
        self.agentUpdateService = agentUpdateService
        _selectedMode = State(initialValue: initialMode)
    }

    private enum KanbanLane: String, CaseIterable, Identifiable {
        case triage = "Triage"
        case todo = "Todo"
        case ready = "Ready"
        case running = "Running"
        case review = "Review"
        case scheduled = "Scheduled"
        case blocked = "Blocked"
        case done = "Done"

        var id: String { rawValue }
        var emptyTitle: String {
            switch self {
            case .triage: "Nothing awaiting triage"
            case .todo: "No queued work"
            case .ready: "Nothing ready to start"
            case .running: "No active work"
            case .review: "Nothing awaiting review"
            case .scheduled: "Nothing scheduled"
            case .blocked: "No blocked work"
            case .done: "No completed work"
            }
        }
        var emptyDetail: String {
            switch self {
            case .triage: "New tasks will appear here for routing."
            case .todo: "Tasks waiting for an owner or next step appear here."
            case .ready: "Assigned tasks ready for execution appear here."
            case .running: "Tasks currently being worked will appear here."
            case .review: "Tasks submitted for review appear here."
            case .scheduled: "Tasks with a future dispatch time appear here."
            case .blocked: "Tasks needing attention or a dependency appear here."
            case .done: "Completed tasks remain visible here when reported."
            }
        }
        var icon: String {
            switch self {
            case .triage: "scope"
            case .todo: "circle.dashed"
            case .ready: "circle"
            case .running: "refresh-cw"
            case .review: "eye"
            case .scheduled: "clock"
            case .blocked: "exclamationmark.octagon"
            case .done: "checkmark.circle"
            }
        }
        var color: Color {
            switch self {
            case .triage: Color.dockWarning
            case .todo: Color.dockSecondaryText
            case .ready: Color.dockAccent
            case .running: Color.dockAccent
            case .review: Color.dockSecondaryText
            case .scheduled: Color.dockAccent
            case .blocked: Color.dockWarning
            case .done: Color.dockSuccess
            }
        }
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
            if selectedMode == .kanban {
                kanbanContent
            } else if selectedMode == .officePreview {
                officePreviewContent
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
                            case .officePreview: officePreviewContent
                            case .core: coreContent
                            case .quota: quotaContent
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
        if selectedMode == .kanban {
            DockPageHeader(
                icon: selectedMode.pageHeaderIcon,
                title: selectedMode.pageHeaderTitle,
                subtitle: pageHeaderSubtitle,
                onRefresh: { applyKanbanFilters() },
                isRefreshing: control.isKanbanRefreshPending
            )
        } else {
            DockPageHeader(
                icon: selectedMode.pageHeaderIcon,
                title: selectedMode.pageHeaderTitle,
                subtitle: pageHeaderSubtitle
            )
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
        case .core:
            return projectionHeaderSubtitle(
                model.runtimeConfigurationProjectionState,
                fallback: selectedMode.pageHeaderSubtitle
            )
        default:
            return selectedMode.pageHeaderSubtitle
        }
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
                    LucideImage(systemName: "command")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockAccent)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .help("Command palette")
                .keyboardShortcut("k", modifiers: [.command])
                Button(action: onClose) {
                    LucideImage(systemName: "chevron.left")
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
        .onChange(of: control.capabilities) { _, _ in
            guard selectedMode == .kanban, control.capabilityAvailable("kanban") else { return }
            applyKanbanFilters()
        }
        .onChange(of: selectedMode) { _, mode in
            switch mode {
            case .quota:
                control.refreshProviderQuota()
            case .kanban:
                // Re-apply this surface's visible controls. This prevents a
                // session-only query started from Activity from leaking into
                // a separately opened global board.
                applyKanbanFilters()
            case .officePreview:
                // The office reads the same global Kanban projection as the
                // Kanban page; it never creates or mutates a second task store.
                control.refreshGlobalKanban()
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
            else if selectedMode == .kanban { applyKanbanFilters() }
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
                Button(request.action.rawValue.uppercased()) {
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
            Text("Hermes will remove the latest real user turn and its following output. This cannot be recovered through the Dock.")
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
            Text("Hermes will prepare a no-edit Markdown handoff in the current session. The result stays in the current Dock runtime until you copy or explicitly send it elsewhere.")
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
                control.engageEmergencyStop(reason: "Paused from Hermes Agent Dock")
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
                Text("Hermes will restore this session to checkpoint \(checkpoint.hash). Changes after that checkpoint cannot be recovered through the Dock.")
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
            VStack(alignment: .leading, spacing: 14) {
                Text("CLARIFICATION REQUIRED")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
                Text(item.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockPrimaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let choices = item.choices, !choices.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("SUGGESTED RESPONSES")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.dockSecondaryText)
                        ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                            Button {
                                clarificationResponse = choice
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    LucideImage(systemName: clarificationResponse == choice ? "checkmark.circle.fill" : "circle")
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
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                HStack {
                    Spacer()
                    Button("Cancel") { clarificationItem = nil }
                    Button("SEND RESPONSE") {
                        control.respond(to: item, action: .respond, response: clarificationResponse)
                        clarificationItem = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(clarificationResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 390)
            .background(Color.dockCanvas)
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

            compactTabButton(title: "Artifacts", icon: "doc.text.magnifyingglass", isSelected: false) {
                onOpenArtifacts()
            }
            compactTabButton(
                title: "Conversations",
                icon: "bubble.left.and.bubble.right",
                count: compactUnlinkedSessions.count,
                isUrgent: false,
                isSelected: selectedMode == .session
            ) {
                select(.session)
            }
            compactTabButton(
                title: "Projects",
                icon: "folder",
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
                    icon: "ellipsis.circle",
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
        icon: String,
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
        icon: String,
        detail: String?,
        badgeCount: Int,
        isUrgent: Bool,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 6) {
            LucideImage(systemName: icon)
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
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    private struct CompactProjectGroup: Identifiable {
        let id: String
        let title: String
        let sessions: [HermesSession]
    }

    private var compactSortedSessions: [HermesSession] {
        model.sessions.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
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
            .sorted { ($0.sessions.first?.startedAt ?? .distantPast) > ($1.sessions.first?.startedAt ?? .distantPast) }
    }

    private var compactUnlinkedSessions: [HermesSession] {
        let linkedIDs = Set(compactProjectGroups.flatMap { $0.sessions.map(\.id) })
        return compactSortedSessions.filter { !linkedIDs.contains($0.id) }
    }

    /// Compact mode mirrors the fullscreen rail's daily operator destinations.
    /// Repository and setup surfaces remain available from More.
    private var compactRailNavigation: [ControlTab] {
        [.today, .inbox, .kanban, .quota, .automations]
    }

    private var compactOverflowNavigation: [ControlTab] {
        [.projects, .search, .officePreview, .core]
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
            LucideImage(systemName: "ellipsis.circle")
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
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    private func secondaryModeButton(_ mode: ControlTab) -> some View {
        Button { select(mode) } label: {
            HStack {
                LucideLabel(mode.tabLabel, icon: mode.icon)
                if badgeCount(for: mode) > 0 {
                    Text(badgeLabel(for: mode))
                }
                if selectedMode == mode {
                    LucideImage(systemName: "checkmark")
                }
            }
        }
    }

    private func modeButton(_ mode: ControlTab) -> some View {
        Button { select(mode) } label: {
            HStack(spacing: 8) {
                LucideImage(systemName: mode.icon)
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
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                    emptyState(icon: "checkmark.circle", title: "Working tree clean", detail: "No staged, unstaged, or untracked files were found.")
                } else {
                    changeSections(changes)
                }
            } else if let path = activeRepositoryPath {
                let inspecting = isRefreshingRepository || workflow.isRefreshing
                emptyState(
                    icon: inspecting ? "refresh-cw" : "folder",
                    title: inspecting ? "Inspecting project" : "Project is not a Git repository",
                    detail: inspecting ? path : "\(path) is available as a local project folder, but it has no Git working tree to inspect."
                )
            } else {
                emptyState(icon: "doc.text.magnifyingglass", title: "No project selected", detail: "Choose a project from Projects to inspect its local changes.")
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
                LucideImage(systemName: file.status == .conflicted ? "exclamationmark.octagon" : "doc")
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
                LucideImage(systemName: findings.isEmpty ? "checkmark.shield" : "exclamationmark.shield")
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
                emptyState(icon: "checkmark.seal", title: "Verification unavailable", detail: "Open a Hermes project session with a local folder, then refresh Settings to request verification facts.")
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
                                let prompt = "Review repository \(notice.displayName) without editing files. The Dock detected \(notice.changedFiles) changed files. Report risks, missing tests, and verification scope without quoting suspected credential values."
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
                emptyState(icon: "folder.badge.gearshape", title: "No repositories attached", detail: "Use Change Repository from Today to attach a local repository to a Hermes session.")
            } else {
                if !workflow.worktrees.isEmpty {
                    DisclosureGroup("WORKTREES  ·  \(workflow.worktrees.count)") {
                        ForEach(workflow.worktrees) { worktree in
                            HStack(spacing: 8) {
                                LucideImage(systemName: worktree.snapshot?.conflictedFiles ?? 0 > 0 ? "exclamationmark.octagon" : "arrow.triangle.branch")
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
                applyKanbanFilters()
            }
        }
    }

    private var automationsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            projectionRefreshNotice("cron.jobs")

            HStack(spacing: 8) {
                Spacer()
                Button {
                    control.refresh()
                    control.refreshCronRuns()
                } label: {
                    LucideImage(systemName: "refresh-cw")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.dockSecondaryText)
                .help("Refresh schedules and run history")
                Button {
                    withAnimation(.dockEase(duration: 0.2)) {
                        isShowingAutomationComposer.toggle()
                    }
                } label: {
                    LucideLabel(
                        isShowingAutomationComposer ? "Close" : "New automation",
                        icon: isShowingAutomationComposer ? "xmark" : "plus",
                        iconColor: .dockOnAccentText
                    )
                }
                .buttonStyle(.dockPrimary)
                .font(.system(size: 12, weight: .semibold))
            }

            cronOverviewMetrics

            if isShowingAutomationComposer {
                automationComposer
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            cronWorkspace
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cronOverviewMetrics: some View {
        let activeCount = control.cronJobs.filter(\.enabled).count
        let successfulRuns = control.cronRuns.filter(cronRunIsSuccessful).count
        let successRate = control.cronRuns.isEmpty ? "—" : "\(Int((Double(successfulRuns) / Double(control.cronRuns.count)) * 100))%"
        let nextJob = control.cronJobs.first(where: { $0.nextRun != nil })

        return HStack(spacing: 0) {
            cronMetric(value: "\(activeCount)", label: "ACTIVE", tint: activeCount > 0 ? .dockSuccess : .dockSecondaryText)
            cronMetric(value: "\(control.cronRuns.count)", label: "RUNS", tint: .dockAccent)
            cronMetric(value: successRate, label: "SUCCESS RATE", tint: successfulRuns > 0 ? .dockSuccess : .dockSecondaryText)
            cronMetric(
                value: nextJob?.nextRun.map(HumanDateFormatting.dateAndTime) ?? "No next run",
                label: "NEXT UP",
                tint: nextJob == nil ? .dockSecondaryText : .dockAccent,
                isCompactValue: true
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.dockSurface.opacity(0.34))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.dockBorderLight, lineWidth: 0.5)
        }
    }

    private func cronMetric(value: String, label: String, tint: Color, isCompactValue: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: isCompactValue ? 11 : 19, weight: .semibold, design: isCompactValue ? .monospaced : .default))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Color.dockMetadataText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .overlay(alignment: .trailing) {
            Color.dockBorderLight.frame(width: 0.5, height: 28)
        }
    }

    private var cronWorkspace: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 22) {
                cronSchedulesColumn
                    .frame(minWidth: 320, maxWidth: .infinity, alignment: .topLeading)
                cronHistoryColumn
                    .frame(minWidth: 280, maxWidth: .infinity, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 22) {
                cronSchedulesColumn
                cronHistoryColumn
            }
        }
    }

    private var cronSchedulesColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            cronSectionHeading("Schedules", count: control.cronJobs.count, icon: "calendar.badge.clock")
            if control.cronJobs.isEmpty {
                emptyState(icon: "clock.badge.questionmark", title: "No schedules", detail: "Create an automation when work needs to run without you.")
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(control.cronJobs) { job in
                            cronScheduleRow(job, isExpanded: selectedCronJobID == job.id)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
    }

    private var cronHistoryColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            cronSectionHeading("Run history", count: control.cronRuns.count, icon: "waveform.path.ecg")
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

    private func cronSectionHeading(_ title: String, count: Int, icon: String) -> some View {
        HStack(spacing: 8) {
            LucideImage(systemName: icon)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                LucideImage(systemName: "wand.and.stars")
                    .foregroundStyle(Color.dockAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New automation")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                    Text("Set the intent once; Hermes will keep the cadence.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockMetadataText)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    controlFieldLabel("NAME")
                    dockTextField("Morning review", text: $automationName)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        controlFieldLabel("SCHEDULE")
                        Spacer()
                        Text("every 2h · 0 9 * * *")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.dockMetadataText)
                            .lineLimit(1)
                    }
                    dockTextField("When should Hermes run this?", text: $automationSchedule)
                }
            }

            controlFieldLabel("REQUEST")
            TextField("What should Hermes do?", text: $automationPrompt, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.dockPrimaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .frame(minHeight: 42)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.dockSurface))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.dockBorder, lineWidth: 0.5))

            HStack {
                Spacer()
                Button("Cancel") {
                    withAnimation(.dockEase(duration: 0.2)) { isShowingAutomationComposer = false }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.dockSecondaryText)
                Button("Review and create") { isShowingAutomationConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .opacity(canCreateAutomation && control.capabilityAvailable("rpc-scheduling") ? 1 : 0.42)
                    .disabled(!canCreateAutomation || !control.capabilityAvailable("rpc-scheduling"))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.dockSurface.opacity(0.38)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.dockAccent.opacity(0.28), lineWidth: 0.5))
    }

    private func cronScheduleRow(_ job: CronSummary, isExpanded: Bool) -> some View {
        let health = AutomationHealthPresentation.make(
            job: job,
            runs: control.cronRuns,
            // A loaded job is not unavailable just because a mutation capability is missing.
            capabilityAvailable: true,
            mcpErrorObserved: false
        )
        return VStack(spacing: 0) {
            Button {
                withAnimation(.dockEase(duration: 0.2)) {
                    selectedCronJobID = isExpanded ? nil : job.id
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(job.enabled ? Color.dockSuccess : Color.dockMetadataText)
                            .frame(width: 8, height: 8)
                            .padding(.top, 4)
                        Rectangle()
                            .fill(Color.dockBorderLight)
                            .frame(width: 1)
                            .padding(.top, 6)
                    }
                    .frame(width: 8)
                    .frame(maxHeight: .infinity, alignment: .top)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(job.name)
                                .font(.system(size: 13, weight: .semibold))
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
                        Text(job.schedule)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.dockMetadataText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    if let nextRun = job.nextRun {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("NEXT RUN")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.6)
                            Text(HumanDateFormatting.dateAndTime(nextRun))
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Color.dockMetadataText)
                    }
                    Text(health.state.rawValue.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(health.state == .healthy ? Color.dockSuccess : health.state == .degraded ? Color.dockWarning : Color.dockSecondaryText)
                    LucideImage(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.dockAccent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)

            if isExpanded {
                Divider().overlay(Color.dockBorderLight)
                VStack(alignment: .leading, spacing: 12) {
                    cronReportCard(job)
                    cronJobActions(job)
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(isExpanded ? Color.dockAccent.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
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
                LucideImage(systemName: job.enabled ? "clock.badge.checkmark" : "clock.badge.xmark")
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
                        LucideImage(systemName: expandedCronReportIDs.contains(job.id) ? "chevron.down" : "chevron.right")
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
                        .background(Color.black.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle()
                    .fill(cronRunIsSuccessful(run) ? Color.dockSuccess : Color.dockWarning)
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
                Rectangle()
                    .fill(Color.dockBorderLight)
                    .frame(width: 1)
                    .padding(.top, 6)
            }
            .frame(width: 8)
            .frame(maxHeight: .infinity, alignment: .top)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(run.status.uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                    Spacer(minLength: 4)
                    if canViewReport {
                        HStack(spacing: 4) {
                            Text("REPORT")
                            LucideImage(systemName: "chevron.right")
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
        .padding(.vertical, 11)
        .padding(.horizontal, 3)
        .contentShape(Rectangle())
        .dockGlassPane()
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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.dockSurface)
                    .stroke(Color.dockBorder, lineWidth: 0.5)
            )
    }

    private var canCreateAutomation: Bool {
        !automationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !automationSchedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !automationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func controlFieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(.body).weight(.semibold))
            .tracking(0.9)
            .foregroundStyle(Color.dockSecondaryText)
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
                        LucideLabel("PROJECTS", icon: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
                    Spacer()
                    if let path = selectedProjectFolderPath {
                        Button {
                            startNewChat(in: path)
                        } label: {
                            LucideLabel("NEW CHAT", icon: "plus.bubble")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.dockAccent)
                        .disabled(model.isRestoringSession || model.isCreatingSession)
                        .help("Start a new chat in this project")
                    }
                }
                selectedProjectSummary(project)
                if control.projectSessions.isEmpty {
                    emptyState(icon: "bubble.left.and.bubble.right", title: "No sessions in this project", detail: "No grouped sessions were found for this project.")
                } else {
                    HStack {
                        sectionLabel("SESSIONS")
                        Spacer()
                        Text("\(control.projectSessions.count)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.dockAccent)
                    }
                    ForEach(control.projectSessions) { session in
                        Button {
                            selectedProjectSessionID = session.id
                        openProjectSession(session)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Circle().fill(Color.dockAccent).frame(width: 6, height: 6)
                                    Text(session.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.dockPrimaryText)
                                        .lineLimit(2)
                                    Spacer()
                                    Text(session.state.uppercased())
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.dockSecondaryText)
                                    LucideImage(systemName: "chevron.right")
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
                emptyState(icon: "folder", title: "No projects", detail: "Projects will appear here when project contexts are available.")
            } else {
                HStack {
                    sectionLabel("PROJECTS  ·  \(control.projects.count)")
                    Spacer()
                    projectDirectoryActions
                }
                ForEach(control.projects) { project in
                    Button {
                        openProject(project)
                    } label: {
                        HStack(spacing: 10) {
                            LucideImage(systemName: project.isActive ? "folder.fill" : "folder")
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
                            LucideImage(systemName: "chevron.right")
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
            }
        }
    }

    private var addProjectDirectoryButton: some View {
        Button {
            chooseProjectDirectory()
        } label: {
            LucideLabel("ADD DIRECTORY", icon: "folder.badge.plus")
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
                LucideImage(systemName: project.isActive ? "folder.fill" : "folder")
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

    private var kanbanContent: some View {
        HSplitView {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    pageHeader
                        .padding(.horizontal, 16)

                    VStack(alignment: .leading, spacing: 18) {
                        kanbanOverviewMetrics

            if control.capabilityAvailable("kanban.create"), !kanbanCurrentSessionOnly {
                HStack {
                    Button {
                        withAnimation(.dockEase(duration: 0.2)) {
                            isShowingKanbanComposer.toggle()
                        }
                    } label: {
                        LucideLabel(isShowingKanbanComposer ? "Close task composer" : "Add task", icon: isShowingKanbanComposer ? "xmark" : "plus")
                    }
                    .buttonStyle(.dockPrimary)
                    .font(.system(size: 12, weight: .semibold))
                    Spacer()
                }

                if isShowingKanbanComposer {
                    createKanbanTaskForm
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else if kanbanCurrentSessionOnly {
                LucideLabel("Session cards must be created by a session-aware Kanban worker. Manual CLI cards are global.", icon: "link.badge.plus")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dockMetadataText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if control.capabilityAvailable("kanban.filters"), !control.kanbanTasks.isEmpty {
                HStack(spacing: 9) {
                    LucideImage(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockAccent)
                    kanbanFilterControls
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.dockSurface.opacity(0.28)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
            }
            if !control.kanbanDiagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        sectionLabel("KANBAN HEALTH")
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
                            LucideImage(systemName: "refresh-cw")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.dockAccent)
                    }
                    ForEach(control.kanbanDiagnostics) { diagnostic in
                        Button {
                            if let taskID = diagnostic.taskID,
                               let task = control.kanbanTasks.first(where: { $0.id == taskID }) {
                                selectedKanbanTask = task
                                control.loadKanbanTask(task)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(diagnostic.severity.uppercased())
                                        .foregroundStyle(diagnostic.severity.lowercased() == "error" ? Color.dockDestructive : Color.dockWarning)
                                    Text(diagnostic.title).foregroundStyle(Color.dockSecondaryText)
                                    Spacer()
                                    if diagnostic.taskID != nil { LucideImage(systemName: "chevron.right") }
                                }
                                Text(diagnostic.detail).foregroundStyle(Color.dockSecondaryText).lineLimit(2)
                            }
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .dockListRow()
                        }
                        .buttonStyle(.plain)
                        .disabled(diagnostic.taskID == nil)
                    }
                }
            }

            // Keep the complete board in one scan line. Each lane owns its
            // vertical content while the board itself scrolls horizontally,
            // so cards remain visible from the top of the board to the bottom
            // without creating a second row of lanes.
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(KanbanLane.allCases) { lane in
                        kanbanLane(lane)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            if let state = control.refreshState(for: "kanban.board"), let error = state.error {
                HStack(alignment: .top, spacing: 8) {
                    LucideImage(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .medium))
                    Text(state.isStale ? "Showing the last successful board. \(error)" : error)
                        .font(.system(.body))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color.dockWarning)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(Color.dockWarning.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.dockWarning.opacity(0.34), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)

            if let task = selectedKanbanTask {
                kanbanDetailPanel(task)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.dockEase(duration: 0.2), value: selectedKanbanTask?.id)
    }

    private var kanbanOverviewMetrics: some View {
        let readyCount = control.kanbanTasks.filter { kanbanLane(for: $0) == .ready }.count
        let runningCount = control.kanbanTasks.filter { kanbanLane(for: $0) == .running }.count
        let blockedCount = control.kanbanTasks.filter { kanbanLane(for: $0) == .blocked }.count

        return HStack(spacing: 0) {
            kanbanMetric(value: "\(control.kanbanTasks.count)", label: "TOTAL", tint: .dockAccent)
            kanbanMetric(value: "\(readyCount)", label: "READY", tint: readyCount > 0 ? .dockAccent : .dockSecondaryText)
            kanbanMetric(value: "\(runningCount)", label: "RUNNING", tint: runningCount > 0 ? .dockAccent : .dockSecondaryText)
            kanbanMetric(value: "\(blockedCount)", label: "BLOCKED", tint: blockedCount > 0 ? .dockWarning : .dockSuccess)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.dockSurface.opacity(0.34))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.dockBorderLight, lineWidth: 0.5)
        }
    }

    private func kanbanMetric(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Color.dockMetadataText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .overlay(alignment: .trailing) {
            Color.dockBorderLight.frame(width: 0.5, height: 28)
        }
    }


    private var kanbanFilterControls: some View {
        HStack(spacing: 6) {
            Button {
                isShowingKanbanStatusFilter.toggle()
            } label: {
                kanbanFilterChip(kanbanStatusFilter == "All" ? "Status" : kanbanStatusFilter, icon: "line.3.horizontal.decrease")
            }
            .popover(isPresented: $isShowingKanbanStatusFilter, arrowEdge: .bottom) {
                kanbanStatusPopover
            }
            Button {
                isShowingKanbanAssigneeFilter.toggle()
            } label: {
                kanbanFilterChip(kanbanAssigneeFilter == "All" ? "Assignee" : kanbanAssigneeFilter, icon: "person.2.fill")
            }
            .popover(isPresented: $isShowingKanbanAssigneeFilter, arrowEdge: .bottom) {
                kanbanAssigneePopover
            }
            Button {
                kanbanMineOnly.toggle()
                applyKanbanFilters()
            } label: {
                kanbanFilterChip("Mine", icon: "person.fill", isSelected: kanbanMineOnly)
            }
            Menu {
                ForEach(["updated", "created-desc", "priority-desc", "title"], id: \.self) { value in
                    Button(value.uppercased()) { kanbanSort = value; applyKanbanFilters() }
                }
            } label: {
                kanbanFilterChip(kanbanSort == "updated" ? "Sort" : kanbanSort, icon: "arrow.up.arrow.down")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .padding(6)
        .background(Color.dockSurface2.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.dockBorderLight, lineWidth: 0.5)
        }
        .disabled(control.isKanbanRefreshPending)
    }

    private func kanbanFilterChip(_ title: String, icon: String, isSelected: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron-down")
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
                Image(systemName: "circle.grid.2x2.fill")
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
                        LucideImage(systemName: lane.icon)
                            .foregroundStyle(lane.color)
                    } else {
                        Image(systemName: "circle.grid.2x2.fill")
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
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.dockAccent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? Color.dockAccent.opacity(0.11) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var kanbanAssigneePopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
                Text("ASSIGNEE")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(Color.dockMetadataText)
                Spacer()
                Text("\(control.kanbanAssignees.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            ScrollView {
                LazyVStack(spacing: 3) {
                    kanbanAssigneeRow("All", isSelected: kanbanAssigneeFilter == "All")
                    ForEach(control.kanbanAssignees, id: \.self) { assignee in
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
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.dockAccent.opacity(0.18))
                        Image(systemName: "person.2.fill")
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
                        kanbanAssigneeAvatar(assignee)
                    }
                }
                Text(assignee == "All" ? "All assignees" : assignee)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.dockAccent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? Color.dockAccent.opacity(0.11) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func kanbanAssigneeAvatar(_ assignee: String, size: CGFloat = 30) -> some View {
        let hue = Double(assignee.utf8.reduce(0) { ($0 + Int($1)) % 360 }) / 360
        let initial = String(assignee.prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(hue: hue, saturation: 0.62, brightness: 0.82))
            Text(initial)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
        }
        .frame(width: size, height: size)
    }

    private func applyKanbanFilters() {
        control.refreshVisibleKanban(filter: KanbanListFilter(
            status: kanbanStatusFilter == "All" ? nil : kanbanStatusFilter.lowercased(),
            assignee: kanbanAssigneeFilter == "All" ? nil : kanbanAssigneeFilter,
            mine: kanbanMineOnly,
            sessionID: kanbanCurrentSessionOnly ? model.kanbanSessionID : nil,
            sort: kanbanSort
        ))
    }

    private var createKanbanTaskForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LucideImage(systemName: "plus")
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
                            LucideImage(systemName: "arrow.up.right")
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
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(12)
        .background(Color.dockSurface2)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.dockBorder, lineWidth: 0.5))
    }

    private func kanbanLane(_ lane: KanbanLane) -> some View {
        let laneTasks = control.kanbanTasks.filter { kanbanLane(for: $0) == lane }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                LucideImage(systemName: lane.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(lane.color)
                Text(lane.rawValue.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.dockSecondaryText)
                Spacer()
                Text("\(laneTasks.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(lane.color)
            }
            .padding(.horizontal, 3)
            Rectangle().fill(lane.color.opacity(0.55)).frame(height: 1)

            if laneTasks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lane.emptyTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockSecondaryText)
                    Text(lane.emptyDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockMetadataText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
                .padding(.horizontal, 12)
                .background(Color.dockSurface2)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(laneTasks) { task in
                        kanbanTaskCard(task, lane: lane)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 260, alignment: .topLeading)
        .frame(minHeight: 178, alignment: .topLeading)
        .background(Color.black.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.dockBorder, lineWidth: 0.5))
    }

    private func kanbanTaskCard(_ task: KanbanTaskSummary, lane: KanbanLane) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(lane.color)
                    .frame(width: 8, height: 8)
                if let priority = task.priority, !priority.isEmpty {
                    kanbanMetadataPill("P\(priority)", tint: Color.dockWarning)
                }
                if let assignee = task.assignee, !assignee.isEmpty {
                    kanbanAssigneePill(assignee)
                }
                Spacer(minLength: 4)
                Text(task.id)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
            }
            Text(task.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.dockSecondaryText)
                .lineLimit(3)
            if let detail = kanbanCardDetail(task.detail) {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(2)
            }

            if let step = task.currentStepKey, !step.isEmpty {
                Text("STEP · \(step)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dockAccent)
                    .lineLimit(1)
            }
            if let event = task.latestEventKind,
               !event.isEmpty,
               !isRedundantKanbanStatus(event, for: lane) {
                HStack(spacing: 5) {
                    Text(event.replacingOccurrences(of: "_", with: " ").uppercased())
                    if let eventAt = task.latestEventAt {
                        Text(eventAt, style: .relative)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.dockMetadataText)
                if let note = task.latestEventNote, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(2)
                }
            } else if let startedAt = task.startedAt {
                Text("STARTED \(startedAt, style: .relative)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.dockMetadataText)
            }

            Rectangle()
                .fill(Color.dockBorderLight)
                .frame(height: 0.5)

            HStack(spacing: 10) {
                if control.capabilityAvailable("kanban.taskDetails") {
                    Button {
                        selectedKanbanTask = task
                        control.loadKanbanTask(task)
                    } label: {
                        kanbanActionChip(
                            title: "Details",
                            icon: "doc.text",
                            pendingTitle: "Loading…",
                            isPending: control.isLoadingKanbanDetail,
                            tint: Color.dockSecondaryText,
                            filled: false
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(control.isLoadingKanbanDetail)
                }
                if lane == .done, control.capabilityAvailable("kanban.archive") {
                    kanbanActionButton("ARCHIVE", task: task, action: .archive)
                } else if lane == .blocked, control.capabilityAvailable("kanban.unblock") {
                    kanbanActionButton("UNBLOCK", task: task, action: .unblock)
                } else {
                    if control.capabilityAvailable("kanban.complete") {
                        kanbanActionButton("DONE", task: task, action: .complete)
                    }
                    if control.capabilityAvailable("kanban.block") {
                        kanbanActionButton("BLOCK", task: task, action: .block)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.dockSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
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

    private func kanbanAssigneePill(_ assignee: String) -> some View {
        HStack(spacing: 5) {
            if let bot = botMode.visibleBots.first(where: {
                $0.id.caseInsensitiveCompare(assignee) == .orderedSame
            }) {
                BotAvatarView(bot: bot, imageData: botMode.avatarImages[bot.id], size: 18)
            } else {
                kanbanAssigneeAvatar(assignee, size: 18)
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

    private func kanbanActionChip(
        title: String,
        icon: String,
        pendingTitle: String,
        isPending: Bool,
        tint: Color,
        filled: Bool = true
    ) -> some View {
        HStack(spacing: 5) {
            if isPending {
                ProgressView()
                    .controlSize(.mini)
                    .tint(tint)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(isPending ? pendingTitle : title)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(filled ? tint.opacity(0.12) : Color.dockSurface2.opacity(0.8))
        .overlay {
            Capsule().stroke(tint.opacity(filled ? 0.18 : 0.28), lineWidth: 0.5)
        }
        .clipShape(Capsule())
        .contentShape(Capsule())
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

    private func kanbanCardDetail(_ detail: String?) -> String? {
        guard let detail else { return nil }
        let lines = detail
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("TASK_ID:") }
            .map { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "OBJECTIVE:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        let normalized = lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func kanbanDetailPanel(_ task: KanbanTaskSummary) -> some View {
        let lane = kanbanLane(for: task)
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

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("KANBAN TASK")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(Color.dockAccent)
                    Text(task.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    selectedKanbanTask = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.dockSecondaryText)
                        .frame(width: 28, height: 28)
                        .background(Color.dockSurface2)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close task details")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    if control.isLoadingKanbanDetail {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("LOADING HERMES TASK…")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.dockSecondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let detail = control.kanbanDetail {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(detail.title)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.dockSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 7) {
                                kanbanMetadataPill(detail.status.uppercased(), tint: laneColor)
                                if let priority = detail.priority {
                                    kanbanMetadataPill("P\(priority)", tint: Color.dockWarning)
                                }
                                if let assignee = detail.assignee {
                                    kanbanMetadataPill(assignee, tint: Color.dockSecondaryText)
                                }
                            }

                            if let body = detail.body, !body.isEmpty {
                                MarkdownMessageView(markdown: body)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.dockSurface2.opacity(0.55))
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }

                        if !control.kanbanAttachments.isEmpty {
                            DisclosureGroup("ATTACHMENTS  ·  \(control.kanbanAttachments.count)") {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(control.kanbanAttachments) { attachment in
                                        HStack {
                                            LucideImage(systemName: "paperclip")
                                            Text(attachment.name).lineLimit(1)
                                            Spacer()
                                            if let kind = attachment.kind { Text(kind) }
                                            if let size = attachment.sizeBytes {
                                                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                            }
                                        }
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.dockSecondaryText)
                                        .padding(.vertical, 4)
                                    }
                                }
                                .padding(.top, 5)
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.dockAccent)
                        }

                        Menu {
                            ForEach(KanbanMutationKind.allCases) { kind in
                                if control.capabilityAvailable(kind.capabilityID) {
                                    Button(kind.title) {
                                        kanbanMutationRequest = KanbanMutationRequest(task: task, kind: kind, value: "", reclaimFirst: false)
                                    }
                                }
                            }
                        } label: {
                            kanbanActionChip(title: "Task actions", icon: "ellipsis.circle", pendingTitle: "Task actions", isPending: false, tint: Color.dockAccent)
                        }
                        .menuStyle(.borderlessButton)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("RUN HISTORY  ·  \(detail.runs.count)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.dockSecondaryText)
                            if detail.runs.isEmpty {
                                Text("No run history returned by Hermes.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.dockMetadataText)
                            } else {
                                ForEach(detail.runs) { run in
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(run.status.uppercased())
                                            if let outcome = run.outcome { Text(outcome) }
                                            Spacer()
                                            if let elapsed = run.elapsed { Text(elapsed) }
                                        }
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.dockAccent)
                                        if let summary = run.summary {
                                            Text(summary)
                                                .font(.system(size: 12))
                                                .foregroundStyle(Color.dockSecondaryText)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .padding(.vertical, 7)
                                    .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
                                }
                            }
                        }
                    } else {
                        Text("Hermes did not return structured details for this task.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockWarning)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 340, idealWidth: 360, maxWidth: 420, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.dockBorder, lineWidth: 0.5)
        }
        .background(Color.dockCanvas)
    }

    private func kanbanLane(for task: KanbanTaskSummary) -> KanbanLane {
        let status = task.status.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        if ["done", "completed", "complete", "archived"].contains(status) { return .done }
        if ["blocked", "failed", "error"].contains(status) { return .blocked }
        switch status {
        case "triage": return .triage
        case "todo": return .todo
        case "ready": return .ready
        case "running", "active", "in_progress", "inprogress", "working": return .running
        case "review": return .review
        case "scheduled": return .scheduled
        default: return .todo
        }
    }

    private var canCreateKanbanTask: Bool {
        !kanbanTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func kanbanActionButton(_ label: String, task: KanbanTaskSummary, action: KanbanTaskAction) -> some View {
        let isPending = control.isActionPending(control.kanbanActionID(action, task: task))
        return Button {
            kanbanChangeRequest = KanbanChangeRequest(task: task, action: action)
            isShowingKanbanChangeConfirmation = true
        } label: {
            kanbanActionChip(
                title: label,
                icon: kanbanActionIcon(for: action),
                pendingTitle: "Updating…",
                isPending: isPending,
                tint: action == .block || action == .archive ? Color.dockWarning : Color.dockAccent
            )
        }
        .buttonStyle(.plain)
        .disabled(isPending)
    }

    private func kanbanActionIcon(for action: KanbanTaskAction) -> String {
        switch action {
        case .complete: "checkmark"
        case .block: "pause"
        case .unblock: "arrow.uturn.backward"
        case .archive: "archivebox"
        }
    }

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("SEARCH SOURCES")
            HStack(spacing: 8) {
                LucideImage(systemName: "magnifyingglass")
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
                        LucideImage(systemName: "xmark.circle.fill")
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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                emptyState(icon: "questionmark.circle", title: "No matches", detail: "Try a session title, project name, reminder, or Inbox detail.")
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
            LucideImage(systemName: result.reference.source == .appleReminder ? "checklist" : "circle.dotted")
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
                LucideImage(systemName: "chevron.right")
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
                emptyState(icon: "checkmark.circle", title: "Nothing needs your attention", detail: "Approvals, failures, clarifications, and due reminders will appear here.")
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
                LucideImage(systemName: item.kind == .approval ? "exclamationmark.triangle" : "circle.dotted")
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
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(isSelected ? Color.dockAccent : .clear, lineWidth: 0.5))
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
                    LucideImage(systemName: "pause.circle.fill")
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
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.dockWarning.opacity(0.55), lineWidth: 0.5))
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
                attentionRow(icon: "checkmark.circle", title: "All clear", detail: "No approvals, clarifications, or failures need a response.", color: .dockSuccess)
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
                        LucideImage(systemName: "waveform.path.ecg")
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
                                        Text(activity.sessionTitle)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(Color.dockMetadataText)
                                            .lineLimit(1)
                                    } else {
                                        Text(activity.sessionTitle)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Color.dockPrimaryText)
                                            .lineLimit(1)
                                    }
                                    Text(activity.activityName)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.dockMetadataText)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                LucideImage(systemName: "chevron.right")
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
                        LucideImage(systemName: "bolt.fill")
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
                                LucideImage(systemName: "person.2.fill")
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
                                LucideImage(systemName: "gearshape.2")
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
                                LucideImage(systemName: "terminal.fill")
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
                    Button {
                        if session.id != model.sessionID {
                            openProjectSession(session)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(session.id == model.sessionID ? Color.dockAccent : sessionStateColor(session.state)).frame(width: 5, height: 5)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                                HStack(spacing: 6) {
                                    if let projectID = control.projectIDBySessionID[session.id] {
                                        Text(projectID.uppercased())
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(Color.dockAccent)
                                    }
                                    Text(session.displayPreview ?? session.state.uppercased()).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            if session.id == model.sessionID {
                                Text("CURRENT").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dockAccent)
                            } else {
                                Text(session.state.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(sessionStateColor(session.state))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dockListRow()
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
                        LucideImage(systemName: "calendar.badge.clock")
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
                        LucideImage(systemName: "checklist")
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
                                    LucideImage(systemName: reminder.isOverdue ? "exclamationmark.circle" : "checklist")
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
                        LucideImage(systemName: "exclamationmark.triangle")
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
                        LucideImage(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.dockAccent)
                    }
                    .padding(12)
                    .dockGlassPane()
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.dockWarning.opacity(0.55), lineWidth: 0.5))
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
                    icon: "checkmark.circle",
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
                        LucideImage(systemName: "bolt.fill")
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
                                LucideImage(systemName: "person.2.fill")
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
                                    LucideImage(systemName: "chevron.right")
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
                                LucideImage(systemName: "gearshape.2")
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
                        LucideImage(systemName: "clock.arrow.circlepath")
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
                        LucideImage(systemName: "calendar.badge.clock")
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
                        LucideImage(systemName: "checklist")
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
                                    LucideImage(systemName: reminder.isOverdue ? "exclamationmark.circle" : "checklist")
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
                        LucideImage(systemName: "exclamationmark.triangle")
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
                        LucideImage(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.dockAccent)
                    }
                    .padding(12)
                    .dockGlassPane()
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.dockWarning.opacity(0.55), lineWidth: 0.5))
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
                LucideLabel("WORKSPACE", icon: "chevron.left")
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
                icon: "exclamationmark.circle",
                tint: attentionCount > 0 ? .dockWarning : .dockSuccess
            ) { select(.inbox) }
            todayPulseMetric(
                value: "\(runningCount)",
                label: "IN FLIGHT",
                icon: "bolt.fill",
                tint: runningCount > 0 ? .dockAccent : .dockSecondaryText
            ) { select(.session) }
            todayPulseMetric(
                value: "\(control.activeSessions.count)",
                label: "SESSIONS",
                icon: "bubble.left.and.bubble.right",
                tint: control.activeSessions.isEmpty ? .dockSecondaryText : .dockAccent
            ) { select(.session) }
            todayPulseMetric(
                value: "\(scheduledCount)",
                label: "SCHEDULED",
                icon: "calendar.badge.clock",
                tint: scheduledCount > 0 ? .dockSuccess : .dockSecondaryText
            ) { select(.automations) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.dockSurface.opacity(0.34))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.dockBorderLight, lineWidth: 0.5)
        }
    }

    private func todayPulseMetric(
        value: String,
        label: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    LucideImage(systemName: icon)
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.dockSurface.opacity(0.34))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                LucideImage(systemName: "scope").foregroundStyle(Color.dockAccent)
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
            LucideImage(systemName: readiness.state == .ready ? "checkmark.seal" : readiness.state == .blocked ? "xmark.octagon" : "exclamationmark.circle")
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
                if let sessionID, commandCenterPreferences.isPinnedReference(sessionID) {
                    Text("PINNED").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dockAccent)
                }
                if let sessionID {
                    Button(commandCenterPreferences.isPinnedReference(sessionID) ? "UNPIN" : "PIN") { commandCenterPreferences.togglePinnedReference(sessionID) }
                        .buttonStyle(.borderless).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dockAccent)
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
                LucideImage(systemName: workflow.repository.isGitRepository ? "arrow.triangle.branch" : "folder")
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
                                    LucideLabel(branch, icon: "checkmark")
                                } else {
                                    Text(branch)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        LucideImage(systemName: "arrow.triangle.branch")
                        Text("SWITCH BRANCH")
                        LucideImage(systemName: "chevron.down")
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
            LucideImage(systemName: "exclamationmark.triangle")
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
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.dockWarning.opacity(0.55), lineWidth: 0.5))
    }

    private var unavailableSetupCapabilities: [CapabilityState] {
        control.capabilities.filter {
            ["reminders", "notes", "calendar", "messaging", "email"].contains($0.id) && !$0.isAvailable
        }
    }

    private func attentionRow(icon: String, title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            LucideImage(systemName: icon).font(.system(size: 12)).foregroundStyle(color).frame(width: 14)
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
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selectedAgentID == id ? color.opacity(0.5) : Color.dockBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 9))
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
                        LucideLabel("COPY \(command)", icon: "doc.on.doc")
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
            Text("\(capabilityInventorySnapshot.verifiedCount) READY").foregroundStyle(Color.dockSuccess)
            Text("\(capabilityInventorySnapshot.unverifiedCount) REVIEW").foregroundStyle(Color.dockAccent)
            Text("\(capabilityInventorySnapshot.missingCount + capabilityInventorySnapshot.unsupportedCount) MISSING/UNSUPPORTED")
                .foregroundStyle(Color.dockWarning)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.dockSecondaryText)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var agentUpdateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Hermes Agent Update")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.dockPrimaryText)
                Spacer()
                Button("RESTART") { isShowingDockRestartConfirmation = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
                    .disabled(agentUpdateService.isBusy)
                if agentUpdateService.phase == .checking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("CHECKING…")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                } else {
                    Button("CHECK") { agentUpdateService.checkForUpdates() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10, weight: .semibold))
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
            case .upToDate: agentUpdateCheckedContent(statusText: "UP TO DATE", statusColor: .dockSuccess, showsUpdateButton: false)
            case .updateAvailable: agentUpdateCheckedContent(statusText: "UPDATE AVAILABLE", statusColor: .dockWarning, showsUpdateButton: true)
            case .checkFailed(let reason): agentUpdateCheckFailedContent(reason)
            case .updating: agentUpdateProgressContent
            case .updateSucceeded: agentUpdateSucceededContent
            case .updateFailed(let reason): agentUpdateFailedContent(reason)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.dockSurface.opacity(0.34))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.dockBorderLight, lineWidth: 0.5)
        }
        .confirmationDialog("Update Hermes Agent?", isPresented: $isShowingAgentUpdateConfirmation) {
            Button("Update Hermes Agent") { agentUpdateService.performUpdate() }
                .disabled(agentUpdateService.isBusy)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: "The Dock will run the allow-listed command `\(HermesUpdateService.updateCommandDisplay)`. It pulls the latest code from NousResearch/hermes-agent, reinstalls dependencies, and may migrate new configuration options. Running Hermes sessions keep the current version until Hermes restarts.")
        }
        .confirmationDialog("Restart Hermes Agent Dock?", isPresented: $isShowingDockRestartConfirmation) {
            Button("Restart Dock", role: .destructive) { onRestartDock() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This closes the current Hermes backend and relaunches the Dock. Unsaved draft text and the current session view will be cleared; the next chat will load the currently selected Codex account and global model.")
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
                        Button("RELEASE") { NSWorkspace.shared.open(url) }
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
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.dockAccent)
                        .disabled(!agentUpdateService.canStartUpdate)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(statusColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text("SOURCE  ·  NousResearch/hermes-agent" + (agentUpdateService.lastChecked.map { "  ·  checked " + HumanDateFormatting.timeOnly($0) } ?? ""))
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("UPDATING HERMES AGENT")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.dockAccent)
                Spacer()
                TimelineView(.periodic(from: agentUpdateService.updateStartedAt ?? Date(), by: 1)) { context in
                    Text(agentUpdateElapsedText(until: context.date))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockSecondaryText)
                }
            }
            ProgressView()
                .progressViewStyle(.linear)
                .tint(Color.dockAccent)
            if let latestLine = agentUpdateService.logLines.last {
                Text(latestLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(2)
            }
            agentUpdateLogTail
        }
    }

    private var agentUpdateSucceededContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                LucideImage(systemName: "checkmark.circle.fill")
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
            Text("The Dock will restart automatically so new sessions run the updated agent.")
                .font(.system(size: 12))
                .foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
            agentUpdateLogTail
        }
    }

    private func agentUpdateFailedContent(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                LucideImage(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockDestructive)
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("The Dock never retries an update automatically. Review the output below and run CHECK before trying again.")
                .font(.system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            agentUpdateLogTail
        }
    }

    private var agentUpdateLogTail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(agentUpdateService.logLines.suffix(120).reversed().enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 110)
    }

    private func agentUpdateElapsedText(until now: Date) -> String {
        guard let started = agentUpdateService.updateStartedAt else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(started)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var coreContent: some View {
        VStack(alignment: .leading, spacing: 17) {
            coreOverview
            settingsCommandBar

            settingsDisclosure(title: "Agent update", subtitle: "Installed version and update channel", icon: "refresh-cw", isExpanded: $isAgentUpdateExpanded) {
                agentUpdateSection
            }

            settingsDisclosure(title: "Appearance & pets", subtitle: appearanceSubtitle, icon: "sparkles", isExpanded: $isAppearanceExpanded) {
                appearanceSection
            }

            if let insights = control.insightsSummary {
                settingsDisclosure(title: "Usage insights", subtitle: "Last \(insights.days) days", icon: "chart.bar", isExpanded: $isInsightsExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        diagnosticRow(label: "SESSIONS", value: "\(insights.sessions)", color: .dockAccent)
                        diagnosticRow(label: "MESSAGES", value: "\(insights.messages)", color: .dockMetadataText)
                    }
                }
            }

            emergencyStopSection

            if !unavailableSetupCapabilities.isEmpty {
                settingsDisclosure(title: "Setup needed", subtitle: "\(unavailableSetupCapabilities.count) integrations need attention", icon: "exclamationmark.triangle", isExpanded: $isSetupExpanded, tint: .dockWarning) {
                    ForEach(unavailableSetupCapabilities) { capability in
                        providerSetupCard(capability)
                    }
                }
            }

            settingsDisclosure(title: "Capabilities", subtitle: "Permission and integration readiness", icon: "checkmark.shield", isExpanded: $isCapabilitiesExpanded) {
                projectionRefreshNotice("core")
                capabilityInventorySummary
                if capabilityInventorySnapshot.states.isEmpty {
                    emptyState(
                        icon: "refresh-cw",
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
            if control.projectFacts != nil || control.verification != nil {
                settingsDisclosure(title: "Verification", subtitle: "Project facts and delivery evidence", icon: "checkmark.seal", isExpanded: $isVerificationExpanded) {
                    if let facts = control.projectFacts {
                    diagnosticRow(label: "PROJECT", value: facts.manifests.joined(separator: ", ").isEmpty ? "Code workspace" : facts.manifests.joined(separator: ", "), color: Color.dockAccent)
                    if !facts.packageManagers.isEmpty { diagnosticRow(label: "TOOLS", value: facts.packageManagers.joined(separator: ", "), color: Color.dockMetadataText) }
                    if !facts.contextFiles.isEmpty { diagnosticRow(label: "CONTEXT", value: facts.contextFiles.joined(separator: ", "), color: Color.dockMetadataText) }
                    ForEach(VerificationRecipeBuilder.make(facts: facts, repository: workflow.repository)) { recipe in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recipe.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dockSecondaryText)
                                Text(recipe.command).font(.system(size: 11)).foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                            }
                            Spacer()
                            Button("COPY") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(recipe.command, forType: .string)
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.dockAccent)
                            Button("ASK HERMES") {
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
                    let stateColor: Color = verification.state == .passed ? .dockSuccess : (verification.state == .failed ? .dockDestructive : .dockWarning)
                    diagnosticRow(label: "DELIVERY", value: deliveryEvidence.title.uppercased(), color: deliveryEvidence.state == .current ? .dockSuccess : .dockWarning)
                    diagnosticRow(label: "STATUS", value: verification.state.rawValue.uppercased(), color: stateColor)
                    if let evidence = verification.evidence {
                        if let command = evidence.canonicalCommand ?? evidence.command { diagnosticRow(label: "EVIDENCE", value: command, color: Color.dockMetadataText) }
                        if let scope = evidence.scope { diagnosticRow(label: "SCOPE", value: scope.uppercased(), color: scope == "targeted" ? Color.dockWarning : Color.dockMetadataText) }
                        if let exitCode = evidence.exitCode { diagnosticRow(label: "EXIT", value: String(exitCode), color: exitCode == 0 ? Color.dockSuccess : Color.dockDestructive) }
                        if let adapter = evidence.adapter { diagnosticRow(label: "ADAPTER", value: adapter, color: Color.dockMetadataText) }
                        if let capturedAt = evidence.capturedAt { diagnosticRow(label: "CAPTURED", value: ISO8601DateFormatter().string(from: capturedAt), color: Color.dockMetadataText) }
                        if let repository = evidence.repositoryIdentity { diagnosticRow(label: "REPOSITORY", value: repository, color: Color.dockMetadataText) }
                        if let commit = evidence.commitFingerprint { diagnosticRow(label: "COMMIT", value: commit, color: Color.dockMetadataText) }
                        if let target = evidence.targetFingerprint { diagnosticRow(label: "TARGET", value: target, color: Color.dockMetadataText) }
                        if let diff = evidence.diffFingerprint { diagnosticRow(label: "DIFF", value: diff, color: Color.dockMetadataText) }
                        if let rules = evidence.rulesScopeDetail { diagnosticRow(label: "RULES", value: rules, color: Color.dockMetadataText) }
                        if let staleReason = deliveryEvidence.staleReason { diagnosticRow(label: "STALE", value: staleReason, color: Color.dockWarning) }
                    }
                    }
                }
            }
            let canSteerSession = model.status == .working && model.sessionID != nil
            if control.sessionUsage != nil || control.sessionContext != nil || canSteerSession || !control.restoreCheckpoints.isEmpty || control.isLoadingCheckpoints {
                settingsDisclosure(title: "Session cockpit", subtitle: "Context, usage, and active-turn controls", icon: "waveform.path.ecg", isExpanded: $isSessionCockpitExpanded) {
                    if let usage = control.sessionUsage {
                    diagnosticRow(label: "TOKENS", value: "\(usage.totalTokens) total  ·  \(usage.inputTokens) in  ·  \(usage.outputTokens) out", color: Color.dockAccent)
                    if let model = usage.model { diagnosticRow(label: "MODEL", value: model, color: Color.dockMetadataText) }
                }
                if let context = control.sessionContext {
                    if let percent = context.contextPercent {
                        diagnosticRow(label: "CONTEXT", value: String(format: "%.1f%%", percent), color: percent >= 90 ? Color.dockDestructive : percent >= 80 ? Color.dockWarning : Color.dockSuccess)
                    }
                    if !context.categories.isEmpty {
                        ForEach(context.categories.prefix(6)) { category in
                            diagnosticRow(label: category.label.uppercased(), value: "\(category.tokens) tokens", color: Color.dockMetadataText)
                        }
                    }
                }
                let pressure = SessionContextPressure.make(percent: control.sessionContext?.contextPercent)
                if pressure != .unavailable {
                    let color: Color = pressure == .critical ? .dockDestructive : pressure == .warning ? .dockWarning : .dockSuccess
                    diagnosticRow(label: "CONTEXT PRESSURE", value: pressure.rawValue.uppercased(), color: color)
                    if pressure == .warning || pressure == .critical {
                        Text("Create a handoff or branch before context pressure grows. Compression remains an explicit confirmed action.")
                            .font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
                        HStack(spacing: 8) {
                            TextField("Handoff focus (optional)", text: $handoffFocus).textFieldStyle(.dockGlass)
                            Button("HANDOFF") { isShowingHandoffConfirmation = true }
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
                                Button("DIFF") { control.loadCheckpointDiff(checkpoint) }
                                    .buttonStyle(.borderless).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dockAccent)
                                Button("RESTORE") { checkpointForRestore = checkpoint }
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
                    Button("STEER") {
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
                            .foregroundStyle(sessionSteerFeedback.contains("REJECTED") ? Color.dockWarning : Color.dockSuccess)
                    }
                    }
                }
            }
            if let budget = control.promptBudget {
                Divider().overlay(Color.dockBorderLight)
                sectionLabel("PROMPT BUDGET")
                let percent = budget.percent ?? 0
                let color: Color = percent >= 95 ? .dockDestructive : (percent >= 85 ? .dockWarning : .dockAccent)
                diagnosticRow(label: "TOKENS", value: "\(budget.totalTokens)" + (budget.tokenLimit.map { " / \($0)" } ?? ""), color: color)
                if budget.percent != nil { diagnosticRow(label: "USED", value: String(format: "%.1f%%", percent), color: color) }
                if let model = budget.model { diagnosticRow(label: "MODEL", value: model, color: Color.dockMetadataText) }
            }
            settingsDisclosure(title: "Session actions", subtitle: "Rename, redirect, branch, or pause the active session", icon: "bolt.horizontal", isExpanded: $isSessionActionsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("New session title", text: $sessionRenameText)
                            .textFieldStyle(.dockGlass)
                        Button("RENAME") {
                            Task { if await control.renameActiveSession(sessionRenameText) { sessionRenameText = "" } }
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.dockAccent)
                        .disabled(sessionRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    HStack(spacing: 8) {
                        TextField("Redirect the active turn…", text: $sessionRedirectText)
                            .textFieldStyle(.dockGlass)
                        Button("REDIRECT") {
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
                        Button("BRANCH") { isShowingBranchConfirmation = true }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.dockAccent)
                            .disabled(!control.capabilityAvailable("rpc-sessions"))
                        TextField("Compression focus (optional)", text: $sessionCompressTopic)
                            .textFieldStyle(.dockGlass)
                        Button("COMPRESS") { isShowingCompressConfirmation = true }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.dockAccent)
                            .disabled(!control.capabilityAvailable("rpc-sessions"))
                    }
                    HStack(spacing: 8) {
                        Button("UNDO LAST TURN") { isShowingUndoConfirmation = true }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.dockWarning)
                        Button(control.delegationPaused ? "RESUME DELEGATION" : "PAUSE DELEGATION") { isShowingDelegationConfirmation = true }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.dockWarning)
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
            }
            if !control.activeAgents.isEmpty || !control.processes.isEmpty {
                Divider().overlay(Color.dockBorderLight)
                sectionLabel("RUNTIME CONTROLS")
                ForEach(control.activeAgents) { agent in
                    HStack {
                        LucideImage(systemName: "person.2.fill").foregroundStyle(Color.dockAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.name).foregroundStyle(Color.dockPrimaryText)
                            Text(agent.state.uppercased()).foregroundStyle(Color.dockMetadataText)
                        }
                        Spacer()
                        if let native = model.activeSubagents.first(where: { $0.id == agent.id }), !model.isSyntheticSubagent(native.id) {
                            Button("INTERRUPT") { pendingAgentID = native.id }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Color.dockWarning)
                        }
                    }
                    .font(.system(size: 11))
                }
                ForEach(control.processes) { process in
                    HStack {
                        LucideImage(systemName: "gearshape.2").foregroundStyle(Color.dockSecondaryText)
                        Text(process.name).foregroundStyle(Color.dockPrimaryText)
                        Spacer()
                        Button("STOP") { pendingProcess = process }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.dockWarning)
                    }
                    .font(.system(size: 11))
                }
            }
            if !control.diagnostics.isEmpty {
                settingsDisclosure(title: "Read-only diagnostics", subtitle: "Observed runtime detail", icon: "stethoscope", isExpanded: $isDiagnosticsExpanded) {
                    ForEach(control.diagnostics) { diagnostic in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(diagnostic.isAvailable ? Color.dockSuccess : Color.dockWarning)
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
            if !control.journeyNodes.isEmpty || control.sessionStoreStatus != nil || control.memoryHealthStatus != nil {
                settingsDisclosure(title: "Learning & storage", subtitle: "Session store, memory, and journey state", icon: "internaldrive", isExpanded: $isLearningExpanded) {
                    ForEach([control.sessionStoreStatus, control.memoryHealthStatus].compactMap { $0 }) { status in
                    diagnosticRow(label: status.title.uppercased(), value: status.detail, color: status.isAvailable ? Color.dockSuccess : Color.dockWarning)
                }
                if !control.journeyNodes.isEmpty {
                    Text("JOURNEY  ·  \(control.journeyNodes.count) NODES")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dockMetadataText)
                    ForEach(control.journeyNodes.prefix(8)) { node in
                        HStack(spacing: 7) {
                            Circle().fill(node.state == "active" ? Color.dockSuccess : Color.dockSecondaryText).frame(width: 5, height: 5)
                            Text(node.label).font(.system(size: 12)).foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                            Spacer()
                            Text([node.kind, node.useCount.map { "\($0)x" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
                        }
                    }
                    }
                }
            }
            Divider().overlay(Color.dockBorderLight)
            sectionLabel("NOTIFICATIONS")
            // Notifications toggle row with space-between layout so the switch is placed at the far right end
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Completion alerts")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockPrimaryText)
                    Text("Notify when Hermes finishes a request while the Dock is hidden.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockMetadataText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle("", isOn: Binding(
                    get: { model.completionNotificationsEnabled },
                    set: { model.setCompletionNotificationsEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Color.dockAccent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider().overlay(Color.dockBorderLight)
            sectionLabel("QUICK CAPTURE")
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open Hermes Control")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockPrimaryText)
                    Text("Double-press Command to focus Ask from any app.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockMetadataText)
                }
                Spacer()
                Text("⌘  ⌘")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockAccent)
            }
            settingsDisclosure(title: "Runtime configuration", subtitle: "Default model, tools, skills, and plugins", icon: "gearshape.2", isExpanded: $isRuntimeConfigurationExpanded) {
            HStack {
                Text("HERMES RUNTIME")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
                Spacer()
                Button(action: { model.refreshRuntimeConfiguration() }) {
                    if model.isLoadingRuntimeConfiguration {
                        ProgressView().controlSize(.small).tint(Color.dockAccent)
                    } else {
                        LucideImage(systemName: "refresh-cw")
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
                diagnosticRow(label: "MODEL", value: configuration.model ?? "NOT CONFIGURED", color: configuration.model == nil ? Color.dockWarning : Color.dockSuccess)
                diagnosticRow(label: "PROVIDER", value: configuration.provider ?? "NOT CONFIGURED", color: configuration.provider == nil ? Color.dockWarning : Color.dockSuccess)
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
                                        LucideImage(systemName: "checkmark")
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
                            LucideImage(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.dockSecondaryText)
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 36)
                        .background(Color.dockControlSurface)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.dockBorder, lineWidth: 0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                sectionLabel("EXECUTION")
                if let turns = configuration.maxTurns {
                    diagnosticRow(label: "MAX TURNS", value: turns, color: Color.dockSecondaryText)
                }
                if let timeout = configuration.terminalTimeout {
                    diagnosticRow(label: "TERMINAL TIMEOUT", value: "\(timeout)S", color: Color.dockSecondaryText)
                }

                Divider().overlay(Color.dockBorderLight)
                sectionLabel("INSTALLED SKILLS  ·  \(configuration.skills.count)")
                configurationList(
                    configuration.skills,
                    empty: "No enabled skills reported by Hermes.",
                    isExpanded: isShowingAllSkills,
                    onToggle: { isShowingAllSkills.toggle() }
                )

                Divider().overlay(Color.dockBorderLight)
                sectionLabel("MCP SERVERS  ·  \(configuration.mcpServers.count)")
                configurationList(configuration.mcpServers, empty: "No MCP servers configured in Hermes.")
                if control.mcpInventoryAvailable {
                    if control.mcpServers.isEmpty {
                        Text("Hermes reports no configured MCP connections.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockMetadataText)
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(control.mcpServers) { server in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(server.isEnabled ? Color.dockSuccess : Color.dockSecondaryText)
                                        .frame(width: 6, height: 6)
                                        .padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(server.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(Color.dockPrimaryText)
                                        Text("\(server.transport)  ·  \(server.tools)")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.dockMetadataText)
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text(server.isEnabled ? "ENABLED" : "DISABLED")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(server.isEnabled ? Color.dockSuccess : Color.dockSecondaryText)
                                        if control.capabilityAvailable("mcp.test") {
                                            Button { control.testMCP(server) } label: {
                                                DockActionLabel(
                                                    title: "TEST",
                                                    pendingTitle: "TESTING…",
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
                }
                if model.sessionID != nil {
                    Button { isShowingMCPReloadConfirmation = true } label: {
                        DockActionLabel(
                            title: "RELOAD MCP TOOLS",
                            pendingTitle: "RELOADING…",
                            isPending: control.isActionPending(control.reloadMCPActionID)
                        )
                    }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockAccent)
                        .disabled(control.isActionPending(control.reloadMCPActionID))
                }

                Divider().overlay(Color.dockBorderLight)
                sectionLabel("COMMAND ALLOWLIST  ·  \(control.commandAllowlistEntries?.count ?? 0)")
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
                    sectionLabel("ENABLED PLUGINS  ·  \(configuration.plugins.count)")
                    configurationList(configuration.plugins, empty: "")
                }
            } else {
                emptyState(icon: "exclamationmark.triangle", title: "Runtime unavailable", detail: "Hermes configuration could not be read. Start Hermes, then refresh.")
            }
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
            guard let configuration = model.runtimeConfiguration,
                  let matching = options.first(where: { $0.model == configuration.model && $0.provider == configuration.provider }) else { return }
            selectedModelID = matching.id
        }
    }

    private var appearanceSubtitle: String {
        guard let projection = control.appearanceProjection,
              control.appearanceProjectionAvailable else {
            return "Skin and installed-pet inventory unavailable"
        }
        return "\(projection.skins.count) skins · \(projection.installedPets.count) installed pets"
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !control.appearanceProjectionAvailable {
                emptyState(
                    icon: "sparkles",
                    title: "Appearance inventory unavailable",
                    detail: "Hermes did not return a readable skin and installed-pet projection. Refresh Settings to retry."
                )
            } else if let projection = control.appearanceProjection {
                if !projection.skins.isEmpty {
                    settingsCategoryDisclosure(title: "SKINS", count: projection.skins.count, readyCount: projection.skins.filter(\.isActive).count, isExpanded: .constant(true)) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(projection.skins, id: \.id) { skin in
                                diagnosticRow(label: skin.isActive ? "ACTIVE" : "SKIN", value: skin.name, color: skin.isActive ? .dockSuccess : .dockMetadataText)
                            }
                        }
                    }
                }
                if !projection.installedPets.isEmpty {
                    settingsCategoryDisclosure(title: "INSTALLED PETS", count: projection.installedPets.count, readyCount: projection.installedPets.count, isExpanded: .constant(true)) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(projection.installedPets, id: \.id) { pet in
                                diagnosticRow(label: "PET", value: pet.name, color: .dockMetadataText)
                            }
                        }
                    }
                }
                if projection.skins.isEmpty && projection.installedPets.isEmpty {
                    emptyState(icon: "sparkles", title: "No installed appearance items", detail: "Hermes reported no readable skins or installed pets.")
                }
                Text("Switching skins or pets remains copy-only until Hermes publishes a verified mutation contract.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockMetadataText)
            }
        }
    }

    private var emergencyStopSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                LucideImage(systemName: control.emergencyStopActive == true ? "pause.circle.fill" : "play.circle")
                    .foregroundStyle(control.emergencyStopActive == true ? Color.dockWarning : Color.dockSecondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(control.emergencyStopActive == true ? "NEW WORK PAUSED" : control.emergencyStopActive == false ? "DISPATCH RESUMED" : "DISPATCH STATUS UNKNOWN")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                    Text(control.emergencyStopMessage ?? "Pause or resume records this Dock action; Hermes does not expose a stable ESTOP status contract.")
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
                        title: control.emergencyStopActive == true ? "RESUME" : "PAUSE",
                        pendingTitle: "UPDATING…",
                        isPending: control.isActionPending(control.emergencyStopActionID),
                        tint: control.emergencyStopActive == true ? .dockSuccess : .dockWarning
                    )
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(control.emergencyStopActive == true ? Color.dockSuccess : Color.dockWarning)
                .disabled(control.isActionPending(control.emergencyStopActionID))
            }
        }
        .padding(12)
        .dockGlassPane()
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
                LucideImage(systemName: "refresh-cw")
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
        icon: String,
        isExpanded: Binding<Bool>,
        tint: Color = .dockAccent,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.dockEase(duration: 0.18)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    LucideImage(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 24, height: 24)
                        .background(tint.opacity(isExpanded.wrappedValue ? 0.13 : 0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.dockPrimaryText)
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    Spacer(minLength: 10)
                    LucideImage(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.dockSecondaryText)
                        .frame(width: 20, height: 28)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(isExpanded.wrappedValue ? "expanded" : "collapsed")")

            if isExpanded.wrappedValue {
                Divider().overlay(Color.dockBorderLight)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.vertical, 14)
            }
        }
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
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
                        .foregroundStyle(readyCount == count ? Color.dockSuccess : Color.dockWarning)
                    LucideImage(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionLabel("PROVIDER QUOTA")
                Spacer()
                if control.refreshState(for: "provider.quota")?.isRefreshing == true {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Refreshing…")
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.dockSecondaryText)
                    .transition(.opacity)
                }
                if let lastSuccess = control.refreshState(for: "provider.quota")?.lastSuccess {
                    Text("Updated \(lastSuccess, format: .dateTime.hour().minute())")
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.dockMetadataText)
                }
                Button { control.refreshProviderQuota() } label: {
                LucideImage(systemName: "refresh-cw")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.dockAccent)
                .help("Refresh provider quota")
                .accessibilityLabel("Refresh provider quota")
            }

            quotaOverviewMetrics

            if !control.providerQuotas.isEmpty || control.refreshState(for: "provider.quota")?.isRefreshing != true {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(orderedQuotaProviders) { descriptor in
                        quotaProviderRow(descriptor)
                    }
                }
            }

            if let state = control.refreshState(for: "provider.quota"), let error = state.error {
                Text(state.isStale ? "Showing last successful data. \(error)" : error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $connectTarget) { descriptor in
            ProviderConnectSheet(descriptor: descriptor, control: control)
        }
    }

    private var quotaOverviewMetrics: some View {
        let connected = control.providerQuotas.count
        let attention = control.providerQuotas.filter { snapshot in
            snapshot.windows.contains { $0.threshold == .warning || $0.threshold == .critical }
        }.count
        let offline = max(0, orderedQuotaProviders.count - connected)

        return HStack(spacing: 0) {
            quotaMetric(value: "\(orderedQuotaProviders.count)", label: "PROVIDERS", tint: .dockAccent)
            quotaMetric(value: "\(connected)", label: "CONNECTED", tint: connected > 0 ? .dockAccent : .dockSecondaryText)
            quotaMetric(value: "\(attention)", label: "ATTENTION", tint: attention > 0 ? .dockWarning : .dockSuccess)
            quotaMetric(value: "\(offline)", label: "OFFLINE", tint: offline > 0 ? .dockSecondaryText : .dockSuccess)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.dockSurface.opacity(0.34))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.dockBorderLight, lineWidth: 0.5)
        }
    }

    private func quotaMetric(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Color.dockMetadataText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .overlay(alignment: .trailing) {
            Color.dockBorderLight.frame(width: 0.5, height: 28)
        }
    }

    private var orderedQuotaProviders: [QuotaProviderDescriptor] {
        quotaProviderOrder.compactMap(QuotaProviderCatalog.descriptor(for:))
    }

    @ViewBuilder
    private func quotaProviderRow(_ descriptor: QuotaProviderDescriptor) -> some View {
        Group {
            if let snapshot = control.providerQuotas.first(where: { $0.provider == descriptor.id }) {
                quotaProviderCard(snapshot)
            } else {
                quotaDisconnectedCard(descriptor)
            }
        }
        .onDrag {
            draggingQuotaProviderID = descriptor.id
            return NSItemProvider(object: descriptor.id as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: QuotaProviderDropDelegate(
                targetID: descriptor.id,
                order: $quotaProviderOrder,
                draggingID: $draggingQuotaProviderID
            )
        )
        .help("Drag to reorder providers")
    }

    private func quotaProviderCard(_ snapshot: ProviderQuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(quotaProviderColor(snapshot))
                    .frame(width: 8, height: 8)
                Text(snapshot.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                if let modelName = snapshot.model {
                    Text(modelName)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                }
                Spacer()
                if let detail = snapshot.safeDetail {
                    Text(detail.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.dockAccent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.dockAccent.opacity(0.10)))
                }
            }
            if snapshot.windows.isEmpty {
                Text("No quota windows were reported.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.dockSecondaryText)
            } else {
                ForEach(snapshot.windows) { window in quotaWindow(window) }
            }
        }
        .padding(10)
        .modifier(QuotaCardSurfaceModifier())
        .textSelection(.enabled)
    }

    private func quotaProviderColor(_ snapshot: ProviderQuotaSnapshot) -> Color {
        guard !snapshot.windows.isEmpty else { return .dockMetadataText }
        if snapshot.windows.contains(where: { $0.threshold == .critical }) { return .dockDestructive }
        if snapshot.windows.contains(where: { $0.threshold == .warning }) { return .dockWarning }
        return .dockSuccess
    }

    private func quotaDisconnectedCard(_ descriptor: QuotaProviderDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(descriptor.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dockSecondaryText)
                Spacer()
                Text("NOT CONNECTED")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.dockSurface4))
            }
            Text(descriptor.summary)
                .font(.system(size: 12))
                .foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
            if let diagnostic = control.providerQuotaDiagnostics[descriptor.id] {
                Text(diagnostic)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button {
                    connectTarget = descriptor
                } label: {
                    LucideLabel("Connect…", icon: "key.horizontal")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                if let website = descriptor.website {
                    Link("Website", destination: website)
                        .font(.system(size: 11))
                }
                Spacer()
            }
        }
        .padding(10)
        .modifier(QuotaCardSurfaceModifier())
        .opacity(0.78)
    }

    private func quotaWindow(_ window: ProviderQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.dockSecondaryText)
                Spacer()
                Text(window.remainingDisplay ?? (window.remainingPercent.map { String(format: "%.0f%% left", $0) } ?? "Availability reported without a percentage"))
                    .font(.caption.monospaced())
                    .foregroundStyle(quotaColor(window.threshold))
                    .multilineTextAlignment(.trailing)
            }
            if let percent = window.remainingPercent {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Color.dockSurface4)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(quotaColor(window.threshold))
                            .frame(width: max(3, geometry.size.width * percent / 100))
                    }
                }
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    if let daily = QuotaForecasting.dailyAllowance(for: window) {
                        GeometryReader { geometry in
                            let marker = QuotaForecasting.dailyBudgetMarker(for: window) ?? Double(daily)
                            Rectangle()
                                .fill(Color.dockWarning)
                                .frame(width: 2, height: 12)
                                .offset(
                                    // The marker shows the expected remaining
                                    // balance at this point in the quota cycle.
                                    x: min(max(0, geometry.size.width * CGFloat(marker) / 100), geometry.size.width - 2),
                                    y: -4
                                )
                                    .accessibilityLabel("Remaining balance target after today's budget: \(Int(marker)) percent")
                        }
                    }
                }
                .accessibilityLabel("\(window.label), \(Int(percent)) percent remaining")
            }
            if let forecast = QuotaForecasting.limitForecast(for: window) {
                HStack(spacing: 4) {
                    Spacer()
                    LucideImage(systemName: "flame.fill")
                    Text("Limit forecast: \(RelativeDateTimeFormatter().localizedString(for: forecast, relativeTo: Date()))")
                }
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(Color.dockWarning.opacity(0.82))
                .help("Estimated from the current average consumption rate; the provider does not report a depletion date.")
            }
            HStack {
                if let limit = window.limitDisplay {
                    Text(limit).foregroundStyle(Color.dockSecondaryText)
                } else if let daily = QuotaForecasting.dailyAllowance(for: window) {
                    Text("Available budget today: \(daily)%")
                        .foregroundStyle(Color.dockSecondaryText)
                        .help("Unused daily budget carries forward and increases the amount available today.")
                }
                Spacer()
                if let reset = window.resetsAt {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(RelativeDateTimeFormatter().localizedString(for: reset, relativeTo: Date()) + " · " + reset.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                    .multilineTextAlignment(.trailing)
                } else if let reset = window.resetsDisplay {
                    Text(reset).foregroundStyle(Color.dockSecondaryText)
                }
            }
            .font(.caption.monospaced())
        }
        .accessibilityElement(children: .combine)
        .padding(.vertical, 3)
        .overlay(alignment: .bottom) {
            Color.dockBorderLight.opacity(0.6)
                .frame(height: 0.5)
        }
    }

    private func quotaColor(_ threshold: ProviderQuotaThreshold) -> Color {
        switch threshold {
        case .healthy: .dockAccent
        case .warning: .dockWarning.opacity(0.78)
        case .critical: .dockDestructive
        case .unknown: .dockMetadataText
        }
    }

    private struct QuotaCardSurfaceModifier: ViewModifier {
        func body(content: Content) -> some View {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.dockSurface2.opacity(0.72))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.dockBorderLight, lineWidth: 0.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
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
            Text(label).font(.system(size: 12, weight: .semibold)).tracking(0.8).foregroundStyle(Color.dockMetadataText)
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(value).font(.system(size: 12, weight: .semibold)).tracking(0.35).foregroundStyle(Color.dockPrimaryText).lineLimit(1)
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
                                LucideImage(systemName: isExpanded ? "chevron.up" : "chevron.down")
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

    private func capabilityRow(icon: String, title: String, detail: String, state: String, color: Color) -> some View {
        HStack(spacing: 8) {
            LucideImage(systemName: icon).font(.system(size: 12)).foregroundStyle(color).frame(width: 14)
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

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LucideImage(systemName: icon).foregroundStyle(Color.dockMetadataText)
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

/// The session inspector is deliberately a separate surface from the workspace.
/// Workspace navigation answers "what needs attention overall?"; this panel
/// answers "what is happening in this conversation?".

private struct QuotaProviderDropDelegate: DropDelegate {
    let targetID: String
    @Binding var order: [String]
    @Binding var draggingID: String?

    func dropEntered(info: DropInfo) {
        guard let draggingID,
              draggingID != targetID,
              let sourceIndex = order.firstIndex(of: draggingID),
              let targetIndex = order.firstIndex(of: targetID) else {
            return
        }

        withAnimation(.dockEase(duration: 0.18)) {
            order.move(
                fromOffsets: IndexSet(integer: sourceIndex),
                toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
            )
        }
        QuotaProviderCatalog.saveProviderOrder(order)
    }

    func performDrop(info: DropInfo) -> Bool {
        QuotaProviderCatalog.saveProviderOrder(order)
        draggingID = nil
        return true
    }

    func dropExited(info: DropInfo) {}
}
