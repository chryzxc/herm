import AppKit
import Combine
import SwiftUI

struct SessionSimulatorCanvas: NSViewRepresentable {
    let capture: SessionSimulatorCapture
    var platform: SessionSimulatorPlatform = .ios
    var annotate: (String) -> Bool = { _ in false }
    @ObservedObject var diagnostics: SessionSimulatorDiagnostics

    func makeNSView(context: Context) -> SimulatorCanvas {
        let view = SimulatorCanvas(frame: .zero)
        view.focusRingType = .exterior
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel("Simulator display. Click to focus, then type or drag to interact.")
        return view
    }

    func updateNSView(_ view: SimulatorCanvas, context: Context) {
        view.platform = platform
        view.annotate = annotate
        if diagnostics.snapshot == nil { view.closeAnnotation() }
        view.capture = capture
        view.diagnostics = diagnostics
        view.observe(capture.frames)
        view.show(diagnostics.snapshot ?? capture.image, frozen: diagnostics.snapshot != nil)
        view.needsDisplay = true
    }

    static func dismantleNSView(_ view: SimulatorCanvas, coordinator: ()) {
        view.closeAnnotation()
        view.capture?.releaseInput()
        view.observe(nil)
        view.capture = nil
    }

    final class SimulatorCanvas: NSView {
        var platform: SessionSimulatorPlatform = .ios
        var annotate: (String) -> Bool = { _ in false }
        private var annotationPopover: NSPopover?
        weak var capture: SessionSimulatorCapture?
        private var image: CGImage?
        private let screen = NSView()
        private weak var frames: SessionSimulatorCapture.Frames?
        private var frameObservation: AnyCancellable?
        private var frozen = false
        weak var diagnostics: SessionSimulatorDiagnostics?
        private var selectionStart: CGPoint?
        private var highlight: CGRect?
        private var dragging = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            let pixels = CALayer()
            pixels.contentsGravity = .resize
            pixels.masksToBounds = true
            pixels.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull()]
            screen.layer = pixels
            screen.wantsLayer = true
            addSubview(screen)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

        func observe(_ frames: SessionSimulatorCapture.Frames?) {
            guard self.frames !== frames else { return }
            self.frames = frames
            frameObservation = frames?.updates.sink { [weak self] image in
                guard let self, !frozen else { return }
                show(image, frozen: false)
            }
        }

        func show(_ next: CGImage?, frozen: Bool) {
            guard image !== next || self.frozen != frozen else { return }
            let layoutChanged = image?.width != next?.width || image?.height != next?.height || self.frozen != frozen
            image = next
            self.frozen = frozen
            screen.isHidden = frozen || next == nil
            screen.layer?.contents = frozen ? nil : next
            if layoutChanged {
                needsLayout = true
                needsDisplay = true
            }
        }

