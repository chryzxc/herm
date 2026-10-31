import Foundation

/// Herm-owned message bookmarks per profile and conversation. Hermes has no pin
/// feature, so these never touch the runtime. Only references are persisted;
/// message text always comes from Hermes history.
@MainActor
struct MessagePinStore {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        let supportRoot =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support", isDirectory: true)
        self.fileURL =
            fileURL
            ?? supportRoot.appendingPathComponent("Herm", isDirectory: true)
            .appendingPathComponent("message-pins-v1.json")
    }

    func pins(profile: String?, sessionID: String) -> [MessagePinRecord] {
        all()[scope(profile, sessionID)] ?? []
    }

    func save(_ pins: [MessagePinRecord], profile: String?, sessionID: String) {
        var stored = all()
        stored[scope(profile, sessionID)] = pins.isEmpty ? nil : pins
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            DebugLog.write("message pins: persistence failed")
        }
    }

    private func all() -> [String: [MessagePinRecord]] {
        (try? Data(contentsOf: fileURL)).flatMap {
            try? JSONDecoder().decode([String: [MessagePinRecord]].self, from: $0)
        }
            ?? [:]
    }

    private func scope(_ profile: String?, _ sessionID: String) -> String {
        "\(profile ?? "default")|\(sessionID)"
    }
}
