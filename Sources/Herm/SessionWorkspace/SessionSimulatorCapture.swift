import AppKit
import Combine
import ImageIO

/// Direct device pixels and input. Never captures a desktop window or requests macOS privacy grants.
@MainActor
final class SessionSimulatorCapture: ObservableObject {
    struct Device: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        var running: Bool? = nil
        var isRunning: Bool { running ?? true }
    }
    private struct Update: Decodable {
        var devices: [Device]?
        var error: String?
        var booted: String?
        var setup: String?
        var diagnostic: SessionSimulatorDiagnosticResult?
        var displayReady: UInt64?
    }

    @Published private(set) var devices: [Device] = []
    @MainActor final class Frames: ObservableObject {
        @Published private(set) var size: CGSize?
        private(set) var image: CGImage?
        let updates = PassthroughSubject<CGImage?, Never>()

        func show(_ image: CGImage?) {
            self.image = image
            let next = image.map { CGSize(width: $0.width, height: $0.height) }
            if size != next { size = next }
            updates.send(image)
        }
    }
    let frames = Frames()
    var image: CGImage? { frames.image }
    private(set) var visible = true
    private var frameRevision: UInt64 = 0
    private var displayRevision: UInt64 = 0
    private var awaitingDisplayRevision: UInt64?

    func pauseDisplay() {
        guard visible else { return }
        if inputAllowed { objectWillChange.send() }
        visible = false
        frameRevision &+= 1
        awaitingDisplayRevision = nil
        releaseInput()
        bridge.send(["kind": "display", "visible": false])
        if !isStarting {
            deadline?.cancel()
            deadline = nil
        }
    }

    @discardableResult
    func resumeDisplay() -> UInt64? {
        guard !visible else { return awaitingDisplayRevision }
        visible = true
        guard !isStarting, image != nil || (isLoading && !selectedID.isEmpty) else { return nil }
        displayRevision &+= 1
        awaitingDisplayRevision = displayRevision
        isLoading = true
        message = "Resuming device display…"
        bridge.send(["kind": "display", "visible": true, "revision": displayRevision])
        startDeadline(boot: false)
        return displayRevision
    }

    func receiveFrame(_ data: Data) async {
        guard visible, awaitingDisplayRevision == nil else { return }
        frameRevision &+= 1
        let revision = frameRevision
        let decoded = await Self.decodeFrame(data)
        guard visible, frameRevision == revision else { return }
        installFrame(decoded)
    }

    nonisolated private static func decodeFrame(_ data: Data) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private func installFrame(_ frame: CGImage?) {
        guard let frame else {
            fail("The device returned an invalid display frame. Reconnect to retry.")
            return
        }
        if image == nil { objectWillChange.send() }
        frames.show(frame)
        if connectionFailed { connectionFailed = false }
        if isLoading { isLoading = false }
        if !message.isEmpty { message = "" }
        deadline?.cancel()
        deadline = nil
    }
    @Published private(set) var message = "Start a device from your chat, then refresh."
    @Published private(set) var isLoading = false
    @Published private(set) var connectionFailed = false
    @Published private(set) var setupRequired = false
    @Published private(set) var isStarting = false
    private var platform: SessionSimulatorPlatform = .ios
    @Published var selectedID = ""
    var inputAllowed: Bool { visible && !isLoading && image != nil }
    @Published private(set) var isPreviewing = false
    var deviceInputAllowed: Bool { inputAllowed && !isPreviewing && diagnostics.snapshot == nil }

    func setPreviewing(_ enabled: Bool) {
        guard !enabled || inputAllowed else { return }
        releaseInput()
        diagnostics.resume()
        isPreviewing = enabled
    }
    let diagnostics = SessionSimulatorDiagnostics()
    private let bridge = HermesSimulatorBridge()
    private var generation = UUID()
    private var deadline: Task<Void, Never>?
    private var modifiers: Set<UInt16> = []
    private var allowsAutomaticSelection = true
    private var diagnosticsObservation: AnyCancellable?

    init() {
        // The retained capture owns diagnostics, including across SwiftUI view reconstruction.
        diagnosticsObservation = diagnostics.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func selectDevice(_ id: String) {
        // Invalidate the old stream immediately, before SwiftUI schedules reconnection.
        stop()
        allowsAutomaticSelection = false
        selectedID = id
    }

    func refresh(_ platform: SessionSimulatorPlatform, preferredID: String? = nil, boot: Bool = false) {
        stop()
        if let preferredID { selectedID = preferredID }
        self.platform = platform
        setupRequired = false
        connectionFailed = false
        isStarting = boot
        let request = generation
        let connectingDevice = selectedID
        isLoading = true
        message = boot ? "Starting device…" : (selectedID.isEmpty ? "Finding devices…" : "Connecting to device…")
        do {
            try bridge.start(platform: platform.rawValue, device: selectedID, boot: boot, displayVisible: visible) {
                [weak self] kind, data in
                guard let self, self.generation == request else { return }
                if kind == 73 {
                    await self.receiveFrame(data)
                } else {
                    self.receive(kind: kind, data: data)
                }
            } ended: { [weak self] in
                guard let self, self.generation == request else { return }
                if boot || !connectingDevice.isEmpty,
                    boot || self.devices.first(where: { $0.id == connectingDevice })?.isRunning != false
                {
                    self.fail("Device connection ended. Check the bridge installation and reconnect.")
                } else {
                    self.isLoading = false
                }
            }
            if boot || visible { startDeadline(boot: boot) }
        } catch {
            setupRequired = true
            fail(HermesDiagnosticsService.safeSummary(error.localizedDescription))
        }
    }

    private func startDeadline(boot: Bool) {
        deadline?.cancel()
        let current = generation
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(boot ? 150 : 30)) } catch { return }
            guard let self, generation == current, isLoading else { return }
            fail("The device did not provide a display. Check the bridge installation and retry.")
        }
    }

    func receive(kind: UInt8, data: Data) {
        if kind == 73 {
            guard visible, awaitingDisplayRevision == nil else { return }
            let source = CGImageSourceCreateWithData(data as CFData, nil)
            installFrame(source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        } else if let update = try? JSONDecoder().decode(Update.self, from: data) {
            if let revision = update.displayReady, visible, revision == awaitingDisplayRevision {
                awaitingDisplayRevision = nil
            }
            if let booted = update.booted {
                refresh(platform, preferredID: booted)
                return
            }
            if let setup = update.setup {
                setupRequired = true
                message = HermesDiagnosticsService.safeSummary(setup)
            }
            if let diagnostic = update.diagnostic { diagnostics.receive(diagnostic) }
            if let devices = update.devices {
                self.devices = devices
                if selectedID.isEmpty {
                    isLoading = false
                    message =
                        devices.isEmpty
                        ? "No devices installed. Create a device, then check again."
                        : "Choose a device to start or connect."
                    let running = devices.filter(\.isRunning)
                    if !setupRequired, allowsAutomaticSelection, running.count == 1 { selectedID = running[0].id }
                } else if devices.first(where: { $0.id == selectedID })?.isRunning == false {
                    isLoading = false
                    message = "This device is stopped. Start it to use its display here."
                } else if !devices.contains(where: { $0.id == selectedID }) {
                    fail("The selected device is no longer running. Choose another device or launch it again.")
                }
            }
            if let setup = update.setup { fail(HermesDiagnosticsService.safeSummary(setup)) }
            if let error = update.error { fail(HermesDiagnosticsService.safeSummary(error)) }
        }
    }

    private func fail(_ detail: String) {
        stop()
        connectionFailed = true
        message = detail
    }

    func stop() {
        diagnostics.reset()
        isPreviewing = false
        releaseInput()
        generation = UUID()
        deadline?.cancel()
        deadline = nil
        bridge.stop()
        frameRevision &+= 1
        awaitingDisplayRevision = nil
        if image != nil {
            objectWillChange.send()
            frames.show(nil)
        }
        isLoading = false
        isStarting = false
    }

    func inspect() {
        guard inputAllowed, !isPreviewing else { return }
        releaseInput()
        guard let request = diagnostics.begin("inspect", image: image) else { return }
        bridge.send(["kind": "inspect", "request": request])
    }

    func readLogs(app: String, severity: String) {
        guard inputAllowed, let request = diagnostics.begin("logs", image: nil, app: app) else { return }
        bridge.send(["kind": "logs", "request": request, "app": app, "severity": severity])
    }

    func button(_ name: String) {
        guard deviceInputAllowed else { return }
        bridge.send(["kind": "button", "name": name])
    }

    func mouse(_ event: NSEvent, point: CGPoint) {
        guard deviceInputAllowed else { return }
        let phase: String
        switch event.type {
        case .leftMouseDown: phase = "down"
        case .leftMouseDragged: phase = "move"
        case .leftMouseUp: phase = "up"
        default: return
        }
        bridge.send(["kind": "touch", "phase": phase, "x": point.x, "y": point.y])
    }

    func key(_ event: NSEvent) {
        guard deviceInputAllowed else { return }
        var up = event.type == .keyUp
        if event.type == .flagsChanged {
            up = modifiers.contains(event.keyCode)
            if up { modifiers.remove(event.keyCode) } else { modifiers.insert(event.keyCode) }
        }
        bridge.send(["kind": "key", "phase": up ? "up" : "down", "code": Int(event.keyCode)])
    }

    func releaseInput() {
        bridge.send(["kind": "release"])
        modifiers.removeAll()
    }
}
