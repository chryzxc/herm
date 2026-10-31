import AppKit
import ObjectiveC

/// Thin, track-less overlay scroller used by every scroll view in the app.
final class DockScroller: NSScroller {
    private static let thickness: CGFloat = 8

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style)
        -> CGFloat
    {
        thickness
    }

    private var scrollerIsVertical: Bool { bounds.height >= bounds.width }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        // Only the knob's length comes from AppKit; its thickness is centred in our own bounds so it never clips.
        let knob = rect(for: .knob)
        let rect =
            scrollerIsVertical
            ? NSRect(x: bounds.midX - 3, y: knob.minY + 1, width: 6, height: max(knob.height - 2, 0))
            : NSRect(x: knob.minX + 1, y: bounds.midY - 3, width: max(knob.width - 2, 0), height: 6)
        guard rect.width > 0, rect.height > 0 else { return }
        // labelColor follows the window appearance, so every skin gets a readable knob.
        NSColor.labelColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
    }
}

extension NSScrollView {
    /// Swaps the system scrollers for `DockScroller` as scroll views enter a window.
    @MainActor static let installDockScrollers: Void = {
        let selector = #selector(NSScrollView.viewDidMoveToWindow)
        let dockSelector = #selector(NSScrollView.dockViewDidMoveToWindow)
        guard
            let original = class_getInstanceMethod(NSScrollView.self, selector),
            let dock = class_getInstanceMethod(NSScrollView.self, dockSelector)
        else { return }
        // viewDidMoveToWindow is inherited from NSView; exchanging it in place would swap it for every view.
        // Add it to NSScrollView first so only scroll views are affected.
        if class_addMethod(
            NSScrollView.self, selector, method_getImplementation(dock), method_getTypeEncoding(dock))
        {
            class_replaceMethod(
                NSScrollView.self, dockSelector, method_getImplementation(original),
                method_getTypeEncoding(original))
        } else {
            method_exchangeImplementations(original, dock)
        }
    }()

    @objc fileprivate func dockViewDidMoveToWindow() {
        dockViewDidMoveToWindow()  // original implementation after the exchange
        guard window != nil else { return }
        scrollerStyle = .overlay
        if hasVerticalScroller, !(verticalScroller is DockScroller) {
            verticalScroller = DockScroller()
        }
        if hasHorizontalScroller, !(horizontalScroller is DockScroller) {
            horizontalScroller = DockScroller()
        }
    }
}
