import Foundation

enum WorkspaceTaskStatus: String, Codable, CaseIterable {
    case todo = "Todo"
    case inProgress = "In Progress"
    case awaitingApproval = "Awaiting Approval"
    case readyForReview = "Ready for Review"
    case done = "Done"
}

enum WorkspaceAgentRole: String, Codable, CaseIterable, Identifiable {
    case planner = "Planner"
    case implementer = "Implementer"
    case reviewer = "Reviewer"
    case verifier = "Verifier"
    var id: String { rawValue }
}

enum WorkspaceAgentStatus: String, Codable {
    case queued = "Queued"
    case running = "Running"
    case blocked = "Blocked"
    case complete = "Complete"
}

struct WorkspaceAgentRun: Identifiable, Codable, Equatable {
    let id: UUID
    var role: WorkspaceAgentRole
    var status: WorkspaceAgentStatus
    var taskID: UUID?
    var sessionID: String?
    var createdAt: Date
    var updatedAt: Date
    var summary: String
    var errorMessage: String?

    init(id: UUID, role: WorkspaceAgentRole, status: WorkspaceAgentStatus, taskID: UUID?, sessionID: String?, createdAt: Date, updatedAt: Date, summary: String = "", errorMessage: String? = nil) {
        self.id = id
        self.role = role
        self.status = status
        self.taskID = taskID
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.summary = summary
        self.errorMessage = errorMessage
    }

    private enum CodingKeys: String, CodingKey { case id, role, status, taskID, sessionID, createdAt, updatedAt, summary, errorMessage }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(WorkspaceAgentRole.self, forKey: .role)
        status = try values.decode(WorkspaceAgentStatus.self, forKey: .status)
        taskID = try values.decodeIfPresent(UUID.self, forKey: .taskID)
        sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        errorMessage = try values.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}

