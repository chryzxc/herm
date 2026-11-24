import Combine
import Foundation

/// Read-only summaries of the selected session's existing projections.
struct SessionRailSummary: Equatable {
    struct Attention: Equatable, Identifiable {
        let id: String
        let title: String
        let detail: String
    }
    struct Workspace: Equatable {
        let path: String
        let branch: String?
        let latestCommit: String?
    }
    struct Outputs: Equatable {
        let owner: ProfileScopedID
        let records: [ArtifactRecord]

        init(owner: ProfileScopedID, records: [ArtifactRecord]) {
            self.owner = owner
            self.records = RichArtifactIndex.latest(records.filter { $0.scopedSessionID == owner })
                .sorted { $0.timestamp > $1.timestamp }
        }
    }
    var attention: [Attention] = []
    var plan: TodoPlan?
    /// Hermes `/plan` files this session named, newest first.
    var plans: [SessionPlan] = []
    var isWorking = false
    var outputs: [ArtifactRecord] = []
    var outputsError: String?
    var pins: [PinnedMessage] = []
    var pinsError: String?
    var workspace: Workspace?
    var contextFiles: [SessionContextFile] = []
    /// Hermes background processes this session started (`process.list`), newest output last.
    var processes: [ProcessSummary] = []
    /// Workers this session delegated, live and finished, newest first.
    var subagents: [HermesSubagent] = []
    /// `rollback.list` checkpoints for this session's workspace, newest first.
    var checkpoints: [RestoreCheckpoint] = []
    var isRestoringCheckpoint = false

    var isEmpty: Bool {
        attention.isEmpty && plan == nil && plans.isEmpty && outputs.isEmpty && outputsError == nil
            && pins.isEmpty && pinsError == nil && workspace == nil && contextFiles.isEmpty && processes.isEmpty
            && subagents.isEmpty && checkpoints.isEmpty
    }

    var runningProcessCount: Int { processes.count { $0.state == "running" } }
    var runningSubagentCount: Int { subagents.count { AgentActivityPresentation.isActiveStatus($0.status) } }

    @MainActor
    static func presentationChanges(
        model: DockModel, workflow: DeveloperWorkflowModel, control: ControlCenterModel
    ) -> AnyPublisher<Void, Never> {
        let workers = model.activityPresentation.$revision.map { [weak model] _ in
            (model?.sessionAgents ?? [], model?.activeSubagents ?? [])
        }.removeDuplicates { $0 == $1 }.dropFirst().map { _ in () }.eraseToAnyPublisher()
        return Publishers.MergeMany(
            DockModel.change(model.$sessionID), DockModel.change(model.$sessionStorageID),
            DockModel.change(model.$sessionProfileID), DockModel.change(model.$profileScopeID),
            DockModel.change(model.$status), DockModel.change(model.$isRestoringSession),
            DockModel.change(model.$isSending), DockModel.change(model.$isHermesConnected),
            DockModel.change(model.$approvalTitle), DockModel.change(model.$approvalText),
            DockModel.change(model.$clarificationQuestion), DockModel.change(model.$valuePrompt),
            DockModel.change(model.$todoPlan), model.latestPlanPromptChanges, workers,
            DockModel.change(model.$pinnedMessages), DockModel.change(model.$messagePinError),
            DockModel.change(workflow.$repository), DockModel.change(workflow.$changes),
            DockModel.change(workflow.$isRefreshing), DockModel.change(control.$processes),
            DockModel.change(control.$restoreCheckpoints), DockModel.change(control.$restoreCheckpointState)
        ).debounce(for: .milliseconds(1), scheduler: DispatchQueue.main).eraseToAnyPublisher()
    }

    /// Live rows override their history copy; nested workers stay listed under the same session.
    @MainActor
    static func subagents(history: [HermesSubagent], live: [HermesSubagent]) -> [HermesSubagent] {
        var byID: [String: HermesSubagent] = [:]
        let liveIDs = Set(live.map(\.id))
        for var agent in history {
            if !liveIDs.contains(agent.id), !DockModel.isTerminalAgentStatus(agent.status) {
                agent.status = "stale"
            }
            byID[agent.id] = agent
        }
        for agent in live { byID[agent.id] = agent }
        return byID.values.sorted {
            ($0.startedAt ?? .distantPast, $0.id) > ($1.startedAt ?? .distantPast, $1.id)
        }
    }

    @MainActor
    static func make(
        model: DockModel, repositoryPath: String?, repository: RepositorySnapshot,
        outputs: Outputs? = nil, outputsError: String?, contextFiles: [SessionContextFile] = [],
        processes: [ProcessSummary] = [], checkpoints: [RestoreCheckpoint] = []
    ) -> Self {
        guard let sessionID = model.navigationSessionID, !model.isRestoringSession else { return Self() }
        let ids = model.currentSessionIDs
        let owner = ProfileScopedID(
            profileID: model.sessionProfileID ?? model.profileScopeID,
            resourceID: sessionID)
        var summary = Self()
        summary.isWorking = model.status == .working
        if let detail = model.approvalText {
            summary.attention.append(
                .init(id: "approval", title: model.approvalTitle ?? "Approval required", detail: detail))
        }
        if model.status == .needsClarification, let question = model.clarificationQuestion {
            summary.attention.append(.init(id: "question", title: "Question", detail: question))
        }
        if let prompt = model.valuePrompt {
            summary.attention.append(.init(id: prompt.requestID, title: prompt.title, detail: prompt.message))
        }
        if let plan = model.currentTodoPlan, !plan.items.isEmpty { summary.plan = plan }
        if let outputs, outputs.owner == owner { summary.outputs = outputs.records }
        summary.outputsError = outputsError
        summary.contextFiles = contextFiles
        summary.processes = processes
        // Historical nonterminal statuses are not evidence of current activity or completion.
        summary.subagents = subagents(history: model.sessionAgents, live: model.activeSubagents)
        summary.checkpoints = checkpoints.filter { ids.contains($0.sessionID) }
        summary.pins = model.pinnedMessages
        // Unsupported pins should not advertise a rail section on older runtimes.
        summary.pinsError = model.pinnedMessages.isEmpty ? nil : model.messagePinError
        if let path = repositoryPath, !path.isEmpty {
            let matches =
                repository.isGitRepository && !repository.isStale
                && RepositorySnapshot.stableID(path: path) == repository.repositoryID
            summary.workspace = .init(
                path: path, branch: matches ? repository.branch : nil,
                latestCommit: matches && !repository.latestCommit.isEmpty ? repository.latestCommit : nil)
        }
        return summary
    }
}

/// Shares the artifact browser's disposable index; never stores another transcript.
@MainActor
final class SessionRailOutputsModel: ObservableObject {
    @Published private(set) var snapshot: SessionRailSummary.Outputs?
    @Published private(set) var error: String?
    @Published private(set) var isRefreshing = false
    private var owner: ProfileScopedID?
    private var generation = UUID()

    func refresh(
        session: HermesSession, load: () async -> ArtifactIndexLoader.SessionResult
    ) async {
        let request = UUID()
        generation = request
        if owner != session.scopedID {
            snapshot = nil
            error = nil
            owner = session.scopedID
        }
        isRefreshing = true
        defer { if generation == request { isRefreshing = false } }
        let result = await load()
        guard !Task.isCancelled, generation == request else { return }
        guard result.sessionID == session.id, result.profileID == session.profileID else {
            error = "Outputs unavailable"
            return
        }
        error = result.error
        if result.error == nil {
            let next = SessionRailSummary.Outputs(owner: session.scopedID, records: result.records)
            if snapshot != next { snapshot = next }
        }
    }
}
