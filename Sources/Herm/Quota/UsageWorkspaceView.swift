import Charts
import SwiftUI

/// The Activity page's Spend tab: what Hermes has spent, read from its
/// `/api/analytics/usage` report. The Dock only draws; every figure is Hermes'.
struct UsageWorkspaceView: View {
    @ObservedObject var control: ControlCenterModel
    var availableWidth: CGFloat = 640

    static let reportDays = 30

    private var refreshState: ProjectionRefreshState? { control.refreshState(for: "token.usage") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            toolbar
            yearActivity

            if let report = control.tokenUsage {
                UsageReportContent(
                    report: report, isWide: availableWidth >= 804,
                    providersRefreshing: control.refreshState(for: "usage.providers")?.isRefreshing == true
                )
                .equatable()
            } else if refreshState?.isRefreshing == true {
                message(
                    title: "Reading Hermes usage…", detail: "Hermes is totalling tokens and cost for the past 30 days.")
            } else if refreshState?.error != nil {
                message(title: "Usage unavailable", detail: "Refresh to try loading the past 30 days again.")
            } else {
                message(
                    title: "No usage report yet",
                    detail: "Usage comes from the Hermes web server. Start Hermes and refresh.")
            }

            if let usage = control.sessionUsage { sessionSection(usage) }

            if let state = refreshState, !state.isRefreshing, let error = state.error {
                Text(state.isStale ? "Showing last successful data. \(error)" : error)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { control.refreshSpend() }
    }

    private var yearActivity: some View {
        let state = control.refreshState(for: "usage.year")
        return VStack(alignment: .leading, spacing: 8) {
            if let daily = control.yearActivity {
                UsageHeatmap(daily: daily).equatable()
            } else {
                message(
                    title: state?.isRefreshing == true
                        ? "Reading yearly activity…"
                        : (state == nil && refreshState?.isRefreshing == true
                            ? "Yearly activity queued" : "Yearly activity unavailable"),
                    detail: "The heatmap loads after the 30-day spend report."
                )
            }
            if state?.isRefreshing != true, let error = state?.error {
                Text(state?.isStale == true ? "Showing last successful activity. \(error)" : error)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockWarning)
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        UsageToolbar(control: control)
            .frame(minHeight: DockControlMetrics.hitTarget)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }

    // MARK: Current session

    private func sessionSection(_ usage: SessionUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                DockSectionLabel(title: "Current session")
                Spacer()
                if let model = usage.model {
                    Text(model)
                        .dockFont(.machineMetadata)
                        .foregroundStyle(Color.dockMetadataText)
                }
            }
            if let percent = usage.contextPercent {
                HStack {
                    Text("Context window")
                        .dockFont(.body)
                        .foregroundStyle(Color.dockSecondaryText)
                    Spacer()
                    Text(
                        [usage.contextUsed.map(Self.tokens), usage.contextMax.map(Self.tokens)].compactMap { $0 }
                            .joined(separator: " / ") + " · " + Self.percent(percent)
                    )
                    .dockFont(.machineMetadata)
                    .foregroundStyle(Color.dockPrimaryText)
                }
                meter(percent / 100, tint: percent >= 80 ? .dockWarningFill : .dockAccent)
            }
            Text(
                "\(Self.tokens(usage.totalTokens)) tokens · \(Self.tokens(usage.inputTokens)) in · \(Self.tokens(usage.outputTokens)) out · \(usage.calls) calls"
            )
            .dockFont(.metadata)
            .foregroundStyle(Color.dockMetadataText)
        }
        .dockCard(padding: 14)
    }

    // MARK: Pieces

