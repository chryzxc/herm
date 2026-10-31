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
    @State private var query = ""
    @State private var itemFilter = CalendarAgenda.Filter.all
    @State private var showingDatePicker = false
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

    private var visibleItems: [CalendarItem] {
        CalendarAgenda.filtered(items, query: query, kind: itemFilter)
    }

    private var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || itemFilter != .all
    }

    var body: some View {
        let agenda = CalendarAgenda.build(visibleItems, in: range, calendar: calendar)
        VStack(alignment: .leading, spacing: 16) {
            toolbar
            searchControls
            GeometryReader { proxy in
                if proxy.size.width >= 1000 {
                    HStack(alignment: .top, spacing: 20) {
                        if scope == .agenda {
                            agendaList(agenda)
                        } else {
                            ScrollView {
                                calendarPane(agenda).frame(height: max(560, proxy.size.height))
                            }
                        }
                        detail(agenda).frame(width: 340)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if scope == .agenda {
                                agendaList(agenda).frame(height: 360)
                            } else {
                                calendarPane(agenda).frame(
                                    height: proxy.size.width < 560
                                        ? (scope == .month ? 440 : 240) : (scope == .month ? 600 : 420))
                            }
                            detail(agenda, stacked: true).frame(height: 380)
                        }
                    }
                }
            }
        }
        .dockPadding(.top, 4)
        .dockPadding(.bottom, 16)
        .frame(maxWidth: 1600, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: range) {
            system.setEnabled(useSystem)
            system.load(range)
        }
        .onChange(of: useSystem) { _, enabled in system.setEnabled(enabled) }
        // Access granted in System Settings shows up when Herm comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            system.refresh()
        }
        .onChange(of: selected) { _, _ in
            if !(agenda[selected] ?? []).contains(where: { $0.id == selectedItemID }) {
                selectedItemID = nil
            }
            actionStatus = nil
        }
        .onChange(of: selectedItemID) { _, _ in actionStatus = nil }
        .dockSheet(item: $prepItem) { item in
            CalendarPrepSheet(item: item, control: control) {
                actionStatus = "Prep scheduled. It shows here once Hermes lists it."
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                dateNavigation
                Spacer(minLength: 12)
                calendarControls
            }
            VStack(alignment: .leading, spacing: 12) {
                dateNavigation
                calendarControls
            }
        }
        .dockPadding(.bottom, 12)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }

    private var dateNavigation: some View {
        let style = DockThemePalette(theme: DockThemeRuntime.current)
        return HStack(spacing: 8) {
            Button {
                showingDatePicker.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(selected.formatted(.dateTime.month(.wide).year()))
                        .dockFont(.pageTitle)
                    DockIcon(.caretDown, size: 10, color: .dockSecondaryText)
                }
            }
            .buttonStyle(.dockCompact)
            .fixedSize()
            .help("Jump to a date")
            .dockPopover(isPresented: $showingDatePicker) {
                DockDateGrid(
                    selection: Binding(
                        get: { selected },
                        set: {
                            selected = calendar.startOfDay(for: $0)
                            showingDatePicker = false
                        })
                )
                .dockPadding(16)
            }
            DockIconButton(icon: .caretLeft, label: "Previous \(scope == .month ? "month" : "week")", style: style) {
                shift(-1)
            }
            DockIconButton(icon: .caretRight, label: "Next \(scope == .month ? "month" : "week")", style: style) {
                shift(1)
            }
            Button("Today") { selected = today }
                .buttonStyle(.dockCompact)
                .disabled(selected == today)
        }
    }

    private var calendarControls: some View {
        let style = DockThemePalette(theme: DockThemeRuntime.current)
        return HStack(spacing: 10) {
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
                .dockFont(.body, weight: .medium)
                .foregroundStyle(Color.dockSecondaryText)
                .dockPadding(.horizontal, 10)
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
        .fixedSize()
    }

    private var searchControls: some View {
        HStack(spacing: 10) {
            DockTextField("Search this \(scope == .month ? "month" : "week")", text: $query)
                .textFieldStyle(.dockGlass)
                .accessibilityLabel("Search calendar titles, sources, and locations")
            DockMenu {
                ForEach(CalendarAgenda.Filter.allCases, id: \.self) { filter in
                    Button(filter.rawValue) { itemFilter = filter }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(itemFilter.rawValue)
                    DockIcon(.caretDown, size: 10, color: .dockSecondaryText)
                }
            }
            .buttonStyle(.dockCompact)
            Button("Clear") {
                query = ""
                itemFilter = .all
            }
            .buttonStyle(.dockCompact)
            .disabled(!isFiltering)
        }
    }

    private func agendaList(_ agenda: [Date: [CalendarItem]]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if agenda.isEmpty {
                    Text(isFiltering ? "No matching items this week" : "Nothing scheduled this week")
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(Color.dockSecondaryText)
                        .dockPadding(16)
                }
                ForEach(agenda.keys.sorted(), id: \.self) { day in
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            selected = day
                        } label: {
                            HStack {
                                Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                                if day == today { Text("Today") }
                                Spacer()
                                Text("\(agenda[day]?.count ?? 0) items")
                            }
                            .dockFont(.body, weight: .semibold)
                        }
                        .buttonStyle(.dockCompact)
                        ForEach(agenda[day] ?? []) { item in
                            Button {
                                selected = day
                                selectedItemID = item.id
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Text(item.isAllDay ? "All day" : timeLabel(item))
                                        .monospacedDigit().frame(width: 110, alignment: .leading)
                                        .foregroundStyle(Color.dockSecondaryText)
                                    DockIcon(icon(item), size: 12, color: tint(item))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.title).foregroundStyle(Color.dockPrimaryText)
                                        Text(source(item)).foregroundStyle(Color.dockMetadataText)
                                    }
                                    Spacer(minLength: 0)
                                    DockIcon(.caretRight, size: 10, color: .dockMetadataText)
                                }
                                .dockFont(.body)
                                .multilineTextAlignment(.leading)
                                .dockPadding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.dockHover)
                            .help("Show this day's agenda and actions")
                        }
                    }
                    .dockPadding(12)
                    .background {
                        DockThemeShape(cornerRadius: DockLayout.paneRadius)
                            .dockSelectionFill(day == selected, fallback: Color.dockSurface)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                legendLabel("Events", icon: .calendarBlank, color: DockCategoryTone.event.color)
                legendLabel("Reminders", icon: .checkCircle, color: DockCategoryTone.reminder.color)
                legendLabel("Agent runs", icon: .clockCounterClockwise, color: DockCategoryTone.automation.color)
                legendLabel("Kanban", icon: .kanban, color: DockCategoryTone.task.color)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    legendLabel("Events", icon: .calendarBlank, color: DockCategoryTone.event.color)
                    legendLabel("Reminders", icon: .checkCircle, color: DockCategoryTone.reminder.color)
                }
                HStack(spacing: 16) {
                    legendLabel("Agent runs", icon: .clockCounterClockwise, color: DockCategoryTone.automation.color)
                    legendLabel("Kanban", icon: .kanban, color: DockCategoryTone.task.color)
                }
            }
        }
        .help("Mac events and reminders use their calendar or list color when available.")
    }

    private func legendLabel(_ title: String, icon: Ph, color: Color) -> some View {
        HStack(spacing: 5) {
            DockIcon(icon, size: 12, color: color)
            Text(title).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
        }
        .fixedSize()
    }

    private func sourceToggle(_ source: SystemCalendarService.Source) -> some View {
        Toggle(
            source.title,
            isOn: Binding(
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
        Binding(
            get: { useSystem && system.eventAccess == .granted },
            set: { enabled in
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

    private func calendarPane(_ agenda: [Date: [CalendarItem]]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            grid(agenda)
            legend
                .dockPadding(.horizontal, 4)
        }
    }

    private func grid(_ agenda: [Date: [CalendarItem]]) -> some View {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let ordered = Array(symbols[(calendar.firstWeekday - 1)...] + symbols[..<(calendar.firstWeekday - 1)])
        // Calendar arithmetic, not 86,400s steps, so DST weeks keep seven days.
        let count = calendar.dateComponents([.day], from: range.start, to: range.end).day ?? 0
        let days = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: range.start) }
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        let shape = DockThemeShape(cornerRadius: DockLayout.paneRadius)
        return GeometryReader { proxy in
            let rowHeight = (proxy.size.height - 34) / CGFloat(max(1, weeks.count))
            let cap = min(10, max(0, Int((rowHeight - 62) / (scope == .month ? 40 : 54))))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol.uppercased()).frame(maxWidth: .infinity)
                    }
                }
                .dockFont(.sectionLabel)
                .tracking(0.6)
                .foregroundStyle(Color.dockMetadataText)
                .dockPadding(.vertical, 12)
                ForEach(weeks, id: \.first) { week in
                    HStack(spacing: 0) {
                        ForEach(Array(week.enumerated()), id: \.element) { column, day in
                            dayCell(day, items: agenda[day] ?? [], cap: cap, compact: proxy.size.width < 560)
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
            .background(shape.dockSurfaceFill(Color.dockSurface))
            .clipShape(shape)
            .overlay(shape.stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline))
        }
    }

    private func dayCell(_ day: Date, items: [CalendarItem], cap: Int, compact: Bool) -> some View {
        let isToday = day == today
        let isSelected = day == selected
        let outside = scope == .month && !calendar.isDate(day, equalTo: selected, toGranularity: .month)
        return Button {
            selected = day
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(calendar.component(.day, from: day))")
                        .dockFont(.body, weight: isToday ? .bold : .medium).monospacedDigit()
                        .foregroundStyle(
                            isToday
                                ? Color.dockOnAccentText : (outside ? Color.dockMetadataText : Color.dockPrimaryText)
                        )
                        .frame(minWidth: 22, minHeight: 22)
                        .background { if isToday { Circle().fill(Color.dockAccent) } }
                    Spacer(minLength: 0)
                    if !items.isEmpty {
                        Text("\(items.count)")
                            .dockFont(.machineMetadata)
                            .foregroundStyle(Color.dockMetadataText)
                    }
                }
                .dockPadding(.bottom, 3)
                if compact {
                    HStack(spacing: 3) {
                        ForEach(items.prefix(3)) { item in
                            DockIcon(icon(item), size: 8, color: tint(item))
                        }
                    }
                } else {
                    ForEach(items.prefix(cap)) { chip($0) }
                    if items.count > cap {
                        Text("\(items.count - cap) more")
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockMetadataText)
                            .dockPadding(.leading, 4)
                    }
                }
            }
            .dockPadding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                isSelected ? Color.dockAccentMuted : (calendar.isDateInWeekend(day) ? Color.dockSurface2 : Color.clear)
            )
            .overlay(alignment: .top) {
                if isSelected { Color.dockAccent.frame(height: 2) }
            }
            .clipped()
            .opacity(outside ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day.formatted(.dateTime.weekday(.wide).month().day())), \(items.count) items")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func chip(_ item: CalendarItem) -> some View {
        let color = tint(item)
        return HStack(spacing: 5) {
            DockIcon(icon(item), size: 10, color: color)
            VStack(alignment: .leading, spacing: 0) {
                if !item.isAllDay {
                    Text(item.start.formatted(.dateTime.hour().minute()))
                        .dockFont(.metadata).monospacedDigit()
                        .foregroundStyle(Color.dockMetadataText)
                }
                Text(item.title)
                    .dockFont(.body, weight: .medium)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(scope == .week ? 2 : 1)
            }
        }
        .dockPadding(.vertical, 4)
        .dockPadding(.horizontal, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color.opacity(0.08)))
    }

    // MARK: Detail

    private func detail(_ agenda: [Date: [CalendarItem]], stacked: Bool = false) -> some View {
        let dayItems = agenda[selected] ?? []
        let fullDayItems = CalendarAgenda.build(items, in: range, calendar: calendar)[selected] ?? []
        let overlaps = CalendarAgenda.overlappingEventIDs(fullDayItems)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected.formatted(.dateTime.weekday(.wide)))
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                    Text(selected.formatted(.dateTime.month(.wide).day()))
                        .dockFont(.body)
                        .foregroundStyle(Color.dockMetadataText)
                    Text("\(dayItems.count) \(dayItems.count == 1 ? "item" : "items")")
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockSecondaryText)
                }
                Spacer(minLength: 8)
                if let router {
                    Button("Plan in chat") {
                        router.attach(CalendarAgenda.dayContext(selected, items: fullDayItems), to: nil)
                    }
                    .buttonStyle(.dockSecondary)
                    .controlSize(.small)
                    .help("Start a new chat with this day's agenda attached")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if dayItems.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(isFiltering ? "No matching items" : "Nothing scheduled")
                                .dockFont(.body, weight: .semibold)
                                .foregroundStyle(Color.dockPrimaryText)
                            Text(
                                isFiltering
                                    ? "Clear filters to see the full day."
                                    : "Events, reminders, and Hermes runs for this day appear here."
                            )
                            .dockFont(.body)
                            .foregroundStyle(Color.dockMetadataText)
                        }
                        .dockPadding(.top, 4)
                    } else {
                        ForEach([true, false], id: \.self) { allDay in
                            let sectionItems = dayItems.filter { $0.isAllDay == allDay }
                            if !sectionItems.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(allDay ? "All day" : "Schedule")
                                        .dockFont(.body, weight: .semibold)
                                        .foregroundStyle(Color.dockSecondaryText)
                                    ForEach(sectionItems) { item in
                                        itemRow(item, overlaps: overlaps.contains(item.id))
                                    }
                                }
                            }
                        }
                    }
                    accessCard
                }
            }
            .scrollIndicators(.hidden)
        }
        .dockPadding(stacked ? .top : .leading, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: stacked ? .top : .leading) {
            if stacked {
                Color.dockBorderLight.frame(height: DockLayout.hairline)
            } else {
                Color.dockBorderLight.frame(width: DockLayout.hairline)
            }
        }
    }

    @ViewBuilder
    private var accessCard: some View {
        if useSystem, !system.allGranted {
            // Each service is shown on its own: Reminders being allowed must not
            // hide that Calendar is not.
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect your Mac calendar")
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                Text("Calendar: \(accessLabel(system.eventAccess)) · Reminders: \(accessLabel(system.reminderAccess))")
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
                Text("See your events and reminders beside agent runs. Read-only; nothing is changed.")
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = system.requestError {
                    Text(error)
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button {
                        Task { await system.requestAccess() }
                    } label: {
                        DockActionLabel(
                            title: "Connect", pendingTitle: "Connecting…", isPending: system.isRequestingAccess)
                    }
                    .disabled(system.isRequestingAccess)
                    .buttonStyle(.dockPrimary)
                    .controlSize(.small)
                    Button("Not now") { useSystem = false }
                        .buttonStyle(.dockSecondary)
                        .controlSize(.small)
                        .help("Hide this. Turn it on later from the Calendars menu.")
                    Spacer(minLength: 8)
                    // Existing refusals are changed in System Settings.
                    if system.stillRefused {
                        Button("Privacy Settings") { SystemCalendarService.openPrivacySettings() }
                            .buttonStyle(.dockLink)
                            .help("Allow Herm under Calendars and Reminders in Privacy & Security.")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dockPadding(.top, 16)
            .overlay(alignment: .top) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
        }
    }

    private func accessLabel(_ access: SystemCalendarService.Access) -> String {
        switch access {
        case .granted: "allowed"
        case .notDetermined: "not connected"
        case .denied: "not allowed"
        }
    }

    private func itemRow(_ item: CalendarItem, overlaps: Bool) -> some View {
        let isSelected = item.id == selectedItemID
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                selectedItemID = isSelected ? nil : item.id
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Text(item.isAllDay ? "All day" : item.start.formatted(.dateTime.hour().minute()))
                        .dockFont(.metadata)
                        .monospacedDigit()
                        .foregroundStyle(Color.dockSecondaryText)
                        .frame(width: 66, alignment: .leading)
                        .dockPadding(.top, 2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title)
                            .dockFont(.body, weight: .semibold)
                            .foregroundStyle(Color.dockPrimaryText)
                            .lineLimit(isSelected ? nil : 2)
                            .multilineTextAlignment(.leading)
                        if overlaps {
                            Text("Overlaps another event")
                                .dockFont(.metadata)
                                .foregroundStyle(Color.dockWarning)
                        }
                        HStack(spacing: 5) {
                            DockIcon(icon(item), size: 11, color: tint(item))
                            Text(source(item)).lineLimit(1)
                        }
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                    }
                    Spacer(minLength: 0)
                    DockIcon(isSelected ? .caretUp : .caretDown, size: 10, color: Color.dockMetadataText)
                        .dockPadding(.top, 3)
                }
                .fixedSize(horizontal: false, vertical: true)
                .dockPadding(.vertical, 14)
                .dockPadding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .accessibilityValue(isSelected ? "Expanded" : "Collapsed")
            if isSelected {
                itemPanel(item).dockPadding(.horizontal, 8).dockPadding(.bottom, 14)
            }
        }
        .background {
            DockThemeShape(cornerRadius: DockLayout.controlRadius)
                .dockSelectionFill(isSelected, fallback: isSelected ? Color.dockAccentMuted : Color.clear)
        }
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }

    private func itemPanel(_ item: CalendarItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !item.isAllDay { detailLine(.clockCounterClockwise, timeLabel(item)) }
            // A Group, so an item without details adds no empty gap.
            Group {
                if case .event(_, let location, let attendees, _) = item.kind {
                    if let location, !location.isEmpty { detailLine(.mapPin, location) }
                    if !attendees.isEmpty { detailLine(.users, attendees.joined(separator: ", ")) }
                }
                if let notes = item.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                    Text(notes).dockFont(.body).foregroundStyle(Color.dockSecondaryText).lineLimit(4)
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
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(2)
            }
        }
        .dockPadding(.top, 10)
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
                let canSchedule =
                    control.cronControlAvailable
                    && CalendarAgenda.prepSchedule(before: item.start, leadMinutes: 15) != nil
                Button("Schedule prep…") { prepItem = item }
                    .buttonStyle(.dockSecondary)
                    .controlSize(.small)
                    .disabled(!canSchedule)
                    .help(
                        control.cronControlAvailable
                            ? "Have Hermes run a one-time prep before this event"
                            : "Automation control is unavailable through this Hermes gateway")
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
        .dockFont(.body)
        .foregroundStyle(Color.dockSecondaryText)
    }

    private func createTaskButton(_ item: CalendarItem) -> some View {
        DockAsyncButton("Create Kanban task") { await createTask(item) }
            .buttonStyle(.dockSecondary)
            .controlSize(.small)
            .disabled(!control.capabilityAvailable("kanban.create"))
            .help(
                control.capabilityAvailable("kanban.create")
                    ? "Create a Hermes Kanban task from this item" : "Kanban is unavailable in this Hermes runtime")
    }

    private func createTask(_ item: CalendarItem) async {
        let created = await control.createKanbanTask(title: item.title, body: item.chatBody)
        actionStatus = created ? "Kanban task created." : (control.lastError ?? "Hermes did not create the task.")
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
        if DockThemeRuntime.current == .mono || DockThemeRuntime.current == .eInk { return .dockSecondaryText }
        switch item.kind {
        case .event: return item.color ?? DockCategoryTone.event.color
        case .reminder: return item.color ?? DockCategoryTone.reminder.color
        case .automation: return DockCategoryTone.automation.color
        case .task: return DockCategoryTone.task.color
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
    case agenda = "Agenda"
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
        _prompt = State(
            initialValue:
                "Prepare a short brief for this event: what it is about, open questions, and anything I should read first.\n\n"
                + item.chatBody)
    }

    private var schedule: String? { CalendarAgenda.prepSchedule(before: item.start, leadMinutes: lead) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schedule prep").dockFont(.pageTitle, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
            Text("Hermes runs this once before \(item.title). It appears under Automations.")
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            DockTabBar(options: [15, 30, 60], selection: $lead, title: { "\($0) min before" })
            TextEditor(text: $prompt)
                .dockFont(.body)
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
                .dockPadding(6)
                .background(
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius).dockSurfaceFill(
                        Color.dockControlSurface.opacity(0.6)))
            Text(error ?? (schedule == nil ? "That time has already passed. Pick a shorter lead." : " "))
                .dockFont(.metadata)
                .foregroundStyle(Color.dockWarning)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.dockSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(isSaving ? "Scheduling…" : "Schedule") { save() }
                    .buttonStyle(.dockPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        schedule == nil || isSaving || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .dockPadding(16)
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
