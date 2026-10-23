import Foundation
import SwiftUI

/// One thing on the Calendar page. Mac events and reminders are read live from
/// EventKit and never stored; automation runs and in-progress tasks are Hermes'.
struct CalendarItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case event(calendar: String, location: String?, attendees: [String], url: URL?)
        case reminder(list: String)
        case automation(cronID: String)
        case task(KanbanTaskSummary)
    }

    let id: String
    let kind: Kind
    let title: String
    let start: Date
    var end: Date?
    var isAllDay = false
    var notes: String?
    /// The source calendar or list, so the page can hide it; nil for Hermes items.
    var sourceID: String?
    /// The EventKit calendar's color; nil for Hermes items.
    var color: Color?

    var isEvent: Bool { if case .event = kind { true } else { false } }

    /// What "Attach to chat" and "Create Kanban task" carry.
    var chatContext: ChatContext {
        if case .task(let task) = kind { return ChatContext(kanbanTask: task) }
        return ChatContext(id: "calendar:\(id)", title: title, body: chatBody)
    }

    var chatBody: String {
        var lines: [String]
        switch kind {
        case .event(let calendar, let location, let attendees, let url):
            lines = ["Calendar event: \"\(title)\"", "When: \(Self.when(self))", "Calendar: \(calendar)"]
            if let location, !location.isEmpty { lines.append("Location: \(location)") }
            if !attendees.isEmpty { lines.append("Attendees: \(attendees.joined(separator: ", "))") }
            if let url { lines.append("Link: \(url.absoluteString)") }
        case .reminder(let list):
            lines = ["Reminder: \"\(title)\"", "Due: \(Self.when(self))", "List: \(list)"]
        case .automation(let cronID):
            lines = ["Scheduled Hermes automation \"\(title)\" (\(cronID))", "Next run: \(Self.when(self))"]
        case .task(let task):
            return ChatContext(kanbanTask: task).body
        }
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            lines += ["", String(notes.prefix(4_000))]
        }
        return lines.joined(separator: "\n")
    }

    static func when(_ item: CalendarItem) -> String {
        if item.isAllDay { return item.start.formatted(.dateTime.weekday(.wide).month(.wide).day()) + " (all day)" }
        let start = item.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        guard let end = item.end, end > item.start else { return start }
        return "\(start)–\(end.formatted(.dateTime.hour().minute()))"
    }
}

@MainActor
enum CalendarAgenda {
    /// Items keyed by local start-of-day. Multi-day items appear on every day
    /// they cover inside `range`; each day lists all-day items first, then by start.
    static func build(_ items: [CalendarItem], in range: DateInterval, calendar: Calendar = .current) -> [Date:
        [CalendarItem]]
    {
        var days: [Date: [CalendarItem]] = [:]
        for item in items {
            // An end exactly at midnight belongs to the day before.
            let last = item.end.map { $0 > item.start ? $0.addingTimeInterval(-1) : item.start } ?? item.start
            var day = calendar.startOfDay(for: max(item.start, range.start))
            while day < range.end, day <= last {
                days[day, default: []].append(item)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        for key in days.keys {
            days[key]!.sort { ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title) }
        }
        return days
    }

    /// Upcoming runs of enabled automations. A `nextRun` Hermes did not give
    /// as a timestamp is dropped rather than guessed.
    static func automationItems(_ jobs: [CronSummary]) -> [CalendarItem] {
        jobs.compactMap { job in
            guard job.enabled, let next = job.nextRun.flatMap(HumanDateFormatting.date) else { return nil }
            return CalendarItem(
                id: "cron:\(job.id)", kind: .automation(cronID: job.id), title: job.name, start: next, notes: job.prompt
            )
        }
    }

    static let inProgressStatuses: Set<String> = ["running", "in_progress", "claimed"]

    /// Tasks Hermes is working on right now sit on today as all-day items.
    static func taskItems(_ tasks: [KanbanTaskSummary], now: Date = .now, calendar: Calendar = .current)
        -> [CalendarItem]
    {
        tasks.filter { inProgressStatuses.contains($0.status.lowercased()) }.map { task in
            CalendarItem(
                id: "kanban:\(task.id)", kind: .task(task), title: task.title, start: calendar.startOfDay(for: now),
                isAllDay: true)
        }
    }

    /// A one-shot Hermes schedule `leadMinutes` before `start`, as an ISO 8601
    /// timestamp with offset (Hermes reads an ISO timestamp as "run once").
    /// Nil once that moment has passed.
    static func prepSchedule(before start: Date, leadMinutes: Int, now: Date = .now, timeZone: TimeZone = .current)
        -> String?
    {
        let runAt = start.addingTimeInterval(-Double(leadMinutes) * 60)
        guard runAt > now else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: runAt)
    }

    /// One chat context holding a whole day, for "Plan this day".
    static func dayContext(_ day: Date, items: [CalendarItem]) -> ChatContext {
        let label = day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        var lines = ["My agenda for \(label):"]
        if items.isEmpty { lines.append("Nothing scheduled.") }
        for item in items {
            let time = item.isAllDay ? "all day" : item.start.formatted(.dateTime.hour().minute())
            let kind: String
            switch item.kind {
            case .event(_, let location, _, _): kind = location.map { "event · \($0)" } ?? "event"
            case .reminder: kind = "reminder"
            case .automation: kind = "Hermes automation"
            case .task: kind = "Kanban task in progress"
            }
            lines.append("- \(time): \(item.title) (\(kind))")
        }
        let key = day.formatted(.iso8601.year().month().day())
        return ChatContext(id: "agenda:\(key)", title: "Agenda · \(label)", body: lines.joined(separator: "\n"))
    }
}
