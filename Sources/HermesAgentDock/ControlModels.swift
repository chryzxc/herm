import Foundation

enum ControlSource: String, Codable, Hashable {
    case hermesSession
    case hermesApproval
    case hermesClarification
    case hermesAgentRun
    case hermesCronJob
    case appleReminder
    case hermesProject
}

struct ControlReference: Identifiable, Codable, Hashable, Equatable {
    let id: String
    let source: ControlSource
    let sourceID: String
    var sessionID: String?
    var projectID: String?

    init(source: ControlSource, sourceID: String, sessionID: String? = nil, projectID: String? = nil) {
        self.source = source
        self.sourceID = sourceID
        self.sessionID = sessionID
        self.projectID = projectID
        self.id = "\(source.rawValue):\(sourceID)"
    }
}

enum AttentionKind: String, Codable, CaseIterable {
    case approval
    case clarification
    case failure
    case completed
    case reminder
}

enum AttentionState: String, Codable {
    case open
    case snoozed
    case dismissed
    case resolved
}

enum AttentionAction: String, Codable, CaseIterable {
    case approve
    case deny
    case respond
    case resume
    case stop
    case open
    case dismiss
    case complete
}

struct AttentionItem: Identifiable, Codable, Equatable {
    let id: String
    let reference: ControlReference
    let kind: AttentionKind
    var title: String
    var detail: String
    var createdAt: Date
    var state: AttentionState
    var actions: [AttentionAction]
}

struct ReminderSummary: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let list: String?
    let dueDate: Date?
    let isOverdue: Bool
}

struct SessionSummary: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let state: String
    let preview: String?
}

struct AgentSummary: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let state: String
    let sessionID: String?
}

struct ProcessSummary: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let state: String
    let detail: String?
}

struct TodaySnapshot: Equatable {
    var currentFocus: ControlReference?
    var attention: [AttentionItem]
    var dueReminders: [ReminderSummary]
    var activeSessions: [SessionSummary]
    var activeAgents: [AgentSummary]
    var scheduledJobs: [CronSummary]
    var developmentContext: RepositorySnapshot?
}

struct CronSummary: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let schedule: String
    let enabled: Bool
    let nextRun: String?
    let sessionID: String?

    init(id: String, name: String, schedule: String, enabled: Bool, nextRun: String?, sessionID: String? = nil) {
        self.id = id
        self.name = name
        self.schedule = schedule
        self.enabled = enabled
        self.nextRun = nextRun
        self.sessionID = sessionID
    }
}

struct CronChangeRequest: Identifiable {
    let job: CronSummary
    let enable: Bool
    var id: String { "\(job.id):\(enable)" }
}

struct CapabilityState: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let isAvailable: Bool
    let recovery: String?
}

enum ControlTab: String, CaseIterable, Identifiable {
    case today = "Today"
    case inbox = "Inbox"
    case activity = "Activity"
    case automations = "Automations"
    case core = "Core"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .today: "sun.max"
        case .inbox: "tray"
        case .activity: "waveform.path.ecg"
        case .automations: "clock.arrow.circlepath"
        case .core: "cpu"
        }
    }
}
