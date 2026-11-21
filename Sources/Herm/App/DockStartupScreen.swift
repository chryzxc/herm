import SwiftUI

struct DockStartupScreen: View {
    let usesWindowChrome: Bool

    var body: some View {
        DockExpandedPage(title: "Herm", subtitle: "Opening workspace…") {
            DockLoadingIndicator(size: 42)
                .frame(width: 116, height: 104)
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
