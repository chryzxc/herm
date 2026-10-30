import SwiftUI

/// Shares the chat's top overlay slot so connection changes do not move the transcript or header.
struct SessionSimulatorBanner: View {
    let sessionKey: String
    let metrics: ConversationWorkspaceMetrics
    let open: (SessionSimulatorPlatform) -> Void
    @ObservedObject private var launches = SessionSimulatorLaunchStore.shared

    var body: some View {
        let connected = launches.connectedLaunches(for: sessionKey)
        if !connected.isEmpty {
            VStack(spacing: 6) {
                ForEach(connected, id: \.callID) { request in
                    HStack(spacing: 8) {
                        DockIcon(.checkCircle, size: 14, color: .dockSuccess)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(request.receipt.deviceName)
                                .dockFont(.body, weight: .semibold)
                                .lineLimit(1)
                            Text("\(request.receipt.target?.title ?? "Simulator") connected · This session")
                                .dockFont(.body)
                                .foregroundStyle(Color.dockSecondaryText)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Button("Open tab") {
                            if let platform = request.receipt.target { open(platform) }
                        }
                        .buttonStyle(.dockCompact)
                        .accessibilityLabel("Open \(request.receipt.deviceName) simulator tab")
                    }
                }
            }
            .dockPadding(.horizontal, 12)
            .dockPadding(.vertical, 8)
            .frame(maxWidth: metrics.readingWidth)
            .dockFloatingSurface(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous),
                tint: .dockSurface2, stroke: .dockBorderLight
            )
            .dockPadding(.horizontal, metrics.contentInset)
            .dockPadding(.top, 8)
        }
    }
}
