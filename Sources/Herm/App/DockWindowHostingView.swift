import AppKit
import SwiftUI

final class DockWindowHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
    /// Names this host in performance captures (`hostLayout.<role>`).
    var performanceRole = "root"

    /// Split panes set this. See `needsUpdateConstraints`.
    var containsConstraintInvalidation = false

    /// A pane host publishes no constraints (`sizingOptions = []`), yet SwiftUI
    /// still marks it `needsUpdateConstraints` on every scroll commit, and AppKit
    /// forwards that up to the SwiftUI view hosting the split, which re-lays out
    /// the whole window. A pane turns the request into its own layout pass,
    /// which renders the same graph update without informing its ancestors.
    override var needsUpdateConstraints: Bool {
        get { super.needsUpdateConstraints }
        set {
            if newValue, containsConstraintInvalidation {
                needsLayout = true
                return
            }
            super.needsUpdateConstraints = newValue
        }
    }

    // Nested split-pane hosts relayout whenever the root re-renders; time it so
    // performance captures show whether that cascade is behind a dropped frame.
    override func layout() {
        let start = ProcessInfo.processInfo.systemUptime
        DockHostLayoutTiming.begin()
        super.layout()
        HermPerformanceRecorder.recordWork("hostLayout", since: start)
        DockHostLayoutTiming.end(role: performanceRole, since: start)
    }

    private let hoverGate = DockHoverGate()
    private let scrollHits = DockScrollHitCache()

    override func hitTest(_ point: NSPoint) -> NSView? {
        scrollHits.hitTest(point, in: self) { super.hitTest($0) }
    }

    override func mouseMoved(with event: NSEvent) {
        guard hoverGate.admit(event, replay: { [weak self] in self?.replayHover($0) }) else { return }
        super.mouseMoved(with: event)
    }

    private func replayHover(_ event: NSEvent) {
        super.mouseMoved(with: event)
    }
}

/// Every mouse move re-hit-tests a host's whole SwiftUI tree for hover.
/// Nested hosts receive each move more than once (their own tracking areas,
/// then an inner host forwarding it up the responder chain), and moves that
/// arrive mid-scroll only chase content sliding under a still pointer. The
/// gate admits each move once, holds moves during a scroll, and replays the
/// last held one after the scroll settles so hover ends up correct.
@MainActor
final class DockHoverGate {
    private var lastAdmitted: (timestamp: TimeInterval, location: NSPoint)?
    private var pendingEvent: NSEvent?
    private var pendingReplay: ((NSEvent) -> Void)?
    private var deferred: Task<Void, Never>?

    func admit(_ event: NSEvent, replay: @escaping (NSEvent) -> Void) -> Bool {
        if let last = lastAdmitted, last.timestamp == event.timestamp, last.location == event.locationInWindow {
            return false
        }
        lastAdmitted = (event.timestamp, event.locationInWindow)
        deferred?.cancel()
        guard DockScrollActivity.isScrolling(at: event.timestamp) else {
            pendingEvent = nil
            pendingReplay = nil
            return true
        }
        pendingEvent = event
        pendingReplay = replay
        deferred = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(DockScrollActivity.settleInterval))
            guard !Task.isCancelled, let self, let event = self.pendingEvent, let replay = self.pendingReplay else {
                return
            }
            self.pendingEvent = nil
            self.pendingReplay = nil
            replay(event)
        }
        return false
    }
}

/// AppKit hit-tests the whole view tree for every scroll-wheel event and,
/// as content slides under the pointer, again for cursor updates each frame.
/// Through nested SwiftUI hosts that costs more than the scroll itself. The
/// pointer stays put while scrolling, so the target found when the gesture
/// began is reused until it begins again, the pointer moves, a click or key
/// arrives, the scroll settles, or the view leaves the host.
@MainActor
final class DockScrollHitCache {
    private var cached: (point: NSPoint, view: NSView?)?

    func hitTest(_ point: NSPoint, in host: NSView, compute: (NSPoint) -> NSView?) -> NSView? {
        let event = NSApp.currentEvent
        let scrolling = DockScrollActivity.isScrolling(at: ProcessInfo.processInfo.systemUptime)
        if scrolling, Self.canReuse(during: event), let cached, cached.point == point,
            cached.view.map({ $0.window === host.window && $0.isDescendant(of: host) }) ?? true
        {
            return cached.view
        }
        let view = compute(point)
        cached = scrolling ? (point, view) : nil
        return view
    }

    /// Clicks and keys always hit-test fresh; a new scroll gesture re-targets.
    static func canReuse(during event: NSEvent?) -> Bool {
        guard let event else { return true }
        switch event.type {
        case .scrollWheel:
            return !event.phase.contains(.began) && !event.phase.contains(.mayBegin)
        case .cursorUpdate, .mouseMoved, .mouseEntered, .mouseExited, .appKitDefined, .systemDefined,
            .applicationDefined, .periodic:
            return true
        default:
            return false
        }
    }
}

/// Remembers when the last scroll-wheel (or momentum) event arrived so pointer
/// hover and cursor work can sit out an active scroll.
@MainActor
enum DockScrollActivity {
    static let settleInterval: TimeInterval = 0.15
    private static var lastScrollTimestamp: TimeInterval = -.infinity
    private static let monitor: Any? = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
        let timestamp = event.timestamp
        MainActor.assumeIsolated {
            lastScrollTimestamp = timestamp
            HermPerformanceRecorder.mark("scrollWheel")
        }
        return event
    }

    static func isScrolling(at timestamp: TimeInterval) -> Bool {
        _ = monitor
        return timestamp - lastScrollTimestamp < settleInterval
    }

    /// Seconds until a live scroll counts as settled; 0 when none is live.
    static func remainingSettle(at timestamp: TimeInterval) -> TimeInterval {
        _ = monitor
        return max(0, lastScrollTimestamp + settleInterval - timestamp)
    }
}

/// `hostLayout` counts a nested host inside its parent's time too. This
/// records each host's own (self) time per role, so a capture names the pane
/// that re-lays out every frame instead of one overlapping total.
@MainActor
enum DockHostLayoutTiming {
    private static var childSeconds: [TimeInterval] = []
    /// Receives each host's role as it finishes a layout pass. The layout
    /// budget tests use it to count layouts per pane; it is nil in the app.
    static var layoutObserver: ((String) -> Void)?

    static func begin() { childSeconds.append(0) }

    /// Returns the host's self time: its layout minus nested hosts' layouts.
    @discardableResult
    static func end(
        role: String, since start: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval {
        let total = now - start
        let nested = childSeconds.popLast() ?? 0
        if !childSeconds.isEmpty { childSeconds[childSeconds.count - 1] += total }
        let own = max(0, total - nested)
        HermPerformanceRecorder.recordWork("hostLayout.\(role)", milliseconds: own * 1000)
        layoutObserver?(role)
        return own
    }
}

@MainActor
func splitPaneHost(role: String = "pane") -> NSHostingView<AnyView> {
    let host = DockWindowHostingView(rootView: AnyView(EmptyView()))
    host.performanceRole = role
    // The split view places panes by frame; don't publish SwiftUI's
    // intrinsic/min/max size as constraints for the outer layout to solve.
    host.sizingOptions = []
    // Panes draw their own title row; inheriting the window's titlebar safe
    // area would push every pane down a second 52pt.
    host.safeAreaRegions = []
    host.containsConstraintInvalidation = true
    return host
}
