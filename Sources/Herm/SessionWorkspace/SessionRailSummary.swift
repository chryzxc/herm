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
    var attention: [Attention] = []
    var plan: TodoPlan?
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
        attention.isEmpty && plan == nil && outputs.isEmpty && outputsError == nil
            && pins.isEmpty && pinsError == nil && workspace == nil && contextFiles.isEmpty && processes.isEmpty
            && subagents.isEmpty && checkpoints.isEmpty
    }

    var runningProcessCount: Int { processes.count { $0.state == "running" } }
    var runningSubagentCount: Int { subagents.count { AgentActivityPresentation.isActiveStatus($0.status) } }

    /// Live rows override their history copy; nested workers stay listed under the same session.
    static func subagents(history: [HermesSubagent], live: [HermesSubagent]) -> [HermesSubagent] {
        var byID: [String: HermesSubagent] = [:]
        for agent in history + live { byID[agent.id] = agent }
        return byID.values.sorted {
            ($0.startedAt ?? .distantPast, $0.id) > ($1.startedAt ?? .distantPast, $1.id)
        }
    }

    @MainActor
    static func make(
        model: DockModel, repositoryPath: String?, repository: RepositorySnapshot,
        outputs: [ArtifactRecord], outputsError: String?, contextFiles: [SessionContextFile] = [],
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
        summary.outputs = RichArtifactIndex.latest(outputs.filter { $0.scopedSessionID == owner })
            .sorted { $0.timestamp > $1.timestamp }
        summary.outputsError = outputsError
        summary.contextFiles = contextFiles
        summary.processes = processes
        // Displayed history settles stale non-terminal rows so the rail never shows a ghost "Running".
        summary.subagents = subagents(history: model.displayedSubagents, live: model.activeSubagents)
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
    @Published private(set) var records: [ArtifactRecord] = []
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
            records = []
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
        if result.error == nil { records = result.records.filter { $0.scopedSessionID == session.scopedID } }
    }
}
