import AppKit
import SwiftUI

/// The Calendar destination: what is coming up. Mac events and reminders
/// (read-only, live from EventKit) beside Hermes' scheduled automation runs
/// and in-progress tasks, with actions that hand an item to Herm.
struct CalendarWorkspaceView: View {
    @ObservedObject var control: ControlCenterModel
    var onOpenTask: (KanbanTaskSummary) -> Void = { _ in }
    var onOpenAutomations: () -> Void = {}
    @StateObject private var system = SystemCalendarService()
    @State private var selected = Calendar.current.startOfDay(for: Date())
    @State private var selectedItemID: String?
    @State private var prepItem: CalendarItem?
    @State private var actionStatus: String?
    @AppStorage("dock.calendar.view") private var scopeRaw = CalendarViewScope.week.rawValue
    /// Calendar and list IDs the user hid, newline-separated. A local preference only.
    @AppStorage("dock.calendar.hidden") private var hiddenRaw = ""
    /// Whether to read the Mac's Calendar and Reminders. Access is still asked
    /// only from an explicit tap, so on by default never prompts at launch.
    @AppStorage("dock.calendar.system") private var useSystem = true
    @Environment(\.chatContextRouter) private var router

    private let calendar = Calendar.current
    private var scope: CalendarViewScope { CalendarViewScope(rawValue: scopeRaw) ?? .week }
    private var scopeBinding: Binding<CalendarViewScope> { Binding(get: { scope }, set: { scopeRaw = $0.rawValue }) }
    private var hidden: Set<String> { Set(hiddenRaw.split(separator: "\n").map(String.init)) }
    private var today: Date { calendar.startOfDay(for: Date()) }

    /// Whole weeks, so the month grid's leading and trailing days are filled too.
    private var range: DateInterval {
        let unit: Calendar.Component = scope == .month ? .month : .weekOfYear
        let span = calendar.dateInterval(of: unit, for: selected) ?? DateInterval(start: selected, duration: 86_400 * 7)
        let start = calendar.dateInterval(of: .weekOfYear, for: span.start)?.start ?? span.start
        let lastDay = span.end.addingTimeInterval(-1)
        let end = calendar.dateInterval(of: .weekOfYear, for: lastDay)?.end ?? span.end
        return DateInterval(start: start, end: end)
    }

    private var items: [CalendarItem] {
        system.items.filter { $0.sourceID.map { !hidden.contains($0) } ?? true }
            + CalendarAgenda.automationItems(control.cronJobs)
            + CalendarAgenda.taskItems(control.globalKanbanTasks)
    }

