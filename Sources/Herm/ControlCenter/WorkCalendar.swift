import Foundation

/// One local `git log` row from a project repository Herm has attached.
struct WorkCommit: Identifiable, Equatable, Sendable {
    let repo: String
    let hash: String
    let subject: String
    let date: Date
    var id: String { repo + hash }
}

/// Everything that happened on one local day. Built once per month by
/// `WorkCalendarIndex.build`; the view only reads it.
struct WorkDay: Equatable {
    var sessions: [SessionSummary] = []
    var doneTasks: [KanbanTaskSummary] = []
    var commits: [WorkCommit] = []
    var cronRuns: [CronRunSummary] = []
    var usage: TokenUsageReport.Day?
    /// 0 (idle) … 4 (busiest day of the month).
    var heat = 0
    /// Bots that finished tasks, busiest first.
    var crew: [WorkCount] = []
    /// Activity per local hour, 0…23.
    var hours: [Int] = Array(repeating: 0, count: 24)
    var firstAt: Date?
    var lastAt: Date?

    var activityCount: Int { sessions.count + doneTasks.count + commits.count + cronRuns.count }
    var shippedCount: Int { doneTasks.count + commits.count + cronRuns.filter { !$0.isFailure }.count }
    var hasFailedRun: Bool { cronRuns.contains(where: \.isFailure) }
    var isEmpty: Bool { activityCount == 0 && usage == nil }
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
    var crew: [WorkCount] = []
    var repos: [WorkCount] = []
    var taskCount = 0, commitCount = 0, sessionCount = 0, runCount = 0

    func day(_ date: Date) -> WorkDay? { days[date] }

    static func build(
        month: Date,
        sessions: [SessionSummary],
        tasks: [KanbanTaskSummary],
        commits: [WorkCommit],
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

        for session in sessions { if let k = key(session.updatedAt) { days[k, default: WorkDay()].sessions.append(session) } }
        for task in tasks { if let k = key(task.completedAt) { days[k, default: WorkDay()].doneTasks.append(task) } }
        for commit in commits { if let k = key(commit.date) { days[k, default: WorkDay()].commits.append(commit) } }
        for run in runs { if let k = key(run.claimedDate) { days[k, default: WorkDay()].cronRuns.append(run) } }
        for row in usage { if let k = key(row.day) { days[k, default: WorkDay()].usage = row } }

        let busiest = days.values.map(\.activityCount).max() ?? 0
        var monthCrew: [String: Int] = [:]
        var monthRepos: [String: Int] = [:]
        for k in days.keys {
            var day = days[k]!
            if busiest > 0, day.activityCount > 0 {
                day.heat = max(1, Int((4.0 * Double(day.activityCount) / Double(busiest)).rounded(.up)))
            }
            day.doneTasks.sort { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            var crew: [String: Int] = [:]
            for task in day.doneTasks { if let bot = task.assignee, !bot.isEmpty { crew[bot, default: 0] += 1 } }
            day.crew = crew.map { WorkCount(id: $0.key, count: $0.value) }.sorted { ($0.count, $1.id) > ($1.count, $0.id) }
            for (bot, count) in crew { monthCrew[bot, default: 0] += count }
            for commit in day.commits { monthRepos[commit.repo, default: 0] += 1 }
            let stamps = day.sessions.compactMap(\.updatedAt) + day.doneTasks.compactMap(\.completedAt)
                + day.commits.map(\.date) + day.cronRuns.compactMap(\.claimedDate)
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
        var longest = 0, run = 0
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
            crew: ranked(monthCrew),
            repos: ranked(monthRepos),
            taskCount: days.values.reduce(0) { $0 + $1.doneTasks.count },
            commitCount: days.values.reduce(0) { $0 + $1.commits.count },
            sessionCount: days.values.reduce(0) { $0 + $1.sessions.count },
            runCount: days.values.reduce(0) { $0 + $1.cronRuns.count }
        )
    }

    /// Plain-text standup for one day, ready to paste into chat.
    static func standupMarkdown(for date: Date, day: WorkDay) -> String {
        var lines = ["## \(date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))"]
        if day.shippedCount > 0 {
            lines.append("\n**Shipped**")
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
            lines.append("\n**Spend**: \(tokens.formatted()) tokens · \(usage.estimatedCost.formatted(.currency(code: "USD")))")
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

    static func parseDate(_ string: String) -> Date? {
        plainISO.date(from: string) ?? fractionalISO.date(from: string)
    }
}
