import SwiftUI

/// The top island always wears the black Island skin so it blends with the
/// camera notch; leaving the top restores the skin the user had before.
enum EdgeIslandTheme {
    static let previousThemeKey = "hermes.notch.theme-before-island"

    @MainActor static func apply(side: EdgeDockSide, store: DockThemeStore, defaults: UserDefaults) {
        if side == .top {
            guard store.selectedThemeID != .island else { return }
            defaults.set(store.selectedThemeID.rawValue, forKey: previousThemeKey)
            store.selectedThemeID = .island
        } else if store.selectedThemeID == .island,
                  let previous = defaults.string(forKey: previousThemeKey).flatMap(DockThemeID.init(rawValue:)) {
            defaults.removeObject(forKey: previousThemeKey)
            store.selectedThemeID = previous
        }
    }
}

/// The collapsed top island: two ears flank the camera housing, which stays
/// dark and empty. The shell fill lives in EdgeNotchView so it can grow into the preview.
struct EdgeIslandRail: View {
    @AppStorage(NotchDisplayStyle.defaultsKey) private var displayStyle: NotchDisplayStyle = .dots
    let activity: EdgeNotchActivity
    let notchWidth: CGFloat
    let ear: CGFloat
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                // Extras (finished/blocked) left, the primary status right.
                EdgeNotchStatusIndicator(activity: activity, style: displayStyle, axis: .horizontal, part: .badges)
                    .frame(width: ear, height: height)
                Color.clear.frame(width: notchWidth, height: height)
                EdgeNotchStatusIndicator(activity: activity, style: displayStyle, axis: .horizontal, part: .primary)
                    .frame(width: ear, height: height)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
    }
}
