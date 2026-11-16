import AppKit
import SwiftUI

final class DockWindowHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }

    // Nested split-pane hosts relayout whenever the root re-renders; time it so
    // performance captures show whether that cascade is behind a dropped frame.
    override func layout() {
        let start = ProcessInfo.processInfo.systemUptime
        super.layout()
        HermPerformanceRecorder.recordWork("hostLayout", since: start)
    }
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
