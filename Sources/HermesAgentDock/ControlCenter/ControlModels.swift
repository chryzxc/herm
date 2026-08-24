import Foundation

@MainActor
enum HumanDateFormatting {
    private static let iso8601 = ISO8601DateFormatter()
    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let dateAndTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = .current
        return formatter
    }()

    static let timeOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.locale = .current
        return formatter
    }()

    static func dateAndTime(_ date: Date) -> String {
        dateAndTime.string(from: date)
    }

    static func timeOnly(_ date: Date) -> String {
        timeOnly.string(from: date)
    }

    static func dateAndTime(_ rawValue: String) -> String {
        guard let date = iso8601WithFractionalSeconds.date(from: rawValue) ?? iso8601.date(from: rawValue) else {
            return rawValue
        }
        return dateAndTime(date)
    }
}

@MainActor
enum CronScheduleFormatting {
    static func humanReadable(_ expression: String) -> String {
        let fields = expression.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 5 else { return "Custom schedule" }

        let minute = fields[0]
        let hour = fields[1]
        let dayOfMonth = fields[2]
        let month = fields[3]
        let dayOfWeek = fields[4]

        if minute.hasPrefix("*/"), hour == "*", dayOfMonth == "*", month == "*", dayOfWeek == "*",
           let interval = Int(minute.dropFirst(2)), interval > 0 {
            return interval == 1 ? "Every minute" : "Every \(interval) minutes"
        }
        if hour.hasPrefix("*/"), dayOfMonth == "*", month == "*", dayOfWeek == "*",
           let interval = Int(hour.dropFirst(2)), let minuteValue = Int(minute), interval > 0,
           (0...59).contains(minuteValue) {
            let time = clockTime(hour: 0, minute: minuteValue)
            return interval == 1 ? "Every hour at \(time)" : "Every \(interval) hours at \(time)"
        }

        guard let hourValue = Int(hour), let minuteValue = Int(minute),
              (0...23).contains(hourValue), (0...59).contains(minuteValue) else {
            return "Custom schedule"
        }
        let time = clockTime(hour: hourValue, minute: minuteValue)
        if dayOfMonth == "*", month == "*", dayOfWeek == "*" { return "Every day at \(time)" }
        if dayOfMonth == "*", month == "*", dayOfWeek == "1-5" { return "Weekdays at \(time)" }
        if dayOfMonth == "*", month == "*", let weekday = weekdayName(dayOfWeek) {
            return "Every \(weekday) at \(time)"
        }
        if dayOfMonth != "*", month == "*", dayOfWeek == "*" {
            return "Day \(dayOfMonth) of every month at \(time)"
        }
        return "Custom schedule at \(time)"
    }

    private static func clockTime(hour: Int, minute: Int) -> String {
        let normalizedHour = hour % 24
        let displayHour = normalizedHour % 12 == 0 ? 12 : normalizedHour % 12
        let suffix = normalizedHour >= 12 ? "PM" : "AM"
        return String(format: "%d:%02d %@", displayHour, minute, suffix)
    }

    private static func weekdayName(_ value: String) -> String? {
        switch value {
        case "0", "7": "Sunday"
        case "1": "Monday"
        case "2": "Tuesday"
        case "3": "Wednesday"
        case "4": "Thursday"
        case "5": "Friday"
        case "6": "Saturday"
        default: nil
        }
    }
}

enum CapabilitySource: String, Codable, Equatable {
    case gateway
    case cli
    case local
    case external
}

enum CapabilityCategory: String, Codable, CaseIterable, Hashable {
    case core
    case integration
    case review
    case security
}

enum CapabilityProvenance: String, Codable, Equatable {
    case hermesGateway
    case hermesCLI
    case localTool
    case external
}

enum CapabilityProbeState: String, Codable, Equatable {
    case verified
    case unverified
    case missing
    case unsupported
}

enum CapabilityAccessClassification: String, Codable, Equatable {
    case safeReadOnly
    case confirmedMutation
    case externalSetup
}

enum CapabilityAccess: String, Codable, Equatable {
    case readOnly
    case confirmedMutation
    case externalSetup
}

