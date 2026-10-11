import AppKit
import SwiftUI

/// The fullscreen Calendar destination: per-day features shipped, sessions,
/// automation runs, and spend, read from Hermes plus local git.
struct CalendarWorkspaceView: View {
    @ObservedObject var control: ControlCenterModel
    let repoPaths: [String]
    var botsByID: [String: BotSummary] = [:]
    var avatarImages: [String: Data] = [:]
    var onOpenTask: (KanbanTaskSummary) -> Void = { _ in }
    @State private var month = Date()
    @State private var selected = Calendar.current.startOfDay(for: Date())
    /// Week strip by default so the day below gets the room; the month is one click away.
    @AppStorage("dock.calendar.showsMonth") private var showsMonth = false
    @FocusState private var gridFocused: Bool

    private let calendar = Calendar.current
    private var refreshState: ProjectionRefreshState? { control.refreshState(for: "work.calendar") }
    /// The published index can briefly belong to the previous month while a new one loads.
    private var loadedIndex: WorkCalendarIndex? {
        guard let index = control.workCalendar, calendar.isDate(index.month, equalTo: month, toGranularity: .month) else { return nil }
        return index
    }
    /// Once anything has loaded, stepping into another month keeps the grid on
    /// screen with empty cells instead of swapping the page for a spinner.
    private var index: WorkCalendarIndex? {
        loadedIndex ?? control.workCalendar.map { _ in
            WorkCalendarIndex.build(month: month, sessions: [], tasks: [], commits: [], runs: [], usage: [])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            toolbar
            if let state = refreshState, let error = state.error {
                Text(state.isStale ? "Showing last successful data. \(error)" : error)
                    .font(DockTypography.metadata)
                    .foregroundStyle(Color.dockWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let index {
                // Pinned: the month never scrolls away, so another day is always one click off.
                CalendarGridCard(
                    index: index,
                    month: month,
                    selected: selected,
                    today: calendar.startOfDay(for: Date()),
                    showsMonth: showsMonth,
                    onSelect: select,
                    onMove: { _ = moveSelection($0) },
                    onToggleMonth: { withAnimation(.snappy(duration: 0.2)) { showsMonth.toggle() } }
                )
                .equatable()
                .focusable()
                .focused($gridFocused)
                .focusEffectDisabled()
                .onKeyPress(.leftArrow) { moveSelection(-1) }
                .onKeyPress(.rightArrow) { moveSelection(1) }
                .onKeyPress(.upArrow) { moveSelection(-7) }
                .onKeyPress(.downArrow) { moveSelection(7) }
                // The only scrolling region; each day starts at the top.
                if loadedIndex == nil {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { ScrollView {
                  VStack(spacing: 16) {
                    CalendarDayPane(
                        date: selected,
                        day: index.day(selected) ?? WorkDay(),
                        jobNames: Dictionary(control.cronJobs.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
                        botsByID: botsByID,
                        avatarImages: avatarImages,
                        onOpenTask: onOpenTask,
                        onOpenSession: { [control] in control.openLatestActivitySession($0) }
                    )
                    .equatable()
                    CalendarMonthPane(index: index, botsByID: botsByID, avatarImages: avatarImages, onSelect: select)
                        .equatable()
                  }
                }
                .scrollIndicators(.hidden)
                .id(selected)
                .frame(maxHeight: .infinity) }
            } else if refreshState?.error == nil {
                // Also covers the beat before the first fetch is even marked refreshing.
                DockLoadingState(
                    title: "Loading \(month.formatted(.dateTime.month(.wide).year()))…",
                    detail: "Reading sessions, Kanban, automations, and your repositories.",
                    minHeight: 320
                )
            }
        }
        .padding(.top, 4)
        // Centered like the other monitoring pages, so wide windows don't stretch the cells.
        .frame(maxWidth: 1040, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Kanban and cron load on their own schedule; fold them in as they land.
        .onChange(of: control.globalKanbanTasks) { _, _ in control.rebuildWorkCalendar() }
        .onChange(of: control.cronRuns) { _, _ in control.rebuildWorkCalendar() }
        // Projects can land after the first load; the rebuild re-reads git for any new repo.
        .onChange(of: control.projects) { _, _ in control.rebuildWorkCalendar() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        let style = DockThemePalette(theme: DockThemeRuntime.current)
        return HStack(spacing: 10) {
            DockIconButton(icon: .caretLeft, label: showsMonth ? "Previous month" : "Previous week", style: style) { shift(-1) }
            DockIconButton(icon: .caretRight, label: showsMonth ? "Next month" : "Next week", style: style) { shift(1) }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(month.formatted(.dateTime.month(.wide)))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                Text(month.formatted(.dateTime.year()))
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.dockMetadataText)
            }
            .padding(.leading, 4)
            if !calendar.isDate(month, equalTo: Date(), toGranularity: .month) || selected != calendar.startOfDay(for: Date()) {
                Button("Today") { load(Date(), select: calendar.startOfDay(for: Date())) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Spacer(minLength: 8)
            if let lastSuccess = refreshState?.lastSuccess {
                Text("Updated \(lastSuccess, format: .dateTime.hour().minute())")
                    .font(DockTypography.machineMetadata)
                    .foregroundStyle(refreshState?.isStale == true ? Color.dockWarning : Color.dockMetadataText)
                    .lineLimit(1)
            }
            DockIconButton(
                icon: .arrowsClockwise,
                label: refreshState?.isRefreshing == true ? "Refreshing calendar" : "Refresh calendar",
                isBusy: refreshState?.isRefreshing == true,
                style: style
            ) {
                control.refreshGlobalKanban()
                control.refreshCronRuns()
                control.refreshWorkCalendar(month: month, repoPaths: repoPaths, force: true)
            }
        }
        .frame(minHeight: DockControlMetrics.hitTarget)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }

    private func shift(_ delta: Int) {
        if showsMonth {
            let target = calendar.date(byAdding: .month, value: delta, to: month) ?? month
            load(target, select: calendar.dateInterval(of: .month, for: target)?.start ?? target)
        } else {
            _ = moveSelection(7 * delta)
        }
    }

    private func load(_ target: Date, select day: Date) {
        month = target
        selected = day
        control.refreshWorkCalendar(month: target, repoPaths: repoPaths)
    }

    // MARK: Navigation

    private func select(_ date: Date) {
        selected = date
        gridFocused = true
    }

    private func moveSelection(_ days: Int) -> KeyPress.Result {
        guard let target = calendar.date(byAdding: .day, value: days, to: selected) else { return .ignored }
        if calendar.isDate(target, equalTo: month, toGranularity: .month) {
            selected = target
        } else {
            load(target, select: target)
        }
        return .handled
    }
}

/// Neutral ink for the activity mix: shipped reads strongest, automation
/// quietest, and only a failed run takes the warning hue.
private enum CalendarInk {
    static let shipped = Color.dockPrimaryText.opacity(0.78)
    static let sessions = Color.dockPrimaryText.opacity(0.42)
    static let automation = Color.dockPrimaryText.opacity(0.2)
    static let failed = Color.dockWarning
}

/// Hairline-divided rows inside one card, so lists read as one unit of content.
private struct CalendarDivided<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Color.dockBorderLight.frame(height: DockLayout.hairline) }
                row(item)
            }
        }
    }
}

/// The week strip or month grid. Equatable so model churn that leaves the
/// month alone never re-lays out the cells.
private struct CalendarGridCard: View, Equatable {
    let index: WorkCalendarIndex
    let month: Date
    let selected: Date
    let today: Date
    let showsMonth: Bool
    let onSelect: (Date) -> Void
    let onMove: (Int) -> Void
    let onToggleMonth: () -> Void

