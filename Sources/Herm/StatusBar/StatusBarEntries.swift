import Foundation

/// Everything the bar can show, as plain values the model gathers. Pure, so the
/// rules for what appears, in which order and tone, are tested without a view.
@MainActor
struct StatusBarInput {
    var tasks: [EdgeNotchTask] = []
    var workingBots: [BotSummary] = []
    var enabled: Set<StatusBarItem> = Set(StatusBarItem.allCases.filter(\.isOnByDefault))
    var mode: GatewayConnectionSettings.Mode = .local
    var isOffline = false
    var now = Date()
    var stalledAfter: TimeInterval = 5 * 60
    /// When Herm saw each working task's status line last change, by presentation ID.
    var lastChange: [String: Date] = [:]
    var localServer: LocalPreviewServer?
    var routines: [RoutineReference] = [] {
        didSet {
            scheduledRoutines = routines.compactMap { reference in
                guard reference.job.enabled, let start = reference.job.nextRun.flatMap(HumanDateFormatting.date)
                else { return nil }
                return (reference, start)
            }.sorted { $0.start < $1.start }
        }
    }
    private(set) var scheduledRoutines: [(reference: RoutineReference, start: Date)] = []
    var repository: RepositorySnapshot?
    var failedTest: StatusBarEntry.Action?
    var plan: TodoPlan?
    var queuedCount = 0
    var nextMeeting: CalendarItem?
    /// Loaded by the Pull requests page; empty until it has been.
    var pullRequests: [PullRequestRecord] = []
    var viewerLogin: String?
    var bootedSimulator: String?
}

struct StatusBarEntry: Identifiable, Equatable {
    /// How an entry reads: one filled chip for what blocks an agent, a colored
    /// icon for problems, neutral for outcomes, plain text for context.
    enum Tone: Equatable { case decision, problem, warning, outcome, context }

    enum Action: Equatable {
        case task(EdgeNotchTask)
        case tab(ControlTab)
        case preview
        case pullRequests
        case url(URL)
        case calendar(CalendarItem)
        case routine(RoutineReference)
        case terminal(identity: String, tabID: UUID?, shellID: UUID)
        case none
    }

    let item: StatusBarItem
    var icon: Ph?
    let text: String
    let tone: Tone
    var action: Action
    var help: String = ""
    var compactText: String? = nil

    var id: StatusBarItem { item }
}

/// The same inventory drives the bar counts and the Activity preview.
struct WorkspaceStatusSummary: Equatable {
    var attention: [EdgeNotchTask] = []
    var running: [EdgeNotchTask] = []
    var otherWorkingBots: [BotSummary] = []
    var finished: [EdgeNotchTask] = []
    var isStale = false
    var runningCount: Int { running.count + otherWorkingBots.count }

    init(tasks: [EdgeNotchTask] = [], workingBots: [BotSummary] = []) {
        let current = tasks.filter(\.isStatusCurrent)
        isStale = current.isEmpty && !tasks.isEmpty && workingBots.isEmpty
        var seen = Set<String>()
        var requests = Set<AttentionRequest>()
        for task in isStale ? tasks : current where seen.insert(task.presentationID).inserted {
            switch task.phase {
            case .attention:
                if let request = task.attentionRequest, !requests.insert(request).inserted { continue }
                attention.append(task)
            case .working:
                if !task.isQueued { running.append(task) }
            case .finished:
                if task.isFailure {
                    attention.append(task)
                } else {
                    finished.append(task)
                }
            case .pending:
                break
            }
        }
        let represented = Set(running.compactMap(\.botProfileID))
        otherWorkingBots = workingBots.filter { !represented.contains($0.id) }
        finished.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }
}

@MainActor
struct StatusBarLayout: Equatable {
    var summary = WorkspaceStatusSummary()
    var attentionPullRequests: [PullRequestRecord] = []
    var isOffline = false

    /// Left zone, in fold priority: the first stays longest.
    var chips: [StatusBarEntry] = []
    /// Right zone, in fold priority.
    var trailing: [StatusBarEntry] = []
    var isStale: Bool { isOffline || summary.isStale }
    var attentionCount: Int { summary.attention.count + attentionPullRequests.count }

