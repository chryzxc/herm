import AppKit
import SwiftUI

final class DockWindowHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor
func splitPaneHost() -> NSHostingView<AnyView> {
    let host = DockWindowHostingView(rootView: AnyView(EmptyView()))
    // The split view places panes by frame; don't publish SwiftUI's
    // intrinsic/min/max size as constraints for the outer layout to solve.
    host.sizingOptions = []
    // Panes draw their own title row; inheriting the window's titlebar safe
    // area would push every pane down a second 52pt.
    host.safeAreaRegions = []
    return host
}
