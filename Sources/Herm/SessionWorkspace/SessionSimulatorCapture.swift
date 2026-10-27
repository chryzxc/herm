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
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var image: CGImage?
    @Published private(set) var message = "Start a device from your chat, then refresh."
    @Published private(set) var isLoading = false
    @Published private(set) var connectionFailed = false
    @Published private(set) var setupRequired = false
    @Published private(set) var isStarting = false
    private var platform: SessionSimulatorPlatform = .ios
    @Published var selectedID = ""
    var inputAllowed: Bool { image != nil }
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
            try bridge.start(platform: platform.rawValue, device: selectedID, boot: boot) { [weak self] kind, data in
                guard let self, self.generation == request else { return }
                self.receive(kind: kind, data: data)
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
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(boot ? 150 : 30)) } catch { return }
                guard let self, self.generation == request, self.isLoading else { return }
                self.fail("The device did not provide a display. Check the bridge installation and retry.")
            }
        } catch {
            setupRequired = true
            fail(HermesDiagnosticsService.safeSummary(error.localizedDescription))
        }
    }

    func receive(kind: UInt8, data: Data) {
        if kind == 73 {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                fail("The device returned an invalid display frame. Reconnect to retry.")
                return
            }
            self.image = image
            connectionFailed = false
            isLoading = false
            message = ""
            deadline?.cancel()
        } else if let update = try? JSONDecoder().decode(Update.self, from: data) {
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
        image = nil
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
