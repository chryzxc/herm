import SwiftUI

struct DockBuildBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var build: HermBuildInfo = .current
    var includesCommit = false

    var body: some View {
        if let label = build.badge(includesCommit: includesCommit) {
            let tint: DockAccentColor = build.channel == .nightly ? .blue : .violet
            HStack(spacing: 4) {
                DockIcon(build.channel == .nightly ? .moonStars : .terminal, size: 11, color: tint.color)
                    .scaleEffect(appeared || !DockMotion.isEnabled(reduceMotion: reduceMotion) ? 1 : 0.65)
                    .opacity(appeared || !DockMotion.isEnabled(reduceMotion: reduceMotion) ? 1 : 0.5)
                Text(label)
                    .dockFont(.metadata, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
            }
            .dockPadding(.horizontal, 2)
            .dockPill(tint: tint.fill)
            .overlay(Capsule().stroke(tint.color.opacity(0.3), lineWidth: DockLayout.hairline))
            .fixedSize()
            .accessibilityLabel("Herm \(label) build")
            .onAppear {
                withAnimation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.35)) {
                    appeared = true
                }
            }
        }
    }
}

/// Reserves the badge's space in a title row and reports where it sits. The real badge
/// is drawn once by `dockBuildBadgeOverlay`, which places it on the leftmost visible slot.
struct DockBuildBadgeSlot: View {
    @Environment(\.dockHostVisible) private var hostVisible

    var body: some View {
        DockBuildBadge().hidden().accessibilityHidden(true)
            .anchorPreference(key: DockBuildBadgeSlotKey.self, value: .bounds) { hostVisible ? [$0] : [] }
    }
}

private struct DockBuildBadgeSlotKey: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

/// The sidebar toggle and history buttons beside the traffic lights, after the build badge's
/// slot. Every leftmost title row uses this so the badge and icons keep one rhythm on every page.
struct DockTitleLeadingControls<Toggle: View>: View {
    var showsBadge = true
    var showsHistory = true
    @ViewBuilder let toggle: () -> Toggle

    /// Badge edge to the toggle's 28pt box; with the glyph's own inset it matches the glyph-to-glyph gap.
    static var badgeGap: CGFloat { 6 }

    var body: some View {
        HStack(spacing: 0) {
            if showsBadge {
                DockBuildBadgeSlot()
                    .dockPadding(.trailing, HermBuildInfo.current.badge() == nil ? 0 : Self.badgeGap)
            }
            toggle()
            if showsHistory { DockHistoryButtons() }
        }
    }
}

extension View {
    /// Draws the build badge once at the window's leading title row, above every page. It sits
    /// exactly on the leftmost visible `DockBuildBadgeSlot`, so each page's own spacing holds.
    func dockBuildBadgeOverlay() -> some View {
        overlayPreferenceValue(DockBuildBadgeSlotKey.self, alignment: .topLeading) { anchors in
            GeometryReader { proxy in
                if let slot = anchors.map({ proxy[$0] }).min(by: { $0.minX < $1.minX }) {
                    DockBuildBadge()
                        .frame(height: slot.height)
                        .offset(x: slot.minX, y: slot.minY)
                } else {
                    DockBuildBadge()
                        .frame(height: DockWindowChrome.titleRowHeight)
                        .padding(.leading, 52 + DockWindowChrome.sidebarToggleLeading)  // rail + toggle inset
                }
            }
            .allowsHitTesting(false)
        }
    }
}
