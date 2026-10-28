import SwiftUI

struct SessionDashboardCard: View {
    let row: SessionDashboardRow
    let isCurrent: Bool
    let isLoadingSession: Bool
    let request: AttentionItem?
    let activity: LatestActivityItem?
    let profileID: String?
    let client: HermesRPCClientProtocol?
    let onRespond: () -> Void
    @StateObject private var content = SessionDashboardCardContent()
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(row.session.displayTitle).dockFont(.body, weight: .semibold)
                    .lineLimit(2).frame(height: 34, alignment: .topLeading)
                    .help(row.session.displayTitle)
                Spacer(minLength: 8)
                if isCurrent, let state = row.status.activityState {
                    DockActivityIndicator(state: state, size: 12, unreadDot: true)
                }
            }
            if let project = row.project {
                DockIconLabel(project, icon: .folder).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
            }
            HStack {
                if !isCurrent {
                    Text("Status not current")
                } else if row.status != .none {
                    Text(row.status == .unreadComplete ? "Ready to review" : row.status.label)
                }
                Spacer(minLength: 4)
                if let date = row.session.lastUpdatedAt { Text(date, style: .relative) }
            }
            .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
            Color.dockBorderLight.frame(height: DockLayout.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let request {
                        Text(request.title).dockFont(.body, weight: .semibold)
                        Text(request.detail).dockFont(.body).textSelection(.enabled)
                    } else if row.status == .working, let activity {
                        Text(activity.activityName).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    }
                    if let preview = content.text ?? SessionDashboardCardContent.preview(row.session.preview) {
                        MarkdownMessageView(markdown: preview, bodySize: DockTypography.size(.body))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if request == nil {
                        Text("No saved update yet.").dockFont(.body).foregroundStyle(Color.dockMetadataText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 130)
            HStack(spacing: 8) {
                Text(content.error != nil ? "Update unavailable" : content.text == nil ? "Preview" : "Latest reply")
                    .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                    .help(content.error ?? "Most recent saved reply from this session")
                if content.loading { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
                Button(request == nil ? "Respond" : "Review request", action: onRespond)
                    .buttonStyle(.dockSecondary)
                    .disabled(isLoadingSession)
                    .accessibilityLabel("Respond to \(row.session.displayTitle)")
            }
        }
        .foregroundStyle(Color.dockPrimaryText)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovered ? Color.dockSurface2 : Color.dockSurface))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(
                hovered ? Color.dockBorderStrong : Color.dockBorderLight, lineWidth: DockLayout.hairline)
        }
        .onHover { hovered = $0 }
        .offset(y: DockMotion.isEnabled(reduceMotion: reduceMotion) && hovered ? -2 : 0)
        .animation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.16), value: hovered)
        .animation(DockMotion.animation(reduceMotion: reduceMotion), value: row.status)
        .task(id: "\(row.session.lastUpdatedAt?.timeIntervalSince1970 ?? 0)-\(isCurrent)") {
            guard let client, isCurrent else { return }
            await content.load(session: row.session, profileID: profileID, client: client)
        }
    }

}
