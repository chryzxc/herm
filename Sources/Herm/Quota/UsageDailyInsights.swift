import Charts
import SwiftUI

/// Daily buckets cover conversation accounting, independently of background totals.
struct UsageDailyRollup: Equatable {
    struct Point: Identifiable, Equatable {
        let date: Date
        let cost: Double
        let cumulativeCost: Double
        var id: Date { date }
    }
    let points: [Point]
    let total: Double
    let peak: Point?
    var average: Double? { points.isEmpty ? nil : total / Double(points.count) }

    init(daily: [TokenUsageReport.Day]) {
        // A repeated bucket is a replacement, matching the heatmap's semantics.
        let rows = Dictionary(daily.map { ($0.day, $0) }, uniquingKeysWith: { $1 }).values.sorted { $0.day < $1.day }
        var sum = 0.0
        points = rows.map { row in
            sum += row.estimatedCost
            return Point(date: row.day, cost: row.estimatedCost, cumulativeCost: sum)
        }
        total = sum
        peak = points.max { ($0.cost, $1.date) < ($1.cost, $0.date) }
    }
}

struct UsageDailyInsights: View {
    let daily: [TokenUsageReport.Day]

    var body: some View {
        let rollup = UsageDailyRollup(daily: daily)
        VStack(alignment: .leading, spacing: 12) {
            DockSectionLabel(title: "How spend accumulated")
            if let average = rollup.average, let peak = rollup.peak {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)], spacing: 12) {
                    metric("Recorded daily cost", UsageWorkspaceView.cost(rollup.total))
                    metric("Average / reported day", UsageWorkspaceView.cost(average))
                    metric(
                        "Highest day · \(peak.date.formatted(.dateTime.month(.abbreviated).day()))",
                        UsageWorkspaceView.cost(peak.cost))
                }
                Chart(rollup.points) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Cumulative USD", point.cumulativeCost))
                        .foregroundStyle(Color.dockReviewFill)
                    PointMark(x: .value("Date", point.date), y: .value("Cumulative USD", point.cumulativeCost))
                        .foregroundStyle(Color.dockReviewFill).symbolSize(12)
                        .accessibilityLabel(point.date.formatted(.dateTime.month(.wide).day()))
                        .accessibilityValue(UsageWorkspaceView.cost(point.cumulativeCost))
                }
                .chartYAxisLabel("USD")
                .frame(height: 110)
                Text(
                    "\(rollup.points.count) reported day buckets · conversation only. Missing dates are not treated as zero; background costs are excluded."
                )
                .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No daily cost records in this report.")
                    .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            }
        }
        .dockCard(padding: 14)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).dockFont(.body, weight: .semibold).monospacedDigit()
                .foregroundStyle(Color.dockPrimaryText)
            Text(label).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
        }
        .accessibilityElement(children: .combine)
    }
}