    struct Preview: Equatable {
        struct Row: Equatable, Identifiable {
            let id: String
            let title: String
            let status: String
            let icon: Ph
            let action: StatusBarEntry.Action
            var task: EdgeNotchTask?
            var botID: String?

            init(id: String, title: String, status: String, icon: Ph, action: StatusBarEntry.Action) {
                self.id = id
                self.title = title
                self.status = status
                self.icon = icon
                self.action = action
            }

            init(task: EdgeNotchTask) {
                let icon: Ph = task.kanbanTask != nil ? .kanban : task.routine != nil ? .clock : .chatText
                let canOpen = task.kanbanTask != nil || task.routine != nil || task.session != nil || task.isCurrent
                self.init(
                    id: task.presentationID, title: task.title, status: task.statusLabel,
                    icon: icon, action: canOpen ? .task(task) : .none)
                self.task = task
            }

            init(bot: BotSummary) {
                self.init(
                    id: "working-bot/\(bot.id)", title: bot.name, status: "Working", icon: .chatText, action: .none)
                botID = bot.id
            }
        }

        let headline: String
        var rows: [Row] = []
        var title = "Activity"
        var icon: Ph = .pulse
        var detail: String?
        var footerAction: StatusBarEntry.Action = .tab(.usage)
        var footerTitle = "Open Activity"

        @MainActor static func heldNotifications(_ notices: [HermNotice], overflow: Int) -> Self {
            let count = notices.count + overflow
            let rows = notices.suffix(2).reversed().map { notice in
                Row(
                    id: notice.id, title: notice.kind.title, status: StatusBarLayout.clock(notice.createdAt),
                    icon: .bellSimple, action: .none)
            }
            return Self(
                headline: "\(count.formatted()) held \(count == 1 ? "notification" : "notifications")",
                rows: rows, title: "Held notifications", icon: .bellSimpleSlash,
                detail: rows.isEmpty ? "Details of earlier notifications are unavailable." : nil,
                footerAction: .none)
        }
    }

    func preview(for entry: StatusBarEntry) -> Preview {
        let tasks: [EdgeNotchTask]
        switch entry.item {
        case .needsYou:
            return Preview(
                headline: isStale ? unavailableHeadline : attentionLabel,
                rows: isStale ? [] : attentionRows(), title: entry.item.title, icon: .warning,
                detail: isStale ? "The count is from the last available update." : entry.item.detail)
        case .agentActivity:
            return Preview(
                headline: entry.text, rows: runningRows(limit: 2), title: entry.item.title, icon: entry.icon ?? .pulse)
        case .readyToReview: tasks = summary.finished
        case .stalled:
            if case .task(let task) = entry.action { tasks = [task] } else { tasks = [] }
        default: tasks = []
        }
        if !tasks.isEmpty {
            return Preview(
                headline: entry.text, rows: tasks.prefix(2).map(Preview.Row.init(task:)),
                title: entry.item.title, icon: entry.icon ?? .pulse)
        }
        return Preview(
            headline: entry.text, title: entry.item.title, icon: entry.icon ?? .info,
            detail: entry.help.isEmpty || entry.help == entry.text ? nil : entry.help,
            footerAction: entry.action, footerTitle: "Open details")
    }

    var preview: Preview {
        if isStale {
            return Preview(headline: unavailableHeadline)
        }
        if attentionCount > 0 {
            return Preview(headline: attentionLabel, rows: attentionRows())
        }
        if summary.runningCount > 0 {
            return Preview(headline: "\(summary.runningCount) running", rows: runningRows(limit: 1))
        }
        if let task = summary.finished.first {
            return Preview(headline: "Recently finished", rows: [Preview.Row(task: task)])
        }
        return Preview(headline: "No current activity")
    }

    private var unavailableHeadline: String {
        isOffline ? "Hermes Agent is offline" : "Activity status unavailable"
    }

    private func attentionRows() -> [Preview.Row] {
        let limit = 2
        let tasks = summary.attention.prefix(limit).map(Preview.Row.init(task:))
        let pulls = attentionPullRequests.prefix(limit - tasks.count).map { pull in
            Preview.Row(
                id: pull.id, title: "#\(pull.number) \(pull.title)", status: "Checks failed", icon: .gitPullRequest,
                action: pull.webURL.map(StatusBarEntry.Action.url) ?? .pullRequests)
        }
        return tasks + pulls
    }

