import Foundation

/// Hermes-owned automation families. They are intentionally not interchangeable
/// projections: a cron job is not a goal, loop, heartbeat, or Kanban task.
enum AutomationKind: String, CaseIterable, Equatable, Sendable {
    case cron, kanban, goals, loops, heartbeats
}

struct AutomationCronJob: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let schedule: String
    let enabled: Bool
    let skills: [String]
    let prompt: String?
    let model: String?
    let provider: String?
    let workdir: String?
    let delivery: String?
    let script: String?
    let noAgent: Bool?
    let chain: String?
    let monitor: String?
    let attachSession: Bool?
    let repeatStatus: String?
}

struct AutomationKanbanTask: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let status: String
}

struct AutomationGoal: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let status: String
}

struct AutomationLoop: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let status: String
}

struct AutomationHeartbeat: Identifiable, Equatable, Sendable {
    let id: String
    let status: String
    let lastSeen: String?
}

struct AutomationSnapshot: Equatable, Sendable {
    let cron: [AutomationCronJob]
    let kanban: [AutomationKanbanTask]
    let goals: [AutomationGoal]
    let loops: [AutomationLoop]
    let heartbeats: [AutomationHeartbeat]
}

enum AutomationUnavailableReason: Equatable, Sendable {
    case unsupported(String)
    case denied(String)
    case malformed(String)

    var message: String {
        switch self {
        case .unsupported(let value), .denied(let value), .malformed(let value): value
        }
    }
}

enum AutomationProjectionState: Equatable, Sendable {
    case loading
    case ready(AutomationSnapshot)
    case stale(AutomationSnapshot, safeMessage: String)
    case unavailable(AutomationUnavailableReason)
    case failed(String)

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .loading: "Loading automation projections."
        case .ready: ""
        case .stale(_, let message), .failed(let message): message
        case .unavailable(let reason): reason.message
        }
    }
}

enum AutomationOperation: String, CaseIterable, Equatable, Sendable {
    case createCron = "cron.create"
    case pauseCron = "cron.pause"
    case resumeCron = "cron.resume"
    case runCron = "cron.run"
    case deleteCron = "cron.delete"
    case pauseKanban = "kanban.pause"
    case resumeKanban = "kanban.resume"
    case runKanban = "kanban.run"
    case deleteKanban = "kanban.delete"
    case createGoal = "goals.create"
    case pauseGoal = "goals.pause"
    case resumeGoal = "goals.resume"
    case deleteGoal = "goals.delete"
    case pauseLoop = "loops.pause"
    case resumeLoop = "loops.resume"
    case deleteLoop = "loops.delete"
    case pauseHeartbeat = "heartbeats.pause"
    case resumeHeartbeat = "heartbeats.resume"
    case deleteHeartbeat = "heartbeats.delete"
}

struct AutomationCapabilityGate: Equatable, Sendable {
    let available: Set<String>

    init(available: Set<String>) { self.available = available }
    init(available: [String]) { self.init(available: Set(available)) }

    func allows(_ operation: AutomationOperation) -> Bool {
        available.contains(operation.rawValue)
    }
}

struct AutomationOperationRequest: Equatable, Sendable {
    let operation: AutomationOperation
    let parameters: [String: String]

    var capabilityID: String { operation.rawValue }

    init(operation: AutomationOperation, parameters: [String: String]) {
        self.operation = operation
        self.parameters = parameters
    }

    init(operation: AutomationOperation, id: String? = nil) {
        self.operation = operation
        self.parameters = id.map { ["id": $0] } ?? [:]
    }

    static func createCron(name: String, schedule: String, prompt: String) -> Self {
        Self(operation: .createCron, parameters: ["name": name, "schedule": schedule, "prompt": prompt])
    }
    static func pauseCron(jobID: String) -> Self { Self(operation: .pauseCron, id: jobID) }
    static func resumeCron(jobID: String) -> Self { Self(operation: .resumeCron, id: jobID) }
    static func runCron(jobID: String) -> Self { Self(operation: .runCron, id: jobID) }
    static func deleteCron(jobID: String) -> Self { Self(operation: .deleteCron, id: jobID) }
    static func pauseKanban(taskID: String) -> Self { Self(operation: .pauseKanban, id: taskID) }
    static func resumeKanban(taskID: String) -> Self { Self(operation: .resumeKanban, id: taskID) }
    static func runKanban(taskID: String) -> Self { Self(operation: .runKanban, id: taskID) }
    static func deleteKanban(taskID: String) -> Self { Self(operation: .deleteKanban, id: taskID) }
    static func createGoal(id: String) -> Self { Self(operation: .createGoal, id: id) }
    static func pauseGoal(id: String) -> Self { Self(operation: .pauseGoal, id: id) }
    static func resumeGoal(id: String) -> Self { Self(operation: .resumeGoal, id: id) }
    static func deleteGoal(id: String) -> Self { Self(operation: .deleteGoal, id: id) }
    static func pauseLoop(id: String) -> Self { Self(operation: .pauseLoop, id: id) }
    static func resumeLoop(id: String) -> Self { Self(operation: .resumeLoop, id: id) }
    static func deleteLoop(id: String) -> Self { Self(operation: .deleteLoop, id: id) }
    static func pauseHeartbeat(id: String) -> Self { Self(operation: .pauseHeartbeat, id: id) }
    static func resumeHeartbeat(id: String) -> Self { Self(operation: .resumeHeartbeat, id: id) }
    static func deleteHeartbeat(id: String) -> Self { Self(operation: .deleteHeartbeat, id: id) }
}

@MainActor
protocol AutomationTransport: AnyObject {
    func fetchAutomationSnapshot() async throws -> AutomationSnapshot
    func perform(_ request: AutomationOperationRequest) async throws
}
