import AppKit
import Combine

struct SessionSimulatorElement: Decodable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let label: String
    let identifier: String
    let role: String
    let value: String

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1.001 && y + height <= 1.001
    }
    var description: String {
        "Role: \(role)\nLabel: \(label)\nIdentifier: \(identifier)\nValue: \(value)"
    }
}

struct SessionSimulatorDiagnosticResult: Decodable {
    let request: String
    var elements: [SessionSimulatorElement]?
    var text: String?
    var detail: String?
    var error: String?
}

@MainActor
final class SessionSimulatorDiagnostics: ObservableObject {
    @Published private(set) var snapshot: CGImage?
    @Published private(set) var elements: [SessionSimulatorElement] = []
    @Published var selection: CGRect?
    @Published var selectedElement: SessionSimulatorElement?
    @Published var excerpt = ""
    @Published private(set) var logScope = ""
    @Published private(set) var logApp = ""
    @Published private(set) var status = ""
    @Published private(set) var pending: String?
    private var request: String?
    private var timeout: Task<Void, Never>?

    func begin(_ kind: String, image: CGImage?, app: String = "") -> String? {
        guard pending == nil else { return nil }
        if kind == "inspect" {
            snapshot = image
            elements = []
            selection = nil
            selectedElement = nil
        } else {
            excerpt = ""
            logScope = ""
            logApp = app
        }
        let id = UUID().uuidString
        request = id
        pending = kind
        status = kind == "inspect" ? "Reading elements…" : "Reading app logs…"
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(50)) } catch { return }
            guard let self, self.request == id else { return }
            self.receive(.init(request: id, error: "Request timed out. Retry when the device is responsive."))
        }
        return id
    }

    func receive(_ result: SessionSimulatorDiagnosticResult) {
        guard result.request == request else { return }
        timeout?.cancel()
        timeout = nil
        request = nil
        pending = nil
        if let error = result.error {
            status = HermesDiagnosticsService.safeSummary(error)
            return
        }
        if let elements = result.elements {
            self.elements = Array(elements.filter(\.isValid).prefix(2000))
            status =
                self.elements.isEmpty
                ? "No element details available. Drag a screenshot region."
                : "Click an element or drag a region to comment. Esc returns to live input."
        }
        if let text = result.text {
            excerpt = String(text.suffix(24000))
            logScope = result.detail ?? "App log snapshot"
            status =
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No matching log entries." : logScope
        }
    }

    func element(at point: CGPoint) -> SessionSimulatorElement? {
        elements.filter { $0.rect.contains(point) }.min { $0.width * $0.height < $1.width * $1.height }
    }

    func select(from start: CGPoint, to end: CGPoint) {
        if abs(start.x - end.x) < 0.008 && abs(start.y - end.y) < 0.008, let element = element(at: end) {
            selectedElement = element
            selection = element.rect
        } else {
            selectedElement = nil
            let rect = CGRect(
                x: min(start.x, end.x), y: min(start.y, end.y),
                width: abs(start.x - end.x), height: abs(start.y - end.y))
            selection = rect.width > 0.002 && rect.height > 0.002 ? rect : nil
        }
    }

    func resume() {
        if pending == "inspect" {
            timeout?.cancel()
            request = nil
            pending = nil
        }
        snapshot = nil
        elements = []
        selection = nil
        selectedElement = nil
        status = ""
    }

    func reset() {
        timeout?.cancel()
        timeout = nil
        pending = nil
        request = nil
        resume()
        excerpt = ""
        logScope = ""
        logApp = ""
    }

    func attachmentImage(live: CGImage?) -> NSImage? {
        guard let image = snapshot ?? live else { return nil }
        let result: CGImage
        if snapshot != nil, let selection {
            let rect = CGRect(
                x: selection.minX * CGFloat(image.width), y: selection.minY * CGFloat(image.height),
                width: selection.width * CGFloat(image.width), height: selection.height * CGFloat(image.height))
            guard let cropped = image.cropping(to: rect.integral) else { return nil }
            result = cropped
        } else {
            result = image
        }
        return NSImage(cgImage: result, size: NSSize(width: result.width, height: result.height))
    }
}

extension DockModel {
    @discardableResult
    func attachSimulator(_ context: ChatContext, image: NSImage?, owner: String) -> Bool {
        guard WorkspaceIdentity.session(self) == owner else { return false }
        if let image, !stageImage(image) { return false }
        attachedContexts.append(context)
        requestComposerFocus()
        return true
    }
}