    private func runningRows(limit: Int) -> [Preview.Row] {
        let tasks = summary.running.prefix(limit).map(Preview.Row.init(task:))
        let bots = summary.otherWorkingBots.prefix(limit).map(Preview.Row.init(bot:))
        // Give a Bot outside the selected profile a preview slot beside the first detailed task.
        return Array((tasks.prefix(1) + bots + tasks.dropFirst()).prefix(limit))
    }

    private var attentionLabel: String {
        "\(attentionCount) need\(attentionCount == 1 ? "s" : "") attention"
    }

    static func make(_ input: StatusBarInput) -> StatusBarLayout {
        var layout = StatusBarLayout(
            summary: WorkspaceStatusSummary(tasks: input.tasks, workingBots: input.isOffline ? [] : input.workingBots),
            isOffline: input.isOffline)
        func on(_ item: StatusBarItem) -> Bool {
            (item.isLocked || input.enabled.contains(item))
                && BackendReach.access(item.resource, mode: input.mode).isAvailable
        }
        if BackendReach.access(.pullRequests, mode: input.mode).isAvailable {
            layout.attentionPullRequests = failingPullRequests(input.pullRequests, viewer: input.viewerLogin)
        }
        let count = layout.attentionCount
        if count > 0 {
            layout.chips.append(
                StatusBarEntry(
                    item: .needsYou, icon: .warning, text: layout.attentionLabel,
                    tone: .decision, action: .preview))
        }
        var context: [StatusBarEntry] = []
        if let upcoming = Self.upcoming(input) { context.append(upcoming) }
        if on(.verification), let failedTest = input.failedTest {
            context.append(
                StatusBarEntry(
                    item: .verification, icon: .xCircle, text: "Tests failed", tone: .problem,
                    action: failedTest, help: "Open the test result in Terminal"))
        }
        if on(.unpushed), let repo = input.repository, repo.isGitRepository, !repo.isStale,
            repo.statusError == nil, let ahead = repo.aheadCount, ahead > 0
        {
            context.append(
                StatusBarEntry(
                    item: .unpushed, icon: .arrowUp, text: "\(ahead) unpushed commit\(ahead == 1 ? "" : "s")",
                    tone: .outcome, action: .tab(.changes), help: "Open Source Control for \(repo.branch)"))
        }
        if on(.processes), let server = input.localServer {
            context.append(
                StatusBarEntry(
                    item: .processes, icon: .globe, text: "\(server.processName ?? "Local preview") · :\(server.port)",
                    tone: .context, action: .url(server.url), help: "Open \(server.url.absoluteString)"))
        }
        let working = layout.summary.running
        if on(.agentActivity), layout.summary.runningCount > 0 {
            context.append(
                StatusBarEntry(
                    item: .agentActivity, icon: .pulse, text: "\(layout.summary.runningCount) running", tone: .context,
                    action: .preview, help: "Preview running work"))
        }
        if on(.stalled) {
            let stalled = working.filter { task in
                input.lastChange[task.presentationID].map { input.now.timeIntervalSince($0) >= input.stalledAfter }
                    ?? false
            }
            if let first = stalled.first, let since = input.lastChange[first.presentationID] {
                let text =
                    stalled.count == 1
                    ? "\(first.title) stalled \(Self.minutes(input.now.timeIntervalSince(since)))"
                    : "\(stalled.count) stalled"
                context.append(
                    StatusBarEntry(
                        item: .stalled, icon: .hourglass, text: text, tone: .warning, action: .task(first),
                        help: "No update from \(first.title) since \(Self.clock(since))"))
            }
        }
        let review = layout.summary.finished
        if on(.readyToReview), let first = review.first {
            context.append(
                StatusBarEntry(
                    item: .readyToReview, icon: .checkCircle, text: "\(review.count) ready to review",
                    tone: .outcome, action: review.count == 1 ? .task(first) : .preview,
                    help: "Finished work waiting for you"))
        }
        if on(.reviewRequested) {
            let requested = Self.reviewRequests(input.pullRequests, viewer: input.viewerLogin)
            if !requested.isEmpty {
                context.append(
                    StatusBarEntry(
                        item: .reviewRequested, icon: .gitPullRequest,
                        text: "\(requested.count) review\(requested.count == 1 ? "" : "s") requested", tone: .outcome,
                        action: .pullRequests, help: "Pull requests waiting on your review"))
            }
        }

        if on(.simulator), let simulator = input.bootedSimulator {
            context.append(
                StatusBarEntry(
                    item: .simulator, icon: .deviceMobile, text: "\(simulator) booted", tone: .context,
                    action: .none, help: "A booted simulator keeps using memory"))
        }
        if on(.planProgress), let plan = input.plan, !plan.items.isEmpty, let current = plan.current {
            let step = min(plan.done + 1, plan.items.count)
            context.append(
                StatusBarEntry(
                    item: .planProgress, icon: .listChecks, text: "Step \(step) of \(plan.items.count)",
                    tone: .context, action: .none, help: current.content))
        }
        if on(.queued), input.queuedCount > 0 {
            context.append(
                StatusBarEntry(
                    item: .queued, icon: .stack, text: "\(input.queuedCount) queued", tone: .context,
                    action: .none, help: "Prompts that send when the agent finishes"))
        }
        layout.trailing = context
        return layout
    }