        override func layout() {
            super.layout()
            let rect = imageRect
            screen.frame = rect
            screen.layer?.cornerRadius = SessionSimulatorGeometry.screenRadius(rect: rect, platform: platform)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                    owner: self))
        }

        override func mouseMoved(with event: NSEvent) {
            guard diagnostics?.snapshot != nil else { return }
            let point = SessionSimulatorGeometry.normalizedPoint(
                convert(event.locationInWindow, from: nil), imageRect: imageRect)
            highlight = point.flatMap { diagnostics?.element(at: $0)?.rect }
            toolTip = point.flatMap { diagnostics?.element(at: $0)?.description }
            needsDisplay = true
        }

        override func mouseExited(with event: NSEvent) {
            highlight = nil
            needsDisplay = true
        }
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { capture?.inputAllowed == true && capture?.isPreviewing != true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private var imageRect: CGRect {
            guard let image else { return .zero }
            return SessionSimulatorGeometry.fittedRect(
                source: CGSize(width: image.width, height: image.height), bounds: bounds.insetBy(dx: 10, dy: 10))
        }

        private var screenPath: NSBezierPath {
            let radius = SessionSimulatorGeometry.screenRadius(rect: imageRect, platform: platform)
            return NSBezierPath(roundedRect: imageRect, xRadius: radius, yRadius: radius)
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let image else { return }
            let radius = SessionSimulatorGeometry.screenRadius(rect: imageRect, platform: platform)
            let bezel = NSBezierPath(
                roundedRect: imageRect.insetBy(dx: -5, dy: -5), xRadius: radius + 5, yRadius: radius + 5)
            NSColor(Color.dockDeviceCanvas).setFill()
            bezel.fill()
            NSColor(Color.dockSecondaryText).withAlphaComponent(0.6).setStroke()
            bezel.lineWidth = 1
            bezel.stroke()
            guard frozen else { return }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: imageRect, xRadius: radius, yRadius: radius).addClip()
            NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(
                in: imageRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            drawSelection()
            NSGraphicsContext.restoreGraphicsState()
        }

        private func drawSelection() {
            guard diagnostics?.snapshot != nil, let rect = highlight ?? diagnostics?.selection else { return }
            let display = CGRect(
                x: imageRect.minX + rect.minX * imageRect.width,
                y: imageRect.minY + rect.minY * imageRect.height,
                width: rect.width * imageRect.width, height: rect.height * imageRect.height)
            NSColor(Color.dockAccent).setStroke()
            let path = NSBezierPath(rect: display.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
        }

        override var focusRingMaskBounds: NSRect { imageRect }
        override func drawFocusRingMask() { screenPath.fill() }

        override func resignFirstResponder() -> Bool {
            capture?.releaseInput()
            selectionStart = nil
            dragging = false
            return super.resignFirstResponder()
        }

        override func mouseDown(with event: NSEvent) {
            guard capture?.inputAllowed == true,
                screenPath.contains(convert(event.locationInWindow, from: nil)),
                SessionSimulatorGeometry.normalizedPoint(
                    convert(event.locationInWindow, from: nil), imageRect: imageRect) != nil
            else { return }
            window?.makeFirstResponder(self)
            if diagnostics?.snapshot != nil {
                selectionStart = SessionSimulatorGeometry.normalizedPoint(
                    convert(event.locationInWindow, from: nil), imageRect: imageRect)
                return
            }
            dragging = true
            forward(event)
        }
        override func mouseDragged(with event: NSEvent) {
            if let start = selectionStart,
                let end = SessionSimulatorGeometry.normalizedPoint(
                    convert(event.locationInWindow, from: nil), imageRect: imageRect, clamp: true)
            {
                diagnostics?.select(from: start, to: end)
                highlight = nil
                needsDisplay = true
            } else if dragging {
                forward(event)
            }
        }
        override func mouseUp(with event: NSEvent) {
            if let start = selectionStart,
                let end = SessionSimulatorGeometry.normalizedPoint(
                    convert(event.locationInWindow, from: nil), imageRect: imageRect, clamp: true)
            {
                diagnostics?.select(from: start, to: end)
                selectionStart = nil
                highlight = nil
                needsDisplay = true
                showAnnotation()
                return
            }
            if dragging { forward(event) }
            dragging = false
        }
        override func scrollWheel(with event: NSEvent) { forward(event) }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53, diagnostics?.snapshot != nil {
                closeAnnotation()
                diagnostics?.resume()
            } else {
                capture?.key(event)
            }
        }
        override func keyUp(with event: NSEvent) { capture?.key(event) }
        override func flagsChanged(with event: NSEvent) { capture?.key(event) }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard capture?.inputAllowed == true, window?.firstResponder === self else { return false }
            keyDown(with: event)
            return true
        }

        func closeAnnotation() {
            annotationPopover?.close()
            annotationPopover = nil
        }

        private func showAnnotation() {
            closeAnnotation()
            guard let selection = diagnostics?.selection else { return }
            let popover = NSPopover()
            popover.behavior = .transient
            let label = diagnostics?.selectedElement?.label ?? "Screenshot region"
            popover.contentViewController = NSHostingController(
                rootView: SessionSimulatorAnnotation(
                    label: label.isEmpty ? "Selected element" : label,
                    cancel: { [weak self] in
                        self?.diagnostics?.selection = nil
                        self?.diagnostics?.selectedElement = nil
                        self?.closeAnnotation()
                    },
                    submit: { [weak self] comment in
                        guard let self, self.annotate(comment) else { return false }
                        self.closeAnnotation()
                        self.diagnostics?.resume()
                        return true
                    }
                ).dockPreferredTextSize())
            annotationPopover = popover
            let anchor = CGRect(
                x: imageRect.minX + selection.midX * imageRect.width,
                y: imageRect.minY + selection.maxY * imageRect.height, width: 1, height: 1)
            popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
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
