import SwiftUI

struct WorkCommitRow: View {
    let commit: WorkCommit
    let timestamp: String
    let tint: Color
    @Environment(\.dockWorkspaceScale) private var scale

    var body: some View {
        HStack(spacing: 8) {
            DockIcon(.gitCommit).dockFont(.body).foregroundStyle(tint).frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(commit.subject).dockFont(.rowTitle).foregroundStyle(Color.dockPrimaryText).lineLimit(2)
                (Text(commit.repo + " · ") + DockCommitPresentation.text(commit.hash, length: nil, scale: scale)
                    + Text(" · " + timestamp))
                    .dockFont(.metadata).foregroundStyle(Color.dockMetadataText).lineLimit(2)
            }
            Spacer(minLength: 8)
        }
        .dockPadding(.vertical, 5)
        .contentShape(Rectangle())
    }
}