    var body: some View {
        let agenda = CalendarAgenda.build(items, in: range, calendar: calendar)
        VStack(alignment: .leading, spacing: 16) {
            toolbar
            GeometryReader { proxy in
                if proxy.size.width >= 1000 {
                    HStack(alignment: .top, spacing: 20) {
                        grid(agenda)
                        detail(agenda).frame(width: 360)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        grid(agenda).frame(height: scope == .month ? 460 : 320)
                        detail(agenda)
                    }
                }
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 16)
        .frame(maxWidth: 1600, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: range) {
            system.setEnabled(useSystem)
            system.load(range)
        }
        .onChange(of: useSystem) { _, enabled in system.setEnabled(enabled) }
        // Access granted in System Settings shows up when Herm comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in system.refresh() }
        .onChange(of: selected) { _, _ in
            selectedItemID = nil
            actionStatus = nil
        }
        .onChange(of: selectedItemID) { _, _ in actionStatus = nil }
        .sheet(item: $prepItem) { item in
            CalendarPrepSheet(item: item, control: control) { actionStatus = "Prep scheduled. It shows here once Hermes lists it." }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        let style = DockThemePalette(theme: DockThemeRuntime.current)
        return HStack(spacing: 10) {
            DockIconButton(icon: .caretLeft, label: "Previous \(scope.rawValue.lowercased())", style: style) { shift(-1) }
            DockIconButton(icon: .caretRight, label: "Next \(scope.rawValue.lowercased())", style: style) { shift(1) }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(selected.formatted(.dateTime.month(.wide)))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                Text(selected.formatted(.dateTime.year()))
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.dockMetadataText)
            }
            .padding(.leading, 4)
            if selected != today {
                Button("Today") { selected = today }
                    .buttonStyle(.dockSecondary)
                    .controlSize(.small)
            }
            Spacer(minLength: 8)
            DockTabBar(options: CalendarViewScope.allCases, selection: scopeBinding, title: \.rawValue)
            DockMenu {
                DockMenuSection("Mac") {
                    Toggle("Show Calendar & Reminders", isOn: useSystemBinding)
                }
                if !eventSources.isEmpty {
                    DockMenuSection("Calendars") { ForEach(eventSources) { sourceToggle($0) } }
                }
                if !reminderSources.isEmpty {
                    DockMenuSection("Reminders") { ForEach(reminderSources) { sourceToggle($0) } }
                }
            } label: {
                // Same pill as `AttachToChatMenu`, so the menu reads as clickable at rest.
                HStack(spacing: 5) {
                    DockIcon(.funnel, size: 12, color: Color.dockSecondaryText)
                    Text("Calendars")
                    DockIcon(.caretDown, size: 10, color: Color.dockMetadataText)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.dockSecondaryText)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous)
                        .dockSurfaceFill(Color.dockControlSurface.opacity(0.6))
                )
            }
            .fixedSize()
            DockIconButton(icon: .arrowsClockwise, label: "Refresh calendar", style: style) {
                system.refresh()
                control.refresh()
                control.refreshGlobalKanban()
            }
        }
        .frame(minHeight: DockControlMetrics.hitTarget)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }

    private func sourceToggle(_ source: SystemCalendarService.Source) -> some View {
        Toggle(source.title, isOn: Binding(
            get: { !hidden.contains(source.id) },
            set: { show in
                var next = hidden
                if show { next.remove(source.id) } else { next.insert(source.id) }
                hiddenRaw = next.sorted().joined(separator: "\n")
            }
        ))
    }

    private var eventSources: [SystemCalendarService.Source] { system.sources.filter { !$0.isReminders } }
    private var reminderSources: [SystemCalendarService.Source] { system.sources.filter(\.isReminders) }

    /// Checked only while Mac events are actually readable. Checking it asks
    /// macOS for access right here, like Connect.
    private var useSystemBinding: Binding<Bool> {
        Binding(get: { useSystem && system.eventAccess == .granted }, set: { enabled in
            useSystem = enabled
            guard enabled, !system.allGranted else { return }
            Task { await system.requestAccess() }
        })
    }

    private func shift(_ delta: Int) {
        let unit: Calendar.Component = scope == .month ? .month : .weekOfYear
        selected = calendar.date(byAdding: unit, value: delta, to: selected).map(calendar.startOfDay) ?? selected
    }

    // MARK: Grid

    private func grid(_ agenda: [Date: [CalendarItem]]) -> some View {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let ordered = Array(symbols[(calendar.firstWeekday - 1)...] + symbols[..<(calendar.firstWeekday - 1)])
        // Calendar arithmetic, not 86,400s steps, so DST weeks keep seven days.
        let count = calendar.dateComponents([.day], from: range.start, to: range.end).day ?? 0
        let days = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: range.start) }
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        let shape = RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol.uppercased()).frame(maxWidth: .infinity)
                }
            }
            .font(DockTypography.sectionLabel)
            .tracking(0.6)
            .foregroundStyle(Color.dockMetadataText)
            .padding(.vertical, 10)
            ForEach(weeks, id: \.first) { week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.element) { column, day in
                        dayCell(day, items: agenda[day] ?? [])
                            .overlay(alignment: .leading) {
                                if column > 0 { Color.dockBorderLight.frame(width: DockLayout.hairline) }
                            }
                    }
                }
                .frame(maxHeight: .infinity)
                .overlay(alignment: .top) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(Color.dockPrimaryText.opacity(0.02)))
        .clipShape(shape)
        .overlay(shape.stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline))
    }

    private func dayCell(_ day: Date, items: [CalendarItem]) -> some View {
        let isToday = day == today
        let isSelected = day == selected
        let outside = scope == .month && !calendar.isDate(day, equalTo: selected, toGranularity: .month)
        // ponytail: fixed caps; size by cell height if rows get crowded.
        let cap = scope == .month ? 3 : 10
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: 12, weight: isToday ? .bold : .medium).monospacedDigit())
                .foregroundStyle(isToday ? Color.dockOnAccentText : (outside ? Color.dockMetadataText : Color.dockPrimaryText))
                .frame(minWidth: 22, minHeight: 22)
                .background { if isToday { Circle().fill(Color.dockAccent) } }
                .padding(.bottom, 1)
            ForEach(items.prefix(cap)) { chip($0) }
            if items.count > cap {
                Text("\(items.count - cap) more")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.dockMetadataText)
                    .padding(.leading, 4)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isSelected ? Color.dockAccent.opacity(0.08) : Color.clear)
        .clipped()
        .opacity(outside ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture { selected = day }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day.formatted(.dateTime.weekday(.wide).month().day())), \(items.count) items")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func chip(_ item: CalendarItem) -> some View {
        let color = tint(item)
        return HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 0) {
                if scope == .week, !item.isAllDay {
                    Text(item.start.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Color.dockMetadataText)
                }
                Text(item.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(scope == .week ? 2 : 1)
            }
        }
        .padding(.vertical, 2)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color.opacity(0.14)))
    }

    // MARK: Detail

    private func detail(_ agenda: [Date: [CalendarItem]]) -> some View {
        let dayItems = agenda[selected] ?? []
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected.formatted(.dateTime.weekday(.wide)))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                    Text(selected.formatted(.dateTime.month(.wide).day().year()))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockMetadataText)
                }
                Spacer(minLength: 8)
                if let router {
                    Button("Plan in chat") {
                        router.attach(CalendarAgenda.dayContext(selected, items: dayItems), to: nil)
                    }
                    .buttonStyle(.dockSecondary)
                    .controlSize(.small)
                    .help("Start a new chat with this day's agenda attached")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    accessCard
                    if dayItems.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Nothing scheduled")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.dockPrimaryText)
                            Text("Events, reminders, and Hermes runs for this day appear here.")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.dockMetadataText)
                        }
                        .padding(.top, 4)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(dayItems) { itemRow($0) }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var accessCard: some View {
        if useSystem, !system.allGranted {
            // Each service is shown on its own: Reminders being allowed must not
            // hide that Calendar is not.
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect your Mac calendar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                Text("Calendar: \(accessLabel(system.eventAccess)) · Reminders: \(accessLabel(system.reminderAccess))")
                    .font(DockTypography.metadata)
                    .foregroundStyle(Color.dockMetadataText)
                Text("Herm reads events from every account in Calendar, plus your reminders, to place them beside Hermes' scheduled runs. Nothing is stored or changed.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = system.requestError {
                    Text(error)
                        .font(DockTypography.metadata)
                        .foregroundStyle(Color.dockWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Connect") { Task { await system.requestAccess() } }
                        .buttonStyle(.dockPrimary)
                        .controlSize(.small)
                    Button("Not now") { useSystem = false }
                        .buttonStyle(.dockSecondary)
                        .controlSize(.small)
                        .help("Hide this. Turn it on later from the Calendars menu.")
                    Spacer(minLength: 8)
                    // Only after Connect could not get past a refusal.
                    if system.stillRefused {
                        Button("Privacy Settings") { SystemCalendarService.openPrivacySettings() }
                            .buttonStyle(.dockLink)
                            .help("macOS did not show the prompt. Allow Herm under Calendars and Reminders there.")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dockCard()
        }
    }

    private func accessLabel(_ access: SystemCalendarService.Access) -> String {
        switch access {
        case .granted: "allowed"
        case .notDetermined: "not connected"
        case .denied: "not allowed"
        }
    }

    private func itemRow(_ item: CalendarItem) -> some View {
        let isSelected = item.id == selectedItemID
        let shape = RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            Button { selectedItemID = isSelected ? nil : item.id } label: {
                HStack(alignment: .top, spacing: 10) {
                    Capsule().fill(tint(item)).frame(width: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.dockPrimaryText)
                            .lineLimit(isSelected ? 3 : 1)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 5) {
                            DockIcon(icon(item), size: 11, color: Color.dockMetadataText)
                            Text(timeLabel(item))
                            Text("·")
                            Text(source(item)).lineLimit(1)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockMetadataText)
                    }
                    Spacer(minLength: 0)
                    DockIcon(isSelected ? .caretUp : .caretDown, size: 10, color: Color.dockMetadataText)
                        .padding(.top, 3)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            if isSelected { itemPanel(item).padding(.horizontal, 10).padding(.bottom, 10) }
        }
        .background(shape.fill(Color.dockPrimaryText.opacity(isSelected ? 0.05 : 0.025)))
        .overlay(shape.stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline))
    }

    private func itemPanel(_ item: CalendarItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // A Group, so an item without details adds no empty gap.
            Group {
                if case .event(_, let location, let attendees, _) = item.kind {
                    if let location, !location.isEmpty { detailLine(.mapPin, location) }
                    if !attendees.isEmpty { detailLine(.users, attendees.joined(separator: ", ")) }
                }
                if let notes = item.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                    Text(notes).font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText).lineLimit(4)
                }
            }
            // One row when it fits; the open link drops below otherwise.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    actions(item)
                    Spacer(minLength: 8)
                    openLink(item)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { actions(item) }
                    openLink(item)
                }
            }
            if let actionStatus {
                Text(actionStatus)
                    .font(DockTypography.metadata)
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(2)
            }
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func actions(_ item: CalendarItem) -> some View {
        AttachToChatMenu(pill: true) { item.chatContext }
        switch item.kind {
        case .event, .reminder:
            createTaskButton(item)
            if item.isEvent, !item.isAllDay {
                let canSchedule = control.cronControlAvailable && CalendarAgenda.prepSchedule(before: item.start, leadMinutes: 15) != nil
                Button("Schedule prep…") { prepItem = item }
                    .buttonStyle(.dockSecondary)
                    .controlSize(.small)
                    .disabled(!canSchedule)
                    .help(control.cronControlAvailable ? "Have Hermes run a one-time prep before this event" : "Automation control is unavailable through this Hermes gateway")
            }
        case .automation, .task:
            EmptyView()
        }
    }

    @ViewBuilder
    private func openLink(_ item: CalendarItem) -> some View {
        switch item.kind {
        case .event: Button("Open in Calendar") { SystemCalendarService.open(item) }.buttonStyle(.dockLink)
        case .reminder: Button("Open in Reminders") { SystemCalendarService.open(item) }.buttonStyle(.dockLink)
        case .automation: Button("Open Automations", action: onOpenAutomations).buttonStyle(.dockLink)
        case .task(let task): Button("Open task") { onOpenTask(task) }.buttonStyle(.dockLink)
        }
    }

    private func timeLabel(_ item: CalendarItem) -> String {
        if item.isAllDay { return "All day" }
        let start = item.start.formatted(.dateTime.hour().minute())
        guard let end = item.end, end > item.start else { return start }
        return "\(start)–\(end.formatted(.dateTime.hour().minute()))"
    }

    private func detailLine(_ icon: Ph, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            DockIcon(icon, size: 11, color: Color.dockMetadataText)
            Text(text).lineLimit(2)
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.dockSecondaryText)
    }

    private func createTaskButton(_ item: CalendarItem) -> some View {
        Button("Create Kanban task") { createTask(item) }
            .buttonStyle(.dockSecondary)
            .controlSize(.small)
            .disabled(!control.capabilityAvailable("kanban.create"))
            .help(control.capabilityAvailable("kanban.create") ? "Create a Hermes Kanban task from this item" : "Kanban is unavailable in this Hermes runtime")
    }

    private func createTask(_ item: CalendarItem) {
        Task {
            let created = await control.createKanbanTask(title: item.title, body: item.chatBody)
            actionStatus = created ? "Kanban task created." : (control.lastError ?? "Hermes did not create the task.")
        }
    }

    private func icon(_ item: CalendarItem) -> Ph {
        switch item.kind {
        case .event: .calendarBlank
        case .reminder: .checkCircle
        case .automation: .clockCounterClockwise
        case .task: .kanban
        }
    }

    private func tint(_ item: CalendarItem) -> Color {
        switch item.kind {
        case .event, .reminder: item.color ?? .dockAccent
        case .automation: .dockAccent
        case .task: .dockSuccess
        }
    }

    private func source(_ item: CalendarItem) -> String {
        switch item.kind {
        case .event(let calendar, _, _, _): calendar
        case .reminder(let list): list
        case .automation: "Automation"
        case .task: "Kanban"
        }
    }
}

