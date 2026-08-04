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
        let run = WorkspaceAgentRun(id: UUID(), role: role, status: .queued, taskID: taskID, sessionID: nil, createdAt: Date(), updatedAt: Date())
        agentRuns.insert(run, at: 0)
        save()
        return run
    }

    func updateAgent(_ runID: UUID, status: WorkspaceAgentStatus, sessionID: String? = nil) {
        guard let index = agentRuns.firstIndex(where: { $0.id == runID }) else { return }
        agentRuns[index].status = status
        agentRuns[index].updatedAt = Date()
        if let sessionID { agentRuns[index].sessionID = sessionID }
        save()
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
