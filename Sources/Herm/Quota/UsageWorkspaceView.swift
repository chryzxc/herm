import Charts
import SwiftUI

/// The Activity page's Spend tab: what Hermes has spent, read from its
/// `/api/analytics/usage` report. The Dock only draws; every figure is Hermes'.
struct UsageWorkspaceView: View {
    @ObservedObject var control: ControlCenterModel
    @State private var expandedModels: Set<String> = []

    static let reportDays = 30

    private var refreshState: ProjectionRefreshState? { control.refreshState(for: "token.usage") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            toolbar
            yearActivity

            if let report = control.tokenUsage {
                overview(report)
                DailyUsageChart(daily: report.daily)
                modelsSection(report)
                if !report.tasks.isEmpty { tasksSection(report) }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        shareSection(title: "Tools", detail: "\(report.tools.reduce(0) { $0 + $1.count }.formatted()) calls", rows: report.tools, tint: .dockInfo)
                            .frame(minWidth: 300)
                        shareSection(title: "Skills", detail: "\(report.skillLoads.formatted()) loads · \(report.distinctSkills) distinct", rows: report.skills, tint: .dockMerged)
                            .frame(minWidth: 300)
                    }
                    VStack(spacing: 16) {
                        shareSection(title: "Tools", detail: "\(report.tools.reduce(0) { $0 + $1.count }.formatted()) calls", rows: report.tools, tint: .dockInfo)
                        shareSection(title: "Skills", detail: "\(report.skillLoads.formatted()) loads · \(report.distinctSkills) distinct", rows: report.skills, tint: .dockMerged)
                    }
                }
            } else if refreshState?.isRefreshing == true {
                message(title: "Reading Hermes usage…", detail: "Hermes is totalling tokens and cost for the past 30 days.")
            } else {
                message(title: "No usage report yet", detail: "Usage comes from the Hermes web server. Start Hermes and refresh.")
            }

            if let usage = control.sessionUsage { sessionSection(usage) }

            if let state = refreshState, let error = state.error {
                Text(state.isStale ? "Showing last successful data. \(error)" : error)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await control.refreshYearActivity() }
    }

    private var yearActivity: some View {
        let state = control.refreshState(for: "usage.year")
        return VStack(alignment: .leading, spacing: 8) {
            if let daily = control.yearActivity {
                UsageHeatmap(daily: daily)
            } else {
                message(
                    title: state?.isRefreshing == true ? "Reading yearly activity…" : "Yearly activity unavailable",
                    detail: "The heatmap reads the past year of usage from Hermes. Refresh to try again."
                )
            }
            if let error = state?.error {
                Text(state?.isStale == true ? "Showing last successful activity. \(error)" : error)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockWarning)
            }
        }
    }

    /// Indent that lines sub-rows up under the model name, past the provider icon.
    private func inset(_ model: TokenUsageReport.Model) -> CGFloat { model.providers.isEmpty ? 18 : 44 }

    // MARK: Toolbar

    private var toolbar: some View {
        UsageToolbar(control: control)
            .frame(minHeight: DockControlMetrics.hitTarget)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }

    // MARK: Overview

    private func overview(_ report: TokenUsageReport) -> some View {
        let auxTokens = report.auxInputTokens + report.auxOutputTokens
        return VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) { overviewTiles(report) }
                    .frame(minWidth: 880)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 0) {
                    overviewTiles(report)
                }
            }
            Color.dockBorderLight.frame(height: DockLayout.hairline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 12) {
                supportingMetric("API calls", report.apiCalls.formatted(), help: report.apiCalls > 0 ? "Main conversation · \(Self.tokens((report.inputTokens + report.outputTokens) / report.apiCalls)) tokens per call" : "No calls in range")
                supportingMetric("Reasoning", Self.tokens(report.reasoningTokens), help: "Hidden reasoning tokens reported by the provider for the main conversation.")
                supportingMetric("Background share", report.totalTokens > 0 ? Self.percent(Double(auxTokens) / Double(report.totalTokens) * 100) : "—", help: "\(Self.tokens(auxTokens)) tokens outside the chat: review, compression, approvals, titles, and vision.")
                supportingMetric("Models", report.models.count.formatted(), help: report.models.first.map { "Most used: \($0.model)" } ?? "No models in range")
            }
            .padding(14)
        }
        .dockCard(padding: 0)
    }

    @ViewBuilder
    private func overviewTiles(_ report: TokenUsageReport) -> some View {
        tile("Estimated cost", report.totalCost > 0 ? Self.cost(report.totalCost) : "—",
             detail: report.totalCost > 0 ? "\(Self.cost(report.estimatedCost)) chat · \(Self.cost(report.auxCost)) background" : "No per-token billing reported",
             tint: .dockReview, help: "Hermes' estimate. Subscription-included and unpriced models count as $0.")
        tile("Total tokens", Self.tokens(report.totalTokens),
             detail: "\(Self.tokens(report.totalInputTokens)) in · \(Self.tokens(report.totalOutputTokens)) out",
             tint: .dockInfo, help: "Input plus output, including background work. Cache reads are counted separately.")
        tile("Cache reads", Self.tokens(report.cacheReadTokens),
             detail: report.cacheHitRate.map { "\(Self.percent($0 * 100)) of prompt served from cache" } ?? "No prompt tokens",
             tint: .dockMerged, help: "Prompt tokens the provider served from its cache. Usually billed at a discount.")
        tile("Sessions", report.sessions.formatted(),
             detail: report.sessions > 0 ? "\(Self.tokens(report.totalTokens / report.sessions)) tokens each" : "None in range",
             tint: .dockInfo, help: nil)
    }

    private func supportingMetric(_ title: String, _ value: String, help: String) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(Color.dockSecondaryText)
            Text(value).fontWeight(.semibold).foregroundStyle(Color.dockPrimaryText)
        }
        .dockFont(.metadata)
        .accessibilityElement(children: .combine)
        .help(help)
    }

    private func tile(_ title: String, _ value: String, detail: String, tint: Color, help: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Capsule().fill(tint).frame(width: 3, height: 12)
                DockSectionLabel(title: title)
            }
            Text(value)
                .dockFont(.metric)
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(detail)
                .dockFont(.metadata)
                .foregroundStyle(Color.dockMetadataText)
                .lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .help(help ?? "")
    }

    // MARK: Models & tasks

    private func modelsSection(_ report: TokenUsageReport) -> some View {
        let maxTokens = max(1, report.models.map(\.totalTokens).max() ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            DockSectionLabel(title: "By model", count: report.models.count)
            ForEach(report.models) { model in
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        if expandedModels.contains(model.id) { expandedModels.remove(model.id) } else { expandedModels.insert(model.id) }
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
                            Text(Self.tokens(model.totalTokens))
                                .dockFont(.machineMetadata)
                                .foregroundStyle(Color.dockPrimaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.dockHover)
                    .disabled(model.tasks.isEmpty)

                    meter(Double(model.totalTokens) / Double(maxTokens), tint: .dockInfoFill)
                        .padding(.leading, inset(model))

                    Text("\(Self.tokens(model.inputTokens)) in · \(Self.tokens(model.outputTokens)) out · \(model.sessions) sessions · \(model.apiCalls.formatted()) calls · \(model.estimatedCost > 0 ? Self.cost(model.estimatedCost) : "no per-token cost")")
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
                Text("\(Self.tokens(report.auxInputTokens + report.auxOutputTokens)) tokens · \(Self.cost(report.auxCost))")
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
            Text(Self.taskLabel(task.task))
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
            Spacer(minLength: 8)
            Text("\(Self.tokens(task.inputTokens)) in · \(Self.tokens(task.outputTokens)) out · \(task.apiCalls.formatted()) calls\(task.estimatedCost > 0 ? " · " + Self.cost(task.estimatedCost) : "")")
                .dockFont(.machineMetadata)
                .foregroundStyle(Color.dockMetadataText)
                .lineLimit(1)
        }
    }

    // MARK: Tools & skills

    private func shareSection(title: String, detail: String, rows: [TokenUsageReport.Share], tint: Color) -> some View {
        let top = Array(rows.prefix(10))
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
                        Text("\(row.count.formatted()) · \(Self.percent(row.percentage))")
                            .dockFont(.machineMetadata)
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    meter(row.percentage / maxShare, tint: tint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockCard(padding: 14)
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
                    Text([usage.contextUsed.map(Self.tokens), usage.contextMax.map(Self.tokens)].compactMap { $0 }.joined(separator: " / ") + " · " + Self.percent(percent))
                        .dockFont(.machineMetadata)
                        .foregroundStyle(Color.dockPrimaryText)
                }
                meter(percent / 100, tint: percent >= 80 ? .dockWarningFill : .dockAccent)
            }
            Text("\(Self.tokens(usage.totalTokens)) tokens · \(Self.tokens(usage.inputTokens)) in · \(Self.tokens(usage.outputTokens)) out · \(usage.calls) calls")
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
                .dockFont(size: 12, weight: .semibold)
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
        "$" + value.formatted(.number.precision(.fractionLength(value < 10 ? 2 : 0)))
    }

    static func percent(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0))))%"
    }

    static func taskLabel(_ task: String) -> String {
        task.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// Its own view so hover selection redraws only the chart, and SwiftUI skips
/// it entirely when unrelated control-center state changes.
private struct DailyUsageChart: View {
    let daily: [TokenUsageReport.Day]
    @State private var metric: DailyMetric = .tokens
    @State private var selectedDay: Date?

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
                DockSectionLabel(title: "Daily")
                Spacer()
                HStack(spacing: 4) {
                    ForEach(DailyMetric.allCases) { choice in
                        DockTabButton(title: choice.rawValue, isSelected: metric == choice) { metric = choice }
                    }
                }
            }

            if daily.isEmpty {
                Text("No sessions in this range. Pick a longer range.")
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
            } else {
                Chart {
                    ForEach(daily) { day in
                        switch metric {
                        case .tokens:
                            BarMark(x: .value("Day", day.day, unit: .day), y: .value("Tokens", day.inputTokens))
                                .foregroundStyle(by: .value("Kind", "Input"))
                            BarMark(x: .value("Day", day.day, unit: .day), y: .value("Tokens", day.outputTokens))
                                .foregroundStyle(by: .value("Kind", "Output"))
                        case .cache:
                            BarMark(x: .value("Day", day.day, unit: .day), y: .value("Cache reads", day.cacheReadTokens))
                                .foregroundStyle(Color.dockMergedFill)
                        case .cost:
                            BarMark(x: .value("Day", day.day, unit: .day), y: .value("Cost", day.estimatedCost))
                                .foregroundStyle(Color.dockReviewFill)
                        case .calls:
                            BarMark(x: .value("Day", day.day, unit: .day), y: .value("API calls", day.apiCalls))
                                .foregroundStyle(Color.dockInfoFill)
                        }
                    }
                    if let selected {
                        RuleMark(x: .value("Day", selected.day, unit: .day))
                            .foregroundStyle(Color.dockBorderStrong)
                            .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                dayTooltip(selected)
                            }
                    }
                }
                .chartForegroundStyleScale(["Input": Color.dockInfoFill, "Output": Color.dockReviewFill.opacity(DockThemeRuntime.current == .mono || DockThemeRuntime.current == .eInk ? 0.4 : 1)])
                .chartLegend(metric == .tokens ? .visible : .hidden)
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine().foregroundStyle(Color.dockBorderLight)
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(metric == .cost ? UsageWorkspaceView.cost(number) : UsageWorkspaceView.tokens(Int(number)))
                                    .dockFont(.machineMetadata)
                            }
                        }
                    }
                }
                .chartXSelection(value: Binding(
                    get: { selectedDay },
                    // Snap to the day so hover only re-renders when the day changes.
                    set: { raw in
                        let day = raw.map { Calendar.current.startOfDay(for: $0) }
                        if day != selectedDay { selectedDay = day }
                    }
                ))
                .frame(height: 200)
                .padding(.top, 28)

                Text("Main conversation only · days bucketed by session start (UTC) · hover a bar for details")
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
            }
        }
        .dockCard(padding: 14)
    }

    private func dayTooltip(_ day: TokenUsageReport.Day) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(day.day, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                .dockFont(size: 11, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
            Group {
                Text("\(UsageWorkspaceView.tokens(day.inputTokens)) in · \(UsageWorkspaceView.tokens(day.outputTokens)) out")
                Text("\(UsageWorkspaceView.tokens(day.cacheReadTokens)) cache · \(UsageWorkspaceView.tokens(day.reasoningTokens)) reasoning")
                Text("\(day.sessions) sessions · \(day.apiCalls) calls · \(UsageWorkspaceView.cost(day.estimatedCost))")
            }
            .dockFont(.machineMetadata)
            .foregroundStyle(Color.dockSecondaryText)
        }
        .padding(8)
        .dockFloatingSurface(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous), stroke: .dockBorderLight, lineWidth: 1)
    }
}

/// Report period, freshness and refresh for Usage.
struct UsageToolbar: View {
    @ObservedObject var control: ControlCenterModel

    private var refreshState: ProjectionRefreshState? { control.refreshState(for: "token.usage") }

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
                label: refreshState?.isRefreshing == true ? "Refreshing usage" : "Refresh usage",
                isBusy: refreshState?.isRefreshing == true,
                style: DockThemePalette(theme: DockThemeRuntime.current)
            ) {
                control.refreshTokenUsage(days: UsageWorkspaceView.reportDays)
                Task { await control.refreshYearActivity() }
            }
        }
    }
}
