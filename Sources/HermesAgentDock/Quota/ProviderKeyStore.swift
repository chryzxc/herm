import Foundation

/// Stores user-entered provider API keys for the quota services in a dock-owned
/// JSON file with owner-only permissions. The macOS Keychain is deliberately
/// not used; keys the user pastes here are the Dock's own configuration.
struct ProviderKeyStore: Sendable, Equatable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/hermes-agent-dock/providers.json")
    }

    /// The trimmed stored key for a catalog entry, or nil when absent or blank.
    func savedKey(_ storageKey: String) -> String? {
        guard let entries = loadEntries(),
              let entry = entries[storageKey] as? [String: Any],
              let key = (entry["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }

    func contains(_ storageKey: String) -> Bool {
        savedKey(storageKey) != nil
    }

    /// Saves the key, or removes the entry when `key` is nil. Failures are
    /// silent: quota simply keeps reporting the previous state.
    func save(_ key: String?, storageKey: String) {
        var entries = loadEntries() ?? [:]
        if let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            entries[storageKey] = ["key": key]
        } else {
            entries.removeValue(forKey: storageKey)
        }
        writeEntries(entries)
    }

    private func loadEntries() -> [String: Any]? {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private func writeEntries(_ entries: [String: Any]) {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            return
        }
    }
}
