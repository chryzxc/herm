import Foundation

/// Immutable value snapshots cross to the calendar worker; no model or AppKit state is shared.
struct WorkCalendarBuildInput: @unchecked Sendable {
    let month: Date
    let sessions: [SessionSummary]
    let tasks: [KanbanTaskSummary]
    let commits: [WorkCommit]
    let pullRequests: [WorkPullRequest]
    let runs: [CronRunSummary]
    let usage: [TokenUsageReport.Day]

    struct Result: @unchecked Sendable { let index: WorkCalendarIndex }
    nonisolated func build() -> Result {
        Result(
            index: WorkCalendarIndex.build(
                month: month, sessions: sessions, tasks: tasks, commits: commits,
                pullRequests: pullRequests, runs: runs, usage: usage))
    }
}

/// One local `git log` row from a project repository Herm has attached.
struct WorkCommit: Identifiable, Equatable, Sendable {
    let repo: String
    let hash: String
    let subject: String
    let date: Date
    var id: String { repo + hash }
}

/// A pull request the user merged, from GitHub search.
struct WorkPullRequest: Identifiable, Equatable, Sendable {
    let repo: String
    let number: Int
    let title: String
    let url: URL?
    let mergedAt: Date
    var id: String { "\(repo)#\(number)" }
}

/// Everything that happened on one local day. Built once per month by
/// `WorkCalendarIndex.build`; the view only reads it.
struct WorkDay: Equatable {
    var sessions: [SessionSummary] = []
    var doneTasks: [KanbanTaskSummary] = []
    var commits: [WorkCommit] = []
    /// Merged PRs are the rollup of commits, so they stay out of `shippedCount` and `activityCount`.
    var pullRequests: [WorkPullRequest] = []
    var pullRequestsByRepository: [WorkCount] {
        Dictionary(grouping: pullRequests, by: \.repo)
            .map { WorkCount(id: $0.key, count: $0.value.count) }
            .sorted { ($0.count, $1.id) > ($1.count, $0.id) }
    }
    var cronRuns: [CronRunSummary] = []
    var usage: TokenUsageReport.Day?
    /// 0 (idle) … 4 (busiest day of the month).
    var heat = 0
    /// Bots that finished tasks, busiest first.
    var assignees: [WorkCount] = []
    /// Activity per local hour, 0…23.
    var hours: [Int] = Array(repeating: 0, count: 24)
    var firstAt: Date?
    var lastAt: Date?

    var activityCount: Int { sessions.count + doneTasks.count + commits.count + cronRuns.count }
    var shippedCount: Int { doneTasks.count + commits.count + cronRuns.filter { !$0.isFailure }.count }
    var hasFailedRun: Bool { cronRuns.contains(where: \.isFailure) }
    var isEmpty: Bool { activityCount == 0 && pullRequests.isEmpty && usage == nil }

    /// Hours of the day with any activity.
    var activeHours: Int { hours.reduce(0) { $0 + ($1 > 0 ? 1 : 0) } }
    /// The longest run of consecutive active hours.
    var longestStretch: Int {
        var best = 0
        var run = 0
        for count in hours {
            run = count > 0 ? run + 1 : 0
            best = max(best, run)
        }
        return best
    }
    /// Finished work for cost-per-item: tasks plus merged PRs, or commits when no PR was merged.
    var shippedItems: Int { doneTasks.count + (pullRequests.isEmpty ? commits.count : pullRequests.count) }
    var cost: Double { usage?.estimatedCost ?? 0 }
}

extension Double {
    /// Whole-percent change against `usual`, nil when there's no baseline or the change is under 10%.
    func percentChange(from usual: Double?) -> Int? {
        guard let usual, usual > 0 else { return nil }
        let change = Int(((self - usual) / usual * 100).rounded())
        return abs(change) >= 10 ? change : nil
    }
}

/// A name with a tally: a bot's finished tasks or a repo's commits.
struct WorkCount: Identifiable, Equatable {
    let id: String
    var count: Int
}

extension CronRunSummary {
    var isFailure: Bool {
        error != nil || ["fail", "error", "timeout"].contains { status.localizedCaseInsensitiveContains($0) }
    }

    var claimedDate: Date? { claimedAt.flatMap(WorkCalendarIndex.parseDate) }
}