struct WorkspaceTask: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var status: WorkspaceTaskStatus
    var projectPath: String?
    var sessionID: String?
    var createdAt: Date
    var updatedAt: Date
    var summary: String

    init(id: UUID = UUID(), title: String, status: WorkspaceTaskStatus = .todo, projectPath: String? = nil, sessionID: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date(), summary: String = "") {
        self.id = id
        self.title = title
        self.status = status
        self.projectPath = projectPath
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.summary = summary
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var tasks: [WorkspaceTask] = []
    @Published private(set) var agentRuns: [WorkspaceAgentRun] = []
    @Published var projectPath: String? {
        didSet { save() }
    }

    private let fileURL: URL
    /// Each background role owns an isolated gateway/session. Keeping these alive is
    /// required for its event stream; the user-facing conversation keeps its own gateway.
    private var agentGateways: [UUID: HermesGateway] = [:]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HermesWorkspace", isDirectory: true)
        fileURL = support.appendingPathComponent("workspace.json")
        load()
    }

    var activeTask: WorkspaceTask? { tasks.first(where: { $0.status != .done }) }

    @discardableResult
    func createTask(title: String, sessionID: String? = nil) -> WorkspaceTask {
        let task = WorkspaceTask(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled task" : title, status: .inProgress, projectPath: projectPath, sessionID: sessionID)
        tasks.insert(task, at: 0)
        save()
        return task
    }

    func updateStatus(_ status: WorkspaceTaskStatus, for taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].status = status
        tasks[index].updatedAt = Date()
        save()
    }

    func updateTaskFromHermes(taskID: UUID, status: WorkspaceTaskStatus, summary: String? = nil) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].status = status
        tasks[index].updatedAt = Date()
        if let summary, !summary.isEmpty { tasks[index].summary = summary }
        save()
    }

    func deleteTask(_ taskID: UUID) {
        tasks.removeAll { $0.id == taskID }
        save()
    }

    @discardableResult
    func queueAgent(_ role: WorkspaceAgentRole, for taskID: UUID?) -> WorkspaceAgentRun {
        let run = WorkspaceAgentRun(id: UUID(), role: role, status: .queued, taskID: taskID, sessionID: nil, createdAt: Date(), updatedAt: Date(), summary: "", errorMessage: nil)
        agentRuns.insert(run, at: 0)
        save()
        return run
    }

    func updateAgent(_ runID: UUID, status: WorkspaceAgentStatus, sessionID: String? = nil, summary: String? = nil, errorMessage: String? = nil) {
        guard let index = agentRuns.firstIndex(where: { $0.id == runID }) else { return }
        agentRuns[index].status = status
        agentRuns[index].updatedAt = Date()
        if let sessionID { agentRuns[index].sessionID = sessionID }
        if let summary, !summary.isEmpty { agentRuns[index].summary = summary }
        if let errorMessage { agentRuns[index].errorMessage = errorMessage }
        save()
    }

    func startAgent(_ role: WorkspaceAgentRole, for taskID: UUID?) {
        guard let taskID, let task = tasks.first(where: { $0.id == taskID }) else { return }
        guard !agentRuns.contains(where: { $0.role == role && $0.taskID == taskID && $0.status == .running }) else { return }

        let run = queueAgent(role, for: taskID)
        let repositoryPath = task.projectPath ?? projectPath
        let gateway = HermesGateway(workingDirectory: repositoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) })
        agentGateways[run.id] = gateway
        gateway.onEvent = { [weak self] type, params in
            self?.handleAgentEvent(type, params: params, runID: run.id)
        }

        Task { [weak self, gateway] in
            guard let self else { return }
            do {
                try await gateway.connect()
                let result = try await gateway.request("session.create", params: ["source": "hermes-workspace-\(role.rawValue.lowercased())"])
                guard let sessionID = result["session_id"] as? String else {
                    throw HermesGateway.GatewayError.malformedResponse
                }
                self.updateAgent(run.id, status: .running, sessionID: sessionID)
                _ = try await gateway.request("prompt.submit", params: [
                    "session_id": sessionID,
                    "text": self.agentPrompt(role: role, task: task, repositoryPath: repositoryPath)
                ])
            } catch {
                self.updateAgent(run.id, status: .blocked, errorMessage: error.localizedDescription)
                self.agentGateways.removeValue(forKey: run.id)?.close()
            }
        }
    }

    private func handleAgentEvent(_ type: String, params: [String: Any], runID: UUID) {
        let payload = params["payload"] as? [String: Any] ?? [:]
        switch type {
        case "message.complete":
            updateAgent(runID, status: .complete)
            agentGateways.removeValue(forKey: runID)?.close()
        case "approval.request":
            let detail = (payload["command"] as? String) ?? (payload["description"] as? String) ?? "Approval required"
            updateAgent(runID, status: .blocked, errorMessage: detail)
        case "error":
            let detail = (payload["message"] as? String) ?? "Hermes reported an error."
            updateAgent(runID, status: .blocked, errorMessage: detail)
            agentGateways.removeValue(forKey: runID)?.close()
        case "message.delta":
            let delta = (payload["delta"] as? String) ?? (payload["text"] as? String) ?? ""
            guard !delta.isEmpty, let index = agentRuns.firstIndex(where: { $0.id == runID }) else { return }
            agentRuns[index].summary = String((agentRuns[index].summary + delta).suffix(1_200))
            agentRuns[index].updatedAt = Date()
        default:
            break
        }
    }

    private func agentPrompt(role: WorkspaceAgentRole, task: WorkspaceTask, repositoryPath: String?) -> String {
        let repository = repositoryPath.map { "Repository: \($0)" } ?? "No repository is attached."
        let roleInstruction: String
        switch role {
        case .planner:
            roleInstruction = "Create a concise implementation plan, identify risks, and propose verification steps. Do not modify files or run destructive commands."
        case .implementer:
            roleInstruction = "Inspect the task and repository, then describe the smallest safe implementation approach and exact files likely involved. Do not modify files yet; code-writing work will run in an isolated worktree in a later workflow step."
        case .reviewer:
            roleInstruction = "Review the task context for likely regressions, edge cases, and acceptance criteria. Do not modify files."
        case .verifier:
            roleInstruction = "Propose focused validation commands and success criteria. Do not run commands or modify files."
        }
        return """
        You are the \(role.rawValue) agent in Hermes Workspace.

        Task: \(task.title)
        \(repository)

        \(roleInstruction)
        Return a concise, actionable handoff for the workspace.
        """
    }

    func attachProject(at path: String) {
        projectPath = path
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder.workspace.decode(WorkspaceState.self, from: data) else { return }
        tasks = state.tasks
        agentRuns = state.agentRuns
        projectPath = state.projectPath
    }

    private func save() {
        let state = WorkspaceState(tasks: tasks, agentRuns: agentRuns, projectPath: projectPath)
        guard let data = try? JSONEncoder.workspace.encode(state) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            DebugLog.write("workspace: persistence failed: \(error.localizedDescription)")
        }
    }
}

private struct WorkspaceState: Codable {
    var tasks: [WorkspaceTask]
    var agentRuns: [WorkspaceAgentRun]
    var projectPath: String?

    init(tasks: [WorkspaceTask], agentRuns: [WorkspaceAgentRun] = [], projectPath: String?) {
        self.tasks = tasks
        self.agentRuns = agentRuns
        self.projectPath = projectPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decodeIfPresent([WorkspaceTask].self, forKey: .tasks) ?? []
        agentRuns = try container.decodeIfPresent([WorkspaceAgentRun].self, forKey: .agentRuns) ?? []
        projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
    }
}

private extension JSONEncoder {
    static var workspace: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var workspace: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