enum CapabilityAvailability: String, Codable, Equatable {
    case available
    case unsupported
    case unavailable
}

struct ApprovalPresentation: Equatable {
    let title: String
    let detail: String

    static func from(payload: [String: Any]) -> ApprovalPresentation {
        let command = stringValue(in: payload, keys: ["command", "cmd"])
        // The description/reason is usually the safety rule that triggered the
        // approval (for example, "recursive delete"). Lead with the command so
        // every approval surface shows the exact action the user is deciding on.
        let detail = command
            ?? stringValue(in: payload, keys: ["message", "details", "description", "reason"])
            ?? "Hermes wants to perform an action."

        let title = stringValue(in: payload, keys: ["title", "approval_title", "action_title"])
            ?? (command != nil ? "Run command" : "Review requested action")

        return ApprovalPresentation(title: title, detail: detail)
    }

    private static func stringValue(in payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = payload[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

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
    /// Hermes may offer safe, concrete replies for a clarification. Optional
    /// preserves compatibility with attention rows saved before choices were
    /// introduced.
    var choices: [String]? = nil
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

    var displayPreview: String? {
        SessionPreviewPresentation.summary(preview)
    }
}

/// Session list rows are an operational summary, not a transport log. Hermes
/// can return the last response as a JSON envelope (for example a failed shell
/// command), which is useful in Activity but noisy and potentially sensitive in
/// navigation.
enum SessionPreviewPresentation {
    static func summary(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: data),
           let dictionary = payload as? [String: Any] {
            return summary(for: dictionary)
        }

        let normalized = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if normalized.lowercased().hasPrefix("blocked:") {
            return "Blocked — action needs approval"
        }
        if normalized.lowercased().hasPrefix("error:") {
            return "Session reported an error"
        }
        if normalized.hasPrefix("{") || normalized.hasPrefix("[") {
            return "Session activity updated"
        }
        return normalized
    }

    private static func summary(for payload: [String: Any]) -> String {
        let error = (payload["error"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let exitCode = payload["exit_code"] as? Int

        if let error, !error.isEmpty {
            let lowercaseError = error.lowercased()
            if lowercaseError.contains("blocked") || lowercaseError.contains("approval") {
                return "Blocked — action needs approval"
            }
            if lowercaseError.contains("permission") || lowercaseError.contains("denied") {
                return "Blocked — permission required"
            }
            return "Session command failed"
        }
        if let exitCode, exitCode != 0 {
            return "Command failed (exit code \(exitCode))"
        }
        if let state = payload["state"] as? String, !state.isEmpty {
            return state.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return "Session activity updated"
    }
}

struct SessionActivityStep: Equatable {
    let id: String
    let name: String
    let timestamp: Date
}

struct LatestActivityItem: Identifiable, Equatable {
    let id: String
    let sessionID: String
    let sessionTitle: String
    let state: String
    let activityName: String
    let timestamp: Date
}

/// The Global overview's LATEST ACTIVITY strip is a cross-session activity
/// feed. A session may contribute multiple rows when several of its steps are
/// newer than the latest step from other sessions.
enum SessionActivityPresentation {
    static func latestActivity(
        _ sessions: [SessionSummary],
        stepsBySessionID: [String: [SessionActivityStep]],
        limit: Int = 10
    ) -> [LatestActivityItem] {
        let items = sessions.flatMap { session in
            (stepsBySessionID[session.id] ?? []).map { step in
                LatestActivityItem(
                    id: "\(session.id)|\(step.id)",
                    sessionID: session.id,
                    sessionTitle: session.title,
                    state: session.state,
                    activityName: step.name,
                    timestamp: step.timestamp
                )
            }
        }
        return Array(items.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.id > rhs.id
        }.prefix(max(0, limit)))
    }
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

struct ProjectSummary: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let repoCount: Int
    let sessionCount: Int
    let sessionIDs: Set<String>
    let preview: String?
    let isActive: Bool
}

struct ControlSearchResult: Identifiable, Equatable {
    let id: String
    let reference: ControlReference
    let title: String
    let detail: String
    let sourceLabel: String
}

struct KanbanTaskSummary: Identifiable, Equatable {
    let id: String
    let boardSlug: String?
    let title: String
    let status: String
    let detail: String?
    let priority: String?
    let assignee: String?

    init(id: String, boardSlug: String? = nil, title: String, status: String, detail: String?, priority: String?, assignee: String?) {
        self.id = id
        self.boardSlug = boardSlug
        self.title = title
        self.status = status
        self.detail = detail
        self.priority = priority
        self.assignee = assignee
    }
}

struct KanbanRunSummary: Identifiable, Equatable {
    let id: String
    let boardSlug: String?
    let status: String
    let outcome: String?
    let profile: String?
    let summary: String?
    let elapsed: String?

    init(id: String, boardSlug: String? = nil, status: String, outcome: String?, profile: String?, summary: String?, elapsed: String?) {
        self.id = id
        self.boardSlug = boardSlug
        self.status = status
        self.outcome = outcome
        self.profile = profile
        self.summary = summary
        self.elapsed = elapsed
    }
}

struct KanbanTaskDetail: Identifiable, Equatable {
    let id: String
    let boardSlug: String?
    let title: String
    let body: String?
    let status: String
    let priority: String?
    let assignee: String?
    let runs: [KanbanRunSummary]

    init(id: String, boardSlug: String? = nil, title: String, body: String?, status: String, priority: String?, assignee: String?, runs: [KanbanRunSummary]) {
        self.id = id
        self.boardSlug = boardSlug
        self.title = title
        self.body = body
        self.status = status
        self.priority = priority
        self.assignee = assignee
        self.runs = runs
    }
}

struct KanbanStatsSummary: Equatable {
    let counts: [String: Int]
}

struct KanbanBoardSummary: Identifiable, Equatable {
    let slug: String
    let name: String
    let description: String?
    let isCurrent: Bool
    let archived: Bool
    let total: Int
    let counts: [String: Int]

    var id: String { slug }
}

/// A read-only projection of Hermes' Kanban list flags. Hermes remains the
/// canonical owner of filtering and ordering; the Dock only forwards options.
struct KanbanListFilter: Equatable {
    var status: String?
    var assignee: String?
    var mine = false
    var sessionID: String?
    var includeArchived = false
    var sort: String?
}

struct HermesJourneyNode: Identifiable, Equatable {
    let id: String
    let label: String
    let kind: String
    let category: String?
    let state: String?
    let useCount: Int?
}

struct HermesReadOnlyStatus: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let isAvailable: Bool
}

struct SessionUsageSummary: Equatable {
    let calls: Int
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let contextUsed: Int?
    let contextMax: Int?
    let contextPercent: Double?
    let model: String?
}

struct ProviderQuotaWindow: Identifiable, Equatable {
    let id: String
    let label: String
    let remainingPercent: Double?
    let remainingDisplay: String?
    let limitDisplay: String?
    let resetsAt: Date?
    let resetsDisplay: String?

    var threshold: ProviderQuotaThreshold {
        guard let remainingPercent else { return .unknown }
        if remainingPercent <= 10 { return .critical }
        if remainingPercent <= 20 { return .warning }
        return .healthy
    }
}

struct ProviderQuotaSnapshot: Equatable {
    let provider: String
    let displayName: String
    let model: String?
    let updatedAt: Date
    let windows: [ProviderQuotaWindow]
    let safeDetail: String?
}

enum ProviderQuotaThreshold: Equatable {
    case healthy, warning, critical, unknown
}

struct SessionContextCategory: Identifiable, Equatable {
    let id: String
    let label: String
    let tokens: Int
    let percent: Double?
}

struct SessionContextSummary: Equatable {
    let categories: [SessionContextCategory]
    let contextUsed: Int
    let contextMax: Int
    let contextPercent: Double?
    let estimatedTotal: Int
    let model: String?
}

enum SessionTextActionStatus: String, Equatable {
    case queued
    case redirected
    case rejected
}

struct SessionTextActionResult: Equatable {
    let status: SessionTextActionStatus
    let text: String

    var wasAccepted: Bool { status != .rejected }
}

struct ProjectionRefreshState: Equatable {
    var lastSuccess: Date?
    var error: String?
    var isStale: Bool
    var isRefreshing: Bool
}

enum KanbanTaskAction: String, CaseIterable {
    case complete
    case block
    case unblock
    case archive
}

enum KanbanMutationKind: String, CaseIterable, Identifiable {
    case comment
    case schedule
    case assign
    case reassign
    case promote
    case reclaim

    var id: String { rawValue }
    var title: String { rawValue.replacingOccurrences(of: "_", with: " ").uppercased() }
    var capabilityID: String { "kanban.\(rawValue)" }
}

struct KanbanMutationRequest: Identifiable {
    let task: KanbanTaskSummary
    let kind: KanbanMutationKind
    let value: String
    let reclaimFirst: Bool
    var id: String { "\(kind.rawValue):\(task.id)" }
}

struct KanbanChangeRequest: Identifiable {
    let task: KanbanTaskSummary
    let action: KanbanTaskAction
    var id: String { "\(action.rawValue):\(task.id)" }
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
    let delivery: String?
    let prompt: String?
    let report: String?
    let editableFields: Set<CronEditField>

    init(id: String, name: String, schedule: String, enabled: Bool, nextRun: String?, sessionID: String? = nil, delivery: String? = nil, prompt: String? = nil, report: String? = nil, editableFields: Set<CronEditField> = []) {
        self.id = id
        self.name = name
        self.schedule = schedule
        self.enabled = enabled
        self.nextRun = nextRun
        self.sessionID = sessionID
        self.delivery = delivery
        self.prompt = prompt
        self.report = report
        self.editableFields = editableFields
    }
}

enum CronEditField: String, CaseIterable, Hashable, Identifiable, Codable {
    case name
    case schedule
    case prompt
    case deliver
    case workdir
    case model
    case provider

    var id: String { rawValue }
    var flag: String {
        switch self {
        case .name: "--name"
        case .schedule: "--schedule"
        case .prompt: "--prompt"
        case .deliver: "--deliver"
        case .workdir: "--workdir"
        case .model: "--model"
        case .provider: "--provider"
        }
    }
    var title: String { rawValue.uppercased() }
}

struct CronEditDraft: Equatable {
    var name: String
    var schedule: String
    var prompt: String

    init(job: CronSummary) {
        name = job.name
        schedule = job.schedule
        prompt = job.prompt ?? ""
    }

    func changes(comparedTo job: CronSummary) -> [CronEditField: String] {
        var result: [CronEditField: String] = [:]
        if name != job.name { result[.name] = name }
        if schedule != job.schedule { result[.schedule] = schedule }
        if prompt != (job.prompt ?? "") { result[.prompt] = prompt }
        return result
    }
}

enum CronSchedule {
    /// 5-field cron sanity check; Hermes remains the authoritative validator.
    static func isValid(_ schedule: String) -> Bool {
        let trimmed = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count == 5 else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789*/,-").union(.letters)
        return fields.allSatisfy { field in
            !field.isEmpty
                && field.count <= 20
                && field.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }
}

struct CronRunSummary: Identifiable, Equatable {
    let id: String
    let status: String
    let jobID: String?
    let source: String?
    let claimedAt: String?
    let error: String?
    let sessionID: String?

    init(id: String, status: String, jobID: String?, source: String?, claimedAt: String?, error: String?, sessionID: String? = nil) {
        self.id = id
        self.status = status
        self.jobID = jobID
        self.source = source
        self.claimedAt = claimedAt
        self.error = error
        self.sessionID = sessionID
    }
}

struct CronReportDetail: Identifiable, Equatable {
    let id: String
    let jobID: String
    let title: String
    let markdown: String
}

struct CronReportRequest: Identifiable, Equatable {
    let job: CronSummary
    let sessionID: String
    var id: String { sessionID }
}

struct MCPServerSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let transport: String
    let tools: String
    let isEnabled: Bool
}

struct CapabilityState: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let isAvailable: Bool
    let recovery: String?
    let recoveryCommand: String?
    let source: CapabilitySource
    let access: CapabilityAccess
    let availability: CapabilityAvailability
    let category: CapabilityCategory
    let provenance: CapabilityProvenance
    let probeState: CapabilityProbeState
    let accessClassification: CapabilityAccessClassification

    init(
        id: String,
        title: String,
        detail: String,
        isAvailable: Bool,
        recovery: String?,
        recoveryCommand: String? = nil,
        source: CapabilitySource = .gateway,
        access: CapabilityAccess = .readOnly,
        availability: CapabilityAvailability? = nil,
        category: CapabilityCategory? = nil,
        provenance: CapabilityProvenance? = nil,
        probeState: CapabilityProbeState? = nil,
        accessClassification: CapabilityAccessClassification? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isAvailable = isAvailable
        self.recovery = recovery
        self.recoveryCommand = recoveryCommand
        self.source = source
        self.access = access
        if isAvailable {
            self.availability = .available
        } else if availability == .unavailable {
            self.availability = .unavailable
        } else {
            self.availability = .unsupported
        }
        self.category = category ?? CapabilityCategory(readinessID: id)
        self.provenance = CapabilityProvenance(source: source)
        switch self.availability {
        case .available:
            self.probeState = probeState == .missing || probeState == .unsupported ? .unverified : (probeState ?? .unverified)
        case .unavailable:
            self.probeState = .missing
        case .unsupported:
            self.probeState = .unsupported
        }
        self.accessClassification = CapabilityAccessClassification(access: access)
    }
}

extension CapabilityCategory {
    init(readinessID: String) {
        let id = readinessID.lowercased()
        if ["security", "gitleaks", "semgrep", "trivy", "snyk", "yara"].contains(where: id.contains) {
            self = .security
        } else if ["review", "ocr", "opencode"].contains(where: id.contains) {
            self = .review
        } else if ["integration", "reminder", "note", "calendar", "messaging", "email", "mcp", "kanban", "cron"].contains(where: id.contains) {
            self = .integration
        } else {
            self = .core
        }
    }
}

extension CapabilityProvenance {
    init(source: CapabilitySource) {
        switch source {
        case .gateway: self = .hermesGateway
        case .cli: self = .hermesCLI
        case .local: self = .localTool
        case .external: self = .external
        }
    }
}

extension CapabilityAccessClassification {
    init(access: CapabilityAccess) {
        switch access {
        case .readOnly: self = .safeReadOnly
        case .confirmedMutation: self = .confirmedMutation
        case .externalSetup: self = .externalSetup
        }
    }
}

struct CapabilitySnapshot: Equatable {
    let states: [CapabilityState]
    let generatedAt: Date