    private var calendar: Calendar { .current }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.month == rhs.month && lhs.selected == rhs.selected && lhs.today == rhs.today
            && lhs.showsMonth == rhs.showsMonth && lhs.index == rhs.index
    }

    /// Calendar rows: leading/trailing blanks are nil, so every row has 7 slots.
    private var weeks: [[Date?]] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let count = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let lead = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        var slots: [Date?] = Array(repeating: nil, count: lead)
            + (0..<count).map { calendar.date(byAdding: .day, value: $0, to: interval.start) }
        slots += Array(repeating: nil, count: (7 - slots.count % 7) % 7)
        return stride(from: 0, to: slots.count, by: 7).map { Array(slots[$0..<$0 + 7]) }
    }

    var body: some View {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let ordered = Array(symbols[(calendar.firstWeekday - 1)...] + symbols[..<(calendar.firstWeekday - 1)])
        let all = weeks
        let rows = showsMonth ? all : all.filter { $0.contains(selected) }
        let total: ([Date?]) -> Int = { $0.compactMap { $0.flatMap(index.day)?.shippedCount }.reduce(0, +) }
        let weekTotals = rows.map(total)
        let maxWeek = max(1, all.map(total).max() ?? 1)
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol.uppercased()).frame(maxWidth: .infinity)
                }
                Text("WEEK").frame(width: 44)
            }
            .font(DockTypography.sectionLabel)
            .tracking(0.6)
            .foregroundStyle(Color.dockMetadataText)

            ForEach(Array(rows.enumerated()), id: \.offset) { row, week in
                HStack(spacing: 6) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, date in
                        if let date {
                            CalendarDayCell(
                                dayNumber: calendar.component(.day, from: date),
                                day: index.day(date),
                                isSelected: date == selected,
                                isToday: date == today,
                                isFuture: date > today
                            )
                            .equatable()
                            .dockHoverable().onTapGesture { onSelect(date) }
                        } else {
                            Color.clear.frame(maxWidth: .infinity, minHeight: 56)
                        }
                    }
                    weekTotal(weekTotals[row], max: maxWeek)
                }
            }
            Color.dockBorderLight.frame(height: DockLayout.hairline).padding(.top, 4)
            footer
        }
        .padding(12)
        // Keep the strip at its natural height; the day detail below gets the rest.
        .fixedSize(horizontal: false, vertical: true)
        .dockCard(padding: 0)
    }

    private func weekTotal(_ total: Int, max: Int) -> some View {
        VStack(spacing: 4) {
            Text(total > 0 ? "\(total)" : "·")
                .font(DockTypography.machineMetadata.weight(.semibold))
                .foregroundStyle(total > 0 ? Color.dockPrimaryText : Color.dockMetadataText)
            Capsule().fill(Color.dockPrimaryText.opacity(0.06))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(CalendarInk.shipped).frame(width: proxy.size.width * CGFloat(total) / CGFloat(max))
                    }
                }
                .padding(.horizontal, 6)
        }
        .frame(width: 44, height: 56)
        .help("\(total) shipped this week")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(total) shipped this week")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            legendSwatch(CalendarInk.shipped, "Shipped")
            legendSwatch(CalendarInk.sessions, "Sessions")
            legendSwatch(CalendarInk.automation, "Automation")
            legendSwatch(CalendarInk.failed, "Failed run")
            Spacer(minLength: 8)
            if !showsMonth {
                HStack(spacing: 2) {
                    stepButton(.caretLeft, "Previous week") { onMove(-7) }
                    Text(weekRange)
                        .font(DockTypography.machineMetadata)
                        .foregroundStyle(Color.dockPrimaryText)
                        .frame(minWidth: 96)
                    stepButton(.caretRight, "Next week") { onMove(7) }
                }
                .padding(2)
                .background(Capsule().fill(Color.dockPrimaryText.opacity(0.04)))
                .overlay(Capsule().stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline))
            }
            Button(action: onToggleMonth) {
                Label(showsMonth ? "Week view" : "Month view", icon: showsMonth ? .caretUp : .caretDown)
                    .font(DockTypography.control)
                    .foregroundStyle(Color.dockAccent)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.dockPress)
            .help(showsMonth ? "Show only the selected week" : "Show the whole month")
        }
        .font(DockTypography.metadata)
        .foregroundStyle(Color.dockMetadataText)
    }

    private func stepButton(_ icon: Ph, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DockIcon(icon)
                .foregroundStyle(Color.dockAccent)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.dockPress)
        .help(label)
        .accessibilityLabel(label)
    }

    /// "Sep 28 – Oct 4" for the week holding the selected day.
    private var weekRange: String {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: selected),
              let last = calendar.date(byAdding: .day, value: 6, to: week.start) else { return "" }
        return (week.start..<last).formatted(.interval.month(.abbreviated).day())
    }

    private func legendSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) { Capsule().fill(color).frame(width: 12, height: 4); Text(label) }
    }
}

