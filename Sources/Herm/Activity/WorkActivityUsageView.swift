import SwiftUI

/// Usage is a reported daily projection; missing days are never treated as free usage.
struct WorkActivityUsageView: View {
    let activity: WorkRange

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(Color.dockBorderLight)
            DockSectionLabel(title: "Usage")
            if activity.hasUsage {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)],
                    alignment: .leading, spacing: 16
                ) {
                    metric("Input tokens", UsageWorkspaceView.tokens(activity.inputTokens))
                    metric("Output tokens", UsageWorkspaceView.tokens(activity.outputTokens))
                    metric("Cache read tokens", UsageWorkspaceView.tokens(activity.cacheReadTokens))
                    metric("Reasoning tokens", UsageWorkspaceView.tokens(activity.reasoningTokens))
                    metric("API calls", activity.apiCalls.formatted())
                    metric("Reported sessions", activity.usageSessions.formatted())
                    metric("Estimated cost", UsageWorkspaceView.cost(activity.cost))
                }
                Text(
                    "Days with reported usage: \(activity.usageDays). Missing days are not counted as zero. Reasoning may overlap output tokens."
                )
                .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No usage reported for this selection.")
                    .dockFont(.body).foregroundStyle(Color.dockMetadataText)
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).dockFont(.body, weight: .semibold)
                .monospacedDigit().foregroundStyle(Color.dockPrimaryText)
            Text(title).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}