    var sortedStates: [CapabilityState] {
        states.sorted {
            ($0.category.rawValue, $0.title, $0.id) < ($1.category.rawValue, $1.title, $1.id)
        }
    }

    var statesByCategory: [CapabilityCategory: [CapabilityState]] {
        Dictionary(grouping: sortedStates, by: \.category)
    }

    func state(for id: String) -> CapabilityState? {
        states.first { $0.id == id }
    }
}

struct HermesDiagnostic: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let isAvailable: Bool
}

struct KanbanDiagnosticSummary: Identifiable, Equatable {
    let id: String
    let severity: String
    let title: String
    let detail: String
    let taskID: String?
}

struct KanbanAttachmentSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String?
    let sizeBytes: Int?
}

struct PromptBudgetSummary: Equatable {
    let totalTokens: Int
    let tokenLimit: Int?
    let percent: Double?
    let model: String?
}

struct ProjectFactsSummary: Equatable {
    let root: String?
    let manifests: [String]
    let packageManagers: [String]
    let verifyCommands: [String]
    let contextFiles: [String]
}

enum VerificationState: String, Equatable {
    case passed
    case failed
    case unverified
    case unknown
    case notApplicable
}

struct VerificationEvidenceSummary: Equatable {
    let command: String?
    let canonicalCommand: String?
    let kind: String?
    let scope: String?
    let status: String?
    let exitCode: Int?
    let outputSummary: String?
}

