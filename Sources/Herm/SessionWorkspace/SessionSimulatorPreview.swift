import AppKit
import SceneKit
import SwiftUI

/// An actual rounded solid with live pixels on its front face. Input never reaches the device.
struct SessionSimulatorPreview: NSViewRepresentable {
    let image: CGImage
    let platform: SessionSimulatorPlatform
    let reset: Int
    var exit: () -> Void = {}

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView(frame: .zero)
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel(
            "3D device preview. Drag to orbit, scroll to zoom, double-click to reset. Arrow keys rotate. Device input is paused."
        )
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.exit = exit
        view.update(image: image, platform: platform, reset: reset)
    }

    static func dismantleNSView(_ view: PreviewView, coordinator: ()) {
        view.scene = nil
    }

    final class PreviewView: SCNView {
        var exit: () -> Void = {}
        private let deviceNode = SCNNode()
        private let cameraNode = SCNNode()
        private let screenMaterial = SCNMaterial()
        private var imageSize = CGSize.zero
        private var lastReset: Int?
        private var yaw: Float = 0
        private var pitch: Float = 0
        private var zoom: Double = 1
        private var lastPoint: CGPoint?

        override init(frame: NSRect, options: [String: Any]? = nil) {
            super.init(frame: frame, options: options)
            backgroundColor = NSColor(Color.dockDeviceCanvas)
            antialiasingMode = .multisampling4X
            rendersContinuously = false
            autoenablesDefaultLighting = true
            let scene = SCNScene()
            scene.rootNode.addChildNode(deviceNode)
            cameraNode.camera = SCNCamera()
            cameraNode.camera?.usesOrthographicProjection = true
            cameraNode.position = SCNVector3(0, 0, 10)
            scene.rootNode.addChildNode(cameraNode)
            self.scene = scene
            pointOfView = cameraNode
            screenMaterial.lightingModel = .constant
            screenMaterial.isDoubleSided = false
            screenMaterial.diffuse.magnificationFilter = .linear
            screenMaterial.diffuse.minificationFilter = .linear
        }

        required init?(coder: NSCoder) { super.init(coder: coder) }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        func update(image: CGImage, platform: SessionSimulatorPlatform, reset: Int) {
            let size = CGSize(width: image.width, height: image.height)
            if size != imageSize {
                imageSize = size
                for node in deviceNode.childNodes { node.removeFromParentNode() }
                let width = size.width / max(size.width, size.height) * 4
                let height = size.height / max(size.width, size.height) * 4
                let screenRect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
                let radius = SessionSimulatorGeometry.screenRadius(rect: screenRect, platform: platform)
                let path = NSBezierPath(
                    roundedRect: screenRect.insetBy(dx: -0.03, dy: -0.03), xRadius: radius + 0.03,
                    yRadius: radius + 0.03)
                path.flatness = 0.001
                let body = SCNShape(path: path, extrusionDepth: 0.12)
                body.chamferRadius = 0.025
                let material = SCNMaterial()
                material.diffuse.contents = NSColor(Color.dockSurface4)
                material.metalness.contents = 0.65
                material.roughness.contents = 0.35
                body.materials = [material]
                deviceNode.addChildNode(SCNNode(geometry: body))
                let screen = SCNPlane(width: width, height: height)
                screen.cornerRadius = radius
                screen.materials = [screenMaterial]
                let screenNode = SCNNode(geometry: screen)
                screenNode.position.z = 0.061
                deviceNode.addChildNode(screenNode)
            }
            screenMaterial.diffuse.contents = image
            if lastReset != reset {
                lastReset = reset
                resetView()
            }
            needsDisplay = true
        }

        override func layout() {
            super.layout()
            fitCamera()
        }

        private func fitCamera() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            // Keep framing fixed during orbit; only resizing or explicit zoom changes scale.
            let w = imageSize.width / max(1, max(imageSize.width, imageSize.height)) * 4
            let h = imageSize.height / max(1, max(imageSize.width, imageSize.height)) * 4
            cameraNode.camera?.orthographicScale =
                max(h + 0.2, (w + 0.2) * bounds.height / bounds.width) / (2 * zoom)
        }

        private func resetView() {
            yaw = 0
            pitch = 0
            zoom = 1
            applyRotation()
            fitCamera()
        }

        private func applyRotation() {
            // Screen-space tilt keeps a horizontal drag predictable even after tilting.
            deviceNode.simdOrientation =
                simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
                * simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
            needsDisplay = true
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            if event.clickCount == 2 {
                resetView()
                lastPoint = nil
                return
            }
            lastPoint = convert(event.locationInWindow, from: nil)
        }
        override func mouseDragged(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard let lastPoint else { return }
            yaw += Float((point.x - lastPoint.x) / max(1, bounds.width)) * .pi
            pitch = min(1.2, max(-1.2, pitch - Float((point.y - lastPoint.y) / max(1, bounds.height)) * .pi))
            yaw.formTruncatingRemainder(dividingBy: .pi * 2)
            self.lastPoint = point
            applyRotation()
        }
        override func mouseUp(with event: NSEvent) { lastPoint = nil }
        override func scrollWheel(with event: NSEvent) {
            zoom = min(1.8, max(0.65, zoom + Double(event.scrollingDeltaY) * 0.01))
            fitCamera()
            needsDisplay = true
        }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 123: yaw -= 0.1
            case 124: yaw += 0.1
            case 125: pitch = min(1.2, pitch + 0.1)
            case 126: pitch = max(-1.2, pitch - 0.1)
            case 15: resetView()
            case 53: exit()
            default:
                super.keyDown(with: event)
                return
            }
            applyRotation()
        }
    }
}