/// A month of work keyed by local start-of-day, so each calendar cell is an
/// O(1) lookup and nothing is filtered while rendering.
struct WorkCalendarIndex: Equatable {
    let month: Date
    let days: [Date: WorkDay]
    let activeDays: Int
    let shippedCount: Int
    let currentStreak: Int
    let longestStreak: Int
    let monthCost: Double
    var monthTokens = 0
    var busiestDay: Date?
    var assignees: [WorkCount] = []
    var repos: [WorkCount] = []
    var taskCount = 0, commitCount = 0, sessionCount = 0, runCount = 0, pullRequestCount = 0

    func day(_ date: Date) -> WorkDay? { days[date] }

    /// Mean activity per active day outside `range`; nil under 3 days, too few to call anything usual.
    func usualActivity(excluding range: ClosedRange<Date>) -> Double? {
        var total = 0
        var count = 0
        for (date, day) in days where !range.contains(date) && day.activityCount > 0 {
            total += day.activityCount
            count += 1
        }
        return count >= 3 ? Double(total) / Double(count) : nil
    }

    static func build(
        month: Date,
        sessions: [SessionSummary],
        tasks: [KanbanTaskSummary],
        commits: [WorkCommit],
        pullRequests: [WorkPullRequest] = [],
        runs: [CronRunSummary],
        usage: [TokenUsageReport.Day],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> WorkCalendarIndex {
        let monthStart = calendar.dateInterval(of: .month, for: month)?.start ?? calendar.startOfDay(for: month)
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        var days: [Date: WorkDay] = [:]
        func key(_ date: Date?) -> Date? {
            guard let date, date >= monthStart, date < monthEnd else { return nil }
            return calendar.startOfDay(for: date)
        }

        for session in sessions {
            if let k = key(session.updatedAt) { days[k, default: WorkDay()].sessions.append(session) }
        }
        for task in tasks { if let k = key(task.completedAt) { days[k, default: WorkDay()].doneTasks.append(task) } }
        for commit in commits { if let k = key(commit.date) { days[k, default: WorkDay()].commits.append(commit) } }
        for pr in pullRequests { if let k = key(pr.mergedAt) { days[k, default: WorkDay()].pullRequests.append(pr) } }
        for run in runs { if let k = key(run.claimedDate) { days[k, default: WorkDay()].cronRuns.append(run) } }
        for row in usage { if let k = key(row.day) { days[k, default: WorkDay()].usage = row } }

        let busiest = days.values.map(\.activityCount).max() ?? 0
        var monthAssignees: [String: Int] = [:]
        var monthRepos: [String: Int] = [:]
        for k in days.keys {
            var day = days[k]!
            if busiest > 0, day.activityCount > 0 {
                day.heat = max(1, Int((4.0 * Double(day.activityCount) / Double(busiest)).rounded(.up)))
            }
            day.doneTasks.sort { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            var assignees: [String: Int] = [:]
            for task in day.doneTasks { if let bot = task.assignee, !bot.isEmpty { assignees[bot, default: 0] += 1 } }
            day.assignees = assignees.map { WorkCount(id: $0.key, count: $0.value) }.sorted {
                ($0.count, $1.id) > ($1.count, $0.id)
            }
            for (bot, count) in assignees { monthAssignees[bot, default: 0] += count }
            for commit in day.commits { monthRepos[commit.repo, default: 0] += 1 }
            let stamps =
                day.sessions.compactMap(\.updatedAt) + day.doneTasks.compactMap(\.completedAt)
                + day.commits.map(\.date) + day.pullRequests.map(\.mergedAt) + day.cronRuns.compactMap(\.claimedDate)
            for stamp in stamps { day.hours[calendar.component(.hour, from: stamp)] += 1 }
            day.firstAt = stamps.min()
            day.lastAt = stamps.max()
            days[k] = day
        }
        func ranked(_ tally: [String: Int]) -> [WorkCount] {
            tally.map { WorkCount(id: $0.key, count: $0.value) }.sorted { ($0.count, $1.id) > ($1.count, $0.id) }
        }

        // Streaks count days inside this month only.
        func active(_ date: Date) -> Bool { (days[date]?.activityCount ?? 0) > 0 }
        func step(_ date: Date, _ by: Int) -> Date { calendar.date(byAdding: .day, value: by, to: date) ?? date }
        var longest = 0
        var run = 0
        var cursor = monthStart
        while cursor < monthEnd {
            run = active(cursor) ? run + 1 : 0
            longest = max(longest, run)
            cursor = step(cursor, 1)
        }
        // An empty today does not break yesterday's streak.
        let today = calendar.startOfDay(for: now)
        var current = 0
        cursor = active(today) ? today : step(today, -1)
        while cursor >= monthStart, cursor < monthEnd, active(cursor) {
            current += 1
            cursor = step(cursor, -1)
        }

        return WorkCalendarIndex(
            month: monthStart,
            days: days,
            activeDays: days.values.filter { $0.activityCount > 0 }.count,
            shippedCount: days.values.reduce(0) { $0 + $1.shippedCount },
            currentStreak: current,
            longestStreak: longest,
            monthCost: days.values.reduce(0) { $0 + ($1.usage?.estimatedCost ?? 0) },
            monthTokens: days.values.reduce(0) { $0 + ($1.usage.map { $0.inputTokens + $0.outputTokens } ?? 0) },
            busiestDay: days.max { ($0.value.activityCount, $1.key) < ($1.value.activityCount, $0.key) }?.key,
            assignees: ranked(monthAssignees),
            repos: ranked(monthRepos),
            taskCount: days.values.reduce(0) { $0 + $1.doneTasks.count },
            commitCount: days.values.reduce(0) { $0 + $1.commits.count },
            sessionCount: days.values.reduce(0) { $0 + $1.sessions.count },
            runCount: days.values.reduce(0) { $0 + $1.cronRuns.count },
            pullRequestCount: days.values.reduce(0) { $0 + $1.pullRequests.count }
        )
    }

    /// Plain-text standup for one day, ready to paste into chat.
    static func standupMarkdown(for date: Date, day: WorkDay) -> String {
        var lines = ["## \(date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))"]
        if day.shippedCount > 0 || !day.pullRequests.isEmpty {
            lines.append("\n**Shipped**")
            lines += day.pullRequests.map { "- PR #\($0.number): \($0.title) (\($0.repo))" }
            lines += day.doneTasks.map { task in
                "- \(task.title)" + (task.assignee.map { $0.isEmpty ? "" : " (\($0))" } ?? "")
            }
            lines += day.commits.map { "- \($0.subject) (\($0.repo) \($0.hash))" }
        }
        if !day.sessions.isEmpty {
            lines.append("\n**Worked on**")
            lines += day.sessions.map { "- \($0.title)" }
        }
        if !day.cronRuns.isEmpty {
            let failed = day.cronRuns.filter(\.isFailure).count
            lines.append("\n**Automations**: \(day.cronRuns.count) runs" + (failed > 0 ? ", \(failed) failed" : ""))
        }
        if let usage = day.usage {
            let tokens = usage.inputTokens + usage.outputTokens
            lines.append("\n**Spend**: \(tokens.formatted()) tokens · \(UsageWorkspaceView.cost(usage.estimatedCost))")
        }
        if day.isEmpty { lines.append("\nNo recorded activity.") }
        return lines.joined(separator: "\n")
    }

    // Formatters are costly to build and every cron run is parsed several times per render.
    private nonisolated(unsafe) static let plainISO = ISO8601DateFormatter()
    private nonisolated(unsafe) static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let formatterLock = NSLock()

    static func parseDate(_ string: String) -> Date? {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return plainISO.date(from: string) ?? fractionalISO.date(from: string)
    }
}

/// Records and totals for any scope, projected from the same daily buckets.
struct WorkRange: Equatable {
    struct Point: Equatable, Identifiable {
        let date: Date
        let shipped: Int
        let sessions: Int
        let runs: Int
        let hasFailure: Bool
        var id: Date { date }
        var total: Int { shipped + sessions + runs }
    }
    var points: [Point] = []
    var pullRequests: [WorkPullRequest] = []
    var tasks: [KanbanTaskSummary] = []
    var commits: [WorkCommit] = []
    var sessions: [SessionSummary] = []
    var runs: [CronRunSummary] = []
    var pullRequestsByRepository: [WorkCount] = []
    var activeDays = 0, tokens = 0, apiCalls = 0, usageSessions = 0
    var inputTokens = 0, outputTokens = 0, cacheReadTokens = 0, reasoningTokens = 0
    var usageDays = 0
    var hasUsage = false
    var activeHours = 0, shippedItems = 0
    var hours = [Int](repeating: 0, count: 24)
    /// Longest consecutive stretch within a single day, never across midnight.
    var longestStretch = 0
    /// Mean activity per occurrence of each weekday (index 0 = Sunday); empty under two weeks of days.
    var weekdayMeans: [Double] = []
    /// Activity per active day against the month's other active days.
    var vsUsual: Int?
    var cost = 0.0
    /// Only set when the range is the whole month.
    var streak = 0
    var repos: [WorkCount] = []
    var assignees: [WorkCount] = []

    var isEmpty: Bool {
        pullRequests.isEmpty && tasks.isEmpty && commits.isEmpty && sessions.isEmpty && runs.isEmpty && !hasUsage
    }
}

extension WorkCalendarIndex {
    /// Days in `[from, to]` that fall inside this month; a week crossing a month edge only counts the loaded side.
    func range(from: Date, to: Date, calendar: Calendar = .current) -> WorkRange {
        var range = WorkRange()
        var repoTally: [String: Int] = [:]
        var prTally: [String: Int] = [:]
        var assigneeTally: [String: Int] = [:]
        var weekdayTotals = [Int](repeating: 0, count: 7)
        var weekdayDays = [Int](repeating: 0, count: 7)
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: month) ?? month
        var cursor = max(calendar.startOfDay(for: from), month)
        let last = min(calendar.startOfDay(for: to), calendar.date(byAdding: .day, value: -1, to: monthEnd) ?? to)
        while cursor <= last {
            let day = days[cursor]
            range.points.append(
                .init(
                    date: cursor,
                    shipped: (day?.doneTasks.count ?? 0) + (day?.commits.count ?? 0),
                    sessions: day?.sessions.count ?? 0,
                    runs: day?.cronRuns.count ?? 0,
                    hasFailure: day?.hasFailedRun ?? false
                ))
            if let day {
                range.pullRequests.append(contentsOf: day.pullRequests)
                range.tasks.append(contentsOf: day.doneTasks)
                range.commits.append(contentsOf: day.commits)
                range.sessions.append(contentsOf: day.sessions)
                range.runs.append(contentsOf: day.cronRuns)
                if day.activityCount > 0 { range.activeDays += 1 }
                range.activeHours += day.activeHours
                range.longestStretch = max(range.longestStretch, day.longestStretch)
                for hour in range.hours.indices { range.hours[hour] += day.hours[hour] }
                range.shippedItems += day.shippedItems
                if let usage = day.usage {
                    range.hasUsage = true
                    range.usageDays += 1
                    range.inputTokens += usage.inputTokens
                    range.outputTokens += usage.outputTokens
                    range.cacheReadTokens += usage.cacheReadTokens
                    range.reasoningTokens += usage.reasoningTokens
                    range.tokens += usage.inputTokens + usage.outputTokens
                    range.apiCalls += usage.apiCalls
                    range.usageSessions += usage.sessions
                    range.cost += usage.estimatedCost
                }
                for commit in day.commits { repoTally[commit.repo, default: 0] += 1 }
                for repo in day.pullRequestsByRepository { prTally[repo.id, default: 0] += repo.count }
                for bot in day.assignees { assigneeTally[bot.id, default: 0] += bot.count }
            }
            let weekday = calendar.component(.weekday, from: cursor) - 1
            weekdayTotals[weekday] += range.points.last?.total ?? 0
            weekdayDays[weekday] += 1
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? monthEnd
        }
        func ranked(_ tally: [String: Int]) -> [WorkCount] {
            tally.map { WorkCount(id: $0.key, count: $0.value) }.sorted { ($0.count, $1.id) > ($1.count, $0.id) }
        }
        range.repos = ranked(repoTally)
        range.pullRequestsByRepository = ranked(prTally)
        range.pullRequests.sort { $0.mergedAt > $1.mergedAt }
        range.tasks.sort { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        range.commits.sort { $0.date > $1.date }
        range.sessions.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        if range.points.count >= 14 {
            range.weekdayMeans = (0..<7).map {
                weekdayDays[$0] > 0 ? Double(weekdayTotals[$0]) / Double(weekdayDays[$0]) : 0
            }
        }
        range.assignees = ranked(assigneeTally)
        if range.activeDays > 0, let first = range.points.first?.date, let last = range.points.last?.date {
            let perDay = Double(range.points.reduce(0) { $0 + $1.total }) / Double(range.activeDays)
            range.vsUsual = perDay.percentChange(from: usualActivity(excluding: first...last))
        }
        if range.points.count == calendar.range(of: .day, in: .month, for: month)?.count {
            range.streak = currentStreak
        }
        return range
    }
}