struct VerificationSummary: Equatable {
    let state: VerificationState
    let evidence: VerificationEvidenceSummary?
}

enum ControlTab: String, CaseIterable, Identifiable {
    case today = "Today"
    case session = "Session"
    case inbox = "Inbox"
    case activity = "Activity"
    case changes = "Source Control"
    case verification = "Verification"
    case automations = "Automations"
    case projects = "Projects"
    case search = "Search"
    case kanban = "Kanban"
    case core = "Core"
    case quota = "Quota"

    /// The fixed navigation strip is deliberately limited to the destinations
    /// used to orient, triage, and act on work. Everything else remains one
    /// click away in a grouped menu instead of competing for horizontal space.
    static let primaryNavigation: [ControlTab] = [.today, .inbox, .kanban]
    /// The Global strip has five directly visible destinations; secondary
    /// operational views remain behind More.
    static let globalNavigation: [ControlTab] = [.today, .inbox, .kanban, .projects, .quota]
    static let sessionNavigation: [ControlTab] = [.session, .activity, .changes, .verification]
    static let workspaceNavigation: [ControlTab] = [.projects]
    static let toolsNavigation: [ControlTab] = [.automations, .search, .core]

    static var secondaryNavigation: [ControlTab] {
        sessionNavigation + toolsNavigation
    }

