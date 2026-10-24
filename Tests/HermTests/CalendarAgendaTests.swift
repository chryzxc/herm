import Foundation
import Testing

@testable import Herm

@MainActor
struct CalendarAgendaTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Manila")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private var week: DateInterval { DateInterval(start: date(19, 0), end: date(26, 0)) }

    private func event(_ id: String, start: Date, end: Date? = nil, allDay: Bool = false, location: String? = nil)
        -> CalendarItem
    {
        CalendarItem(
            id: "event:\(id)", kind: .event(calendar: "Work", location: location, attendees: [], url: nil),
            title: id, start: start, end: end, isAllDay: allDay)
    }

    @Test func bucketsByLocalDayWithAllDayFirst() {
        let agenda = CalendarAgenda.build(
            [
                event("standup", start: date(20, 9), end: date(20, 9, 15)),
                event("offsite", start: date(20, 0), end: date(21, 0), allDay: true),
                event("late", start: date(20, 23, 30), end: date(21, 0)),
            ], in: week, calendar: calendar)

        #expect(agenda[date(20, 0)]?.map(\.id) == ["event:offsite", "event:standup", "event:late"])
        // Ending exactly at midnight does not spill into the next day.
        #expect(agenda[date(21, 0)] == nil)
    }

    @Test func multiDayEventsCoverEveryDayInsideTheRange() {
        let agenda = CalendarAgenda.build(
            [event("trip", start: date(17, 0), end: date(21, 0), allDay: true)], in: week, calendar: calendar)
        #expect(agenda.keys.sorted() == [date(19, 0), date(20, 0)])
    }

    @Test func automationsWithoutATimestampAreDroppedNotGuessed() {
        let jobs = [
            CronSummary(id: "a", name: "Digest", schedule: "0 9 * * *", enabled: true, nextRun: "2026-10-21T01:00:00Z"),
            CronSummary(
                id: "b", name: "Paused", schedule: "0 9 * * *", enabled: false, nextRun: "2026-10-21T01:00:00Z"),
            CronSummary(id: "c", name: "Odd", schedule: "every 2h", enabled: true, nextRun: "soon"),
        ]
        #expect(CalendarAgenda.automationItems(jobs).map(\.id) == ["cron:a"])
    }

    @Test func onlyInProgressTasksSitOnToday() {
        let tasks = [
            KanbanTaskSummary(id: "1", title: "Running", status: "running", detail: nil, priority: nil, assignee: nil),
            KanbanTaskSummary(id: "2", title: "Done", status: "done", detail: nil, priority: nil, assignee: nil),
        ]
        let items = CalendarAgenda.taskItems(tasks, now: date(20, 15), calendar: calendar)
        #expect(items.map(\.id) == ["kanban:1"])
        #expect(items.first?.start == date(20, 0))
        #expect(items.first?.isAllDay == true)
    }

    @Test func prepScheduleIsAnISOTimestampBeforeTheEventOrNilOncePassed() {
        let zone = TimeZone(identifier: "Asia/Manila")!
        #expect(
            CalendarAgenda.prepSchedule(before: date(20, 10), leadMinutes: 30, now: date(20, 8), timeZone: zone)
                == "2026-10-20T09:30:00+08:00")
        #expect(
            CalendarAgenda.prepSchedule(before: date(20, 10), leadMinutes: 30, now: date(20, 9, 45), timeZone: zone)
                == nil)
    }

    @Test func chatBodyCarriesOnlyTheFieldsPresent() {
        let bare = event("Review", start: date(20, 10), end: date(20, 11))
        #expect(bare.chatBody.contains("Calendar event: \"Review\""))
        #expect(!bare.chatBody.contains("Location:"))
        let placed = event("Review", start: date(20, 10), end: date(20, 11), location: "Room 4")
        #expect(placed.chatBody.contains("Location: Room 4"))
        #expect(placed.chatContext.id == "calendar:event:Review")
    }

    @Test func dayContextListsTheAgendaUnderAStableID() {
        let context = CalendarAgenda.dayContext(date(20, 0), items: [event("Standup", start: date(20, 9))])
        #expect(context.id.hasPrefix("agenda:2026-10-"))
        #expect(context.body.contains("Standup (event)"))
    }
    @Test func searchMatchesTitlesSourcesAndLocationsAndCombinesWithKind() {
        let meeting = event("Review", start: date(20, 10), location: "Room 4")
        let reminder = CalendarItem(
            id: "reminder", kind: .reminder(list: "Personal"), title: "Review notes", start: date(20))
        let items = [meeting, reminder]
        #expect(CalendarAgenda.filtered(items, query: "  review  ", kind: .all).count == 2)
        #expect(CalendarAgenda.filtered(items, query: "ROOM 4", kind: .events).map(\.id) == [meeting.id])
        #expect(CalendarAgenda.filtered(items, query: "work", kind: .all).map(\.id) == [meeting.id])
        #expect(CalendarAgenda.filtered(items, query: "review", kind: .reminders).map(\.id) == [reminder.id])
        #expect(CalendarAgenda.filtered(items, query: "missing", kind: .all).isEmpty)
        #expect(CalendarAgenda.filtered(items, query: " ", kind: .all) == items)
    }

    @Test func overlapsExcludeAllDayRemindersMissingEndsAndTouchingBoundaries() {
        let items = [
            event("a", start: date(20, 9), end: date(20, 11)),
            event("b", start: date(20, 10), end: date(20, 12)),
            event("adjacent", start: date(20, 12), end: date(20, 13)),
            event("all day", start: date(20, 0), end: date(21, 0), allDay: true),
            event("unknown end", start: date(20, 10)),
            event("invalid end", start: date(20, 10), end: date(20, 9)),
            CalendarItem(
                id: "reminder", kind: .reminder(list: "Work"), title: "Due", start: date(20, 10), end: date(20, 11)),
        ]
        #expect(CalendarAgenda.overlappingEventIDs(items) == ["event:a", "event:b"])
    }

    @Test func overlapsIncludeNestedAndOvernightEvents() {
        let items = [
            event("overnight", start: date(19, 23), end: date(20, 10)),
            event("nested", start: date(20, 8), end: date(20, 9)),
            event("later", start: date(20, 9), end: date(20, 11)),
        ]
        #expect(CalendarAgenda.overlappingEventIDs(items) == Set(items.map(\.id)))
    }

}
