import AppKit
import SwiftUI

/// Where the plan canvas sits in its pane: `view = pan + canvas × zoom`. The map pans by
/// dragging and zooms with the scroll wheel or a pinch, so it has no scroll bars.
struct SpecMapViewport: Equatable {
    static let minZoom: CGFloat = 0.25
    static let maxZoom: CGFloat = 2
    /// The part of the plan that always stays in view, so it can't be dragged away.
    static let keepVisible: CGFloat = 80

    var zoom: CGFloat = 1
    var pan: CGSize = .zero

    var canZoomIn: Bool { zoom < Self.maxZoom - 0.001 }
    var canZoomOut: Bool { zoom > Self.minZoom + 0.001 }

    /// Scales by `factor` within the limits, keeping the canvas point under `anchor` in place.
    func zoomed(by factor: CGFloat, at anchor: CGPoint) -> SpecMapViewport {
        guard factor.isFinite, factor > 0 else { return self }
        let next = min(max(zoom * factor, Self.minZoom), Self.maxZoom)
        let ratio = next / zoom
        return SpecMapViewport(
            zoom: next,
            pan: CGSize(
                width: anchor.x - (anchor.x - pan.width) * ratio,
                height: anchor.y - (anchor.y - pan.height) * ratio))
    }

    /// Keeps at least `keepVisible` points of the plan inside the pane on each axis.
    func clamped(content: CGSize, in viewport: CGSize) -> SpecMapViewport {
        let width = content.width * zoom
        let height = content.height * zoom
        let keepX = min(Self.keepVisible, width, viewport.width)
        let keepY = min(Self.keepVisible, height, viewport.height)
        return SpecMapViewport(
            zoom: zoom,
            pan: CGSize(
                width: min(max(pan.width, keepX - width), viewport.width - keepX),
                height: min(max(pan.height, keepY - height), viewport.height - keepY)))
    }

    /// The smallest pan that shows `rect` (canvas space) inside the pane less `insets`.
    /// A rect larger than the visible area aligns its leading/top edge.
    func revealing(_ rect: CGRect, in viewport: CGSize, insets: EdgeInsets) -> SpecMapViewport {
        let shown = CGRect(
            x: pan.width + rect.minX * zoom, y: pan.height + rect.minY * zoom,
            width: rect.width * zoom, height: rect.height * zoom)
        let visible = CGRect(
            x: insets.leading, y: insets.top,
            width: max(0, viewport.width - insets.leading - insets.trailing),
            height: max(0, viewport.height - insets.top - insets.bottom))
        func shift(_ low: CGFloat, _ high: CGFloat, _ min: CGFloat, _ max: CGFloat) -> CGFloat {
            if high - low > max - min || low < min { return min - low }
            if high > max { return max - high }
            return 0
        }
        return SpecMapViewport(
            zoom: zoom,
            pan: CGSize(
                width: pan.width + shift(shown.minX, shown.maxX, visible.minX, visible.maxX),
                height: pan.height + shift(shown.minY, shown.maxY, visible.minY, visible.maxY)))
    }

    /// Zoom factor for one wheel or trackpad scroll step; up zooms in.
    static func wheelFactor(deltaY: CGFloat, isPrecise: Bool) -> CGFloat {
        exp(deltaY * (isPrecise ? 0.01 : 0.08))
    }
}

/// Pan and zoom have separate observers so moving the canvas does not update its controls or graph.
@MainActor
@Observable
final class SpecMapViewportState {
    private(set) var pan: CGSize
    private(set) var zoom: CGFloat
    @ObservationIgnored var dragStart: CGSize?

    init(_ viewport: SpecMapViewport) {
        pan = viewport.pan
        zoom = viewport.zoom
    }

    var value: SpecMapViewport {
        get { SpecMapViewport(zoom: zoom, pan: pan) }
        set {
            if newValue.pan != pan { pan = newValue.pan }
            if newValue.zoom != zoom { zoom = newValue.zoom }
        }
    }
}

struct SpecMapCanvasTransform: ViewModifier {
    let viewport: SpecMapViewportState

