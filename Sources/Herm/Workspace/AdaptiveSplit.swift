import SwiftUI

/// List/detail that splits side by side when there is room and otherwise shows one
/// pane at a time (the minimized panel is ~450pt wide). `showsSecondary` is whether the
/// detail is open; set `alwaysSplitWhenWide` when wide layouts keep it open regardless.
/// `onBack` adds a back bar to the narrow detail; nil when it has its own close control.
struct AdaptiveSplit<Primary: View, Secondary: View>: View {
    var breakpoint: CGFloat = 900
    var primaryMinWidth: CGFloat = 0
    var secondaryMinWidth: CGFloat = 0
    var alwaysSplitWhenWide = false
    let showsSecondary: Bool
    var onBack: (() -> Void)?
    @ViewBuilder let primary: Primary
    @ViewBuilder let secondary: Secondary

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= breakpoint {
                HSplitView {
                    primary.frame(minWidth: primaryMinWidth, maxHeight: .infinity)
                    if showsSecondary || alwaysSplitWhenWide {
                        secondary.frame(minWidth: secondaryMinWidth, maxHeight: .infinity)
                            .overlay(alignment: .leading) { Color.dockBorder.frame(width: DockLayout.hairline) }
                    }
                }
            } else if showsSecondary {
                VStack(spacing: 0) {
                    if let onBack {
                        HStack {
                            Button(action: onBack) { DockIconLabel("BACK", icon: .caretLeft) }
                                .buttonStyle(.dockHover)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.dockAccent)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        Divider().overlay(Color.dockBorderLight)
                    }
                    secondary.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                primary.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
