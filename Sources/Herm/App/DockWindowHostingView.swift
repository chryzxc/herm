import AppKit
import SwiftUI

final class DockWindowHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
    /// Names this host in performance captures (`hostLayout.<role>`).
    var performanceRole = "root"

    var handlesConstraintsLocally = false
    private var pendingLocalConstraints = false

    override var needsUpdateConstraints: Bool {
        get { super.needsUpdateConstraints }
        set {
            // These panes are sized by NSSplitView and publish no intrinsic constraints. A scroll
            // changes their rows without changing the window's layout, so it updates locally.
            // Any other change (a section collapsing, rows inserted) can resize the scroll content
            // and must take the window's constraint pass, or rows keep stale positions and overlap.
            if newValue, handlesConstraintsLocally, window != nil, !inLiveResize, !super.needsUpdateConstraints,
                let split = superview as? NSSplitView,
                (split as? FractionPreservingSplitView)?.isDraggingDivider != true
            {
                guard !pendingLocalConstraints else { return }
                pendingLocalConstraints = true
                needsLayout = true
            } else {
                pendingLocalConstraints = false
                super.needsUpdateConstraints = newValue
            }
        }
    }

    override func updateConstraints() {
        pendingLocalConstraints = false
        super.updateConstraints()
    }

    // Nested split-pane hosts relayout whenever the root re-renders; time it so
    // performance captures show whether that cascade is behind a dropped frame.
    override func layout() {
        guard HermPerformanceRecorder.active || DockHostLayoutTiming.layoutObserver != nil else {
            layoutContent()
            return
        }
        let start = ProcessInfo.processInfo.systemUptime
        DockHostLayoutTiming.begin()
        layoutContent()
        HermPerformanceRecorder.recordWork("hostLayout", since: start)
        DockHostLayoutTiming.end(role: performanceRole, since: start)
    }

    private func layoutContent() {
        // Run the host's constraint pass before laying out SwiftUI content. It must be a real
        // subtree pass: calling updateConstraints() bare leaves SwiftUI's update unconsumed, so it
        // invalidates again every pass and an animated change (a section collapse) never lands.
        if pendingLocalConstraints {
            pendingLocalConstraints = false
            super.needsUpdateConstraints = true
            updateConstraintsForSubtreeIfNeeded()
        }
        super.layout()
    }

    private let scrollHits = DockScrollHitCache()

    override func hitTest(_ point: NSPoint) -> NSView? {
        scrollHits.hitTest(point, in: self) { super.hitTest($0) }
    }

    override func mouseMoved(with event: NSEvent) {
        guard DockHoverGate.admit(event, in: self, replay: { [weak self] in self?.replayHover($0) }) else { return }
        super.mouseMoved(with: event)
    }

    private func replayHover(_ event: NSEvent) {
        super.mouseMoved(with: event)
    }
}

/// During a scroll, deliver the latest move through the deepest host once per window after
/// the scroll settles. Otherwise each host takes each move immediately, once.
@MainActor
final class DockHoverGate {
    private static let windows = NSMapTable<NSWindow, DockHoverGate>(
        keyOptions: .weakMemory, valueOptions: .strongMemory)
    private static let seen = NSMapTable<NSView, NSEvent>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private struct Move {
        let event: NSEvent
        let depth: Int
        let replay: (NSEvent) -> Void
    }
    private var pending: Move?
    private var delivered: NSEvent?
    private var isReplaying = false
    private(set) var deferred: Task<Void, Never>?

    static func admit(_ event: NSEvent, in host: NSView, replay: @escaping (NSEvent) -> Void) -> Bool {
        guard let window = host.window else { return true }
        let gate: DockHoverGate
        if let existing = windows.object(forKey: window) {
            gate = existing
        } else {
            gate = DockHoverGate()
            windows.setObject(gate, forKey: window)
        }
        // Outside a scroll each host handles a move once, in the same event as AppKit's own
        // cursor updates. Deferring it lets text views set the I-beam or link hand, then SwiftUI
        // hover resets the cursor a frame later, so the pointer flickers on every move.
        if gate.deferred == nil, !DockScrollActivity.isScrolling(at: ProcessInfo.processInfo.systemUptime) {
            if let last = seen.object(forKey: host), isSameMove(last, event) { return false }
            seen.setObject(event, forKey: host)
            return true
        }
        var depth = 0
        var parent = host.superview
        while let view = parent {
            depth += 1
            parent = view.superview
        }
        return gate.admit(event, depth: depth) { [weak host, weak window] move in
            guard let window, host?.window === window, let content = window.contentView,
                content.bounds.contains(content.convert(window.mouseLocationOutsideOfEventStream, from: nil))
            else { return }
            replay(move)
        }
    }

    func admit(_ event: NSEvent, depth: Int, replay: @escaping (NSEvent) -> Void) -> Bool {
        if let delivered, Self.isSameMove(delivered, event) { return isReplaying }
        if let pending {
            guard event.timestamp >= pending.event.timestamp,
                !Self.isSameMove(pending.event, event) || depth > pending.depth
            else { return false }
        }
        pending = Move(event: event, depth: depth, replay: replay)
        guard deferred == nil else { return false }
        deferred = Task { @MainActor [weak self] in
            var remaining = 1.0 / 120
            repeat {
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled, self != nil else { return }
                remaining = DockScrollActivity.remainingSettle(at: ProcessInfo.processInfo.systemUptime)
            } while remaining > 0
            guard let self, let move = self.pending else { return }
            self.deferred = nil
            self.pending = nil
            self.delivered = move.event
            // Super may forward this move through ancestor responders.
            self.isReplaying = true
            move.replay(move.event)
            self.isReplaying = false
        }
        return false
    }

    private static func isSameMove(_ lhs: NSEvent, _ rhs: NSEvent) -> Bool {
        lhs.timestamp == rhs.timestamp && lhs.locationInWindow == rhs.locationInWindow
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
    private static var lastInputTimestamp: TimeInterval = -.infinity
    private static let monitor: Any? = NSEvent.addLocalMonitorForEvents(
        matching: [
            .scrollWheel, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged,
            .rightMouseDragged, .otherMouseDragged,
        ]
    ) { event in
        let isScrollWheel = event.type == .scrollWheel
        MainActor.assumeIsolated {
            let now = ProcessInfo.processInfo.systemUptime
            lastInputTimestamp = now
            if isScrollWheel { recordScroll(at: now) }
        }
        return event
    }

    static func recordScroll(at timestamp: TimeInterval) {
        lastScrollTimestamp = timestamp
        HermPerformanceRecorder.mark("scrollWheel")
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

    static func waitForInputIdle() async -> Bool {
        while !Task.isCancelled {
            let remaining = remainingInputSettle()
            guard remaining > 0 else { return true }
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return false }
        }
        return false
    }

    static func remainingInputSettle() -> TimeInterval {
        _ = monitor
        return max(0, lastInputTimestamp + settleInterval - ProcessInfo.processInfo.systemUptime)
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
    host.handlesConstraintsLocally = true
    // Panes draw their own title row; inheriting the window's titlebar safe
    // area would push every pane down a second 52pt.
    host.safeAreaRegions = []
    return host
}
