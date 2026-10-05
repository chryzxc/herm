import Foundation

/// Carries settings and state over from builds released as "HermesAgentDock"
/// (bundle ID `app.herm.HermesAgentDock`) so the rename to Herm keeps them.
enum LegacyAppIdentity {
    static let bundleID = "app.herm.HermesAgentDock"

    static func migrate(
        defaults: UserDefaults = .standard,
        currentBundleID: String? = Bundle.main.bundleIdentifier,
        legacyBundleID: String = bundleID,
        fileManager: FileManager = .default,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        if let currentBundleID, currentBundleID != legacyBundleID,
           defaults.persistentDomain(forName: currentBundleID)?.isEmpty ?? true,
           let legacy = defaults.persistentDomain(forName: legacyBundleID), !legacy.isEmpty {
            defaults.setPersistentDomain(legacy, forName: currentBundleID)
        }
        moveIfNeeded("Library/Application Support/HermesAgentDock", to: "Library/Application Support/Herm", home: home, fileManager: fileManager)
        moveIfNeeded(".config/hermes-agent-dock", to: ".config/herm", home: home, fileManager: fileManager)
    }

    private static func moveIfNeeded(_ old: String, to new: String, home: URL, fileManager: FileManager) {
        let source = home.appendingPathComponent(old), destination = home.appendingPathComponent(new)
        guard fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: destination.path) else { return }
        try? fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.moveItem(at: source, to: destination)
    }
}