    /// Open pull requests you wrote whose checks fail.
    static func failingPullRequests(_ records: [PullRequestRecord], viewer: String?) -> [PullRequestRecord] {
        guard let viewer else { return [] }
        return records.filter {
            $0.state == "open" && $0.mergedAt == nil && $0.author.caseInsensitiveCompare(viewer) == .orderedSame
                && $0.checks.contains(where: \.isFailure)
        }
    }

    static func reviewRequests(_ records: [PullRequestRecord], viewer: String?) -> [PullRequestRecord] {
        guard let viewer else { return [] }
        return records.filter { record in
            record.state == "open"
                && record.requestedReviewers.contains { $0.caseInsensitiveCompare(viewer) == .orderedSame }
        }
    }

    private static func upcoming(_ input: StatusBarInput) -> StatusBarEntry? {
        let cutoff = input.now.addingTimeInterval(30 * 60)
        let routine =
            input.enabled.contains(.nextSchedule)
            ? input.scheduledRoutines.first { $0.start > input.now }
            : nil
        let upcomingRoutine = routine.flatMap { $0.start <= cutoff ? $0 : nil }
        if input.enabled.contains(.nextMeeting), let meeting = input.nextMeeting,
            meeting.isEvent, !meeting.isAllDay, meeting.start > input.now, meeting.start <= cutoff,
            upcomingRoutine.map({ meeting.start <= $0.start }) ?? true
        {
            return scheduleEntry(
                title: meeting.title, start: meeting.start, now: input.now,
                item: .nextMeeting, icon: .calendarBlank, action: .calendar(meeting))
        }
        if let (reference, start) = upcomingRoutine {
            return scheduleEntry(
                title: reference.job.name, start: start, now: input.now,
                item: .nextSchedule, icon: .clock, action: .routine(reference))
        }
        return nil
    }

    private static func scheduleEntry(
        title: String, start: Date, now: Date, item: StatusBarItem, icon: Ph, action: StatusBarEntry.Action
    ) -> StatusBarEntry {
        let remainingMinutes = Int(ceil(start.timeIntervalSince(now) / 60))
        let label = item == .nextMeeting ? "Meeting" : "Routine"
        return StatusBarEntry(
            item: item, icon: icon, text: "\(title) in \(remainingMinutes)m", tone: .context, action: action,
            help: "\(title) at \(clock(start))", compactText: "\(label) in \(remainingMinutes)m")
    }

    /// Compact durations, including days for older items.
    static func minutes(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 1 { return "now" }
        if minutes >= 1440 {
            let hours = minutes / 60 % 24
            return "\(minutes / 1440)d\(hours == 0 ? "" : " \(hours)h")"
        }
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h\(minutes % 60 == 0 ? "" : " \(minutes % 60)m")"
    }

    static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}
