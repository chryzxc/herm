import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct SessionSimulatorDiagnosticsTests {
    private func element(x: Double = 0, width: Double = 1) -> SessionSimulatorElement {
        .init(x: x, y: 0, width: width, height: 1, label: "Continue", identifier: "continue", role: "Button", value: "")
    }

    @Test func staleResultsAndDisconnectCannotRestoreDiagnostics() throws {
        let state = SessionSimulatorDiagnostics()
        let first = try #require(state.begin("logs", image: nil, app: "first"))
        #expect(state.begin("inspect", image: nil) == nil)
        state.reset()
        let second = try #require(state.begin("logs", image: nil, app: "second"))
        state.receive(.init(request: first, text: "old app logs"))
        #expect(state.excerpt.isEmpty)
        #expect(state.pending == "logs")
        state.receive(.init(request: second, text: "new logs", detail: "scope"))
        #expect(state.excerpt == "new logs")
        #expect(state.logApp == "second")
        #expect(state.pending == nil)
        state.reset()
        #expect(state.excerpt.isEmpty)
    }

    @Test func inspectorSelectsSmallestElementAndSupportsRegions() throws {
        let state = SessionSimulatorDiagnostics()
        let request = try #require(state.begin("inspect", image: nil))
        state.receive(.init(request: request, elements: [element(), element(x: 0.2, width: 0.1), element(x: -1)]))
        #expect(state.elements.count == 2)
        let point = CGPoint(x: 0.25, y: 0.5)
        state.select(from: point, to: point)
        #expect(state.selectedElement?.width == 0.1)
        state.select(from: .init(x: 0.1, y: 0.1), to: .init(x: 0.9, y: 0.9))
        #expect(state.selectedElement == nil)
        #expect(state.selection?.width == 0.8)
        state.resume()
        #expect(state.selection == nil)
    }

    @Test func diagnosticFailureDoesNotDisconnectDisplay() throws {
        let capture = SessionSimulatorCapture()
        let context = try #require(
            CGContext(
                data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        capture.receive(kind: 73, data: png)
        let request = try #require(capture.diagnostics.begin("inspect", image: image))
        capture.diagnostics.receive(.init(request: request, error: "Unavailable"))
        #expect(capture.inputAllowed)
        #expect(capture.diagnostics.snapshot != nil)
        capture.diagnostics.select(from: .init(x: 0.25, y: 0.25), to: .init(x: 0.75, y: 0.75))
        #expect(capture.diagnostics.attachmentImage(live: nil)?.size.width == 10)
        capture.stop()
        #expect(capture.diagnostics.snapshot == nil)
    }

    @Test func solidPreviewResetsOrbitAndPreservesItAcrossLiveFrames() throws {
        let context = try #require(
            CGContext(
                data: nil, width: 390, height: 844, bitsPerComponent: 8,
                bytesPerRow: 1560, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let view = SessionSimulatorPreview.PreviewView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        view.update(image: image, platform: .ios, reset: 0)
        let device = try #require(view.scene?.rootNode.childNodes.first)
        #expect(device.childNodes.count == 2)
        let original = device.eulerAngles.y
        #expect(original == 0)
        #expect(device.eulerAngles.x == 0)
        let scale = view.pointOfView?.camera?.orthographicScale
        let right = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 124))
        view.keyDown(with: right)
        #expect(device.eulerAngles.y > original)
        let rotated = device.eulerAngles.y
        #expect(view.pointOfView?.camera?.orthographicScale == scale)
        view.update(image: image, platform: .ios, reset: 0)
        #expect(device.eulerAngles.y == rotated)
        view.update(image: image, platform: .ios, reset: 1)
        #expect(abs(device.eulerAngles.y - original) < 0.001)
        let down = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: CGPoint(x: 100, y: 300), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let drag = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDragged, location: CGPoint(x: 150, y: 330), modifierFlags: [],
                timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: down)
        view.mouseDragged(with: drag)
        let dragged = device.simdOrientation
        #expect(abs(dragged.vector.y) > 0.1)
        #expect(view.pointOfView?.camera?.orthographicScale == scale)
        view.update(image: image, platform: .ios, reset: 1)
        #expect(device.simdOrientation == dragged)
        view.mouseUp(with: drag)
        view.update(image: image, platform: .ios, reset: 2)
        #expect(abs(device.eulerAngles.x) < 0.001)
        #expect(abs(device.eulerAngles.y) < 0.001)
        if let path = ProcessInfo.processInfo.environment["HERM_SIMULATOR_PREVIEW_IMAGE"], path != "fixture",
            let live = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        {
            view.update(image: live, platform: .ios, reset: 2)
            let tiff = try #require(view.snapshot().tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/herm-solid-device.png"))
        }
        view.scene = nil
    }

    @Test func previewPausesInputAndLeavingRestoresInteractiveDisplay() throws {
        let capture = SessionSimulatorCapture()
        capture.setPreviewing(true)
        #expect(!capture.isPreviewing)
        let context = try #require(
            CGContext(
                data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        capture.receive(kind: 73, data: png)
        #expect(capture.deviceInputAllowed)
        capture.inspect()
        #expect(!capture.deviceInputAllowed)
        capture.setPreviewing(true)
        #expect(capture.diagnostics.snapshot == nil)
        #expect(capture.diagnostics.pending == nil)
        #expect(capture.inputAllowed)
        #expect(!capture.deviceInputAllowed)
        capture.inspect()
        #expect(capture.diagnostics.snapshot == nil)
        capture.setPreviewing(false)
        #expect(capture.deviceInputAllowed)
        capture.setPreviewing(true)
        capture.stop()
        #expect(!capture.isPreviewing)
        #expect(!capture.deviceInputAllowed)
    }

    @Test func rebuildingTabRetainsConnectionAndItsDiagnostics() throws {
        let capture = SessionSimulatorCapture()
        let root = SessionSimulatorView(platform: .ios, sessionKey: "fixture", isActive: false, capture: capture)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.display()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let context = try #require(
            CGContext(
                data: nil, width: 20, height: 20, bitsPerComponent: 8,
                bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        capture.receive(kind: 73, data: png)
        host.layoutSubtreeIfNeeded()
        // Parent updates recreate the view value with a fresh default capture argument.
        host.rootView = SessionSimulatorView(platform: .ios, sessionKey: "fixture", isActive: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()
        func canvas(in view: NSView) -> SessionSimulatorCanvas.SimulatorCanvas? {
            if let result = view as? SessionSimulatorCanvas.SimulatorCanvas { return result }
            return view.subviews.lazy.compactMap { canvas(in: $0) }.first
        }
        let display = try #require(canvas(in: host))
        #expect(display.capture === capture)
        #expect(display.diagnostics === capture.diagnostics)
        let request = try #require(capture.diagnostics.begin("inspect", image: image))
        capture.diagnostics.receive(.init(request: request, elements: [element()]))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        #expect(display.diagnostics?.snapshot != nil)
        #expect(display.diagnostics?.elements.count == 1)
    }

    @Test func explicitDeviceSelectionSurvivesInventoryRefresh() {
        let capture = SessionSimulatorCapture()
        let inventory = Data(#"{"devices":[{"id":"first","name":"First"}]}"#.utf8)
        capture.receive(kind: 74, data: inventory)
        #expect(capture.selectedID == "first")
        capture.selectDevice("")
        capture.receive(kind: 74, data: inventory)
        #expect(capture.selectedID.isEmpty)
        capture.selectDevice("second")
        capture.receive(kind: 74, data: inventory)
        #expect(capture.selectedID == "second")
        #expect(!capture.inputAllowed)
    }

    @Test func stoppedDevicesRequireExplicitStartAndSetupErrorsStayActionable() {
        let capture = SessionSimulatorCapture()
        let stopped = Data(#"{"devices":[{"id":"phone","name":"Phone","running":false}]}"#.utf8)
        capture.receive(kind: 74, data: stopped)
        #expect(capture.selectedID.isEmpty)
        capture.selectDevice("phone")
        capture.receive(kind: 74, data: stopped)
        #expect(capture.message.contains("stopped"))
        #expect(!capture.isLoading)
        #expect(!capture.inputAllowed)
        capture.receive(kind: 74, data: Data(#"{"devices":[],"setup":"Install SDK tools."}"#.utf8))
        #expect(capture.setupRequired)
        #expect(capture.connectionFailed)
        #expect(capture.message == "Install SDK tools.")
        #expect(!capture.inputAllowed)
    }

    @Test func attachmentsStayInOwningDraftAndNeverSend() {
        let model = DockModel()
        model.draft = "Investigate this"
        let context = ChatContext(id: "sim-test", title: "Selection", body: "Device snapshot")
        #expect(!model.attachSimulator(context, image: nil, owner: "wrong-session"))
        #expect(model.attachedContexts.isEmpty)
        #expect(model.attachSimulator(context, image: nil, owner: WorkspaceIdentity.session(model)))
        #expect(model.attachedContexts.last?.id == context.id)
        #expect(model.draft == "Investigate this")
    }
}
