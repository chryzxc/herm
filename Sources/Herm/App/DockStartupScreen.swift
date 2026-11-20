import SwiftUI

struct DockStartupScreen: View {
    let usesWindowChrome: Bool

    var body: some View {
        DockExpandedPage(title: "Herm", subtitle: "Opening workspace…") {
            ZStack {
                DockLayerMotion(kind: .startupSignal, color: .dockAccent)
                    .frame(maxWidth: 342)
                    .frame(height: 112)
                DockAppIcon()
                    .frame(width: 112, height: 112)
            }
            .dockPadding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
        }
        .environment(
            \.dockTitleRow,
            usesWindowChrome
                ? DockTitleRow(
                    height: DockWindowChrome.titleRowHeight,
                    leadingClearance: DockWindowChrome.fullWidthTrafficLightClearance)
                : nil)
    }
}