private enum CalendarViewScope: String, CaseIterable {
    case week = "Week"
    case month = "Month"
}

/// One-time Hermes automation ahead of an event. Hermes reads an ISO
/// timestamp schedule as "run once".
private struct CalendarPrepSheet: View {
    let item: CalendarItem
    @ObservedObject var control: ControlCenterModel
    let onScheduled: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var lead = 30
    @State private var prompt: String
    @State private var isSaving = false
    @State private var error: String?

    init(item: CalendarItem, control: ControlCenterModel, onScheduled: @escaping () -> Void) {
        self.item = item
        self.control = control
        self.onScheduled = onScheduled
        _prompt = State(initialValue: "Prepare a short brief for this event: what it is about, open questions, and anything I should read first.\n\n" + item.chatBody)
    }

    private var schedule: String? { CalendarAgenda.prepSchedule(before: item.start, leadMinutes: lead) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schedule prep").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.dockPrimaryText)
            Text("Hermes runs this once before \(item.title). It appears under Automations.")
                .font(.system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            DockTabBar(options: [15, 30, 60], selection: $lead, title: { "\($0) min before" })
            TextEditor(text: $prompt)
                .font(.system(size: 12))
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius).dockSurfaceFill(Color.dockControlSurface.opacity(0.6)))
            Text(error ?? (schedule == nil ? "That time has already passed. Pick a shorter lead." : " "))
                .font(DockTypography.metadata)
                .foregroundStyle(Color.dockWarning)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.dockSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(isSaving ? "Scheduling…" : "Schedule") { save() }
                    .buttonStyle(.dockPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(schedule == nil || isSaving || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 480)
    }

    private func save() {
        guard let schedule else { return }
        isSaving = true
        Task {
            if await control.createCron(name: "Prep: \(item.title)", schedule: schedule, prompt: prompt) {
                onScheduled()
                dismiss()
            } else {
                error = control.lastError ?? "Hermes did not create the automation."
            }
            isSaving = false
        }
    }
}
