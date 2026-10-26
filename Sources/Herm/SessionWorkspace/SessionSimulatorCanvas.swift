import AppKit
import SwiftUI

struct SessionSimulatorCanvas: NSViewRepresentable {
    let capture: SessionSimulatorCapture
    let image: CGImage

    func makeNSView(context: Context) -> SimulatorCanvas {
        let view = SimulatorCanvas()
        view.focusRingType = .exterior
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel("Simulator display. Click to focus, then type or drag to interact.")
        return view
    }

    func updateNSView(_ view: SimulatorCanvas, context: Context) {
        view.capture = capture
        view.image = image
        view.needsDisplay = true
    }

    static func dismantleNSView(_ view: SimulatorCanvas, coordinator: ()) {
        view.capture?.releaseInput()
        view.capture = nil
    }

    final class SimulatorCanvas: NSView {
        weak var capture: SessionSimulatorCapture?
        var image: CGImage?
        private var dragging = false
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { capture?.inputAllowed == true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private var imageRect: CGRect {
            guard let image else { return .zero }
            return SessionSimulatorGeometry.fittedRect(
                source: CGSize(width: image.width, height: image.height), bounds: bounds)
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let image else { return }
            NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(
                in: imageRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        }

        override var focusRingMaskBounds: NSRect { imageRect }
        override func drawFocusRingMask() { NSBezierPath(rect: imageRect).fill() }

        override func resignFirstResponder() -> Bool {
            capture?.releaseInput()
            dragging = false
            return super.resignFirstResponder()
        }

        override func mouseDown(with event: NSEvent) {
            guard capture?.inputAllowed == true,
                SessionSimulatorGeometry.normalizedPoint(
                    convert(event.locationInWindow, from: nil), imageRect: imageRect) != nil
            else { return }
            window?.makeFirstResponder(self)
            dragging = true
            forward(event)
        }
        override func mouseDragged(with event: NSEvent) { if dragging { forward(event) } }
        override func mouseUp(with event: NSEvent) {
            if dragging { forward(event) }
            dragging = false
        }
        override func scrollWheel(with event: NSEvent) { forward(event) }
        override func keyDown(with event: NSEvent) { capture?.key(event) }
        override func keyUp(with event: NSEvent) { capture?.key(event) }
        override func flagsChanged(with event: NSEvent) { capture?.key(event) }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            capture?.key(event)
            return true
        }

        private func forward(_ event: NSEvent) {
            guard
                let point = SessionSimulatorGeometry.normalizedPoint(
                    convert(event.locationInWindow, from: nil), imageRect: imageRect, clamp: dragging)
            else { return }
            capture?.mouse(event, point: point)
        }
    }
}
