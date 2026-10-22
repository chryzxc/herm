import SwiftUI

/// A year of daily activity, one square per day, oldest week on the left.
struct UsageHeatmap: View {
    let daily: [TokenUsageReport.Day]
    @State private var metric: Metric = .tokens
    @State private var selected: Date?

    enum Metric: String, CaseIterable, Identifiable {
        case tokens = "Tokens", cost = "Cost", calls = "API calls"
        var id: String { rawValue }
        func value(_ day: TokenUsageReport.Day) -> Double {
            switch self {
            case .tokens: Double(day.inputTokens + day.outputTokens)
            case .cost: day.estimatedCost
            case .calls: Double(day.apiCalls)
            }
        }
    }

    private static let weeks = 53
    private static let gap = 0.2 // fraction of a cell left as spacing
    private static let labelRows = 1.4

    private var calendar: Calendar { .current }

    /// First day of the leftmost column.
    private var start: Date {
        let today = calendar.startOfDay(for: Date())
        let week = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        return calendar.date(byAdding: .day, value: -7 * (Self.weeks - 1), to: week) ?? week
    }

    var body: some View {
        let start = start
        let values = Dictionary(daily.map { (calendar.startOfDay(for: $0.day), $0) }, uniquingKeysWith: { $1 })
        let peak = values.values.map(metric.value).max() ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                DockSectionLabel(title: "Yearly activity")
                Spacer()
                HStack(spacing: 4) {
                    ForEach(Metric.allCases) { choice in
                        DockTabButton(title: choice.rawValue, isSelected: metric == choice) { metric = choice }
                    }
                }
            }

            Color.clear
                .aspectRatio(Double(Self.weeks) / (7 + Self.labelRows), contentMode: .fit)
                .overlay { canvas(start: start, values: values, peak: peak) }
                .overlay { popoverAnchor(start: start, values: values) }

            Text("Main conversation only · days bucketed by session start · hover a square for details")
                .font(DockTypography.metadata)
                .foregroundStyle(Color.dockMetadataText)
        }
        .dockCard(padding: 14)
    }

    private func canvas(start: Date, values: [Date: TokenUsageReport.Day], peak: Double) -> some View {
        Canvas { context, size in
            let pitch = size.width / Double(Self.weeks)
            let cell = pitch * (1 - Self.gap)
            let top = pitch * Self.labelRows
            let today = calendar.startOfDay(for: Date())
            var lastMonth = -1
            for week in 0..<Self.weeks {
                for row in 0..<7 {
                    guard let date = calendar.date(byAdding: .day, value: week * 7 + row, to: start), date <= today else { continue }
                    if row == 0, calendar.component(.month, from: date) != lastMonth {
                        lastMonth = calendar.component(.month, from: date)
                        context.draw(
                            Text(date, format: .dateTime.month(.abbreviated)).font(DockTypography.machineMetadata).foregroundStyle(Color.dockMetadataText),
                            at: CGPoint(x: Double(week) * pitch, y: 0), anchor: .topLeading)
                    }
                    let rect = CGRect(x: Double(week) * pitch, y: top + Double(row) * pitch, width: cell, height: cell)
                    context.fill(Path(roundedRect: rect, cornerRadius: cell * 0.25), with: .color(color(values[date].map(metric.value) ?? 0, peak: peak)))
                    if date == selected {
                        context.stroke(Path(roundedRect: rect, cornerRadius: cell * 0.25), with: .color(Color.dockPrimaryText), lineWidth: 1)
                    }
                }
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): selected = day(at: point)
            case .ended: selected = nil
            }
        }
        .overlay { GeometryReader { geo in Color.clear.onAppear { width = geo.size.width }.onChange(of: geo.size.width) { _, new in width = new } } }
    }

    @State private var width: Double = 0

    private func day(at point: CGPoint) -> Date? {
        guard width > 0 else { return nil }
        let pitch = width / Double(Self.weeks)
        let week = Int(point.x / pitch)
        guard point.x >= 0, point.y >= pitch * Self.labelRows else { return nil }
        let row = Int((point.y - pitch * Self.labelRows) / pitch)
        guard (0..<Self.weeks).contains(week), (0..<7).contains(row),
              let date = calendar.date(byAdding: .day, value: week * 7 + row, to: start),
              date <= calendar.startOfDay(for: Date()) else { return nil }
        return date
    }

    private func color(_ value: Double, peak: Double) -> Color {
        guard value > 0, peak > 0 else { return Color.dockBorderLight }
        let tint: Color = switch metric {
        case .tokens, .calls: .dockInfoFill
        case .cost: .dockReviewFill
        }
        // Four steps of the metric's color, brightest at the peak.
        let level = min(3, Int(value / peak * 4))
        return tint.opacity(0.3 + 0.23 * Double(level))
    }

    /// A clear square over the hovered cell that hosts the stats popover.
    @ViewBuilder
    private func popoverAnchor(start: Date, values: [Date: TokenUsageReport.Day]) -> some View {
        if let selected, width > 0 {
            let offset = calendar.dateComponents([.day], from: start, to: selected).day ?? 0
            let pitch = width / Double(Self.weeks)
            let cell = pitch * (1 - Self.gap)
            Color.clear
                .frame(width: cell, height: cell)
                .popover(isPresented: .constant(true), arrowEdge: .bottom) { stats(selected, values[selected]) }
                .position(x: Double(offset / 7) * pitch + cell / 2, y: pitch * Self.labelRows + Double(offset % 7) * pitch + cell / 2)
                .id(selected)
                .allowsHitTesting(false)
        }
    }

    private func stats(_ date: Date, _ day: TokenUsageReport.Day?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            if let day {
                Group {
                    Text("\(UsageWorkspaceView.tokens(day.inputTokens)) in · \(UsageWorkspaceView.tokens(day.outputTokens)) out")
                    Text("\(UsageWorkspaceView.tokens(day.cacheReadTokens)) cache · \(UsageWorkspaceView.tokens(day.reasoningTokens)) reasoning")
                    Text("\(day.sessions) sessions · \(day.apiCalls) calls · \(UsageWorkspaceView.cost(day.estimatedCost))")
                }
                .font(DockTypography.machineMetadata)
                .foregroundStyle(Color.dockSecondaryText)
            } else {
                Text("No activity")
                    .font(DockTypography.machineMetadata)
                    .foregroundStyle(Color.dockSecondaryText)
            }
        }
        .fixedSize()
        .padding(10)
    }
}
