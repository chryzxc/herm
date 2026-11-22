import AppKit
import SwiftUI
import Testing

@testable import Herm

/// The notch window resizes in steps while the shell springs open; a step must
/// only re-place the shell, not rebuild the preview inside it.
@MainActor
@Suite("Notch morph budget", .serialized)
struct NotchMorphBudgetTests {
    final class TimedHost: NSHostingView<AnyView> {
        var passes: [Double] = []
        override func layout() {
            let start = CACurrentMediaTime()
            super.layout()
            passes.append(CACurrentMediaTime() - start)
        }
    }

    @Test(arguments: [EdgeDockSide.top, .right])
    func windowResizeStepsDoNotRebuildThePreview(side: EdgeDockSide) async throws {
        let state = EdgeNotchState()
        state.side = side
        state.tasks = (0..<6).map { index in
            EdgeNotchTask(
                id: "task-\(index)", title: "Improve the conversation workspace \(index)",
                phase: index.isMultiple(of: 2) ? .working : .finished,
                statusLabel: "Working", detail: "Running swift test for the notch preview layout", updatedAt: nil,
                isCurrent: index == 0, isStatusCurrent: true, session: nil)
        }
        let host = TimedHost(
            rootView: AnyView(EdgeNotchView(state: state, controlCenter: ControlCenterModel(), openDock: {})))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: state.panelSize), styleMask: [.borderless],
            backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(origin: .zero, size: state.panelSize))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.contentView = container
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))

        // Opening builds the preview once; that is the cost a resize step must stay well under.
        host.passes = []
        state.expanded = true
        let open = state.panelSize
        window.setFrame(NSRect(origin: .zero, size: open), display: true)
        try await Task.sleep(for: .milliseconds(700))
        let build = try #require(host.passes.max())

        var steps: [Double] = []
        for step in 1...12 {
            host.passes = []
            let inset = CGFloat(step % 2) * 6
            window.setFrame(
                NSRect(x: 0, y: 0, width: open.width - inset, height: open.height - inset), display: true)
            window.layoutIfNeeded()
            steps.append(host.passes.reduce(0, +))
        }
        let step = steps.sorted()[steps.count / 2]
        #expect(step < build / 4, "resize step \(step * 1000)ms vs preview build \(build * 1000)ms")
    }
}
