import AppKit

/// Keeps deferred notch resizes tied to the placement that requested them.
@MainActor
final class EdgePanelFrameTransition {
    private let panel: NSPanel
    private var generation = 0
    private var targetFrame: NSRect?
    private var fitTask: DispatchWorkItem?

    init(panel: NSPanel) { self.panel = panel }

    func cancel() {
        generation &+= 1
        fitTask?.cancel()
        fitTask = nil
        targetFrame = nil
    }

    func position(to target: NSRect, animated: Bool) {
        // Activity refreshes must not restart the settling deadline for the same size.
        if animated, targetFrame == target { return }
        cancel()
        targetFrame = target
        guard panel.frame != target else { return }
        guard animated, panel.frame.intersects(target) else {
            panel.setFrame(target, display: true)
            return
        }
        let cover = panel.frame.union(target)
        // Defer even the grow operation: SwiftUI may currently be laying out.
        schedule(cover, after: 0)
        if cover != target { schedule(target, after: EdgeDockMotion.morphSettle) }
    }

    private func schedule(_ frame: NSRect, after delay: TimeInterval) {
        let generation = generation
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation else { return }
            if delay > 0 { self.fitTask = nil }
            // The SwiftUI shell supplies the motion inside this cover. Applying the
            // window frame once keeps AppKit from relaying out the host on every tick.
            if self.panel.frame != frame { self.panel.setFrame(frame, display: true) }
        }
        if delay > 0 { fitTask = task }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }
}