    var id: String { rawValue }
    var tabLabel: String {
        switch self {
        case .session: "Overview"
        case .automations: "Automate"
        default: rawValue
        }
    }

    var icon: String {
        switch self {
        case .today: "sun.max"
        case .session: "bubble.left.and.bubble.right"
        case .inbox: "tray"
        case .activity: "waveform.path.ecg"
        case .changes: "doc.text.magnifyingglass"
        case .verification: "checkmark.seal"
        case .automations: "clock.arrow.circlepath"
        case .projects: "folder.badge.gearshape"
        case .search: "magnifyingglass"
        case .kanban: "rectangle.3.group"
        case .core: "cpu"
        case .quota: "gauge.with.dots.needle.50percent"
        }
    }
}

enum InboxFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case needsResponse = "Needs response"
    case approvals = "Approvals"
    case clarifications = "Clarifications"
    case failures = "Failures"
    case reminders = "Reminders"
    case completed = "Completed"

    var id: String { rawValue }

    func includes(_ item: AttentionItem) -> Bool {
        switch self {
        case .all: true
        case .needsResponse: item.kind == .approval || item.kind == .clarification
        case .approvals: item.kind == .approval
        case .clarifications: item.kind == .clarification
        case .failures: item.kind == .failure
        case .reminders: item.kind == .reminder
        case .completed: item.kind == .completed
        }
    }
}