    func body(content: Content) -> some View {
        content.scaleEffect(viewport.zoom, anchor: .topLeading).offset(viewport.pan)
    }
}

/// Routes scroll-wheel and pinch events over the map to zoom, at the pointer.
/// A local monitor because SwiftUI on macOS 14 has no scroll-wheel input for plain views.
struct SpecMapZoomInput: NSViewRepresentable {
    let onZoom: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> ZoomInputView {
        let view = ZoomInputView()
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ view: ZoomInputView, context: Context) { view.onZoom = onZoom }

    final class ZoomInputView: NSView {
        var onZoom: ((CGFloat, CGPoint) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                // Read the event here; only plain values cross into the main-actor check.
                let isMagnify = event.type == .magnify
                let factor =
                    isMagnify
                    ? 1 + event.magnification
                    : SpecMapViewport.wheelFactor(
                        deltaY: event.scrollingDeltaY, isPrecise: event.hasPreciseScrollingDeltas)
                let location = event.locationInWindow
                let windowNumber = event.windowNumber
                let handled = MainActor.assumeIsolated {
                    self?.zoom(factor: factor, at: location, windowNumber: windowNumber) ?? false
                }
                return handled ? nil : event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }

        private func zoom(factor: CGFloat, at location: NSPoint, windowNumber: Int) -> Bool {
            guard let window, window.windowNumber == windowNumber, !isHiddenOrHasHiddenAncestor else { return false }
            let point = convert(location, from: nil)
            guard bounds.contains(point) else { return false }
            // A scroller inside the map (long notes in an open card) keeps its own scrolling.
            if let hit = window.contentView?.hitTest(location), let inner = hit.enclosingScrollView,
                inner !== enclosingScrollView
            {
                return false
            }
            if factor != 1 { onZoom?(factor, point) }
            return true
        }
    }
}

/// The plan's drafting surface: a dot grid fixed to the canvas, so it travels with a drag and
/// tightens with zoom, showing the map moved. Dots keep one screen size; at low zoom every other
/// row drops out so the grid never turns to noise.
struct SpecMapGrid: View {
    let viewport: SpecMapViewportState

    static let spacing: CGFloat = 24
    static let minScreenSpacing: CGFloat = 14
    static let dot: CGFloat = 1.6

    /// Screen spacing for a zoom, doubled until it is at least `minScreenSpacing`.
    static func screenSpacing(zoom: CGFloat) -> CGFloat {
        var step = spacing * max(zoom, SpecMapViewport.minZoom)
        while step < minScreenSpacing { step *= 2 }
        return step
    }

    /// Wraps the offset within one grid cell, including drags past the origin.
    static func offset(for pan: CGFloat, spacing: CGFloat) -> CGFloat {
        let remainder = pan.truncatingRemainder(dividingBy: spacing)
        return remainder < 0 ? remainder : remainder - spacing
    }

    var body: some View {
        let step = Self.screenSpacing(zoom: viewport.zoom)
        let pan = viewport.pan
        GeometryReader { geometry in
            Dots(step: step, color: .dockBorder)
                .equatable()
                .frame(width: geometry.size.width + 2 * step, height: geometry.size.height + 2 * step)
                .offset(x: Self.offset(for: pan.width, spacing: step), y: Self.offset(for: pan.height, spacing: step))
                .transaction { $0.animation = nil }
        }
        .clipped()
        .background(Color.dockCanvas)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Dots: View, Equatable {
        let step: CGFloat
        let color: Color

        var body: some View {
            Canvas { context, size in
                var dots = Path()
                var y: CGFloat = 0
                while y <= size.height {
                    var x: CGFloat = 0
                    while x <= size.width {
                        dots.addEllipse(
                            in: CGRect(
                                x: x - SpecMapGrid.dot / 2, y: y - SpecMapGrid.dot / 2,
                                width: SpecMapGrid.dot, height: SpecMapGrid.dot))
                        x += step
                    }
                    y += step
                }
                context.fill(dots, with: .color(color))
            }
        }
    }
}
