import AppKit
import SwiftUI

/// Vertical edge autoscroll shared by Herm's dragged reorder lists: a pointer held inside a
/// viewport's edge band keeps the list moving, so a row can travel through rows that were
/// offscreen when the drag started.
enum DockEdgeAutoscroll {
    /// How close to a viewport edge a held pointer must stay to keep scrolling.
    static let band: CGFloat = 28
    /// Furthest one step may scroll, so a held pointer cannot skip a row.
    static let step: CGFloat = 10

    enum Direction: Equatable {
        case towardStart
        case towardEnd
    }

    /// The scroll a pointer asks for, or nil outside the viewport or between the bands.
    /// A viewport too short for two bands never scrolls on its own.
    static func direction(pointer: CGPoint, viewport: CGRect) -> Direction? {
        guard viewport.height > band * 2, viewport.contains(pointer) else { return nil }
        if pointer.y < viewport.minY + band { return .towardStart }
        if pointer.y > viewport.maxY - band { return .towardEnd }
        return nil
    }

    /// Scroll one step within AppKit's clip limits and return the actual vertical origin change.
    @MainActor
    static func scrollStep(in scrollView: NSScrollView, toward direction: Direction) -> CGFloat {
        guard scrollView.documentView != nil else { return 0 }
        let clip = scrollView.contentView
        let before = clip.bounds
        // A flipped clip starts at a smaller origin; an unflipped one at a larger origin.
        let sign: CGFloat = clip.isFlipped == (direction == .towardStart) ? -1 : 1
        let proposed = before.offsetBy(dx: 0, dy: sign * step)
        let next = clip.constrainBoundsRect(proposed).minY
        guard next != before.minY else { return 0 }
        clip.scroll(to: NSPoint(x: before.minX, y: next))
        let delta = clip.bounds.minY - before.minY
        if delta != 0 { scrollView.reflectScrolledClipView(clip) }
        return delta
    }

    /// Content travel in row coordinates since `startOrigin`; negative goes toward the start.
    static func travel(from startOrigin: CGFloat, to origin: CGFloat, isFlipped: Bool) -> CGFloat {
        (origin - startOrigin) * (isFlipped ? 1 : -1)
    }
}

/// The clip a dragged reorder list scrolls, held weakly so a dismissed popover releases it.
@MainActor
final class DockScrollTarget {
    private(set) weak var scrollView: NSScrollView?
    private(set) var attachment = UUID()
    private weak var owner: NSView?

    /// A replacement probe in the same clip takes ownership without interrupting the drag.
    @discardableResult
    func attach(_ scrollView: NSScrollView, from probe: NSView) -> Bool {
        let replaced = self.scrollView != nil && self.scrollView !== scrollView
        if self.scrollView !== scrollView { attachment = UUID() }
        self.scrollView = scrollView
        owner = probe
        return replaced
    }

    func detach(from probe: NSView) -> Bool {
        guard owner === probe else { return false }
        owner = nil
        scrollView = nil
        attachment = UUID()
        return true
    }
}

/// Binds the nearest enclosing `NSScrollView` from inside its document, so a list scrolls
/// itself rather than a scroll view found elsewhere in the window.
@MainActor
struct DockScrollViewProbe: NSViewRepresentable {
    let target: DockScrollTarget
    let onDetach: @MainActor () -> Void

    func makeNSView(context: Context) -> Probe { Probe(target: target, onDetach: onDetach) }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.onDetach = onDetach }
    static func dismantleNSView(_ nsView: Probe, coordinator: ()) { nsView.dismantle() }

    final class Probe: NSView {
        let target: DockScrollTarget
        var onDetach: @MainActor () -> Void
        private var isDismantled = false

        init(target: DockScrollTarget, onDetach: @escaping @MainActor () -> Void) {
            self.target = target
            self.onDetach = onDetach
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            bind()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            bind()
        }

        private func bind() {
            guard !isDismantled else { return }
            if window != nil, let scrollView = enclosingScrollView {
                if target.attach(scrollView, from: self) { onDetach() }
            } else if target.detach(from: self) {
                onDetach()
            }
        }

        func dismantle() {
            isDismantled = true
            if target.detach(from: self) { onDetach() }
            onDetach = {}
        }
    }
}
