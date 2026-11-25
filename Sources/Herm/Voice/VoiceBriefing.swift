import Foundation

/// The facts a spoken briefing ("good morning") may use. Each source either reports
/// what it holds or says it isn't connected; an unread source never reads as "nothing".
@MainActor
enum VoiceBriefing {
    nonisolated static let limit = 1_536
    nonisolated static let guidance =
        "Give me a short spoken briefing from these facts only; say plainly which sources are not connected. Add weather or news only if you have a tool for it."

    /// One source: its items, or why it can't be read.
    enum Section: Equatable, Sendable {
        case items([String])
        case unavailable(String)
    }

    struct Facts: Equatable, Sendable {
        var calendar: Section = .unavailable("not connected")
        var reminders: Section = .unavailable("not connected")
        var automations: Section = .unavailable("not loaded")
        var attention: Section = .items([])
        var tasks: Section = .unavailable("not loaded")
        var timers: [String] = []
        /// Ordinary notices Quiet mode held back.
        var heldBack = 0

        var promptLines: [String] {
            var lines = ["Briefing facts for today:"]
            func add(_ name: String, _ section: Section) {
                switch section {
                case .items(let items) where items.isEmpty: lines.append("\(name): none.")
                case .items(let items): lines.append("\(name): " + items.prefix(8).joined(separator: "; ") + ".")
                case .unavailable(let reason): lines.append("\(name): \(reason).")
                }
            }
            add("Calendar", calendar)
            add("Reminders", reminders)
            add("Scheduled Hermes jobs", automations)
            add("Waiting on me", attention)
            add("Hermes tasks running or blocked", tasks)
            if !timers.isEmpty { lines.append("Timers: " + timers.prefix(4).joined(separator: "; ") + ".") }
            if heldBack > 0 { lines.append("Quiet mode held back \(heldBack) updates.") }
            lines.append(VoiceBriefing.guidance)
            var text = lines.map { VoiceScreenContext.sanitized($0, limit: 400) }
            while text.joined(separator: "\n").count > VoiceBriefing.limit, text.count > 2 {
                text.remove(at: text.count - 2)
            }
            return text
        }
    }

    /// "9:30 AM Design review", "All day Offsite"; titles only, no notes or attendees.
    static func eventLine(title: String, start: Date, isAllDay: Bool) -> String {
        isAllDay ? "All day \(title)" : "\(HumanDateFormatting.timeOnly(start)) \(title)"
    }

    static func reminderLine(_ reminder: ReminderSummary) -> String {
        let due = reminder.dueDate.map { " at \(HumanDateFormatting.timeOnly($0))" } ?? ""
        return reminder.isOverdue ? "\(reminder.title) (overdue)" : reminder.title + due
    }

    /// Enabled jobs whose next run falls on today; a run Hermes didn't report as a timestamp is skipped.
    static func automationLines(_ jobs: [CronSummary], now: Date, calendar: Calendar = .current) -> [String] {
        jobs.compactMap { job -> (Date, String)? in
            guard job.enabled, let next = job.nextRun.flatMap(HumanDateFormatting.date), next >= now,
                calendar.isDate(next, inSameDayAs: now)
            else { return nil }
            return (next, "\(job.name) at \(HumanDateFormatting.timeOnly(next))")
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    static func taskLines(_ tasks: [KanbanTaskSummary]) -> [String] {
        let live: Set = ["running", "in_progress", "claimed", "blocked"]
        return tasks.filter { live.contains($0.status.lowercased()) }.map { "\($0.title) (\($0.status))" }
    }
}