struct ControlTabBadgeState: Equatable {
    let urgentAttentionCount: Int
    let inboxCount: Int
    let activityCount: Int
    let changeCount: Int
    let verificationCount: Int

    static func make(attention: [AttentionItem], activeAgentCount: Int, activeToolCount: Int, changeCount: Int = 0, verificationCount: Int = 0) -> ControlTabBadgeState {
        let openAttention = attention.filter { $0.state == .open }
        let urgent = openAttention.filter { item in
            switch item.kind {
            case .approval, .clarification, .failure: true
            case .completed, .reminder: false
            }
        }
        return ControlTabBadgeState(
            urgentAttentionCount: urgent.count,
            inboxCount: openAttention.count,
            activityCount: max(0, activeAgentCount) + max(0, activeToolCount),
            changeCount: max(0, changeCount),
            verificationCount: max(0, verificationCount)
        )
    }

    func count(for tab: ControlTab) -> Int {
        switch tab {
        case .today: urgentAttentionCount
        case .session: 0
        case .inbox: inboxCount
        case .activity: activityCount
        case .changes: changeCount
        case .verification: verificationCount
        case .automations, .projects, .search, .kanban, .core, .quota: 0
        }
    }

    func isUrgent(for tab: ControlTab) -> Bool {
        switch tab {
        case .today: urgentAttentionCount > 0
        case .session: false
        case .inbox: urgentAttentionCount > 0
        case .changes: changeCount > 0
        case .verification: verificationCount > 0
        case .activity, .automations, .projects, .search, .kanban, .core, .quota: false
        }
    }
}
