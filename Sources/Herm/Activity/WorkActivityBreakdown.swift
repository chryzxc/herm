import SwiftUI

/// Counts remain separate: a merged PR may contain commits already listed here.
struct WorkActivityBreakdown: View {
    let activity: WorkRange

    var body: some View {
        let rows: [(String, Int, Color)] = [
            ("Merged PRs", activity.pullRequests.count, .dockMergedFill),
            ("Completed tasks", activity.tasks.count, .dockReviewFill),
            ("Commits", activity.commits.count, .dockReviewFill),
            ("Sessions", activity.sessions.count, .dockInfoFill),
            ("Automation runs", activity.runs.count, .dockMergedFill),
        ]
        let peak = max(1, rows.map { $0.1 }.max() ?? 1)
        VStack(alignment: .leading, spacing: 12) {
            DockSectionLabel(title: "Recorded work")
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.0).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                        Spacer(minLength: 12)
                        Text(row.1.formatted()).dockFont(.body, weight: .semibold)
                            .monospacedDigit().foregroundStyle(Color.dockPrimaryText)
                    }
                    GeometryReader { geometry in
                        Capsule().fill(Color.dockBorderLight)
                            .overlay(alignment: .leading) {
                                Capsule().fill(row.2)
                                    .frame(width: geometry.size.width * Double(row.1) / Double(peak))
                            }
                    }
                    .frame(height: 4)
                    .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            }
            Text("Counts overlap; sessions are dated by latest activity. Hours show events, not time worked.")
                .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
            if !activity.runs.isEmpty {
                let failed = activity.runs.filter(\.isFailure).count
                Text("\(failed) of \(activity.runs.count) automation runs reported a failure.")
                    .dockFont(.body)
                    .foregroundStyle(failed > 0 ? Color.dockWarning : Color.dockSecondaryText)
            }
        }
        .dockCard(padding: 14)
    }
}
