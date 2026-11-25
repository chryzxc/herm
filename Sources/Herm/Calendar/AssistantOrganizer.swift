import EventKit
import Foundation

enum AssistantOrganizer {
    private static let calendarUnavailable = "Connect Calendar in Herm to use this command."
    private static let remindersUnavailable = "Connect Reminders in Herm to use this command."

    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: SystemCalendarService.enabledKey) as? Bool ?? true
    }

    private static var canReadCalendar: Bool {
        enabled && EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    private static var canWriteReminders: Bool {
        enabled && EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    @MainActor static func agenda(_ day: AssistantDay, next: Bool = false, now: Date = .now) async throws
        -> AssistantReply
    {
        let calendar = Calendar.current
        guard let interval = day.interval(now: now, calendar: calendar) else {
            return AssistantReply("I need a day for that calendar request.")
        }
        let range =
            next
            ? DateInterval(start: now, end: calendar.date(byAdding: .day, value: 7, to: now) ?? interval.end)
            : interval
        let showPreview = !next && GenerativeUIIntegration.isEnabled
        let result = try await withEventStore { store -> (text: String, date: String, rows: [[String]]) in
            guard canReadCalendar else { return (calendarUnavailable, "", []) }
            let entries = events(in: range, store: store).filter {
                $0.status != .canceled && (!next || (!$0.isAllDay && $0.startDate >= now))
            }
            guard let first = entries.first else {
                let text =
                    next
                    ? "Your selected calendars have no timed events in the next week."
                    : "Your selected calendars have no events on \(dayLabel(range.start))."
                return (text, "", [])
            }
            let lines = entries.prefix(next ? 1 : 3).map { event in
                let title = event.title ?? "Untitled event"
                return event.isAllDay ? "\(title), all day" : "\(title) at \(clock(event.startDate))"
            }
            let more = !next && entries.count > 3 ? " There are \(entries.count - 3) more." : ""
            let date = next ? dayLabel(first.startDate) : dayLabel(range.start)
            let rows: [[String]] =
                showPreview
                ? entries.prefix(100).map { event in
                    [event.isAllDay ? "All day" : clock(event.startDate), event.title ?? "Untitled event"]
                }
                : []
            return ("\(date): \(lines.joined(separator: ". ")).\(more)", date, rows)
        }
        let preview =
            result.rows.isEmpty
            ? nil
            : VoicePassiveVisual.table(
                title: result.date, columns: ["Time", "Event"], rows: result.rows)
        return AssistantReply(result.text, visual: preview)
    }

    @MainActor static func free(
        _ day: AssistantDay, part: AssistantDayPart, duration: Int? = nil, title: String? = nil, now: Date = .now
    ) async throws -> AssistantReply {
        let calendar = Calendar.current
        guard let interval = day.interval(now: now, calendar: calendar),
            let window = part.interval(on: interval, calendar: calendar), window.end > now
        else { return AssistantReply("That time window has passed. Which future day should I use?") }
        let lead = duration == nil ? now : Date(timeIntervalSince1970: ceil(now.timeIntervalSince1970 / 60) * 60 + 60)
        guard lead < window.end else { return AssistantReply("That calendar window is ending soon.") }
        let range = DateInterval(start: max(lead, window.start), end: window.end)
        let availability = try await withEventStore { store -> ([DateInterval], CalendarDestination?)? in
            guard canReadCalendar else { return nil }
            let gaps = freeIntervals(in: range, blocking: blocking(in: range, store: store))
            let destination = (duration == nil ? nil : store.defaultCalendarForNewEvents).flatMap { calendar in
                calendar.allowsContentModifications && !hiddenSources.contains(calendar.calendarIdentifier)
                    ? CalendarDestination(calendar) : nil
            }
            return (gaps, destination)
        }
        guard let (gaps, destination) = availability else { return AssistantReply(calendarUnavailable) }
        if let duration, let title {
            guard let slot = gaps.first(where: { $0.duration >= Double(duration) }) else {
                return AssistantReply("There’s no \(duration / 60)-minute opening on \(dayLabel(range.start)).")
            }
            guard let destination else {
                return AssistantReply("Choose a writable default calendar in Calendar settings.")
            }
            let target = DateInterval(start: slot.start, duration: Double(duration))
            let summary =
                "Block \(title) on \(dayLabel(target.start)) from \(clock(target.start)) to "
                + "\(clock(target.end)) in \(destination.title)?"
            return .confirm(summary) {
                try await withEventStore { store in
                    guard canReadCalendar else { return calendarUnavailable }
                    guard let calendar = store.defaultCalendarForNewEvents,
                        calendar.calendarIdentifier == destination.id,
                        calendar.allowsContentModifications, !hiddenSources.contains(destination.id)
                    else { return "That calendar is no longer writable." }
                    guard Date.now <= target.start, blocking(in: target, store: store).isEmpty else {
                        return "That opening changed. Ask for another calendar block."
                    }
                    let event = EKEvent(eventStore: store)
                    event.calendar = calendar
                    event.title = title
                    event.startDate = target.start
                    event.endDate = target.end
                    try Task.checkCancellation()
                    try store.save(event, span: .thisEvent)
                    guard let id = event.eventIdentifier, let saved = store.event(withIdentifier: id),
                        saved.calendar.calendarIdentifier == destination.id, saved.startDate == target.start,
                        saved.endDate == target.end
                    else { return "I couldn't verify the calendar block. Check Calendar before trying again." }
                    return "Added \(title) at \(clock(target.start)) on \(dayLabel(target.start))."
                }
            }
        }
        guard !gaps.isEmpty else { return AssistantReply("You have no free time in that window.") }
        let lines = gaps.prefix(3).map { "\(clock($0.start)) to \(clock($0.end))" }
        return AssistantReply("On \(dayLabel(range.start)), you’re free \(lines.joined(separator: ", ")).")
    }

    @MainActor static func reminder(title: String, list: String?, day: AssistantDay?) async throws -> AssistantReply {
        let lists = try await withEventStore { store -> ([CalendarDestination], String?)? in
            guard canWriteReminders else { return nil }
            let hidden = hiddenSources
            let writable = store.calendars(for: .reminder)
                .filter { $0.allowsContentModifications && !hidden.contains($0.calendarIdentifier) }
                .map(CalendarDestination.init)
            return (writable, store.defaultCalendarForNewReminders()?.calendarIdentifier)
        }
        guard let (writable, defaultID) = lists else { return AssistantReply(remindersUnavailable) }
        guard !writable.isEmpty else { return AssistantReply("Create or enable a writable list in Reminders.") }
        if list == nil, let preferred = writable.first(where: { $0.id == defaultID }) {
            return confirmReminder(title: title, listID: preferred.id, listName: preferred.title, day: day)
        }
        let matches =
            list.map { name in
                writable.filter { AssistantIntent.normalized($0.title) == AssistantIntent.normalized(name) }
            } ?? []
        if matches.count == 1, let match = matches.first {
            return confirmReminder(title: title, listID: match.id, listName: match.title, day: day)
        }
        let choices = (matches.isEmpty ? writable : matches).map { calendar in
            ("\(calendar.title), \(calendar.source)", calendar)
        }
        return .choose("Which reminders list?", choices: choices) { selected in
            confirmReminder(title: title, listID: selected.id, listName: selected.title, day: day)
        }
    }

    @MainActor private static func confirmReminder(title: String, listID: String, listName: String, day: AssistantDay?)
        -> AssistantReply
    {
        let calendar = Calendar.current
        let date = day?.interval(now: .now, calendar: calendar)?.start
        let due = date.map { ", due \(dayLabel($0))" } ?? ""
        return .confirm("Add “\(title)” to \(listName)\(due)?") {
            try await withEventStore { store in
                guard canWriteReminders else { return remindersUnavailable }
                guard let list = store.calendar(withIdentifier: listID), list.allowsContentModifications,
                    !hiddenSources.contains(listID)
                else { return "That reminders list is no longer writable." }
                let reminder = EKReminder(eventStore: store)
                reminder.calendar = list
                reminder.title = title
                if let date { reminder.dueDateComponents = calendar.dateComponents([.year, .month, .day], from: date) }
                try Task.checkCancellation()
                try store.save(reminder, commit: true)
                guard let saved = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder,
                    saved.calendar.calendarIdentifier == listID
                else { return "I couldn't verify the reminder. Check Reminders before trying again." }
                return "Added “\(title)” to \(listName)\(due)."
            }
        }
    }

    private struct CalendarDestination: Sendable {
        let id: String
        let title: String
        let source: String

        init(_ calendar: EKCalendar) {
            id = calendar.calendarIdentifier
            title = calendar.title
            source = calendar.source.title
        }
    }

    private static func withEventStore<Value: Sendable>(
        _ work: @escaping @Sendable (EKEventStore) throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try work(EKEventStore())
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func freeIntervals(in range: DateInterval, blocking: [DateInterval]) -> [DateInterval] {
        var gaps: [DateInterval] = []
        var cursor = range.start
        for busy in blocking.sorted(by: { $0.start < $1.start }) {
            guard busy.end > cursor, busy.start < range.end else { continue }
            if busy.start > cursor { gaps.append(DateInterval(start: cursor, end: busy.start)) }
            cursor = min(range.end, busy.end)
        }
        if cursor < range.end { gaps.append(DateInterval(start: cursor, end: range.end)) }
        return gaps
    }

    private static var hiddenSources: Set<String> {
        Set(
            (UserDefaults.standard.string(forKey: SystemCalendarService.hiddenSourcesKey) ?? "")
                .split(separator: "\n").map(String.init))
    }

    private static func events(in range: DateInterval, store: EKEventStore) -> [EKEvent] {
        let hidden = hiddenSources
        let calendars = store.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let query = store.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)
        return store.events(matching: query).sorted { $0.startDate < $1.startDate }
    }

    private static func blocking(in range: DateInterval, store: EKEventStore) -> [DateInterval] {
        events(in: range, store: store).compactMap { event in
            guard event.status != .canceled, event.availability != .free,
                !event.isAllDay || event.availability == .busy || event.availability == .unavailable,
                let start = event.startDate, let end = event.endDate,
                start < range.end, end > range.start, end > start
            else { return nil }
            return DateInterval(start: start, end: end)
        }
    }

    private static func dayLabel(_ date: Date) -> String { date.formatted(.dateTime.weekday(.wide).month().day()) }
    private static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}