/// The month's totals and leaderboards, below the day. Equatable so it only
/// rebuilds when the month's tallies or the bots change.
private struct CalendarMonthPane: View, Equatable {
    let index: WorkCalendarIndex
    let botsByID: [String: BotSummary]
    let avatarImages: [String: Data]
    let onSelect: (Date) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.index == rhs.index && lhs.botsByID == rhs.botsByID && lhs.avatarImages == rhs.avatarImages
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DockSectionLabel(title: "This month").padding(.leading, 2)
            overview
            if !index.crew.isEmpty || !index.repos.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    if !index.crew.isEmpty {
                        leaderboard("Crew", rows: Array(index.crew.prefix(8)), unit: "tasks") { id in
                            BotChip(id: id, botsByID: botsByID, avatarImages: avatarImages)
                        }
                    }
                    if !index.repos.isEmpty {
                        leaderboard("Repositories", rows: Array(index.repos.prefix(6)), unit: "commits") { id in
                            HStack(spacing: 4) {
                                DockIcon(.gitBranch).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
                                Text(id).font(DockTypography.machineMetadata.weight(.medium)).foregroundStyle(Color.dockSecondaryText).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .padding(.bottom, 16)
    }

    /// Measured figures in the metric role; healthy is neutral.
    private var overview: some View {
        let streak = index.currentStreak
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 0, alignment: .topLeading)], alignment: .leading, spacing: 0) {
            metric("Tasks done", "\(index.taskCount)", detail: "\(index.commitCount) commits")
            metric("Sessions", "\(index.sessionCount)", detail: "\(index.activeDays) active days")
            metric("Automation runs", "\(index.runCount)", detail: nil)
            metric("Streak", "\(streak)", detail: streak == 1 ? "day" : "days")
            if index.monthCost > 0 {
                metric("Spent", UsageWorkspaceView.cost(index.monthCost), detail: nil)
            } else if index.monthTokens > 0 {
                metric("Tokens", UsageWorkspaceView.tokens(index.monthTokens), detail: nil)
            }
            if let busiest = index.busiestDay {
                Button { onSelect(busiest) } label: {
                    metric("Busiest day", busiest.formatted(.dateTime.month(.abbreviated).day()), detail: "Jump to day")
                }
                .buttonStyle(.dockHover)
                .help("Jump to the busiest day")
            }
        }
        .dockCard(padding: 0)
    }

    private func metric(_ title: String, _ value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DockSectionLabel(title: title)
            Text(value).font(DockTypography.metric).foregroundStyle(Color.dockPrimaryText).lineLimit(1)
            Text(detail ?? " ").font(DockTypography.metadata).foregroundStyle(Color.dockMetadataText).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func leaderboard<Label: View>(_ title: String, rows: [WorkCount], unit: String, @ViewBuilder label: @escaping (String) -> Label) -> some View {
        let top = max(1, rows.first?.count ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            DockSectionLabel(title: title, count: rows.count)
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    label(row.id).frame(width: 110, alignment: .leading)
                    Capsule().fill(Color.dockPrimaryText.opacity(0.06))
                        .frame(height: 6)
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule().fill(Color.dockSecondaryText).frame(width: proxy.size.width * CGFloat(row.count) / CGFloat(top))
                            }
                        }
                    Text("\(row.count)")
                        .font(DockTypography.machineMetadata)
                        .foregroundStyle(Color.dockPrimaryText)
                        .frame(width: 36, alignment: .trailing)
                }
                .help("\(row.count) \(unit)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .dockCard(padding: 0)
    }
}

