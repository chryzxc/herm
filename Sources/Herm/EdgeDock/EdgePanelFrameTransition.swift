import AppKit

/// Keeps deferred notch resizes tied to the placement that requested them.
@MainActor
final class EdgePanelFrameTransition {
    private let panel: NSPanel
    private var generation = 0
    private var targetFrame: NSRect?
    private var appliedFrame: NSRect?
    private var fitTask: DispatchWorkItem?

    init(panel: NSPanel) { self.panel = panel }

    func cancel() {
        generation &+= 1
        fitTask?.cancel()
        fitTask = nil
        targetFrame = nil
        appliedFrame = panel.frame
    }

    func position(to target: NSRect, animated: Bool) {
        // Activity refreshes must not restart the settling deadline for the same size.
        if animated, targetFrame == target { return }
        cancel()
        targetFrame = target
        guard panel.frame != target else { return }
        guard animated, panel.frame.intersects(target) else {
            appliedFrame = target
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
            self.appliedFrame = frame
            guard self.panel.frame != frame else { return }
            // Direct resizing mid-spring can trigger an NSHostingView constraint loop.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = EdgeDockMotion.windowResize
                self.panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                // An already-running animation can outlive cancellation. Reconcile
                // to the newest applied frame, never the old captured destination.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let latest = self.appliedFrame, self.panel.frame != latest else { return }
                    self.panel.setFrame(latest, display: true)
                }
            }
        }
        if delay > 0 { fitTask = task }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }
}
