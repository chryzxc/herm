import Foundation

enum WorkspaceTaskStatus: String, Codable, CaseIterable {
    case todo = "Todo"
    case inProgress = "In Progress"
    case awaitingApproval = "Awaiting Approval"
    case readyForReview = "Ready for Review"
    case done = "Done"
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

    func attachProject(at path: String) {
        projectPath = path
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder.workspace.decode(WorkspaceState.self, from: data) else { return }
        tasks = state.tasks
        projectPath = state.projectPath
    }

    private func save() {
        let state = WorkspaceState(tasks: tasks, projectPath: projectPath)
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
    var projectPath: String?
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