/// The selected day: header, hourly rhythm, then shipped and worked-on columns.
private struct CalendarDayPane: View, Equatable {
    let date: Date
    let day: WorkDay
    let jobNames: [String: String]
    let botsByID: [String: BotSummary]
    let avatarImages: [String: Data]
    let onOpenTask: (KanbanTaskSummary) -> Void
    let onOpenSession: (SessionSummary) -> Void
    @State private var copied = false
    /// Sections the user opened past the row cap.
    @State private var expanded: Set<String> = []
    private let rowCap = 8

    private var calendar: Calendar { .current }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.date == rhs.date && lhs.day == rhs.day && lhs.jobNames == rhs.jobNames
            && lhs.botsByID == rhs.botsByID && lhs.avatarImages == rhs.avatarImages
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            if !day.isEmpty {
                // Shipped on the left, worked on on the right.
                let shipped = !day.doneTasks.isEmpty || !day.commits.isEmpty
                let worked = !day.sessions.isEmpty || !day.cronRuns.isEmpty || day.usage != nil
                HStack(alignment: .top, spacing: 12) {
                    if shipped { shippedColumn.frame(minWidth: 0, maxWidth: .infinity, alignment: .top) }
                    if worked { workedColumn.frame(minWidth: 0, maxWidth: .infinity, alignment: .top) }
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                dateBadge
                VStack(alignment: .leading, spacing: 3) {
                    Text(date.formatted(.dateTime.weekday(.wide)))
                        .font(DockTypography.pageTitle)
                        .foregroundStyle(Color.dockPrimaryText)
                    Text(subtitle)
                        .font(DockTypography.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(WorkCalendarIndex.standupMarkdown(for: date, day: day), forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy standup", icon: copied ? .check : .copy)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(day.isEmpty)
            }
            if day.isEmpty {
                HStack(spacing: 8) {
                    DockIcon(.calendarBlank).font(.system(size: 14)).foregroundStyle(Color.dockMetadataText)
                    Text(date > calendar.startOfDay(for: Date()) ? "Nothing yet. This day is still ahead." : "A quiet day. Nothing was recorded.")
                        .font(DockTypography.body)
                        .foregroundStyle(Color.dockMetadataText)
                }
                .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                rhythm
                if !day.crew.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(day.crew) { count in
                                HStack(spacing: 3) {
                                    BotChip(id: count.id, botsByID: botsByID, avatarImages: avatarImages)
                                    Text("×\(count.count)").font(DockTypography.machineMetadata).foregroundStyle(Color.dockMetadataText)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockCard(padding: 0)
    }

    private var dateBadge: some View {
        let shape = DockThemeShape(cornerRadius: DockLayout.controlRadius, role: .control)
        return VStack(spacing: 1) {
            Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(DockTypography.compactStatus)
                .tracking(0.6)
                .foregroundStyle(Color.dockAccent)
            Text("\(calendar.component(.day, from: date))")
                .font(DockTypography.metric)
                .foregroundStyle(Color.dockPrimaryText)
        }
        .frame(width: 48, height: 52)
        .background(shape.fill(Color.dockPrimaryText.opacity(0.04)))
        .overlay(shape.stroke(Color.dockBorderLight, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
    }

    private var subtitle: String {
        var parts: [String] = []
        if !day.doneTasks.isEmpty { parts.append("\(day.doneTasks.count) tasks done") }
        if !day.commits.isEmpty { parts.append("\(day.commits.count) commits") }
        if !day.sessions.isEmpty { parts.append("\(day.sessions.count) sessions") }
        if let first = day.firstAt, let last = day.lastAt, last > first {
            let span = Duration.seconds(last.timeIntervalSince(first)).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
            parts.append("\(first.formatted(.dateTime.hour().minute()))–\(last.formatted(.dateTime.hour().minute())) (\(span))")
        }
        return parts.isEmpty ? "No activity" : parts.joined(separator: " · ")
    }

    /// When work happened: one bar per hour of the day.
    private var rhythm: some View {
        let peak = max(1, day.hours.max() ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    let count = day.hours[hour]
                    Capsule()
                        .fill(count > 0 ? Color.dockPrimaryText.opacity(0.3 + 0.5 * Double(count) / Double(peak)) : Color.dockPrimaryText.opacity(0.06))
                        .frame(height: count > 0 ? max(4, 40 * CGFloat(count) / CGFloat(peak)) : 3)
                        .frame(maxWidth: .infinity)
                        .help("\(hour):00 · \(count) events")
                }
            }
            .frame(height: 40, alignment: .bottom)
            HStack {
                ForEach(["12a", "6a", "12p", "6p", "11p"], id: \.self) { tick in
                    Text(tick)
                    if tick != "11p" { Spacer() }
                }
            }
            .font(DockTypography.compactStatus)
            .foregroundStyle(Color.dockMetadataText)
        }
        .accessibilityHidden(true)
    }

    // MARK: Columns

    @ViewBuilder
    private var shippedColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !day.doneTasks.isEmpty {
                section("Tasks done", count: day.doneTasks.count) {
                    capped("tasks", day.doneTasks) { taskRow($0) }
                }
            }
            if !day.commits.isEmpty {
                section("Commits", count: day.commits.count) {
                    capped("commits", day.commits) { commit in
                        row(icon: .gitCommit, tint: .dockSecondaryText, title: commit.subject,
                            meta: "\(commit.repo) · \(commit.hash) · \(commit.date.formatted(.dateTime.hour().minute()))")
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockCard(padding: 0)
    }

    @ViewBuilder
    private var workedColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !day.sessions.isEmpty {
                section("Sessions", count: day.sessions.count) {
                    capped("sessions", day.sessions.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }) { session in
                        Button { onOpenSession(session) } label: {
                            row(icon: .chats, tint: .dockSecondaryText, title: session.title,
                                meta: session.updatedAt?.formatted(.dateTime.hour().minute()), trailingIcon: .arrowUpRight)
                        }
                        .buttonStyle(CalendarRowButtonStyle())
                        .help("Open conversation")
                    }
                }
            }
            if !day.cronRuns.isEmpty {
                section("Automations", count: day.cronRuns.count) {
                    capped("jobs", automationJobs(day.cronRuns)) { job in
                        row(icon: job.failed > 0 ? .warningCircle : .clockCounterClockwise,
                            tint: job.failed > 0 ? .dockWarning : .dockSecondaryText,
                            title: jobNames[job.id] ?? job.id,
                            meta: ["\(job.runs) runs", job.failed > 0 ? "\(job.failed) failed" : nil,
                                   job.last.map { "last \($0.formatted(.dateTime.hour().minute()))" }]
                                .compactMap { $0 }.joined(separator: " · "),
                            metaTint: job.failed > 0 ? .dockWarning : .dockMetadataText)
                    }
                }
            }
            if let usage = day.usage {
                section("Usage", count: nil) {
                    HStack(spacing: 20) {
                        stat(UsageWorkspaceView.tokens(usage.inputTokens + usage.outputTokens), "tokens")
                        stat(usage.apiCalls.formatted(), "calls")
                        stat("\(usage.sessions)", "sessions")
                        stat(usage.estimatedCost > 0 ? UsageWorkspaceView.cost(usage.estimatedCost) : "—", "cost")
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockCard(padding: 0)
    }

    private struct AutomationJob: Identifiable {
        let id: String
        var runs = 0
        var failed = 0
        var last: Date?
    }

    /// One row per job: hourly jobs otherwise repeat the same name dozens of times.
    private func automationJobs(_ runs: [CronRunSummary]) -> [AutomationJob] {
        var byJob: [String: AutomationJob] = [:]
        for run in runs {
            let id = run.jobID ?? run.id
            var job = byJob[id] ?? AutomationJob(id: id)
            job.runs += 1
            if run.isFailure { job.failed += 1 }
            if let date = run.claimedDate, date > (job.last ?? .distantPast) { job.last = date }
            byJob[id] = job
        }
        return byJob.values.sorted { ($0.failed, $0.runs, $0.id) > ($1.failed, $1.runs, $1.id) }
    }

    /// First `rowCap` rows, with a toggle for the rest.
    @ViewBuilder
    private func capped<Item: Identifiable, Row: View>(_ key: String, _ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        let open = expanded.contains(key)
        CalendarDivided(items: open ? items : Array(items.prefix(rowCap)), row: row)
        if items.count > rowCap {
            Button(open ? "Show less" : "Show \(items.count - rowCap) more") {
                if open { expanded.remove(key) } else { expanded.insert(key) }
            }
            .buttonStyle(.dockPress)
            .font(DockTypography.control)
            .foregroundStyle(Color.dockAccent)
            .padding(.top, 6)
        }
    }

    // MARK: Rows

    private func taskRow(_ task: KanbanTaskSummary) -> some View {
        Button { onOpenTask(task) } label: {
            HStack(spacing: 8) {
                DockIcon(.checkCircle, size: 13, weight: .fill, color: DockStatusTone.complete.color)
                Text(task.title)
                    .font(DockTypography.rowTitle)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let bot = task.assignee, !bot.isEmpty {
                    BotChip(id: bot, botsByID: botsByID, avatarImages: avatarImages)
                }
                if let finished = task.completedAt {
                    Text(finished.formatted(.dateTime.hour().minute()))
                        .font(DockTypography.machineMetadata)
                        .foregroundStyle(Color.dockMetadataText)
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(CalendarRowButtonStyle())
        .help("Open in Kanban")
    }

    private func section<Content: View>(_ title: String, count: Int?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DockSectionLabel(title: title, count: count)
            content()
        }
    }

    private func row(icon: Ph, tint: Color, title: String, meta: String?, metaTint: Color = .dockMetadataText, trailingIcon: Ph? = nil) -> some View {
        HStack(spacing: 8) {
            DockIcon(icon).font(.system(size: 12)).foregroundStyle(tint).frame(width: 14)
            Text(title).font(DockTypography.rowTitle).foregroundStyle(Color.dockPrimaryText).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let meta {
                Text(meta).font(DockTypography.machineMetadata).foregroundStyle(metaTint).lineLimit(1)
            }
            if let trailingIcon {
                DockIcon(trailingIcon).font(.system(size: 10)).foregroundStyle(Color.dockMetadataText)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(DockTypography.machineMetadata.weight(.semibold)).foregroundStyle(Color.dockPrimaryText)
            Text(label).font(DockTypography.metadata).foregroundStyle(Color.dockMetadataText)
        }
    }
}

/// Hover highlight for clickable detail rows.
private struct CalendarRowButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = DockThemeShape(cornerRadius: DockLayout.controlRadius - 2, role: .control)
        return configuration.label
            .padding(.horizontal, 6)
            .background(shape.fill(Color.dockPrimaryText.opacity(configuration.isPressed ? 0.08 : isHovering ? 0.05 : 0)))
            .padding(.horizontal, -6)
            .onHover { isHovering = $0 }
    }
}

/// Equatable so a cell only redraws when its own day changes.
private struct CalendarDayCell: View, Equatable {
    let dayNumber: Int
    let day: WorkDay?
    let isSelected: Bool
    let isToday: Bool
    let isFuture: Bool

    var body: some View {
        let heat = Double(day?.heat ?? 0)
        let shipped = day?.shippedCount ?? 0
        let shape = DockThemeShape(cornerRadius: DockLayout.controlRadius, role: .control)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text("\(dayNumber)")
                    .font(DockTypography.machineMetadata.weight(isToday ? .bold : .medium))
                    .foregroundStyle(isToday ? Color.dockOnAccentText : isFuture ? Color.dockMetadataText : Color.dockPrimaryText)
                    .padding(.horizontal, isToday ? 6 : 0)
                    .background { if isToday { Capsule().fill(Color.dockAccent) } }
                if day?.hasFailedRun == true {
                    Circle().fill(CalendarInk.failed).frame(width: 5, height: 5).padding(.leading, 4)
                }
                Spacer(minLength: 2)
                // Icon-tagged so the count never reads as a second date.
                if shipped > 0 {
                    count(shipped, icon: .checkCircle)
                } else if let sessions = day?.sessions.count, sessions > 0 {
                    count(sessions, icon: .chatCircle)
                }
            }
            Spacer(minLength: 0)
            if let day, day.activityCount > 0 { mixBar(day) }
        }
        .padding(7)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
        .background(shape.fill(Color.dockPrimaryText.opacity(0.015 + heat * 0.02)))
        .overlay(shape.stroke(isSelected ? Color.dockAccent : Color.dockBorderLight, lineWidth: isSelected ? 1.5 : 1))
        .opacity(isFuture ? 0.55 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Day \(dayNumber), \(shipped) shipped, \(day?.sessions.count ?? 0) sessions")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func count(_ value: Int, icon: Ph) -> some View {
        HStack(spacing: 3) {
            DockIcon(icon, size: 10, weight: .fill, color: .dockMetadataText)
            Text("\(value)").font(DockTypography.compactStatus.monospacedDigit()).foregroundStyle(Color.dockSecondaryText)
        }
    }

    /// Proportions of shipped / sessions / automation for the day.
    private func mixBar(_ day: WorkDay) -> some View {
        let parts: [(Int, Color)] = [
            (day.doneTasks.count + day.commits.count, CalendarInk.shipped),
            (day.sessions.count, CalendarInk.sessions),
            (day.cronRuns.count, day.hasFailedRun ? CalendarInk.failed : CalendarInk.automation)
        ].filter { $0.0 > 0 }
        let total = CGFloat(parts.reduce(0) { $0 + $1.0 })
        return GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    part.1.frame(width: max(2, (proxy.size.width - CGFloat(parts.count - 1)) * CGFloat(part.0) / total))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 3)
    }
}
