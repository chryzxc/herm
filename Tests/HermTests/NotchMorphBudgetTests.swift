#if DEBUG
    import AppKit
    import SwiftUI
    import Testing

    @testable import Herm

    /// The notch window resizes in steps while the shell springs open; a step must
    /// only re-place the shell, not rebuild the preview inside it.
    @MainActor
    @Suite("Notch morph budget", .serialized)
    struct NotchMorphBudgetTests {
        @Test(arguments: [EdgeDockSide.top, .right])
        func windowResizeStepsDoNotRebuildThePreview(side: EdgeDockSide) async throws {
            let state = EdgeNotchState()
            state.side = side
            state.expanded = true
            state.tasks = (0..<6).map { index in
                EdgeNotchTask(
                    id: "task-\(index)", title: "Improve the conversation workspace \(index)",
                    phase: index.isMultiple(of: 2) ? .working : .finished,
                    statusLabel: "Working", detail: "Running swift test for the notch preview layout", updatedAt: nil,
                    isCurrent: index == 0, isStatusCurrent: true, session: nil)
            }
            var previewEvaluations = 0
            let host = NSHostingView(
                rootView: EdgeNotchView(
                    state: state, controlCenter: ControlCenterModel(),
                    onPreviewEvaluation: { previewEvaluations += 1 }, openDock: {}))
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

            try #require(previewEvaluations > 0, "The expanded preview must be mounted before measuring resize work.")
            let mountedEvaluations = previewEvaluations
            let open = state.panelSize
            for step in 1...12 {
                let inset = CGFloat(step % 2) * 6
                let size = NSSize(width: open.width - inset, height: open.height - inset)
                window.setFrame(NSRect(origin: .zero, size: size), display: true)
                window.layoutIfNeeded()
                await Task.yield()
                #expect(host.frame.size == size)
            }
            #expect(previewEvaluations == mountedEvaluations)
        }
    }
#endif
