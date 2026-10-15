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
    var onOpenUsage: () -> Void = {}
    @State private var month = Date()
    @State private var selected = Calendar.current.startOfDay(for: Date())
    /// What the detail area summarizes: the selected day, its week, or the whole month.
    @AppStorage("dock.calendar.scope") private var scopeRaw = CalendarScope.day.rawValue
    @FocusState private var gridFocused: Bool

    private let calendar = Calendar.current
    private var jobNames: [String: String] { Dictionary(control.cronJobs.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }) }
    private var scope: CalendarScope { CalendarScope(rawValue: scopeRaw) ?? .day }
    private var scopeBinding: Binding<CalendarScope> { Binding(get: { scope }, set: { scopeRaw = $0.rawValue }) }
    /// The selected day's week, clamped to the loaded month by `WorkCalendarIndex.range`.
    private var weekBounds: (start: Date, end: Date) {
        let start = calendar.dateInterval(of: .weekOfYear, for: selected)?.start ?? selected
        return (start, calendar.date(byAdding: .day, value: 6, to: start) ?? start)
    }
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
                // Wide windows split into calendar | detail; narrow ones stack them.
                GeometryReader { proxy in
                    if proxy.size.width >= 1100 {
                        HStack(alignment: .top, spacing: 16) {
                            ScrollView { gridCard(index, wide: true) }
                                .scrollIndicators(.hidden)
                                .frame(width: min(560, proxy.size.width * 0.45))
                            detail(index, wide: true)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            // Pinned: the grid never scrolls away, so another day is always one click off.
                            gridCard(index, wide: false)
                            detail(index, wide: false)
                        }
                    }
                }
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
        .frame(maxWidth: 1480, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Kanban and cron load on their own schedule; fold them in as they land.
        .onChange(of: control.globalKanbanTasks) { _, _ in control.rebuildWorkCalendar() }
        .onChange(of: control.cronRuns) { _, _ in control.rebuildWorkCalendar() }
        // Projects can land after the first load; the rebuild re-reads git for any new repo.
        .onChange(of: control.projects) { _, _ in control.rebuildWorkCalendar() }
    }

    private func gridCard(_ index: WorkCalendarIndex, wide: Bool) -> some View {
        CalendarGridCard(
            index: index,
            month: month,
            selected: selected,
            today: calendar.startOfDay(for: Date()),
            showsMonth: scope != .week,
            selectable: scope == .day,
            scopeWeek: scope == .week ? weekBounds.start...weekBounds.end : nil,
            onSelect: select,
            onMove: { _ = moveSelection($0) }
        )
        .equatable()
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { scope == .day ? moveSelection(-1) : .ignored }
        .onKeyPress(.rightArrow) { scope == .day ? moveSelection(1) : .ignored }
        .onKeyPress(.upArrow) { scope == .day ? moveSelection(-7) : .ignored }
        .onKeyPress(.downArrow) { scope == .day ? moveSelection(7) : .ignored }
    }

    /// The only scrolling region beside the wide-layout calendar; each scope starts at the top.
    @ViewBuilder
    private func detail(_ index: WorkCalendarIndex, wide: Bool) -> some View {
        if loadedIndex == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    switch scope {
                    case .day:
                        CalendarDayPane(
                            date: selected,
                            day: index.day(selected) ?? WorkDay(),
                            usualActivity: index.usualActivity(excluding: selected...selected),
                            stacked: wide,
                            jobNames: jobNames,
                            botsByID: botsByID,
                            avatarImages: avatarImages,
                            onOpenTask: onOpenTask,
                            onOpenUsage: onOpenUsage,
                            onOpenSession: { [control] in control.openLatestActivitySession($0) }
                        )
                        .equatable()
                    case .week:
                        let bounds = weekBounds
                        rangePane(index.range(from: bounds.start, to: bounds.end),
                                  title: (bounds.start..<bounds.end).formatted(.interval.month(.abbreviated).day()), wide: wide)
                    case .month:
                        rangePane(index.range(from: index.month, to: .distantFuture),
                                  title: month.formatted(.dateTime.month(.wide).year()), wide: wide)
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .id(scope == .day ? selected : (scope == .week ? weekBounds.start : month))
            .frame(maxHeight: .infinity)
        }
    }

    private func rangePane(_ range: WorkRange, title: String, wide: Bool) -> some View {
        CalendarRangePane(
            title: title, range: range, compact: wide, jobNames: jobNames, botsByID: botsByID, avatarImages: avatarImages,
            onOpenUsage: onOpenUsage,
            onOpenDay: { select($0); scopeRaw = CalendarScope.day.rawValue }
        )
        .equatable()
    }

    // MARK: Toolbar

    private var toolbar: some View {
        let style = DockThemePalette(theme: DockThemeRuntime.current)
        return HStack(spacing: 10) {
            DockIconButton(icon: .caretLeft, label: "Previous \(scope.rawValue)", style: style) { shift(-1) }
            DockIconButton(icon: .caretRight, label: "Next \(scope.rawValue)", style: style) { shift(1) }
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
                    .buttonStyle(.dockSecondary)
                    .controlSize(.small)
            }

            Spacer(minLength: 8)
            DockTabBar(options: CalendarScope.allCases, selection: scopeBinding, title: \.title)
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
        switch scope {
        case .day: _ = moveSelection(delta)
        case .week: _ = moveSelection(7 * delta)
        case .month:
            let target = calendar.date(byAdding: .month, value: delta, to: month) ?? month
            load(target, select: calendar.dateInterval(of: .month, for: target)?.start ?? target)
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

private enum CalendarScope: String, CaseIterable {
    case day, week, month
    var title: String { rawValue.capitalized }
}

/// The week strip or month grid. Equatable so model churn that leaves the
/// month alone never re-lays out the cells.
private struct CalendarGridCard: View, Equatable {
    let index: WorkCalendarIndex
    let month: Date
    let selected: Date
    let today: Date
    let showsMonth: Bool
    /// Only the Day scope picks a single day.
    var selectable = true
    /// The selected week, tinted when the Week scope is active.
    var scopeWeek: ClosedRange<Date>?
    let onSelect: (Date) -> Void
    let onMove: (Int) -> Void

    private var calendar: Calendar { .current }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.month == rhs.month && lhs.selected == rhs.selected && lhs.today == rhs.today
            && lhs.showsMonth == rhs.showsMonth && lhs.selectable == rhs.selectable && lhs.scopeWeek == rhs.scopeWeek && lhs.index == rhs.index
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
                                date: date,
                                dayNumber: calendar.component(.day, from: date),
                                day: index.day(date),
                                isSelected: selectable && date == selected,
                                isInScope: scopeWeek?.contains(date) ?? false,
                                isToday: date == today,
                                isFuture: date > today
                            )
                            .equatable()
                            .dockHoverable().onTapGesture { if selectable { onSelect(date) } }
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
            // Only the kinds of work this month actually has.
            let days = index.days.values
            if days.contains(where: { $0.shippedCount > 0 }) { legendSwatch(CalendarInk.shipped, "Shipped") }
            if index.sessionCount > 0 { legendSwatch(CalendarInk.sessions, "Sessions") }
            if index.runCount > 0 { legendSwatch(CalendarInk.automation, "Automation") }
            if days.contains(where: \.hasFailedRun) { legendSwatch(CalendarInk.failed, "Failed run") }
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

/// A week's or month's totals, per-day bars, and leaderboards. Equatable so it only
/// rebuilds when the range's tallies or the bots change.
private struct CalendarRangePane: View, Equatable {
    let title: String
    let range: WorkRange
    /// Stack the leaderboards when the pane is a narrow column.
    var compact = false
    let jobNames: [String: String]
    let botsByID: [String: BotSummary]
    let avatarImages: [String: Data]
    let onOpenUsage: () -> Void
    let onOpenDay: (Date) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.range == rhs.range && lhs.compact == rhs.compact && lhs.jobNames == rhs.jobNames
            && lhs.botsByID == rhs.botsByID && lhs.avatarImages == rhs.avatarImages
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                DockSectionLabel(title: title).padding(.leading, 2)
                Spacer(minLength: 8)
                if range.cost > 0 || range.tokens > 0 { usageLink(onOpenUsage) }
            }
            if range.isEmpty {
                HStack(spacing: 8) {
                    DockIcon(.calendarBlank).font(.system(size: 14)).foregroundStyle(Color.dockMetadataText)
                    Text("Nothing was recorded in this range.").font(DockTypography.body).foregroundStyle(Color.dockMetadataText)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
                .dockCard(padding: 0)
            } else {
                overview
                CalendarDayBars(points: range.points, onOpenDay: onOpenDay)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dockCard(padding: 0)
                if range.weekdayMeans.contains(where: { $0 > 0 }) { weekdayPattern }
                if !range.jobs.isEmpty { automationHealth }
                if !range.assignees.isEmpty || !range.repos.isEmpty {
                    (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))) {
                        if !range.assignees.isEmpty {
                            CalendarLeaderboard(title: "Assignees", rows: Array(range.assignees.prefix(8)), unit: "tasks") { id in
                                BotChip(id: id, botsByID: botsByID, avatarImages: avatarImages)
                            }
                        }
                        if !range.repos.isEmpty {
                            CalendarLeaderboard(title: "Commits by repository", rows: Array(range.repos.prefix(8)), unit: "commits") { id in
                                CalendarRepoLabel(id: id)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Mean activity per weekday, so the habit (not one big day) shows.
    private var weekdayPattern: some View {
        let means = range.weekdayMeans
        let peak = max(0.0001, means.max() ?? 0)
        let calendar = Calendar.current
        // Monday first, to match how a work week reads.
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 }
        return VStack(alignment: .leading, spacing: 8) {
            DockSectionLabel(title: "Usual weekdays")
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(order, id: \.self) { weekday in
                    let ratio = means[weekday] / peak
                    VStack(spacing: 5) {
                        UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 1, bottomTrailingRadius: 1, topTrailingRadius: 3, style: .continuous)
                            .fill(Color.dockPrimaryText.opacity(ratio == 1 ? 0.85 : 0.3 + 0.4 * ratio))
                            .frame(height: means[weekday] > 0 ? max(4, 40 * ratio) : 2)
                            .frame(maxHeight: 40, alignment: .bottom)
                        Text(calendar.shortWeekdaySymbols[weekday])
                            .font(DockTypography.compactStatus)
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(calendar.weekdaySymbols[weekday]) · \(means[weekday].formatted(.number.precision(.fractionLength(1)))) per day")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockCard(padding: 0)
    }

    /// Runs per automation; failures are the only coloured thing.
    private var automationHealth: some View {
        VStack(alignment: .leading, spacing: 8) {
            DockSectionLabel(title: "Automations", count: range.jobs.count)
            ForEach(range.jobs.prefix(8)) { job in
                HStack(spacing: 10) {
                    DockIcon(.clock).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
                    Text(jobNames[job.id] ?? job.id).font(DockTypography.rowTitle).foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                    Spacer(minLength: 8)
                    if job.failed > 0 {
                        Text("\(job.failed) failed").font(DockTypography.machineMetadata).foregroundStyle(Color.dockWarning)
                    }
                    Text("\(job.runs) runs").font(DockTypography.machineMetadata).foregroundStyle(Color.dockMetadataText)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockCard(padding: 0)
    }

    /// Measured figures in the metric role; zero-value figures are left out so the page fits any kind of work.
    private var overview: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 0, alignment: .topLeading)], alignment: .leading, spacing: 0) {
            if range.pullRequests > 0 {
                metric("PRs merged", "\(range.pullRequests)", detail: range.commits > 0 ? "\(range.commits) commits" : nil)
            } else if range.commits > 0 {
                metric("Commits", "\(range.commits)", detail: nil)
            }
            if range.tasks > 0 { metric("Tasks done", "\(range.tasks)", detail: nil) }
            if range.sessions > 0 { metric("Sessions", "\(range.sessions)", detail: "\(range.activeDays) active days") }
            if range.activeHours > 0 {
                metric("Active hours", "\(range.activeHours)h", detail: range.vsUsual.map { "\($0 > 0 ? "↑" : "↓") \(abs($0))% vs usual" })
            }
            if range.runs > 0 { metric("Automation runs", "\(range.runs)", detail: nil) }
            if range.streak > 0 { metric("Streak", "\(range.streak)", detail: range.streak == 1 ? "day" : "days") }
            if range.cost > 0 {
                metric("Spent", UsageWorkspaceView.cost(range.cost),
                       detail: range.shippedItems > 0 ? "\(UsageWorkspaceView.cost(range.cost / Double(range.shippedItems))) per item" : nil)
            } else if range.tokens > 0 {
                metric("Tokens", UsageWorkspaceView.tokens(range.tokens), detail: nil)
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
}

/// One stacked bar per day (shipped, sessions, automation); clicking a bar opens that day.
private struct CalendarDayBars: View {
    let points: [WorkRange.Point]
    let onOpenDay: (Date) -> Void

    var body: some View {
        let peak = max(1, points.map(\.total).max() ?? 1)
        let calendar = Calendar.current
        let dense = points.count > 10
        VStack(alignment: .leading, spacing: 8) {
            DockSectionLabel(title: "Activity by day")
            HStack(alignment: .bottom, spacing: dense ? 3 : 8) {
                ForEach(points) { point in
                    let day = calendar.component(.day, from: point.date)
                    VStack(spacing: 5) {
                        VStack(spacing: 1) {
                            segment(point.runs, peak: peak, color: point.hasFailure ? CalendarInk.failed : CalendarInk.automation)
                            segment(point.sessions, peak: peak, color: CalendarInk.sessions)
                            segment(point.shipped, peak: peak, color: CalendarInk.shipped)
                            if point.total == 0 { Capsule().fill(Color.dockPrimaryText.opacity(0.06)).frame(height: 2) }
                        }
                        .frame(height: 64, alignment: .bottom)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 1, bottomTrailingRadius: 1, topTrailingRadius: 3, style: .continuous))
                        Text(dense ? (day == 1 || day % 5 == 0 ? "\(day)" : " ")
                             : "\(point.date.formatted(.dateTime.weekday(.narrow))) \(day)")
                            .font(DockTypography.compactStatus)
                            .foregroundStyle(Color.dockMetadataText)
                            .fixedSize()
                            .frame(maxWidth: .infinity)
                    }
                    .contentShape(Rectangle())
                    .dockHoverable()
                    .onTapGesture { onOpenDay(point.date) }
                    .help("\(point.date.formatted(.dateTime.month(.abbreviated).day())) · \(point.shipped) shipped · \(point.sessions) sessions · \(point.runs) runs")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(point.date.formatted(.dateTime.month().day())), \(point.total) items. Opens the day.")
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
    }

    @ViewBuilder
    private func segment(_ value: Int, peak: Int, color: Color) -> some View {
        if value > 0 { color.frame(height: max(3, 64 * CGFloat(value) / CGFloat(peak))) }
    }
}

private struct CalendarRepoLabel: View {
    let id: String
    var body: some View {
        HStack(spacing: 4) {
            DockIcon(.gitBranch).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
            Text(id).font(DockTypography.machineMetadata.weight(.medium)).foregroundStyle(Color.dockSecondaryText).lineLimit(1)
        }
    }
}

/// Ranked rows with a neutral meter. Carded when it stands alone, bare inside another card.
private struct CalendarLeaderboard<Label: View>: View {
    let title: String?
    let rows: [WorkCount]
    let unit: String
    var carded = true
    @ViewBuilder let label: (String) -> Label

    var body: some View {
        let top = max(1, rows.first?.count ?? 1)
        let content = VStack(alignment: .leading, spacing: 8) {
            if let title { DockSectionLabel(title: title, count: rows.count) }
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
        if carded {
            content.padding(14).frame(maxWidth: .infinity, alignment: .topLeading).dockCard(padding: 0)
        } else {
            content
        }
    }
}

/// The selected day: header, hourly rhythm, then shipped and worked-on columns.
private struct CalendarDayPane: View, Equatable {
    let date: Date
    let day: WorkDay
    /// Mean activity on the month's other active days, for the comparison chip.
    var usualActivity: Double?
    /// Shipped above worked-on, for a narrow column.
    var stacked = false
    let jobNames: [String: String]
    let botsByID: [String: BotSummary]
    let avatarImages: [String: Data]
    let onOpenTask: (KanbanTaskSummary) -> Void
    var onOpenUsage: () -> Void = {}
    let onOpenSession: (SessionSummary) -> Void
    @State private var copied = false
    /// Sections the user opened past the row cap.
    @State private var expanded: Set<String> = []
    private let rowCap = 8

    private var calendar: Calendar { .current }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.date == rhs.date && lhs.day == rhs.day && lhs.usualActivity == rhs.usualActivity && lhs.stacked == rhs.stacked && lhs.jobNames == rhs.jobNames
            && lhs.botsByID == rhs.botsByID && lhs.avatarImages == rhs.avatarImages
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            if !day.isEmpty {
                // Shipped on the left, worked on on the right.
                let shipped = !day.doneTasks.isEmpty || !day.commits.isEmpty || !day.pullRequests.isEmpty
                let worked = !day.sessions.isEmpty || !day.cronRuns.isEmpty || day.usage != nil
                (stacked ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))) {
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
                .buttonStyle(.dockSecondary)
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
                insights
                if !day.assignees.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(day.assignees) { count in
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
        if !day.pullRequests.isEmpty { parts.append("\(day.pullRequests.count) PRs merged") }
        if !day.doneTasks.isEmpty { parts.append("\(day.doneTasks.count) tasks done") }
        if !day.commits.isEmpty { parts.append("\(day.commits.count) commits") }
        if !day.sessions.isEmpty { parts.append("\(day.sessions.count) sessions") }
        if let first = day.firstAt, let last = day.lastAt, last > first {
            let span = Duration.seconds(last.timeIntervalSince(first)).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
            parts.append("\(first.formatted(.dateTime.hour().minute()))–\(last.formatted(.dateTime.hour().minute())) (\(span))")
        }
        return parts.isEmpty ? "No activity" : parts.joined(separator: " · ")
    }

    /// When work happened: one bar per hour of the day, with the peak called out.
    private var rhythm: some View {
        let peak = max(1, day.hours.max() ?? 1)
        let peakHour = day.hours.firstIndex(of: peak) ?? 0
        let ticks: [Int: Alignment] = [0: .leading, 6: .leading, 12: .leading, 18: .leading, 23: .trailing]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                DockSectionLabel(title: "Activity by hour")
                Spacer(minLength: 8)
                if day.hours[peakHour] > 0 {
                    Text("Peak \(Self.hourLabel(peakHour)) · \(peak) events")
                        .font(DockTypography.machineMetadata)
                        .foregroundStyle(Color.dockMetadataText)
                }
            }
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<24, id: \.self) { hour in
                    let count = day.hours[hour]
                    let ratio = Double(count) / Double(peak)
                    VStack(spacing: 5) {
                        UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 1, bottomTrailingRadius: 1, topTrailingRadius: 3, style: .continuous)
                            .fill(count == 0 ? Color.dockPrimaryText.opacity(0.06)
                                  : Color.dockPrimaryText.opacity(hour == peakHour ? 0.85 : 0.3 + 0.4 * ratio))
                            .frame(height: count > 0 ? max(5, 44 * CGFloat(ratio)) : 2)
                            .frame(maxHeight: 44, alignment: .bottom)
                        // Ticks overflow their column so "12p" stays one line without widening the bar.
                        Text(ticks[hour] != nil ? Self.hourLabel(hour) : " ")
                            .font(DockTypography.compactStatus)
                            .foregroundStyle(Color.dockMetadataText)
                            .fixedSize()
                            .frame(maxWidth: .infinity, alignment: ticks[hour] ?? .leading)
                    }
                    .help("\(Self.hourLabel(hour)) · \(count) events")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity by hour. Peak at \(Self.hourLabel(peakHour)) with \(peak) events.")
    }

    /// Derived stats, each shown only when there is something to say.
    @ViewBuilder
    private var insights: some View {
        let change = Double(day.activityCount).percentChange(from: usualActivity)
        let perItem = day.cost > 0 && day.shippedItems > 0 ? day.cost / Double(day.shippedItems) : nil
        if day.activeHours > 0 || change != nil || perItem != nil || day.usage != nil {
            HStack(alignment: .top, spacing: 24) {
                if day.activeHours > 0 {
                    stat("\(day.activeHours)h active", day.longestStretch > 1 ? "longest stretch \(day.longestStretch)h" : "focus time")
                }
                if let change { stat("\(change > 0 ? "↑" : "↓") \(abs(change))%", "vs your usual day") }
                if let perItem { stat(UsageWorkspaceView.cost(perItem), "cost per item shipped") }
                Spacer(minLength: 0)
                if day.cost > 0 || day.usage != nil { usageLink(onOpenUsage) }
            }
        }
    }

    private static func hourLabel(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h) \(hour < 12 ? "AM" : "PM")"
    }

    // MARK: Columns

    @ViewBuilder
    private var shippedColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !day.pullRequests.isEmpty {
                section("Pull requests merged", count: day.pullRequests.count) {
                    capped("prs", day.pullRequests.sorted { $0.mergedAt > $1.mergedAt }) { pr in
                        Button { if let url = pr.url { NSWorkspace.shared.open(url) } } label: {
                            row(icon: .gitPullRequest, tint: .dockSecondaryText, title: pr.title,
                                meta: "\(pr.repo) #\(pr.number) · \(pr.mergedAt.formatted(.dateTime.hour().minute()))", trailingIcon: .arrowUpRight)
                        }
                        .buttonStyle(CalendarRowButtonStyle())
                        .help("Open on GitHub")
                    }
                }
            }
            if !day.doneTasks.isEmpty {
                section("Tasks done", count: day.doneTasks.count) {
                    capped("tasks", day.doneTasks) { taskRow($0) }
                }
            }
            if !day.commits.isEmpty {
                section("Commits", count: day.commits.count) {
                    CalendarLeaderboard(title: nil, rows: repoCounts, unit: "commits", carded: false) { CalendarRepoLabel(id: $0) }
                        .padding(.vertical, 4)
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
                        if usage.apiCalls > 0 { stat(usage.apiCalls.formatted(), "calls") }
                        if usage.sessions > 0 { stat("\(usage.sessions)", "sessions") }
                        if usage.estimatedCost > 0 { stat(UsageWorkspaceView.cost(usage.estimatedCost), "cost") }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockCard(padding: 0)
    }

    /// The day's commits per repository, busiest first.
    private var repoCounts: [WorkCount] {
        Dictionary(grouping: day.commits, by: \.repo)
            .map { WorkCount(id: $0.key, count: $0.value.count) }
            .sorted { ($0.count, $1.id) > ($1.count, $0.id) }
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
    let date: Date
    let dayNumber: Int
    let day: WorkDay?
    let isSelected: Bool
    let isInScope: Bool
    let isToday: Bool
    let isFuture: Bool
    @State private var isHovering = false
    @State private var showsPreview = false

    // Explicit because the @State properties above are not Equatable.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.date == rhs.date && lhs.day == rhs.day && lhs.isSelected == rhs.isSelected && lhs.isInScope == rhs.isInScope
            && lhs.isToday == rhs.isToday && lhs.isFuture == rhs.isFuture
    }

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
            }
            Spacer(minLength: 0)
            if let day, day.activityCount > 0 { mixBar(day) }
        }
        .padding(7)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
        .background(shape.fill(Color.dockPrimaryText.opacity(0.015 + heat * 0.02)))
        .background(shape.fill(Color.dockAccent.opacity(isInScope ? 0.1 : 0)))
        .overlay(shape.stroke(isSelected ? Color.dockAccent : isInScope ? Color.dockAccent.opacity(0.4) : Color.dockBorderLight, lineWidth: isSelected ? 1.5 : 1))
        .opacity(isFuture ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Debounced so sweeping across the grid opens nothing; the popover body is only built when shown.
        .task(id: isHovering) {
            guard isHovering, day?.isEmpty == false else { showsPreview = false; return }
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { showsPreview = true }
        }
        .popover(isPresented: $showsPreview, arrowEdge: .bottom) {
            if let day { CalendarDayPreview(date: date, day: day) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Day \(dayNumber), \(shipped) shipped, \(day?.sessions.count ?? 0) sessions")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

/// Quick look at one day's figures. Zero rows are left out, so it fits any kind of work.
private struct CalendarDayPreview: View {
    let date: Date
    let day: WorkDay

    var body: some View {
        let failed = day.cronRuns.filter(\.isFailure).count
        let rows: [(Ph, String, Int)] = [
            (.gitPullRequest, "PRs merged", day.pullRequests.count),
            (.checkCircle, "Tasks done", day.doneTasks.count),
            (.gitCommit, "Commits", day.commits.count),
            (.chatCircle, "Sessions", day.sessions.count),
            (.clockCounterClockwise, "Automations", day.cronRuns.count)
        ].filter { $0.2 > 0 }
        VStack(alignment: .leading, spacing: 8) {
            Text(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(DockTypography.rowTitle)
                .foregroundStyle(Color.dockPrimaryText)
            VStack(spacing: 5) {
                ForEach(rows, id: \.1) { icon, label, value in
                    HStack(spacing: 8) {
                        DockIcon(icon).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText).frame(width: 14)
                        Text(label).font(DockTypography.metadata).foregroundStyle(Color.dockSecondaryText)
                        Spacer(minLength: 12)
                        Text("\(value)").font(DockTypography.machineMetadata.weight(.semibold)).foregroundStyle(Color.dockPrimaryText)
                    }
                }
                if failed > 0 {
                    HStack {
                        Text("\(failed) failed").font(DockTypography.metadata).foregroundStyle(Color.dockWarning)
                        Spacer()
                    }
                }
            }
            if let first = day.firstAt, let last = day.lastAt, last > first {
                Text("\(first.formatted(.dateTime.hour().minute()))–\(last.formatted(.dateTime.hour().minute()))")
                    .font(DockTypography.machineMetadata)
                    .foregroundStyle(Color.dockMetadataText)
            }
            if let usage = day.usage, usage.inputTokens + usage.outputTokens > 0 {
                Text("\(UsageWorkspaceView.tokens(usage.inputTokens + usage.outputTokens)) tokens"
                     + (usage.estimatedCost > 0 ? " · \(UsageWorkspaceView.cost(usage.estimatedCost))" : ""))
                    .font(DockTypography.machineMetadata)
                    .foregroundStyle(Color.dockMetadataText)
            }
        }
        .padding(12)
        .frame(width: 210, alignment: .leading)
    }
}

/// Cost and tokens live on the Usage page; the calendar only gives the figure and a way there.
@MainActor
private func usageLink(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 3) {
            Text("Usage")
            DockIcon(.arrowUpRight, size: 10, color: .dockAccent)
        }
        .font(DockTypography.metadata)
        .foregroundStyle(Color.dockAccent)
    }
    .buttonStyle(.plain)
    .help("Open the Usage page")
}
