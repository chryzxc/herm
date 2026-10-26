import AppKit
import Combine
import ImageIO

/// Direct device pixels and input. Never captures a desktop window or requests macOS privacy grants.
@MainActor
final class SessionSimulatorCapture: ObservableObject {
    struct Device: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
    }
    private struct Update: Decodable {
        var devices: [Device]?
        var error: String?
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var image: CGImage?
    @Published private(set) var message = "Start a device from your chat, then refresh."
    @Published private(set) var isLoading = false
    @Published var selectedID = ""
    var inputAllowed: Bool { image != nil }
    private let bridge = HermesSimulatorBridge()
    private var generation = UUID()
    private var deadline: Task<Void, Never>?
    private var modifiers: Set<UInt16> = []

    func refresh(_ platform: SessionSimulatorPlatform, preferredID: String? = nil) {
        stop()
        if let preferredID { selectedID = preferredID }
        let request = generation
        let connectingDevice = selectedID
        isLoading = true
        message = selectedID.isEmpty ? "Finding running devices…" : "Connecting to device…"
        do {
            try bridge.start(platform: platform.rawValue, device: selectedID) { [weak self] kind, data in
                guard let self, self.generation == request else { return }
                self.receive(kind: kind, data: data)
            } ended: { [weak self] in
                guard let self, self.generation == request else { return }
                if !connectingDevice.isEmpty {
                    self.fail("Device connection ended. Check the bridge installation and reconnect.")
                } else {
                    self.isLoading = false
                }
            }
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, self.generation == request, self.isLoading else { return }
                self.fail("The device did not provide a display. Check the bridge installation and retry.")
            }
        } catch {
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
            isLoading = false
            message = ""
            deadline?.cancel()
        } else if let update = try? JSONDecoder().decode(Update.self, from: data) {
            if let devices = update.devices {
                self.devices = devices
                if selectedID.isEmpty {
                    isLoading = false
                    message =
                        devices.isEmpty
                        ? "No running devices. Launch one from your chat, then refresh." : "Choose a device."
                    if devices.count == 1 { selectedID = devices[0].id }
                } else if !devices.contains(where: { $0.id == selectedID }) {
                    fail("The selected device is no longer running. Choose another device or launch it again.")
                }
            }
            if let error = update.error { fail(HermesDiagnosticsService.safeSummary(error)) }
        }
    }

    private func fail(_ detail: String) {
        stop()
        message = detail
    }

    func stop() {
        releaseInput()
        generation = UUID()
        deadline?.cancel()
        deadline = nil
        bridge.stop()
        image = nil
        isLoading = false
    }

    func button(_ name: String) {
        guard inputAllowed else { return }
        bridge.send(["kind": "button", "name": name])
    }

    func mouse(_ event: NSEvent, point: CGPoint) {
        guard inputAllowed else { return }
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
        guard inputAllowed else { return }
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
