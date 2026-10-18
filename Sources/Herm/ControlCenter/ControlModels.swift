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
        guard let date = date(rawValue) else { return rawValue }
        return dateAndTime(date)
    }

    static func date(_ rawValue: String) -> Date? {
        iso8601WithFractionalSeconds.date(from: rawValue) ?? iso8601.date(from: rawValue)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let relativeFullFormatter = RelativeDateTimeFormatter()

    /// "2 hours ago", for list rows that re-render on every scroll frame.
    static func relative(_ date: Date, now: Date = .now) -> String {
        relativeFullFormatter.localizedString(for: date, relativeTo: now)
    }

    /// "in 3 hr" / "2 days ago"; falls back to the raw value when it is not ISO 8601.
    static func relative(_ rawValue: String, now: Date = .now) -> String {
        guard let date = date(rawValue) else { return rawValue }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }
}

@MainActor
enum CronScheduleFormatting {
    static func humanReadable(_ expression: String) -> String {
        if let interval = intervalDescription(expression) { return interval }
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

    /// Hermes interval schedules such as "every 15m", "every 1440m", "every 2h".
    private static func intervalDescription(_ expression: String) -> String? {
        let parts = expression.lowercased().split(separator: " ")
        guard parts.count == 2, parts[0] == "every", let unit = parts[1].last,
              let value = Int(parts[1].dropLast()), value > 0 else { return nil }
        let minutes: Int
        switch unit {
        case "m": minutes = value
        case "h": minutes = value * 60
        case "d": minutes = value * 1_440
        default: return nil
        }
        if minutes % 10_080 == 0 { return minutes == 10_080 ? "Every week" : "Every \(minutes / 10_080) weeks" }
        if minutes % 1_440 == 0 { return minutes == 1_440 ? "Every day" : "Every \(minutes / 1_440) days" }
        if minutes % 60 == 0 { return minutes == 60 ? "Every hour" : "Every \(minutes / 60) hours" }
        return minutes == 1 ? "Every minute" : "Every \(minutes) minutes"
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
    let detailIsCommand: Bool
    /// Why Hermes flagged the command (its `description`), shown under the command.
    var reason: String? = nil
    /// The decisions Hermes offers for this request, in order (once / session / always / deny).
    var choices: [String] = ApprovalChoice.all
    var requestID: String? = nil
    /// Hermes' safety check denied this; the owner may still override it once.
    var smartDenied = false

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

        let description = stringValue(in: payload, keys: ["description", "reason"])
        let smartDenied = payload["smart_denied"] as? Bool == true
        // Mirror Hermes' `_approval_request_payload` when an older backend omits `choices`.
        var choices = (payload["choices"] as? [String])?.filter(ApprovalChoice.all.contains) ?? []
        if choices.isEmpty {
            choices = [ApprovalChoice.once]
            if !smartDenied, payload["allow_session"] as? Bool != false {
                choices.append(ApprovalChoice.session)
                if payload["allow_permanent"] as? Bool != false { choices.append(ApprovalChoice.always) }
            }
            choices.append(ApprovalChoice.deny)
        }
        return ApprovalPresentation(
            title: title,
            detail: detail,
            detailIsCommand: command != nil,
            reason: command != nil && description != detail ? description : nil,
            choices: choices,
            requestID: stringValue(in: payload, keys: ["request_id"]),
            smartDenied: smartDenied
        )
    }

    static func alwaysAllowCaption(for presentation: ApprovalPresentation) -> String {
        guard presentation.detailIsCommand else {
            return "Hermes may limit this to the current session for content findings."
        }
        return "Always allow persists this command in Hermes' allowlist. Never ask again for: \(presentation.detail)"
    }

    static func alwaysAllowCaption(title: String, detail: String) -> String {
        alwaysAllowCaption(for: ApprovalPresentation(
            title: title,
            detail: detail,
            detailIsCommand: title == "Run command"
        ))
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

enum ApprovalChoice {
    static let deny = "deny"
    static let once = "once"
    static let always = "always"
    static let session = "session"
    static let all = [once, session, always, deny]
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
    var clarificationRequestID: String?

    init(source: ControlSource, sourceID: String, sessionID: String? = nil, projectID: String? = nil, clarificationRequestID: String? = nil) {
        self.source = source
        self.sourceID = sourceID
        self.sessionID = sessionID
        self.projectID = projectID
        self.clarificationRequestID = clarificationRequestID
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
    var reference: ControlReference
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
    let profileID: String?
    let title: String
    let state: String
    let preview: String?
    let updatedAt: Date?

    var displayPreview: String? {
        SessionPreviewPresentation.summary(preview)
    }

    var lastUpdatedAt: Date? { updatedAt }

    init(id: String, title: String, state: String, preview: String?, updatedAt: Date? = nil, profileID: String? = nil) {
        self.id = id
        self.profileID = profileID
        self.title = title
        self.state = state
        self.preview = preview
        self.updatedAt = updatedAt
    }
}

/// Stable, user-facing lifecycle semantics for session rows. Hermes may add
/// transport states over time; unknown or missing attribution must never look
/// like an idle/completed session.
enum SessionLifecycleStatus: String, CaseIterable, Equatable, Sendable {
    case active
    case completed
    case failed
    case stale
    case unavailable

    var label: String { rawValue.capitalized }
}

enum SessionLifecyclePresentation {
    static func status(for session: SessionSummary, refresh: ProjectionRefreshState? = nil) -> SessionLifecycleStatus {
        guard !session.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unavailable }
        if refresh?.isStale == true { return .stale }
        if refresh?.lastSuccess == nil, refresh?.error != nil { return .unavailable }

        switch session.state
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_") {
        case "running", "active", "working", "busy", "streaming", "pending", "queued",
             "starting", "needs_approval", "needs_clarification", "waiting", "waiting_for_input":
            return .active
        case "completed", "complete", "done", "idle", "finished", "archived":
            return .completed
        case "failed", "failure", "error", "errored":
            return .failed
        default:
            return .unavailable
        }
    }

    static func detail(for session: SessionSummary, refresh: ProjectionRefreshState? = nil) -> String {
        status(for: session, refresh: refresh).label
    }

    static func rowLabel(for session: SessionSummary, isCurrent: Bool, refresh: ProjectionRefreshState? = nil) -> String {
        let lifecycle = detail(for: session, refresh: refresh)
        return isCurrent ? "Current · \(lifecycle)" : lifecycle
    }

    static func accessibilityLabel(for session: SessionSummary, refresh: ProjectionRefreshState? = nil) -> String {
        "\(detail(for: session, refresh: refresh)): \(session.title)"
    }

    static func accessibilityLabel(for session: SessionSummary, isCurrent: Bool, refresh: ProjectionRefreshState? = nil) -> String {
        "\(rowLabel(for: session, isCurrent: isCurrent, refresh: refresh)): \(session.title)"
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

enum LatestActivityPresentation {
    static let maxMarkdownCharacters = 4_000

    static func boundedMarkdown(_ source: String) -> String {
        guard source.count > maxMarkdownCharacters else { return source }
        return String(source.prefix(maxMarkdownCharacters)) + "…"
    }
}

/// The Global overview's LATEST ACTIVITY strip is a cross-session activity
/// feed. A session may contribute multiple rows when several of its steps are
/// newer than the latest step from other sessions.
enum GlobalSessionActivityPresentation {
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

// Keep the original internal name available to existing projections and tests
// while the global feed uses the more explicit type name above.
typealias SessionActivityPresentation = GlobalSessionActivityPresentation

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

    /// The gateway can expose internal/session buckets alongside real
    /// repo-backed projects. Those buckets must not claim ownership of a
    /// conversation in navigation or session metadata.
    var isRenderableProject: Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedName.isEmpty,
              normalizedName != "__no_project__",
              normalizedName != "tmp" else { return false }

        // Hermes gives every real project a generated `p_<hex>` id, so only a
        // generated-looking *name* (a bucket that defaulted to its id) is internal.
        return normalizedName.range(of: "^p_[0-9a-f]{8,}$", options: .regularExpression) == nil
    }
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
    var status: String
    let detail: String?
    let priority: String?
    var assignee: String?
    let sessionID: String?
    let startedAt: Date?
    let completedAt: Date?
    let currentStepKey: String?
    let latestEventKind: String?
    let latestEventNote: String?
    let latestEventAt: Date?
    let modelOverride: String?
    let providerOverride: String?
    let skills: [String]
    let workflowTemplateID: String?
    /// The directory the task ran in, usually a git worktree of the project.
    let workspacePath: String?

    init(id: String, boardSlug: String? = nil, title: String, status: String, detail: String?, priority: String?, assignee: String?, sessionID: String? = nil, startedAt: Date? = nil, completedAt: Date? = nil, currentStepKey: String? = nil, latestEventKind: String? = nil, latestEventNote: String? = nil, latestEventAt: Date? = nil, modelOverride: String? = nil, providerOverride: String? = nil, skills: [String] = [], workflowTemplateID: String? = nil, workspacePath: String? = nil) {
        self.id = id
        self.boardSlug = boardSlug
        self.title = title
        self.status = status
        self.detail = detail
        self.priority = priority
        self.assignee = assignee
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.currentStepKey = currentStepKey
        self.latestEventKind = latestEventKind
        self.latestEventNote = latestEventNote
        self.latestEventAt = latestEventAt
        self.modelOverride = modelOverride
        self.providerOverride = providerOverride
        self.skills = skills
        self.workflowTemplateID = workflowTemplateID
        self.workspacePath = workspacePath
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
    let stepKey: String?
    let error: String?
    let startedAt: Date?
    let endedAt: Date?

    init(id: String, boardSlug: String? = nil, status: String, outcome: String?, profile: String?, summary: String?, elapsed: String?, stepKey: String? = nil, error: String? = nil, startedAt: Date? = nil, endedAt: Date? = nil) {
        self.id = id
        self.boardSlug = boardSlug
        self.status = status
        self.outcome = outcome
        self.profile = profile
        self.summary = summary
        self.elapsed = elapsed
        self.stepKey = stepKey
        self.error = error
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

struct KanbanCommentSummary: Identifiable, Equatable {
    let id: String
    let author: String
    let body: String
    let createdAt: Date?
}

/// One `task_events` row. `note` is the human-readable part of the payload,
/// when Hermes supplied one; the raw kind is always kept for traceability.
struct KanbanEventSummary: Identifiable, Equatable {
    let id: String
    let kind: String
    let note: String?
    let runID: String?
    let createdAt: Date?
    /// `payload.assignee` on created/assigned events.
    var assignee: String? = nil
}

struct KanbanTaskDetail: Identifiable, Equatable {
    let id: String
    var boardSlug: String?
    let title: String
    let body: String?
    let status: String
    let priority: String?
    let assignee: String?
    var runs: [KanbanRunSummary]
    let modelOverride: String?
    let providerOverride: String?
    // Fields below come from `kanban show --json`; older Hermes versions and
    // the summary fallback leave them empty.
    var latestSummary: String?
    var result: String?
    var lastFailureError: String?
    var skills: [String] = []
    var workflowTemplateID: String?
    var currentStepKey: String?
    var workspaceKind: String?
    var workspacePath: String?
    var branchName: String?
    var sessionID: String?
    var createdBy: String?
    var createdAt: Date?
    var startedAt: Date?
    var completedAt: Date?
    var parents: [String] = []
    var children: [String] = []
    var comments: [KanbanCommentSummary] = []
    var events: [KanbanEventSummary] = []

    init(id: String, boardSlug: String? = nil, title: String, body: String?, status: String, priority: String?, assignee: String?, runs: [KanbanRunSummary], modelOverride: String? = nil, providerOverride: String? = nil) {
        self.id = id
        self.boardSlug = boardSlug
        self.title = title
        self.body = body
        self.status = status
        self.priority = priority
        self.assignee = assignee
        self.runs = runs
        self.modelOverride = modelOverride
        self.providerOverride = providerOverride
    }
}

extension KanbanTaskDetail {
    /// Why the card stopped, for blocked/triage cards: the latest block event's
    /// reason and the last run's error from Hermes' Kanban projection.
    struct BlockExplanation: Equatable {
        var kind: String?
        var reason: String?
        var lastError: String?
    }

    var blockExplanation: BlockExplanation? {
        guard ["blocked", "triage"].contains(status.lowercased()) else { return nil }
        let event = events.last { ["blocked", "gave_up", "block_loop_detected"].contains($0.kind) }
        let explanation = BlockExplanation(
            kind: event?.kind,
            reason: event?.note,
            lastError: lastFailureError.flatMap { $0 == event?.note ? nil : $0 }
        )
        return explanation == BlockExplanation() ? nil : explanation
    }
}

struct KanbanTaskIdentity: Hashable, Equatable {
    let boardSlug: String?
    let taskID: String
}

/// A cached task inspection. `detail` starts as the card summary and is
/// replaced by `kanban show`; it stays visible while a refresh is in flight.
struct KanbanTaskInspection: Equatable {
    var detail: KanbanTaskDetail
    var attachments: [KanbanAttachmentSummary] = []
    /// False when the attachment listing failed, as opposed to an empty list.
    var attachmentsAvailable = true
    var isLoading = false
    var error: String?
    var loadedAt: Date?
}

enum KanbanInspectorTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case activity = "Activity"

    var id: String { rawValue }
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
struct KanbanListFilter: Equatable, Sendable {
    var status: String?
    var assignee: String?
    var mine = false
    var sessionID: String?
    var includeArchived = false
    var sort: String?
}

/// Human-readable ordering choices exposed by the Kanban toolbar.
enum KanbanSortOption: String, CaseIterable, Identifiable {
    case updated
    case createdDesc = "created-desc"
    case priorityDesc = "priority-desc"
    case title

    var id: String { rawValue }
    var label: String {
        switch self {
        case .updated: "Updated"
        case .createdDesc: "Created"
        case .priorityDesc: "Priority"
        case .title: "Title"
        }
    }
}

struct KanbanFilterPresentation: Equatable {
    let status: String
    let assignee: String
    let mineOnly: Bool
    let sort: KanbanSortOption

    var isActive: Bool {
        status != "All" || assignee != "All" || mineOnly || sort != .updated
    }
}

/// Empty lanes start collapsed and lanes with work start expanded. Either can
/// be toggled locally; an empty lane that receives work expands unless the
/// person collapsed that lane while it had work.
struct KanbanLaneExpansionState: Equatable {
    var expandedEmptyLanes: Set<KanbanLane> = []
    var collapsedLanes: Set<KanbanLane> = []

    func isExpanded(_ lane: KanbanLane, hasTasks: Bool) -> Bool {
        hasTasks ? !collapsedLanes.contains(lane) : expandedEmptyLanes.contains(lane)
    }

    mutating func expand(_ lane: KanbanLane, hasTasks: Bool) {
        if hasTasks {
            collapsedLanes.remove(lane)
        } else {
            expandedEmptyLanes.insert(lane)
        }
    }

    mutating func collapse(_ lane: KanbanLane, hasTasks: Bool) {
        if hasTasks {
            collapsedLanes.insert(lane)
        } else {
            expandedEmptyLanes.remove(lane)
        }
    }
}

/// Identifies the authoritative scope of an in-flight session Kanban query.
/// Multiple workspace surfaces can observe the same session; identical reads
/// must share one request rather than canceling one another.
struct SessionKanbanProjectionRequest: Hashable {
    let sessionID: String?
    let boardSlug: String?
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

/// Hermes' `/api/analytics/usage` report. `totals` and `daily` carry the
/// main conversation loop only; auxiliary work (review, compression, titles,
/// vision…) lives in `tasks` and is folded into each model's figures.
struct TokenUsageReport: Equatable {
    struct Day: Identifiable, Equatable {
        let day: Date
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let reasoningTokens: Int
        let estimatedCost: Double
        let sessions: Int
        let apiCalls: Int
        var id: Date { day }
    }

    struct Task: Identifiable, Equatable {
        let task: String
        let inputTokens: Int
        let outputTokens: Int
        let estimatedCost: Double
        let apiCalls: Int
        var id: String { task }
        var totalTokens: Int { inputTokens + outputTokens }
    }

    struct Model: Identifiable, Equatable {
        let model: String
        let inputTokens: Int
        let outputTokens: Int
        let estimatedCost: Double
        let sessions: Int
        let apiCalls: Int
        let tasks: [Task]
        /// Hermes billing providers that served this model, busiest first.
        var providers: [String] = []
        var id: String { model }
        var totalTokens: Int { inputTokens + outputTokens }
    }

    struct Share: Identifiable, Equatable {
        let name: String
        let count: Int
        let percentage: Double
        var id: String { name }
    }

    let days: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let reasoningTokens: Int
    let estimatedCost: Double
    let actualCost: Double
    let sessions: Int
    let apiCalls: Int
    let daily: [Day]
    let models: [Model]
    let tasks: [Task]
    let tools: [Share]
    let skills: [Share]
    let skillLoads: Int
    let distinctSkills: Int

    var auxInputTokens: Int { tasks.reduce(0) { $0 + $1.inputTokens } }
    var auxOutputTokens: Int { tasks.reduce(0) { $0 + $1.outputTokens } }
    var auxCost: Double { tasks.reduce(0) { $0 + $1.estimatedCost } }
    /// Main loop plus auxiliary work, matching the per-model table.
    var totalInputTokens: Int { inputTokens + auxInputTokens }
    var totalOutputTokens: Int { outputTokens + auxOutputTokens }
    var totalTokens: Int { totalInputTokens + totalOutputTokens }
    var totalCost: Double { estimatedCost + auxCost }
    /// Share of prompt tokens served from the provider cache.
    var cacheHitRate: Double? {
        let prompt = inputTokens + cacheReadTokens
        return prompt > 0 ? Double(cacheReadTokens) / Double(prompt) : nil
    }
}

struct ProviderQuotaWindow: Identifiable, Equatable {
    let id: String
    let label: String
    let remainingPercent: Double?
    let remainingDisplay: String?
    let limitDisplay: String?
    let resetsAt: Date?
    let resetsDisplay: String?
    /// USD balance behind `remainingDisplay` for pay-as-you-go providers.
    var amount: Double? = nil

    var threshold: ProviderQuotaThreshold {
        guard let remainingPercent else { return .unknown }
        return Self.threshold(forRemaining: remainingPercent)
    }

    static func threshold(forRemaining remainingPercent: Double) -> ProviderQuotaThreshold {
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
    /// Set when this account is an entry in Hermes' credential pool, which
    /// makes it removable through `hermes auth remove`.
    var hermesCredential: HermesPooledCredential? = nil
}

/// One entry of Hermes' credential pool (`hermes auth list <provider>`).
struct HermesPooledCredential: Equatable {
    /// Hermes provider id, such as `openai-codex`.
    let provider: String
    /// Stable pool entry id; `hermes auth remove` accepts it as the target.
    let id: String
    let label: String
    /// 1-based position as `hermes auth list` numbers it.
    let position: Int
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
    var compressionThresholdTokens: Int? = nil
    var compressionEnabled: Bool? = nil
    var contextEstimated: Bool = false
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
    var title: String { rawValue.capitalized }
    var capabilityID: String {
        HermesFeatureIDs.lookup("kanban.\(rawValue)")?.rawValue ?? rawValue
    }
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

struct CronOwner: Codable, Equatable { let profileID: String? }

struct CronSummary: Identifiable, Codable, Equatable {
    var owner: CronOwner? = nil
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
    let lastRunAt: String?
    let lastStatus: String?
    let lastError: String?
    let details: CronJobDetails

    init(id: String, name: String, schedule: String, enabled: Bool, nextRun: String?, sessionID: String? = nil, delivery: String? = nil, prompt: String? = nil, report: String? = nil, editableFields: Set<CronEditField> = [], lastRunAt: String? = nil, lastStatus: String? = nil, lastError: String? = nil, details: CronJobDetails = CronJobDetails()) {
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
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
        self.lastError = lastError
        self.details = details
    }
}

/// Secondary job configuration Hermes reports in `cron.manage list`; display-only.
struct CronJobDetails: Codable, Equatable {
    var model: String?
    var provider: String?
    var skills: [String] = []
    var toolsets: [String] = []
    var script: String?
    var workdir: String?
    var repeats: String?
    var deliveryError: String?
    var pausedReason: String?
    var noAgent: Bool?

    init(model: String? = nil, provider: String? = nil, skills: [String] = [], toolsets: [String] = [], script: String? = nil, workdir: String? = nil, repeats: String? = nil, deliveryError: String? = nil, pausedReason: String? = nil, noAgent: Bool? = nil) {
        self.model = model
        self.provider = provider
        self.skills = skills
        self.toolsets = toolsets
        self.script = script
        self.workdir = workdir
        self.repeats = repeats
        self.deliveryError = deliveryError
        self.pausedReason = pausedReason
        self.noAgent = noAgent
    }

    init(row: [String: Any]) {
        func text(_ key: String) -> String? {
            (row[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        self.init(
            model: text("model"),
            provider: text("provider"),
            skills: row["skills"] as? [String] ?? [],
            toolsets: row["enabled_toolsets"] as? [String] ?? [],
            script: text("script"),
            workdir: text("workdir"),
            repeats: text("repeat"),
            deliveryError: text("last_delivery_error") ?? text("last_fire_error"),
            pausedReason: text("paused_reason"),
            noAgent: row["no_agent"] as? Bool
        )
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

struct CronConfigurationDraft: Equatable {
    var delivery = "local"
    var workdir = ""
    var model = ""
    var provider = ""

    var parameters: [String: Any] {
        var result: [String: Any] = ["deliver": delivery.trimmingCharacters(in: .whitespacesAndNewlines)]
        for (key, value) in [("workdir", workdir), ("model", model), ("provider", provider)] {
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { result[key] = clean }
        }
        return result
    }
}

struct CronEditDraft: Equatable {
    var name: String
    var schedule: String
    var prompt: String
    var configuration: CronConfigurationDraft

    init(job: CronSummary) {
        name = job.name
        schedule = job.schedule
        prompt = job.prompt ?? ""
        configuration = CronConfigurationDraft(delivery: job.delivery ?? "local", workdir: job.details.workdir ?? "", model: job.details.model ?? "", provider: job.details.provider ?? "")
    }

    func changes(comparedTo job: CronSummary) -> [CronEditField: String] {
        var result: [CronEditField: String] = [:]
        if name != job.name { result[.name] = name }
        if schedule != job.schedule { result[.schedule] = schedule }
        if prompt != (job.prompt ?? "") { result[.prompt] = prompt }
        if configuration.delivery != (job.delivery ?? "local") { result[.deliver] = configuration.delivery }
        if configuration.workdir != (job.details.workdir ?? "") { result[.workdir] = configuration.workdir }
        if configuration.model != (job.details.model ?? "") { result[.model] = configuration.model }
        if configuration.provider != (job.details.provider ?? "") { result[.provider] = configuration.provider }
        if result[.model] == "" { result[.provider] = "" }
        return result
    }
}

enum CronSchedule {
    /// Local safety gate only; Hermes owns schedule grammar and validation.
    static func isValid(_ schedule: String) -> Bool {
        let trimmed = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return schedule.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

struct CronRunSummary: Identifiable, Hashable {
    let id: String
    let status: String
    let jobID: String?
    let source: String?
    let claimedAt: String?
    let error: String?
    let sessionID: String?
    let outputPreview: String?

    init(id: String, status: String, jobID: String?, source: String?, claimedAt: String?, error: String?, sessionID: String? = nil, outputPreview: String? = nil) {
        self.id = id
        self.status = status
        self.jobID = jobID
        self.source = source
        self.claimedAt = claimedAt
        self.error = error
        self.sessionID = sessionID
        self.outputPreview = outputPreview
    }
}

struct CronReportDetail: Identifiable, Equatable {
    let id: String
    let jobID: String
    let title: String
    let markdown: String
}

struct CronReportRequest: Identifiable, Equatable {
    var profileID: String? = nil
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
    let isStale: Bool

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
        accessClassification: CapabilityAccessClassification? = nil,
        isStale: Bool = false
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
        self.isStale = isStale
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

    var totalCount: Int { states.count }
    var availableCount: Int { states.filter { $0.availability == .available }.count }
    var verifiedCount: Int { states.filter { $0.probeState == .verified }.count }
    var unverifiedCount: Int { states.filter { $0.probeState == .unverified }.count }
    var missingCount: Int { states.filter { $0.probeState == .missing }.count }
    var unsupportedCount: Int { states.filter { $0.probeState == .unsupported }.count }

    var sortedStates: [CapabilityState] {
        states.sorted {
            let leftCategory = CapabilityCategory.allCases.firstIndex(of: $0.category) ?? .max
            let rightCategory = CapabilityCategory.allCases.firstIndex(of: $1.category) ?? .max
            return (leftCategory, $0.title, $0.id) < (rightCategory, $1.title, $1.id)
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
    var uploadedBy: String? = nil
    var createdAt: Date? = nil
    /// Local file Hermes stored the upload at; used for Open / Reveal.
    var storedPath: String? = nil
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

enum VerificationEvidenceText {
    static let maxLength = 160

    static func bounded(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let safe = HermesDiagnosticsService.safeSummary(trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty, safe.count <= maxLength else { return nil }
        return safe
    }
}

struct VerificationEvidenceSummary: Equatable {
    let command: String?
    let canonicalCommand: String?
    let kind: String?
    let scope: String?
    let status: String?
    let exitCode: Int?
    let outputSummary: String?

    // Optional provenance is preserved when the verification adapter provides it.
    // These fields deliberately do not imply that a missing value was observed.
    let adapter: String?
    let capturedAt: Date?
    let repositoryIdentity: String?
    let commitFingerprint: String?
    let targetFingerprint: String?
    let diffFingerprint: String?
    let rulesScopeDetail: String?
    let staleReason: String?
    /// Preserves stale precedence when an untrusted raw reason is rejected.
    /// The rejected value is never retained or rendered.
    let hasInvalidStaleReason: Bool

    init(command: String?, canonicalCommand: String?, kind: String?, scope: String?, status: String?, exitCode: Int?, outputSummary: String?, adapter: String? = nil, capturedAt: Date? = nil, repositoryIdentity: String? = nil, commitFingerprint: String? = nil, targetFingerprint: String? = nil, diffFingerprint: String? = nil, rulesScopeDetail: String? = nil, staleReason: String? = nil, hasInvalidStaleReason: Bool = false) {
        self.command = command
        self.canonicalCommand = canonicalCommand
        self.kind = kind
        self.scope = scope
        self.status = status
        self.exitCode = exitCode
        self.outputSummary = outputSummary
        self.adapter = adapter
        self.capturedAt = capturedAt
        self.repositoryIdentity = repositoryIdentity
        self.commitFingerprint = commitFingerprint
        self.targetFingerprint = targetFingerprint
        self.diffFingerprint = diffFingerprint
        self.rulesScopeDetail = rulesScopeDetail
        self.staleReason = VerificationEvidenceText.bounded(staleReason)
        self.hasInvalidStaleReason = hasInvalidStaleReason || (staleReason != nil && self.staleReason == nil)
    }
}

struct VerificationSummary: Equatable {
    let state: VerificationState
    let evidence: VerificationEvidenceSummary?
}

struct HermesInsightsSummary: Equatable, Sendable {
    let days: Int
    let sessions: Int
    let messages: Int
}

struct HermesCheckpointSummary: Identifiable, Equatable, Sendable {
    let hash: String
    let timestamp: String
    let message: String
    var id: String { hash }
}

enum ControlTab: String, CaseIterable, Identifiable {
    case changes = "Source Control"
    case automations = "Automations"
    case projects = "Projects"
    case search = "Search"
    case kanban = "Kanban"
    case officePreview = "Office Preview"
    case core = "Core"
    case quota = "Quota"
    case usage = "Usage"
    case calendar = "Calendar"
    case capabilities = "Capabilities"
    case messaging = "Messaging"

    /// The fixed navigation strip is deliberately limited to the destinations
    /// used to orient, triage, and act on work. Everything else remains one
    /// click away in a grouped menu instead of competing for horizontal space.
    static let primaryNavigation: [ControlTab] = [.kanban]
    /// Keep the high-frequency global destinations directly visible; supporting
    /// operational views remain available through the scrollable More menu.
    static let globalNavigation: [ControlTab] = [.kanban, .projects, .capabilities, .messaging, .quota, .usage, .calendar]
    static let sessionNavigation: [ControlTab] = [.changes]
    static let workspaceNavigation: [ControlTab] = [.projects]
    static let toolsNavigation: [ControlTab] = [.automations, .search, .officePreview, .core]

    static var secondaryNavigation: [ControlTab] {
        sessionNavigation + toolsNavigation
    }

    var id: String { rawValue }
    var tabLabel: String {
        switch self {
        case .changes: "Source Control"
        case .automations: "Automate"
        case .officePreview: "Office"
        case .core: "Settings"
        default: rawValue
        }
    }

    /// Terminology for the fullscreen navigation rail.
    var globalRailLabel: String {
        switch self {
        case .automations: "Automation"
        case .officePreview: "Office"
        case .core: "Settings"
        default: rawValue
        }
    }

    var icon: Ph {
        switch self {
        case .changes: .gitBranch
        case .automations: .clockCounterClockwise
        case .projects: .folder
        case .search: .magnifyingGlass
        case .kanban: .kanban
        case .officePreview: .buildingOffice
        case .core: .gear
        case .quota: .gauge
        case .usage: .chartBar
        case .calendar: .calendarBlank
        case .capabilities: .puzzlePiece
        case .messaging: .chatCircle
        }
    }

    var pageHeaderTitle: String {
        switch self {
        case .changes: "Source Control"
        case .automations: "Automation"
        case .officePreview: "Office"
        case .core: "Settings"
        default: rawValue
        }
    }

    var pageHeaderSubtitle: String {
        switch self {
        case .changes: "Review local changes safely"
        case .automations: "Recurring work, visible at a glance"
        case .projects: "Repositories and connected sessions"
        case .search: "Search across connected Hermes sources"
        case .kanban: "Move work through the board"
        case .officePreview: "Live bot assignments in a simulated 3D office"
        case .core: "Runtime health, permissions, and session tools"
        case .quota: "Provider capacity and reset windows"
        case .usage: "Tokens, cost, and tools Hermes has used"
        case .calendar: "What shipped and what was worked on, day by day"
        case .capabilities: "Connectors, plugins, skills and MCP servers"
        case .messaging: "Run Hermes from Telegram, Discord, Slack and more"
        }
    }
}

struct ControlTabBadgeState: Equatable {
    let changeCount: Int

    static func make(changeCount: Int = 0) -> ControlTabBadgeState {
        ControlTabBadgeState(changeCount: max(0, changeCount))
    }

    func count(for tab: ControlTab) -> Int {
        switch tab {
        case .changes: changeCount
        case .automations, .projects, .search, .kanban, .officePreview, .core, .quota, .usage, .calendar, .capabilities, .messaging: 0
        }
    }

    func isUrgent(for tab: ControlTab) -> Bool {
        switch tab {
        case .changes: changeCount > 0
        case .automations, .projects, .search, .kanban, .officePreview, .core, .quota, .usage, .calendar, .capabilities, .messaging: false
        }
    }
}
