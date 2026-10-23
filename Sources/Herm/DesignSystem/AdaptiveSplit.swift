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
    /// Wide layouts only: the sidebar toggle hid the primary column.
    var hidesPrimary = false
    let showsSecondary: Bool
    var onBack: (() -> Void)?
    @ViewBuilder let primary: Primary
    @ViewBuilder let secondary: Secondary

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= breakpoint, hidesPrimary {
                secondary.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if geo.size.width >= breakpoint {
                // HSplitView hosts each pane in its own AppKit view, which re-adds the
                // window's titlebar safe area. Herm lays out its own title row, so drop it.
                HSplitView {
                    primary.frame(minWidth: primaryMinWidth, maxHeight: .infinity)
                        .ignoresSafeArea(.container, edges: .top)
                    if showsSecondary || alwaysSplitWhenWide {
                        secondary.frame(minWidth: secondaryMinWidth, maxHeight: .infinity)
                            .overlay(alignment: .leading) { Color.dockBorder.frame(width: DockLayout.hairline) }
                            .ignoresSafeArea(.container, edges: .top)
                    }
                }
            } else if showsSecondary {
                VStack(spacing: 0) {
                    if let onBack {
                        HStack {
                            Button(action: onBack) { DockIconLabel("BACK", icon: .caretLeft) }
                                .buttonStyle(.dockCompact)
                                .dockFont(.metadata, weight: .semibold)
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
