import SwiftUI

/// The desktop shell's panes share the window's SwiftUI graph. Their widths come
/// from the shell, so scrolling a pane needs no second hosting view or constraint pass.
struct DockWorkspaceSplit<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing
    let leadingFraction: CGFloat
    let minimumLeadingWidth: CGFloat
    var maximumLeadingWidth: CGFloat?
    let minimumTrailingWidth: CGFloat
    var leadingWidth: Binding<CGFloat>?
    var isLeadingCollapsed = false
    var isTrailingCollapsed = false

    @Environment(\.dockHostVisible) private var hostVisible
    @Environment(\.dockHostResizing) private var hostResizing
    @Environment(\.dockShellToolbarHeight) private var toolbarHeight
    @State private var adjustedWidth: CGFloat?
    @GestureState private var dragOffset: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let hidesTrailing = isTrailingCollapsed && !isLeadingCollapsed
            let hasDivider = !isLeadingCollapsed && !hidesTrailing
            let dividedWidth = max(0, geometry.size.width - DockLayout.hairline)
            let available = hasDivider ? dividedWidth : geometry.size.width
            let limits = leadingLimits(available: dividedWidth)
            let preferred = leadingWidth?.wrappedValue ?? adjustedWidth ?? geometry.size.width * leadingFraction
            let start = min(max(preferred, limits.lowerBound), limits.upperBound)
            let dragged = min(max(start + (dragOffset ?? 0), limits.lowerBound), limits.upperBound)
            let visibleLeadingWidth = hidesTrailing ? available : dragged
            let leadingExtent = isLeadingCollapsed ? 0 : visibleLeadingWidth
            let trailingExtent = available - leadingExtent
            HStack(spacing: 0) {
                pane(leading, width: leadingExtent, hiddenWidth: isLeadingCollapsed ? start : nil)
                if hasDivider {
                    divider(position: start, limits: limits)
                }
                pane(trailing, width: trailingExtent, hiddenWidth: hidesTrailing ? dividedWidth - start : nil)
            }
            .frame(height: geometry.size.height)
            .environment(\.dockHostResizing, hostResizing || dragOffset != nil)
            .animation(nil, value: isLeadingCollapsed)
            .animation(nil, value: isTrailingCollapsed)
        }
    }

    private func pane<Content: View>(_ content: Content, width: CGFloat, hiddenWidth: CGFloat?) -> some View {
        let collapsed = hiddenWidth != nil
        return
            content
            .environment(\.dockHostVisible, hostVisible && !collapsed)
            // Keep the content's width while hidden so its native scroll view keeps its offset.
            .frame(width: hiddenWidth ?? width)
            .frame(width: width, alignment: .leading)
            .frame(maxHeight: .infinity)
            .clipped()
            .allowsHitTesting(!collapsed)
            .accessibilityHidden(collapsed)
            .disabled(collapsed)
    }

    private func divider(position: CGFloat, limits: ClosedRange<CGFloat>) -> some View {
        Color.dockBorder
            .padding(.top, toolbarHeight)
            .frame(width: DockLayout.hairline)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .modifier(ColumnResizeCursor())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .updating($dragOffset) { value, offset, _ in offset = value.translation.width }
                            .onEnded { value in setWidth(position + value.translation.width, within: limits) }
                    )
                    .accessibilityElement()
                    .accessibilityLabel("Resize workspace panes")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: setWidth(position + 20, within: limits)
                        case .decrement: setWidth(position - 20, within: limits)
                        @unknown default: break
                        }
                    }
            }
            .zIndex(1)
    }

    private func leadingLimits(available: CGFloat) -> ClosedRange<CGFloat> {
        let minimum = min(minimumLeadingWidth, available)
        let maximum = max(minimum, available - minimumTrailingWidth)
        return minimum...max(minimum, min(maximum, maximumLeadingWidth ?? maximum))
    }

    private func setWidth(_ width: CGFloat, within limits: ClosedRange<CGFloat>) {
        let width = min(max(width, limits.lowerBound), limits.upperBound)
        if let leadingWidth {
            leadingWidth.wrappedValue = width
        } else {
            adjustedWidth = width
        }
    }
}
