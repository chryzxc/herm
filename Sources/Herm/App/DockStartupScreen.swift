import SwiftUI

struct DockStartupScreen: View {
    @DockChromeTheme private var theme
    let usesWindowChrome: Bool

    var body: some View {
        DockExpandedPage(title: "Herm", subtitle: "") {
            VStack(spacing: 12) {
                DockLayerMotion(
                    kind: .startupLogo, color: DockAccentColor.brandIvory, glow: DockAccentColor.brandMint,
                    rim: DockAccentColor.brandGraphite, paused: !theme.style.animates
                )
                .frame(width: 140, height: 140)
                .accessibilityHidden(true)
                Text("Opening workspace…")
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockSecondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
