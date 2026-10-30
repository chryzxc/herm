import SwiftUI

/// List/detail that splits side by side when there is room and otherwise shows one
/// pane at a time (the minimized panel is ~450pt wide). `showsSecondary` is whether the
/// detail is open; set `alwaysSplitWhenWide` when wide layouts keep it open regardless.
/// `onBack` adds a back bar to the narrow detail; nil when it has its own close control.
struct AdaptiveSplit<Primary: View, Secondary: View>: View {
    var breakpoint: CGFloat = 900
    var primaryMinWidth: CGFloat = 0
    var primaryIdealWidth: CGFloat? = nil
    var primaryMaxWidth: CGFloat? = nil
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
            let wide = geo.size.width >= breakpoint
            let primaryHidden = wide ? hidesPrimary : showsSecondary
            let secondaryHidden = wide ? !(showsSecondary || alwaysSplitWhenWide || hidesPrimary) : !showsSecondary
            FullscreenPanelSplitView(
                leading: primary,
                trailing: VStack(spacing: 0) {
                    if let onBack {
                        if wide, !alwaysSplitWhenWide, !hidesPrimary {
                            closeBar(action: onBack)
                        } else if !wide {
                            navigationBar("BACK", icon: .caretLeft, action: onBack)
                        }
                    }
                    secondary.frame(maxWidth: .infinity, maxHeight: .infinity)
                },
                leadingFraction: nil,
                initialLeadingWidth: primaryIdealWidth ?? max(primaryMinWidth, 390),
                minimumLeadingWidth: primaryMinWidth,
                maximumLeadingWidth: primaryMaxWidth,
                minimumTrailingWidth: secondaryMinWidth,
                isTrailingCollapsed: secondaryHidden,
                isLeadingCollapsed: primaryHidden
            )
        }
    }

    /// Trailing icon-only close, aligned with the title-row controls rather than a labelled button.
    private func closeBar(action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button(action: action) {
                DockIcon(.x, size: DockLayout.toolbarIconSize, color: .dockSecondaryText)
                    .frame(width: DockLayout.iconControlSize, height: DockLayout.iconControlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .help("Close details")
            .accessibilityLabel("Close details")
        }
        .dockPadding(.horizontal, 8)
        .dockPadding(.top, DockWindowChrome.titleRowHeight - DockLayout.iconControlSize - 8)
        .dockPadding(.bottom, 2)
    }

    private func navigationBar(_ title: String, icon: Ph, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: action) { DockIconLabel(title, icon: icon) }
                    .buttonStyle(.dockCompact)
                    .dockFont(.metadata, weight: .semibold)
                    .foregroundStyle(Color.dockAccent)
                Spacer()
            }
            .dockPadding(.horizontal, 12)
            .dockPadding(.vertical, 8)
            Divider().overlay(Color.dockBorderLight)
        }
    }
}
