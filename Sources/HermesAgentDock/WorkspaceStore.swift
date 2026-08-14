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
    @Published private(set) var controlReferences: [ControlReference] = []
    @Published var projectPath: String?

    private let fileURL: URL
    init(fileURL: URL? = nil) {
        let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let support = supportRoot
            .appendingPathComponent("HermesWorkspace", isDirectory: true)
        self.fileURL = fileURL ?? support.appendingPathComponent("workspace.json")
        load()
    }

    var activeTask: WorkspaceTask? { tasks.first(where: { $0.status != .done }) }

    func task(forSessionID sessionID: String) -> WorkspaceTask? {
        tasks.first(where: { $0.sessionID == sessionID })
    }

    /// A Hermes session is the canonical identity for a conversation-backed task.
    /// Repeated UI updates may enrich the title, but must never create duplicates.
    @discardableResult
    func ensureTask(title: String, sessionID: String) -> WorkspaceTask {
        let normalizedTitle = normalizedTaskTitle(title)
        if let index = tasks.firstIndex(where: { $0.sessionID == sessionID }) {
            addControlReference(for: tasks[index])
            if tasks[index].title != normalizedTitle {
                tasks[index].title = normalizedTitle
                tasks[index].updatedAt = Date()
                save()
            }
            return tasks[index]
        }

        return createTask(title: normalizedTitle, sessionID: sessionID)
    }

    @discardableResult
    func createTask(title: String, sessionID: String? = nil) -> WorkspaceTask {
        let task = WorkspaceTask(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled task" : title, status: .inProgress, projectPath: projectPath, sessionID: sessionID)
        tasks.insert(task, at: 0)
        addControlReference(for: task)
        save()
        return task
    }

    func updateStatus(_ status: WorkspaceTaskStatus, for taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard tasks[index].status != status else { return }
        tasks[index].status = status
        tasks[index].updatedAt = Date()
        save()
    }

    func updateStatus(_ status: WorkspaceTaskStatus, forSessionID sessionID: String) {
        guard let taskID = task(forSessionID: sessionID)?.id else { return }
        updateStatus(status, for: taskID)
    }

    func updateTaskFromHermes(taskID: UUID, status: WorkspaceTaskStatus, summary: String? = nil) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].status = status
        tasks[index].updatedAt = Date()
        if let summary, !summary.isEmpty { tasks[index].summary = summary }
        save()
    }

    func deleteTask(_ taskID: UUID) {
        if let task = tasks.first(where: { $0.id == taskID }), let sessionID = task.sessionID {
            controlReferences.removeAll { $0.source == .hermesSession && $0.sourceID == sessionID }
        }
        tasks.removeAll { $0.id == taskID }
        save()
    }

    func attachProject(at path: String) {
        projectPath = path
        save()
    }

    func attachProject(at path: String, toSessionID sessionID: String?) {
        projectPath = path
        if let sessionID, let index = tasks.firstIndex(where: { $0.sessionID == sessionID }) {
            tasks[index].projectPath = path
            tasks[index].updatedAt = Date()
        }
        save()
    }

    /// The selected Hermes project is the default local context. A session can
    /// override it when it belongs to a different project, but an unrelated or
    /// newly opened session should still render the currently selected project.
    func projectPath(forSessionID sessionID: String?) -> String? {
        if let sessionID,
           let sessionPath = task(forSessionID: sessionID)?.projectPath,
           !sessionPath.isEmpty {
            return sessionPath
        }
        return projectPath?.isEmpty == false ? projectPath : nil
    }

    /// A Hermes project groups multiple sessions around one checkout. Persist
    /// the selected local folder against each known session so change review
    /// follows the current session instead of relying on a global path.
    func attachProject(at path: String, toSessions sessions: [SessionSummary]) {
        projectPath = path
        for session in sessions {
            if let index = tasks.firstIndex(where: { $0.sessionID == session.id }) {
                tasks[index].projectPath = path
                tasks[index].updatedAt = Date()
            } else {
                let task = WorkspaceTask(
                    title: session.title,
                    status: .inProgress,
                    projectPath: path,
                    sessionID: session.id
                )
                tasks.insert(task, at: 0)
                addControlReference(for: task)
            }
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder.workspace.decode(WorkspaceState.self, from: data) else { return }
        tasks = state.tasks
        agentRuns = state.agentRuns
        projectPath = state.projectPath

        let migratedReferences = state.controlReferences.isEmpty
            ? tasks.compactMap { task -> ControlReference? in
                guard let sessionID = task.sessionID else { return nil }
                return ControlReference(source: .hermesSession, sourceID: sessionID, sessionID: sessionID)
            }
            : state.controlReferences
        controlReferences = deduplicatedReferences(migratedReferences)

        if state.schemaVersion < WorkspaceState.currentSchemaVersion {
            backupLegacyWorkspaceIfNeeded()
            save()
        }
    }

    private func addControlReference(for task: WorkspaceTask) {
        guard let sessionID = task.sessionID else { return }
        let reference = ControlReference(source: .hermesSession, sourceID: sessionID, sessionID: sessionID, projectID: task.projectPath)
        if !controlReferences.contains(where: { $0.id == reference.id }) {
            controlReferences.append(reference)
        }
    }

    private func deduplicatedReferences(_ references: [ControlReference]) -> [ControlReference] {
        var seen = Set<String>()
        return references.filter { seen.insert($0.id).inserted }
    }

    private func backupLegacyWorkspaceIfNeeded() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let backupURL = fileURL.deletingPathExtension().appendingPathExtension("v1.backup.json")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        do {
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
        } catch {
            DebugLog.write("workspace: migration backup failed: \(error.localizedDescription)")
        }
    }

    private func normalizedTaskTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled task" : String(trimmed.prefix(100))
    }

    private func save() {
        let state = WorkspaceState(tasks: tasks, agentRuns: agentRuns, projectPath: projectPath, controlReferences: controlReferences)
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
    static let currentSchemaVersion = 2
    var schemaVersion: Int
    var tasks: [WorkspaceTask]
    var agentRuns: [WorkspaceAgentRun]
    var projectPath: String?
    var controlReferences: [ControlReference]

    init(tasks: [WorkspaceTask], agentRuns: [WorkspaceAgentRun] = [], projectPath: String?, controlReferences: [ControlReference] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.tasks = tasks
        self.agentRuns = agentRuns
        self.projectPath = projectPath
        self.controlReferences = controlReferences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        tasks = try container.decodeIfPresent([WorkspaceTask].self, forKey: .tasks) ?? []
        agentRuns = try container.decodeIfPresent([WorkspaceAgentRun].self, forKey: .agentRuns) ?? []
        projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
        controlReferences = try container.decodeIfPresent([ControlReference].self, forKey: .controlReferences) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, tasks, agentRuns, projectPath, controlReferences
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
