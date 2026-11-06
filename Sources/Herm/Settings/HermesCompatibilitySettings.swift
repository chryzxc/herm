import SwiftUI

struct HermesCompatibilitySettings: View {
    @ObservedObject private var tracker = HermesCompatibilityService.shared
    let installedVersion: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Hermes compatibility tracker").dockFont(.body, weight: .semibold)
                Spacer(minLength: 0)
                Button(tracker.isChecking ? "Checking…" : "Check upstream") {
                    Task { await tracker.check(force: true) }
                }
                .buttonStyle(.dockSecondary)
                .disabled(tracker.isChecking)
            }
            Text(status)
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let baseline = tracker.baseline {
                Text(
                    "Installed CLI: \(installedVersion ?? "unavailable") · Reviewed upstream: "
                        + "\(baseline.revision.prefix(8)) · \(baseline.reviewedAt)"
                )
                .dockFont(.metadata)
                .foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
                if !baseline.backlog.isEmpty {
                    DisclosureGroup("Known work to review (\(baseline.backlog.count))") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(baseline.backlog) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).dockFont(.body, weight: .semibold)
                                    Text(item.detail).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                                    if let url = URL(string: item.source) {
                                        Button("Upstream evidence ↗") { ExternalOpen.open(url) }
                                            .buttonStyle(.dockLink)
                                    }
                                }
                            }
                        }
                        .dockPadding(.top, 8)
                    }
                }
                if !tracker.changes.isEmpty {
                    DisclosureGroup("Contract changes and feature candidates (\(tracker.changes.count))") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(tracker.changes) { change in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(change.name).dockFont(.body, weight: .semibold)
                                    Text(
                                        change.kind == .added
                                            ? "Feature candidate" : "Contract review: \(change.kind.rawValue)"
                                    )
                                    .dockFont(.body)
                                    .foregroundStyle(Color.dockSecondaryText)
                                }
                            }
                        }
                        .dockPadding(.top, 8)
                    }
                }
                if let revision = tracker.upstreamRevision,
                    let url = URL(
                        string:
                            "https://github.com/NousResearch/hermes-agent/compare/\(baseline.revision)...\(revision)")
                {
                    Button("Review upstream changes ↗") { ExternalOpen.open(url) }
                        .buttonStyle(.dockLink)
                }
            }
            if let checkedAt = tracker.checkedAt {
                Text("Last successful check: \(HumanDateFormatting.dateAndTime(checkedAt))")
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
            }
        }
        .foregroundStyle(Color.dockPrimaryText)
        .dockFont(.body)
        .dockButtonSize(.compact)
        .task { await tracker.check() }
    }

    private var status: String {
        if let error = tracker.error {
            return tracker.checkedAt == nil ? error : "Showing the last successful result. \(error)"
        }
        guard tracker.checkedAt != nil else {
            return
                "Checks public upstream contracts against this build’s reviewed baseline. Compatibility is not yet checked."
        }
        return tracker.changes.isEmpty
            ? "No new structural contract drift detected. Known work still needs review; runtime compatibility is not certified."
            : "Upstream contracts have changed. Review the flagged changes before relying on the new runtime."
    }
}
