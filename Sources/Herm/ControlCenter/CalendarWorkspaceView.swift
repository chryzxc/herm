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
    @State private var copied = false
    /// Week strip by default so the day below gets the room; the month is one click away.
    @AppStorage("dock.calendar.showsMonth") private var showsMonth = false
    @FocusState private var gridFocused: Bool

    private let calendar = Calendar.current
    private var refreshState: ProjectionRefreshState? { control.refreshState(for: "work.calendar") }
    /// The published index can briefly belong to the previous month while a new one loads.
    private var index: WorkCalendarIndex? {
        guard let index = control.workCalendar, calendar.isDate(index.month, equalTo: month, toGranularity: .month) else { return nil }
        return index
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            if let state = refreshState, let error = state.error {
                Text(state.isStale ? "Showing last successful data. \(error)" : error)
                    .font(DockTypography.metadata)
                    .foregroundStyle(Color.dockWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let index {
                // Pinned: the month never scrolls away, so another day is always one click off.
                grid(index)
                // The only scrolling region; each day starts at the top.
                ScrollView {
                    VStack(spacing: 12) {
                        detail(index.day(selected) ?? WorkDay())
                        monthCrew(index)
                    }
                    .padding(.bottom, 16)
                }
                .id(selected)
                .frame(maxHeight: .infinity)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Kanban and cron load on their own schedule; fold them in as they land.
        .onChange(of: control.globalKanbanTasks) { _, _ in control.rebuildWorkCalendar() }
        .onChange(of: control.cronRuns) { _, _ in control.rebuildWorkCalendar() }
        // Hermes' project list can land after the first load; re-read git once it does.
        .onChange(of: control.projects.map(\.name)) { _, _ in
            control.refreshWorkCalendar(month: month, repoPaths: repoPaths, force: true)
        }
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
            // Month totals live in the toolbar's spare width; they drop out when it is narrow.
            if let index {
                ViewThatFits(in: .horizontal) {
                    summary(index, full: true)
                    summary(index, full: false)
                    Color.clear.frame(width: 0)
                }
                .layoutPriority(-1)
            }

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

    // MARK: Summary

    private func summary(_ index: WorkCalendarIndex, full: Bool) -> some View {
        let tasks = index.days.values.reduce(0) { $0 + $1.doneTasks.count }
        let commits = index.days.values.reduce(0) { $0 + $1.commits.count }
        let sessions = index.days.values.reduce(0) { $0 + $1.sessions.count }
        let runs = index.days.values.reduce(0) { $0 + $1.cronRuns.count }
        return HStack(spacing: 12) {
            inlineStat(tasks, "tasks")
            inlineStat(sessions, "sessions")
            if full {
                inlineStat(commits, "commits")
                inlineStat(runs, "runs")
                inlineStat(index.currentStreak, "day streak")
                if index.monthCost > 0 {
                    inlineStat(UsageWorkspaceView.cost(index.monthCost), "spent")
                } else if index.monthTokens > 0 {
                    inlineStat(UsageWorkspaceView.tokens(index.monthTokens), "tokens")
                }
            }
            if let busiest = index.busiestDay {
                Button { select(busiest) } label: {
                    inlineStat(busiest.formatted(.dateTime.month(.abbreviated).day()), "busiest")
                }
                .buttonStyle(.plain)
                .help("Jump to the busiest day")
            }
        }
        .fixedSize()
    }

    private func inlineStat(_ value: CustomStringConvertible, _ label: String) -> some View {
        (Text(value.description).foregroundStyle(Color.dockPrimaryText).fontWeight(.semibold)
            + Text(" " + label).foregroundStyle(Color.dockMetadataText))
            .font(DockTypography.metadata)
            .lineLimit(1)
    }

    // MARK: Grid

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

    private func grid(_ index: WorkCalendarIndex) -> some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let ordered = Array(symbols[(calendar.firstWeekday - 1)...] + symbols[..<(calendar.firstWeekday - 1)])
        let today = calendar.startOfDay(for: Date())
        let all = weeks
        let rows = showsMonth ? all : all.filter { $0.contains(selected) }
        let total: ([Date?]) -> Int = { $0.compactMap { $0.flatMap(index.day)?.shippedCount }.reduce(0, +) }
        let weekTotals = rows.map(total)
        let maxWeek = max(1, all.map(total).max() ?? 1)
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).frame(maxWidth: .infinity)
                }
                Text("Week").frame(width: 44)
            }
            .font(DockTypography.metadata)
            .foregroundStyle(Color.dockMetadataText)

            ForEach(Array(rows.enumerated()), id: \.offset) { row, week in
                HStack(spacing: 4) {
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
                            .onTapGesture { select(date) }
                        } else {
                            Color.clear.frame(maxWidth: .infinity, minHeight: 46)
                        }
                    }
                    weekTotal(weekTotals[row], max: maxWeek)
                }
            }
            legend.padding(.top, 2)
        }
        .padding(10)
        // Keep the strip at its natural height; the day detail below gets the rest.
        .fixedSize(horizontal: false, vertical: true)
        .dockCard(padding: 0)
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { moveSelection(-1) }
        .onKeyPress(.rightArrow) { moveSelection(1) }
        .onKeyPress(.upArrow) { moveSelection(-7) }
        .onKeyPress(.downArrow) { moveSelection(7) }
    }

    private func weekTotal(_ total: Int, max: Int) -> some View {
        VStack(spacing: 4) {
            Text(total > 0 ? "\(total)" : "·")
                .font(DockTypography.machineMetadata.weight(.semibold))
                .foregroundStyle(total > 0 ? Color.dockPrimaryText : Color.dockMetadataText)
            GeometryReader { proxy in
                Capsule().fill(Color.dockSuccess.opacity(0.7))
                    .frame(height: proxy.size.height * CGFloat(total) / CGFloat(max))
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(width: 4, height: 20)
        }
        .frame(width: 44, height: 46)
        .help("\(total) shipped this week")
    }

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

    private var legend: some View {
        HStack(spacing: 12) {
            legendSwatch(Color.dockSuccess, "Shipped")
            legendSwatch(Color.dockAccent, "Sessions")
            legendSwatch(Color.dockSecondaryText, "Automation")
            legendSwatch(Color.dockWarning, "Failed run")
            Spacer()
            Button { withAnimation(.snappy(duration: 0.2)) { showsMonth.toggle() } } label: {
                Label(showsMonth ? "Collapse to week" : "Expand to month", icon: showsMonth ? .caretUp : .caretDown)
                    .foregroundStyle(Color.dockAccent)
            }
            .buttonStyle(.plain)
            .help(showsMonth ? "Show only the selected week" : "Show the whole month")
            Spacer()
            Text("← → ↑ ↓ to move")
        }
        .font(DockTypography.metadata)
        .foregroundStyle(Color.dockMetadataText)
    }

    private func legendSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 10, height: 4); Text(label) }
    }

    // MARK: Month crew

    @ViewBuilder
    private func monthCrew(_ index: WorkCalendarIndex) -> some View {
        if !index.crew.isEmpty || !index.repos.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if !index.crew.isEmpty {
                    leaderboard("Crew this month", rows: Array(index.crew.prefix(8)), unit: "tasks") { id in
                        BotChip(id: id, botsByID: botsByID, avatarImages: avatarImages)
                    }
                }
                if !index.repos.isEmpty {
                    leaderboard("Repositories", rows: Array(index.repos.prefix(6)), unit: "commits") { id in
                        HStack(spacing: 4) {
                            DockIcon(.gitBranch).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
                            Text(id).font(DockTypography.machineMetadata.weight(.medium)).foregroundStyle(Color.dockSecondaryText)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dockCard(padding: 0)
        }
    }

    private func leaderboard<Label: View>(_ title: String, rows: [WorkCount], unit: String, @ViewBuilder label: @escaping (String) -> Label) -> some View {
        let top = max(1, rows.first?.count ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            DockSectionLabel(title: title, count: rows.count)
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    label(row.id).frame(width: 130, alignment: .leading)
                    GeometryReader { proxy in
                        Capsule().fill(Color.dockPrimaryText.opacity(0.06))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.dockSuccess.opacity(0.75))
                                    .frame(width: proxy.size.width * CGFloat(row.count) / CGFloat(top))
                            }
                    }
                    .frame(height: 5)
                    Text("\(row.count)")
                        .font(DockTypography.machineMetadata)
                        .foregroundStyle(Color.dockPrimaryText)
                        .frame(width: 32, alignment: .trailing)
                }
                .help("\(row.count) \(unit)")
            }
        }
    }

    // MARK: Day detail

    @ViewBuilder
    private func detail(_ day: WorkDay) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            dayHeader(day)
            if day.isEmpty {
                VStack(spacing: 6) {
                    DockIcon(.calendarBlank).font(.system(size: 22)).foregroundStyle(Color.dockMetadataText)
                    Text(selected > calendar.startOfDay(for: Date()) ? "Nothing yet. This day is still ahead." : "A quiet day. Nothing was recorded.")
                        .font(DockTypography.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                rhythm(day)
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
        .dockCard(padding: 0)

        if !day.isEmpty {
            // Shipped on the left, worked on on the right. ViewThatFits measured
            // untruncated titles and always stacked, so the split is unconditional.
            let shipped = !day.doneTasks.isEmpty || !day.commits.isEmpty
            let worked = !day.sessions.isEmpty || !day.cronRuns.isEmpty || day.usage != nil
            HStack(alignment: .top, spacing: 12) {
                if shipped { shippedColumn(day).frame(minWidth: 0, maxWidth: .infinity, alignment: .top) }
                if worked { workedColumn(day).frame(minWidth: 0, maxWidth: .infinity, alignment: .top) }
            }
        }
    }

    @ViewBuilder
    private func shippedColumn(_ day: WorkDay) -> some View {
        if !day.doneTasks.isEmpty || !day.commits.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if !day.doneTasks.isEmpty {
                    section("Tasks done", count: day.doneTasks.count) {
                        ForEach(day.doneTasks) { task in taskRow(task) }
                    }
                }
                if !day.commits.isEmpty {
                    section("Commits", count: day.commits.count) {
                        ForEach(day.commits) { commit in
                            row(icon: .gitCommit, tint: .dockSuccess, title: commit.subject,
                                meta: "\(commit.repo) · \(commit.hash) · \(commit.date.formatted(.dateTime.hour().minute()))")
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dockCard(padding: 0)
        }
    }

    @ViewBuilder
    private func workedColumn(_ day: WorkDay) -> some View {
        if !day.sessions.isEmpty || !day.cronRuns.isEmpty || day.usage != nil {
            VStack(alignment: .leading, spacing: 12) {
                if !day.sessions.isEmpty {
                    section("Sessions", count: day.sessions.count) {
                        ForEach(day.sessions.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }) { session in
                            Button { control.openLatestActivitySession(session) } label: {
                                row(icon: .chats, tint: .dockAccent, title: session.title,
                                    meta: session.updatedAt?.formatted(.dateTime.hour().minute()), trailingIcon: .arrowUpRight)
                            }
                            .buttonStyle(CalendarRowButtonStyle())
                            .help("Open conversation")
                        }
                    }
                }
                if !day.cronRuns.isEmpty {
                    section("Automations", count: day.cronRuns.count) {
                        ForEach(day.cronRuns) { run in
                            row(icon: run.isFailure ? .warningCircle : .clockCounterClockwise,
                                tint: run.isFailure ? .dockWarning : .dockSecondaryText,
                                title: run.jobID ?? run.id,
                                meta: [run.claimedDate?.formatted(.dateTime.hour().minute()), run.error ?? run.status].compactMap { $0 }.joined(separator: " · "))
                        }
                    }
                }
                if let usage = day.usage {
                    section("Usage", count: nil) {
                        HStack(spacing: 16) {
                            stat(UsageWorkspaceView.tokens(usage.inputTokens + usage.outputTokens), "tokens")
                            stat(usage.apiCalls.formatted(), "calls")
                            stat("\(usage.sessions)", "sessions")
                            stat(usage.estimatedCost > 0 ? UsageWorkspaceView.cost(usage.estimatedCost) : "—", "cost")
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dockCard(padding: 0)
        }
    }

    private func dayHeader(_ day: WorkDay) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Text(selected.formatted(.dateTime.month(.abbreviated)).uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.dockOnAccentText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .background(Color.dockAccent)
                Text("\(calendar.component(.day, from: selected))")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 44, height: 48)
            .background(Color.dockPrimaryText.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.dockBorderLight, lineWidth: 1))

            VStack(alignment: .leading, spacing: 3) {
                Text(selected.formatted(.dateTime.weekday(.wide)))
                    .font(DockTypography.rowTitle)
                    .foregroundStyle(Color.dockPrimaryText)
                Text(daySubtitle(day))
                    .font(DockTypography.metadata)
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(WorkCalendarIndex.standupMarkdown(for: selected, day: day), forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy standup", icon: copied ? .check : .copy)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(day.isEmpty)
        }
    }

    private func daySubtitle(_ day: WorkDay) -> String {
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
    private func rhythm(_ day: WorkDay) -> some View {
        let peak = max(1, day.hours.max() ?? 1)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<24, id: \.self) { hour in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(day.hours[hour] > 0 ? Color.dockAccent.opacity(0.35 + 0.65 * Double(day.hours[hour]) / Double(peak)) : Color.dockPrimaryText.opacity(0.06))
                        .frame(height: day.hours[hour] > 0 ? max(4, 28 * CGFloat(day.hours[hour]) / CGFloat(peak)) : 3)
                        .frame(maxWidth: .infinity)
                        .help("\(hour):00 · \(day.hours[hour]) events")
                }
            }
            .frame(height: 28, alignment: .bottom)
            HStack {
                Text("12a"); Spacer(); Text("6a"); Spacer(); Text("12p"); Spacer(); Text("6p"); Spacer(); Text("11p")
            }
            .font(.system(size: 9))
            .foregroundStyle(Color.dockMetadataText)
        }
    }

    private func taskRow(_ task: KanbanTaskSummary) -> some View {
        Button { onOpenTask(task) } label: {
            HStack(spacing: 8) {
                DockIcon(.checkCircle, size: 13, weight: .fill, color: .dockSuccess)
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
        }
        .buttonStyle(CalendarRowButtonStyle())
        .help("Open in Kanban")
    }

    private func section<Content: View>(_ title: String, count: Int?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            DockSectionLabel(title: title, count: count)
            content()
        }
    }

    private func row(icon: Ph, tint: Color, title: String, meta: String?, trailingIcon: Ph? = nil) -> some View {
        HStack(spacing: 8) {
            DockIcon(icon).font(.system(size: 12)).foregroundStyle(tint).frame(width: 14)
            Text(title).font(DockTypography.rowTitle).foregroundStyle(Color.dockPrimaryText).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let meta {
                Text(meta).font(DockTypography.machineMetadata).foregroundStyle(Color.dockMetadataText).lineLimit(1)
            }
            if let trailingIcon {
                DockIcon(trailingIcon).font(.system(size: 10)).foregroundStyle(Color.dockMetadataText)
            }
        }
        .padding(.vertical, 2)
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
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.dockPrimaryText.opacity(configuration.isPressed ? 0.08 : isHovering ? 0.05 : 0))
            )
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text("\(dayNumber)")
                    .font(DockTypography.machineMetadata.weight(isToday ? .bold : .medium))
                    .foregroundStyle(isToday ? Color.dockOnAccentText : isFuture ? Color.dockMetadataText : Color.dockPrimaryText)
                    .padding(.horizontal, isToday ? 5 : 0)
                    .background { if isToday { Capsule().fill(Color.dockAccent) } }
                if day?.hasFailedRun == true {
                    Circle().fill(Color.dockWarning).frame(width: 5, height: 5).padding(.leading, 3)
                }
                Spacer(minLength: 2)
                if shipped > 0 {
                    Text("\(shipped)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.dockPrimaryText)
                } else if let sessions = day?.sessions.count, sessions > 0 {
                    Text("\(sessions)s").font(.system(size: 10)).foregroundStyle(Color.dockMetadataText)
                }
            }
            Spacer(minLength: 0)
            if let day, day.activityCount > 0 { mixBar(day) }
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.dockAccent.opacity(heat * 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(isSelected ? Color.dockAccent : Color.dockBorderLight, lineWidth: isSelected ? 1.5 : 1))
        .opacity(isFuture ? 0.55 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Day \(dayNumber), \(shipped) shipped, \(day?.sessions.count ?? 0) sessions")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Proportions of shipped / sessions / automation for the day.
    private func mixBar(_ day: WorkDay) -> some View {
        let parts: [(Int, Color)] = [
            (day.doneTasks.count + day.commits.count, .dockSuccess),
            (day.sessions.count, .dockAccent),
            (day.cronRuns.count, day.hasFailedRun ? .dockWarning : .dockSecondaryText)
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
