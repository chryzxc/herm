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

    /// The scroll a pointer at `pointerY` asks for, or nil between the bands.
    /// A viewport too short for two bands never scrolls on its own.
    static func direction(pointerY: CGFloat, viewport: CGRect) -> Direction? {
        guard viewport.height > band * 2 else { return nil }
        if pointerY < viewport.minY + band { return .towardStart }
        if pointerY > viewport.maxY - band { return .towardEnd }
        return nil
    }

    /// The clip origin one step toward `direction` may reach, clamped to the document's
    /// travel so the list stops at its first and last row.
    static func origin(
        from origin: CGFloat, direction: Direction, clip: CGRect, documentHeight: CGFloat, isFlipped: Bool
    ) -> CGFloat {
        let travel = max(documentHeight - clip.height, 0)
        let limits = isFlipped ? 0...travel : -travel...0
        // A flipped clip starts at a smaller origin; an unflipped one at a larger origin.
        let sign: CGFloat = isFlipped == (direction == .towardStart) ? -1 : 1
        return min(max(origin + sign * step, limits.lowerBound), limits.upperBound)
    }

    /// Content travel toward the list's start since `startOrigin`; negative travels back down.
    static func travel(from startOrigin: CGFloat, to origin: CGFloat, isFlipped: Bool) -> CGFloat {
        (origin - startOrigin) * (isFlipped ? 1 : -1)
    }

    /// Pointer displacement in row slots: the drag's own translation plus the travel the list
    /// made under it, so a held pointer keeps advancing the dragged row.
    static func displacement(
        translation: CGFloat, startOrigin: CGFloat, origin: CGFloat, isFlipped: Bool
    ) -> CGFloat {
        translation + travel(from: startOrigin, to: origin, isFlipped: isFlipped)
    }
}

/// The clip a dragged reorder list scrolls, held weakly so a dismissed popover releases it.
@MainActor
final class DockScrollTarget {
    weak var scrollView: NSScrollView?
}

/// Binds the nearest enclosing `NSScrollView` from inside its document, so a list scrolls
/// itself rather than a scroll view found elsewhere in the window.
struct DockScrollViewProbe: NSViewRepresentable {
    let target: DockScrollTarget

    func makeNSView(context: Context) -> NSView { Probe(target: target) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        let target: DockScrollTarget

        init(target: DockScrollTarget) {
            self.target = target
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
            target.scrollView = window == nil ? nil : enclosingScrollView
        }
    }
}