    private func meter(_ fraction: Double, tint: Color = .dockAccent) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.dockBorderLight)
                Capsule().fill(tint).frame(width: max(2, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private func message(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
            Text(detail)
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }

    static func tokens(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func cost(_ value: Double) -> String {
        // A literal "$": the USD currency style prints "US$" outside the US locale.
        "$" + value.formatted(.number.precision(.fractionLength(2)))
    }

    static func percent(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0))))%"
    }

    static func taskLabel(_ task: String) -> String {
        task.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// Only analytics inputs cross this boundary; unrelated control-center publications cannot rebuild charts.
struct UsageReportContent: View, Equatable {
    let report: TokenUsageReport
    let isWide: Bool
    var providersRefreshing = false
    @State private var expandedModels: Set<String> = []
    @State private var grouping: UsageCostGrouping = .models
    @State private var expandedShares: Set<String> = []

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.report == rhs.report && lhs.isWide == rhs.isWide && lhs.providersRefreshing == rhs.providersRefreshing
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            spendOverview(report)
            UsageDailyInsights(daily: report.daily)
            UsageSpendTotals(report: report, isWide: isWide)
            modelsSection(report)
            if !report.tasks.isEmpty { tasksSection(report) }
            let layout =
                isWide
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            layout {
                shareSection(
                    title: "Tools", detail: "\(report.tools.reduce(0) { $0 + $1.count }.formatted()) calls",
                    rows: report.tools, tint: .dockInfo)
                shareSection(
                    title: "Skills",
                    detail: "\(report.skillLoads.formatted()) loads · \(report.distinctSkills) distinct",
                    rows: report.skills, tint: .dockMerged)
            }
        }
    }

    /// Indent that lines sub-rows up under the model name, past the provider icon.
    private func inset(_ model: TokenUsageReport.Model) -> CGFloat { model.providers.isEmpty ? 18 : 44 }

    // MARK: Spend overview

    private func spendOverview(_ report: TokenUsageReport) -> some View {
        let layout =
            isWide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 28))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
        return layout {
            UsageSpendSummary(report: report, grouping: $grouping, providersRefreshing: providersRefreshing)
                .frame(width: isWide ? 280 : nil)
            DailyUsageChart(daily: report.daily).equatable()
        }
        .padding(18)
        .dockCard(padding: 0)
    }

    // MARK: Models & tasks

    private func modelsSection(_ report: TokenUsageReport) -> some View {
        let maxTokens = max(1, report.models.map(\.totalTokens).max() ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            DockSectionLabel(title: "By model", count: report.models.count)
            ForEach(report.models) { model in
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        if expandedModels.contains(model.id) {
                            expandedModels.remove(model.id)
                        } else {
                            expandedModels.insert(model.id)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            DockIcon(expandedModels.contains(model.id) ? .caretDown : .caretRight)
                                .dockFont(size: 9, weight: .semibold)
                                .foregroundStyle(Color.dockMetadataText)
                                .frame(width: 10)
                                .opacity(model.tasks.isEmpty ? 0 : 1)
                            if let provider = model.providers.first {
                                ProviderMarkBadge(mark: ProviderMark(hermesProvider: provider), size: 18)
                            }
                            Text(model.model)
                                .dockFont(.rowTitle)
                                .foregroundStyle(Color.dockPrimaryText)
                                .lineLimit(1)
                            ForEach(model.providers, id: \.self) { provider in
                                Text(provider)
                                    .dockFont(.metadata)
                                    .foregroundStyle(Color.dockSecondaryText)
                                    .lineLimit(1)
                                    .padding(.horizontal, 7)
                                    .frame(height: 18)
                                    .background(Capsule().fill(Color.dockCanvas))
                                    .overlay(Capsule().stroke(Color.dockBorderLight, lineWidth: 1))
                                    .fixedSize()
                            }
                            Spacer(minLength: 8)
                            Text(UsageWorkspaceView.tokens(model.totalTokens))
                                .dockFont(.machineMetadata)
                                .foregroundStyle(Color.dockPrimaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.dockHover)
                    .disabled(model.tasks.isEmpty)

                    meter(Double(model.totalTokens) / Double(maxTokens), tint: .dockInfoFill)
                        .padding(.leading, inset(model))

                    Text(
                        "\(UsageWorkspaceView.tokens(model.inputTokens)) in · \(UsageWorkspaceView.tokens(model.outputTokens)) out · \(model.sessions) sessions · \(model.apiCalls.formatted()) calls · \(model.estimatedCost > 0 ? UsageWorkspaceView.cost(model.estimatedCost) : "no per-token cost")"
                    )
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
                    .padding(.leading, inset(model))

                    if expandedModels.contains(model.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.tasks) { task in
                                taskLine(task)
                            }
                        }
                        .padding(.leading, inset(model))
                        .padding(.top, 2)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .dockCard(padding: 14)
    }

    private func tasksSection(_ report: TokenUsageReport) -> some View {
        let maxTokens = max(1, report.tasks.map(\.totalTokens).max() ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                DockSectionLabel(title: "Background work", count: report.tasks.count)
                Spacer()
                Text(
                    "\(UsageWorkspaceView.tokens(report.auxInputTokens + report.auxOutputTokens)) tokens · \(UsageWorkspaceView.cost(report.auxCost))"
                )
                .dockFont(.machineMetadata)
                .foregroundStyle(Color.dockMetadataText)
            }
            ForEach(report.tasks) { task in
                VStack(alignment: .leading, spacing: 4) {
                    taskLine(task)
                    meter(Double(task.totalTokens) / Double(maxTokens), tint: .dockMergedFill)
                }
            }
        }
        .dockCard(padding: 14)
    }

    private func taskLine(_ task: TokenUsageReport.Task) -> some View {
        HStack(spacing: 8) {
            Text(UsageWorkspaceView.taskLabel(task.task))
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
            Spacer(minLength: 8)
            Text(
                "\(UsageWorkspaceView.tokens(task.inputTokens)) in · \(UsageWorkspaceView.tokens(task.outputTokens)) out · \(task.apiCalls.formatted()) calls\(task.estimatedCost > 0 ? " · " + UsageWorkspaceView.cost(task.estimatedCost) : "")"
            )
            .dockFont(.machineMetadata)
            .foregroundStyle(Color.dockMetadataText)
            .lineLimit(1)
        }
    }

    // MARK: Tools & skills

    private func shareSection(title: String, detail: String, rows: [TokenUsageReport.Share], tint: Color) -> some View {
        let top = expandedShares.contains(title) ? rows : Array(rows.prefix(10))
        let maxShare = max(0.01, top.map(\.percentage).max() ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                DockSectionLabel(title: title, count: rows.count)
                Spacer()
                Text(detail)
                    .dockFont(.machineMetadata)
                    .foregroundStyle(Color.dockMetadataText)
            }
            if top.isEmpty {
                Text("None in this range.")
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
            }
            ForEach(top) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.name)
                            .dockFont(.body)
                            .foregroundStyle(Color.dockSecondaryText)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(row.count.formatted()) · \(UsageWorkspaceView.percent(row.percentage))")
                            .dockFont(.machineMetadata)
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    meter(row.percentage / maxShare, tint: tint)
                }
            }
            if rows.count > 10 {
                Button(expandedShares.contains(title) ? "Show less" : "Show all \(rows.count)") {
                    if expandedShares.contains(title) {
                        expandedShares.remove(title)
                    } else {
                        expandedShares.insert(title)
                    }
                }
                .buttonStyle(.dockCompact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockCard(padding: 14)
    }

    private func meter(_ fraction: Double, tint: Color) -> some View {
        GeometryReader { proxy in
            Capsule().fill(Color.dockBorderLight)
                .overlay(alignment: .leading) {
                    Capsule().fill(tint).frame(width: proxy.size.width * min(1, max(0, fraction)))
                }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// Its own view so hover selection redraws only the chart, and SwiftUI skips
/// it entirely when unrelated control-center state changes.
private struct DailyUsageChart: View, Equatable {
    let daily: [TokenUsageReport.Day]
    @State private var metric: DailyMetric = .cost
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDay: Date?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.daily == rhs.daily }

    enum DailyMetric: String, CaseIterable, Identifiable {
        case tokens = "Tokens"
        case cache = "Cache reads"
        case cost = "Cost"
        case calls = "API calls"
        var id: String { rawValue }
    }

    var body: some View {
        let selected = selectedDay.flatMap { day in daily.first { Calendar.current.isDate($0.day, inSameDayAs: day) } }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                DockSectionLabel(title: "Daily \(metric.rawValue.lowercased())")
                Spacer()
                HStack(spacing: 4) {
                    ForEach(DailyMetric.allCases) { choice in
                        DockTabButton(title: choice.rawValue, isSelected: metric == choice) { metric = choice }
                    }
                }
            }

            if daily.isEmpty {
                Text("No sessions in the past 30 days.")
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
            } else {
                Chart {
                    ForEach(daily.sorted { $0.day < $1.day }) { day in
                        switch metric {
                        case .tokens:
                            BarMark(x: .value("Day", day.day, unit: .day), y: .value("Tokens", day.inputTokens))
                                .foregroundStyle(by: .value("Kind", "Input"))
                            BarMark(x: .value("Day", day.day, unit: .day), y: .value("Tokens", day.outputTokens))
                                .foregroundStyle(by: .value("Kind", "Output"))
                        case .cache:
                            BarMark(
                                x: .value("Day", day.day, unit: .day), y: .value("Cache reads", day.cacheReadTokens)
                            )
                            .foregroundStyle(Color.dockMergedFill)
                        case .cost:
                            AreaMark(x: .value("Day", day.day, unit: .day), y: .value("Cost", day.estimatedCost))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(Color.dockReviewFill.opacity(0.14))
                            LineMark(x: .value("Day", day.day, unit: .day), y: .value("Cost", day.estimatedCost))
                                .interpolationMethod(.monotone)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                                .foregroundStyle(Color.dockReviewFill)
                            if daily.count == 1 {
                                PointMark(x: .value("Day", day.day, unit: .day), y: .value("Cost", day.estimatedCost))
                                    .foregroundStyle(Color.dockReviewFill)
                            }
                        case .calls:
                            BarMark(x: .value("Day", day.day, unit: .day), y: .value("API calls", day.apiCalls))
                                .foregroundStyle(Color.dockInfoFill)
                        }
                    }
                    if let selected {
                        RuleMark(x: .value("Day", selected.day, unit: .day))
                            .foregroundStyle(Color.dockBorderStrong)
                            .annotation(
                                position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                            ) {
                                dayTooltip(selected)
                            }
                    }
                }
                .chartForegroundStyleScale([
                    "Input": Color.dockInfoFill,
                    "Output": Color.dockReviewFill.opacity(
                        DockThemeRuntime.current == .mono || DockThemeRuntime.current == .eInk ? 0.4 : 1),
                ])
                .chartLegend(metric == .tokens ? .visible : .hidden)
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine().foregroundStyle(Color.dockBorderLight)
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(
                                    metric == .cost
                                        ? UsageWorkspaceView.cost(number) : UsageWorkspaceView.tokens(Int(number))
                                )
                                .dockFont(.machineMetadata)
                            }
                        }
                    }
                }
                .chartXSelection(
                    value: Binding(
                        get: { selectedDay },
                        // Snap to the day so hover only re-renders when the day changes.
                        set: { raw in
                            let day = raw.map { Calendar.current.startOfDay(for: $0) }
                            if day != selectedDay { selectedDay = day }
                        }
                    )
                )
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    if let frame = proxy.plotFrame {
                                        let x = location.x - geometry[frame].origin.x
                                        let date = proxy.value(atX: x, as: Date.self)
                                        selectedDay = date.map { Calendar.current.startOfDay(for: $0) }
                                    }
                                case .ended:
                                    selectedDay = nil
                                }
                            }
                    }
                }
                .frame(height: 240)
                .padding(.top, 28)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: metric)

                Text("Main conversation only · sessions grouped by start day · hover for details")
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 336, alignment: .topLeading)
    }

    private func dayTooltip(_ day: TokenUsageReport.Day) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(day.day, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                .dockFont(.metadata, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
            Group {
                Text(
                    "\(UsageWorkspaceView.tokens(day.inputTokens)) in · \(UsageWorkspaceView.tokens(day.outputTokens)) out"
                )
                Text(
                    "\(UsageWorkspaceView.tokens(day.cacheReadTokens)) cache · \(UsageWorkspaceView.tokens(day.reasoningTokens)) reasoning"
                )
                Text("\(day.sessions) sessions · \(day.apiCalls) calls · \(UsageWorkspaceView.cost(day.estimatedCost))")
            }
            .dockFont(.machineMetadata)
            .foregroundStyle(Color.dockSecondaryText)
        }
        .padding(8)
        .dockFloatingSurface(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous), stroke: .dockBorderLight,
            lineWidth: 1)
    }
}

/// Report period, freshness and refresh for Usage.
struct UsageToolbar: View {
    @ObservedObject var control: ControlCenterModel

    private var refreshState: ProjectionRefreshState? { control.refreshState(for: "token.usage") }
    private var isRefreshing: Bool {
        refreshState?.isRefreshing == true || control.refreshState(for: "usage.year")?.isRefreshing == true
            || control.refreshState(for: "usage.providers")?.isRefreshing == true
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("Past year · spend breakdown: past 30 days")
                .dockFont(.metadata)
                .foregroundStyle(Color.dockSecondaryText)

            Spacer(minLength: 8)

            if let lastSuccess = refreshState?.lastSuccess {
                Text("Updated \(lastSuccess, format: .dateTime.hour().minute())")
                    .dockFont(.machineMetadata)
                    .foregroundStyle(refreshState?.isStale == true ? Color.dockWarning : Color.dockMetadataText)
                    .lineLimit(1)
            }

            DockIconButton(
                icon: .arrowsClockwise,
                label: isRefreshing ? "Refreshing usage" : "Refresh usage",
                isBusy: isRefreshing,
                style: DockThemePalette(theme: DockThemeRuntime.current)
            ) {
                control.refreshSpend(force: true)
            }
        }
    }
}
