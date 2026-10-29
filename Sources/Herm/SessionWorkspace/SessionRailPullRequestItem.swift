import SwiftUI

struct SessionRailPullRequestItem: View {
    let reference: GitHubItemReference
    let record: PullRequestRecord?
    let failure: String?
    let onViewPullRequest: (GitHubItemReference) async -> Bool
    @State private var opening = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                opening = true
                failed = false
                Task {
                    failed = !(await onViewPullRequest(reference))
                    opening = false
                }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: 8) {
                        DockIcon(
                            record?.presentationIcon ?? .gitPullRequest, size: 14,
                            color: record?.presentationColor ?? .dockSecondaryText)
                        Text(opening ? "Opening…" : record?.title ?? "Pull request #\(reference.number)")
                            .multilineTextAlignment(.leading).lineLimit(2)
                        Spacer(minLength: 0)
                        DockIcon(.arrowUpRight, size: 14, color: .dockSecondaryText)
                    }
                    HStack(spacing: 6) {
                        Text("#\(String(reference.number))").foregroundStyle(Color.dockMetadataText)
                        if let record { Text(record.readinessLabel).foregroundStyle(record.readinessColor) }
                    }.dockFont(.metadata).padding(.leading, 22)
                }
            }
            .buttonStyle(.dockHover).disabled(opening)
            .help("Open pull request in a new tab")
            .accessibilityIdentifier("session-rail.pr.\(reference.number)")
            VStack(alignment: .leading, spacing: 6) {
                if let record {
                    Text(record.repository.id).foregroundStyle(Color.dockMetadataText)
                    Text("\(record.headBranch) → \(record.baseBranch)")
                        .foregroundStyle(Color.dockSecondaryText).textSelection(.enabled)
                    Text("By \(record.author)").foregroundStyle(Color.dockSecondaryText)
                    if let additions = record.additions, let deletions = record.deletions {
                        HStack(spacing: 6) {
                            Text("+\(additions.formatted())").foregroundStyle(Color.dockSuccess)
                            Text("−\(deletions.formatted())").foregroundStyle(Color.dockDestructive)
                        }.monospacedDigit()
                    }
                    if let warning = record.detailWarning { Text(warning).foregroundStyle(Color.dockWarning) }
                }
                if let failure {
                    Text(record == nil ? "Details unavailable. \(failure)" : "Last fetched details. \(failure)")
                        .foregroundStyle(Color.dockWarning)
                } else if record == nil {
                    Text("Loading details…").foregroundStyle(Color.dockSecondaryText)
                }
                if failed {
                    Text("Could not open pull request. Refresh and try again.").foregroundStyle(Color.dockWarning)
                }
            }.padding(.leading, 22)
        }
        .dockFont(.body)
    }
}
