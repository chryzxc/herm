import CryptoKit
import Foundation

struct InspectorPresentation: Codable {
    var selected = "Activity"
    var closed = "Browser"
    var recentClosed: [String] = []
    var browserURL: String?
    var terminalTabs: [UUID]?
    var browserTabs: [String]?
    var selectedExtra: UUID?
    var selectedBrowser: Int?
}

/// Durable references only; no source, transcript, browser state, or terminal output.
@MainActor
final class WorkspacePresentationStore {
    static let shared = WorkspacePresentationStore()
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(_ identity: String) -> String {
        "herm.workspace.v1." + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func defaultsData(_ identity: String) -> Data? { defaults.data(forKey: key(identity) + ".references") }
    func saveData(_ data: Data, identity: String) { defaults.set(data, forKey: key(identity) + ".references") }
    func load(_ identity: String) -> InspectorPresentation? {
        defaults.data(forKey: key(identity)).flatMap { try? JSONDecoder().decode(InspectorPresentation.self, from: $0) }
    }
    func save(_ value: InspectorPresentation, identity: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key(identity)) }
    }
    static func restorableBrowserURL(_ text: String) -> String? {
        guard var parts = URLComponents(string: text), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
            parts.host != nil
        else { return nil }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        return parts.url?.absoluteString
    }
}
