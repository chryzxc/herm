import AppKit
import ServiceManagement
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
    @State var selectedMode: ControlTab = .kanban
    @State var capabilitySection: WorkflowIntegrationView.Section = .skills
    @State var isShowingCommandPalette = false
    @State var searchQuery = ""
    @State var selectedModelID = ""
    @State var selectedAgentID: String?
    @State var selectedRepositoryDiff: RepositoryDiff?
    @State var codeDocument: RepositoryFileDocument?
    @State var selectedRepositoryFile: RepositoryFileChange?
    @State var selectedProjectSessionID: String?
    @State var codeWorkspaceError: String?
    @State var isLoadingRepositoryDiff = false
    @State var isRefreshingRepository = false
    @State var showingRepositoryPicker = false
    @State var cronRemovalRequest: CronSummary?
    @State var isShowingCronRemovalConfirmation = false
    @State var cronRunRequest: CronSummary?
    @State var isShowingCronRunConfirmation = false
    @State var isShowingAutomationComposer = false
    @State var selectedCronJobID: String?
    @State var automationHistoryScope: AutomationHistoryScope = .selected
    @State var automationName = ""
    @State var automationSchedule = ""
    @State var automationPrompt = ""
    @State var isShowingAutomationConfirmation = false
    @State var isShowingMCPReloadConfirmation = false
    @State var kanbanTitle = ""
    @State var kanbanBody = ""
    @State var isShowingKanbanComposer = false
    @State var isShowingKanbanConfirmation = false
    @State var kanbanChangeRequest: KanbanChangeRequest?
    @State var isShowingKanbanChangeConfirmation = false
    @State var selectedKanbanTask: KanbanTaskSummary?
    @State var kanbanInspectorTab: KanbanInspectorTab = .overview
    @State var kanbanMutationRequest: KanbanMutationRequest?
    @State var cronEditJob: CronSummary?
    @State var cronReportRequest: CronReportRequest?
    @State var expandedCronReportIDs: Set<String> = []
    @State var isShowingAllSkills = false
    @State var expandedSettingsCapabilityCategories: Set<CapabilityCategory> = [.core]
    @State var isAgentUpdateExpanded = true
    @State var isAppUpdateExpanded = true
    @ObservedObject var appUpdater = HermAppUpdater.shared
    @State var isInsightsExpanded = false
    @State var isCapabilitiesExpanded = true
    @State var isSetupExpanded = true
    @State var isSessionCockpitExpanded = false
    @State var isSessionActionsExpanded = false
    @State var isDiagnosticsExpanded = false
    @State var isLearningExpanded = false
    @State var isRuntimeConfigurationExpanded = true
    @State var kanbanStatusFilter = "All"
    @State var isShowingKanbanStatusFilter = false
    @State var kanbanAssigneeFilter = "All"
    @State var isShowingKanbanAssigneeFilter = false
    @State var kanbanMineOnly = false
    @State var kanbanCurrentSessionOnly = false
    @State var kanbanSort = "updated"
    @State var kanbanDiagnosticSeverity = "ALL"
    @State var isKanbanHealthExpanded = false
    @State var sessionSteerText = ""
    @State var sessionSteerFeedback: String?
    @State var backgroundTaskPrompt = ""
    @State var isStartingBackgroundTask = false
    @State var sessionRenameText = ""
    @State var sessionRedirectText = ""
    @State var sessionBranchName = ""
    @State var sessionCompressTopic = ""
    @State var isShowingUndoConfirmation = false
    @State var isShowingBranchConfirmation = false
    @State var isShowingCompressConfirmation = false
    @State var isShowingDelegationConfirmation = false
    @State var handoffFocus = ""
    @State var isShowingHandoffConfirmation = false
    @State var pendingProcess: ProcessSummary?
    @State var pendingAgentID: String?
    @State var isShowingAgentUpdateConfirmation = false
    @State var isAgentUpdateOutputExpanded = false
    @State var isShowingDockRestartConfirmation = false
    /// Read on appear: `status` is a blocking XPC call, and a `@State` default re-runs on every init.
    @State var opensAtLogin = false
    @State var isShowingEmergencyStopConfirmation = false
    @State var selectedSettingsCategory: SettingsCategory = .general
    @State var isShowingEmergencyResumeConfirmation = false
    @State var checkpointForRestore: RestoreCheckpoint?
    @State var pendingProjectMutation: ProjectMutation?
    @State var isShowingProjectMutationConfirmation = false
    @State var pendingProjectFolder: URL?
    @State var isShowingProjectCreationConfirmation = false
    @State var projectsDisplayLimit = WorkspaceActivitySidebar.projectsPageSize
    @StateObject var commandCenterPreferences = CommandCenterPreferencesStore()
    @AppStorage(DockPanel.hideFromScreenSharingKey) var hidesFromScreenSharing = false
    @AppStorage(OnDeviceAssist.explainApprovalsKey) var explainsApprovalsOnDevice = false
    @AppStorage(OnDeviceAssist.summarizeRepliesKey) var summarizesRepliesOnDevice = false
    @AppStorage(OnDeviceAssist.nameSessionsKey) var namesSessionsOnDevice = true
    @AppStorage(SessionSpotlightIndex.enabledKey) var showsSessionsInSpotlight = false
    @AppStorage(ApprovalAuthGate.key) var requiresAuthForBroadApprovals = false
    @AppStorage(HermDelegate.keepAwakeKey) var keepsAwakeWhileWorking = false
    @AppStorage(SidebarVisibilityKey.kanban) var showsKanbanInSidebar = true
    @AppStorage(SidebarVisibilityKey.pullRequests) var showsPullRequestsInSidebar = true
    @AppStorage(SidebarVisibilityKey.issues) var showsIssuesInSidebar = true
    @AppStorage(SidebarVisibilityKey.office) var showsOfficeInSidebar = true
    @AppStorage(SidebarVisibilityKey.calendar) var showsCalendarInSidebar = true
    @AppStorage(ChatQuotaSettingsKey.chip) var showsQuotaChip = true
    @AppStorage(ChatQuotaSettingsKey.dropBanner) var showsQuotaDropBanner = true
    @AppStorage(DoubleTapShortcut.workspaceKey) var workspaceShortcut = DoubleTapShortcut.command
    @AppStorage(DoubleTapShortcut.notchKey) var notchShortcut = DoubleTapShortcut.option
    @AppStorage(QuickCaptureChord.key) var captureChord = QuickCaptureChord.optionSpace
    @AppStorage("hermes.notch.side") var notchSide: EdgeDockSide = .right
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
        initialMode: ControlTab = .kanban,
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

    enum ProjectMutation: String, Identifiable {
        case activate, archive, delete
        var id: Self { self }
    }

    // Dashboard-style pages read badly stretched edge to edge; boards, diffs and previews keep the full width.
    var readingWidthModes: Set<ControlTab> { [.quota, .usage, .core] }

    @AppStorage("herm.settingsRailCollapsed") var isSettingsRailCollapsed = false
    /// Set in the window: page toolbars move up into the title row like a native toolbar.
    @Environment(\.dockTitleRow) var titleRow

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
            CronEditEditor(job: job, control: control)
        }
        .sheet(item: $cronReportRequest) { request in
            CronReportDetailSheet(request: request, control: control)
        }
        .sheet(isPresented: $isShowingAutomationComposer) {
            automationComposer
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
    }

    static let kanbanCardActionPrefixes: [String] =
        KanbanTaskAction.allCases.map { "kanban.\($0.rawValue):" } + ["kanban.move:", "kanban.reassign:"]

}
