import AppKit
import EventKit
import SwiftUI

/// Read-only window onto the Mac's Calendar and Reminders. Nothing is cached:
/// the visible range is re-read whenever EventKit reports a change.
@MainActor
final class SystemCalendarService: ObservableObject {
    enum Access: Equatable { case notDetermined, granted, denied }

    struct Source: Identifiable, Equatable {
        let id: String
        let title: String
        let color: Color
        let isReminders: Bool
    }

    @Published private(set) var eventAccess = Access.notDetermined
    @Published private(set) var reminderAccess = Access.notDetermined
    @Published private(set) var items: [CalendarItem] = []
    @Published private(set) var sources: [Source] = []
    /// Why the last access request failed, if macOS returned an error.
    @Published private(set) var isRequestingAccess = false
    @Published private(set) var requestError: String?
    var stillRefused: Bool { anyDenied }

    private lazy var store = EKEventStore()
    private var range: DateInterval?
    /// The user's "Show Mac Calendar" choice. Off means EventKit is not read at all.
    private var isEnabled = true
    private var observer: NSObjectProtocol?

    var allGranted: Bool { eventAccess == .granted && reminderAccess == .granted }
    var anyDenied: Bool { eventAccess == .denied || reminderAccess == .denied }

    init() {
        readAccess()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) {
            [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    /// Only from an explicit "Connect" tap; never on launch.
    func requestAccess() async {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        defer { isRequestingAccess = false }
        requestError = nil
        readAccess()
        // A menu-bar app must be frontmost or the system prompt can open behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        do {
            // Only undecided or upgradeable access can show a consent prompt.
            if Self.shouldRequestAccess(EKEventStore.authorizationStatus(for: .event)) {
                _ = try await store.requestFullAccessToEvents()
            }
            if Self.shouldRequestAccess(EKEventStore.authorizationStatus(for: .reminder)) {
                _ = try await store.requestFullAccessToReminders()
            }
        } catch {
            requestError = HermesDiagnosticsService.safeSummary(error.localizedDescription)
        }
        // A store created before access was granted keeps an empty calendar list.
        readAccess()
        if eventAccess == .granted || reminderAccess == .granted { store.reset() }
        reload()
    }

    static func shouldRequestAccess(_ status: EKAuthorizationStatus) -> Bool {
        status == .notDetermined || status == .writeOnly
    }

    /// Re-reads permissions too, so access granted in System Settings shows up on return.
    func refresh() {
        readAccess()
        reload()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        reload()
    }

    func load(_ range: DateInterval) {
        guard range != self.range else { return }
        self.range = range
        reload()
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens the item in Calendar or Reminders.
    static func open(_ item: CalendarItem) {
        let raw = item.id.split(separator: ":", maxSplits: 1)
        guard raw.count == 2 else { return }
        let id = String(raw[1]).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(raw[1])
        let link =
            raw[0] == "event"
            ? "ical://ekevent/\(id)?method=show&options=more" : "x-apple-reminderkit://REMCDReminder/\(id)"
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    private func readAccess() {
        eventAccess = Self.access(EKEventStore.authorizationStatus(for: .event))
        reminderAccess = Self.access(EKEventStore.authorizationStatus(for: .reminder))
    }

    private static func access(_ status: EKAuthorizationStatus) -> Access {
        switch status {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        // Write-only access cannot read anything, so it counts as off.
        default: .denied
        }
    }

    private func reload() {
        guard isEnabled else {
            sources = []
            items = []
            return
        }
        guard let range else { return }
        var sources: [Source] = []
        var events: [CalendarItem] = []
        if eventAccess == .granted {
            let calendars = store.calendars(for: .event)
            sources += calendars.map {
                Source(
                    id: $0.calendarIdentifier, title: $0.title, color: Color(cgColor: $0.cgColor), isReminders: false)
            }
            let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)
            events = store.events(matching: predicate).map(Self.item)
        }
        guard reminderAccess == .granted else {
            self.sources = sources
            items = events
            return
        }
        let lists = store.calendars(for: .reminder)
        sources += lists.map {
            Source(id: $0.calendarIdentifier, title: $0.title, color: Color(cgColor: $0.cgColor), isReminders: true)
        }
        self.sources = sources
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: range.start, ending: range.end, calendars: lists)
        store.fetchReminders(matching: predicate) { reminders in
            let fetched = (reminders ?? []).compactMap(Self.item)
            Task { @MainActor [weak self] in
                // A newer range may have been requested while this one was fetching.
                guard let self, self.isEnabled, self.range == range else { return }
                self.items = events + fetched
            }
        }
    }

    nonisolated private static func item(_ event: EKEvent) -> CalendarItem {
        CalendarItem(
            id: "event:\(event.eventIdentifier ?? event.calendarItemIdentifier)",
            kind: .event(
                calendar: event.calendar.title,
                location: event.location,
                attendees: (event.attendees ?? []).compactMap {
                    $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                },
                url: event.url
            ),
            title: event.title ?? "Untitled event",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            notes: event.notes,
            sourceID: event.calendar.calendarIdentifier,
            color: Color(cgColor: event.calendar.cgColor)
        )
    }

    nonisolated private static func item(_ reminder: EKReminder) -> CalendarItem? {
        guard let components = reminder.dueDateComponents, let due = Calendar.current.date(from: components) else {
            return nil
        }
        return CalendarItem(
            id: "reminder:\(reminder.calendarItemIdentifier)",
            kind: .reminder(list: reminder.calendar.title),
            title: reminder.title ?? "Untitled reminder",
            start: due,
            isAllDay: components.hour == nil,
            notes: reminder.notes,
            sourceID: reminder.calendar.calendarIdentifier,
            color: Color(cgColor: reminder.calendar.cgColor)
        )
    }
}
