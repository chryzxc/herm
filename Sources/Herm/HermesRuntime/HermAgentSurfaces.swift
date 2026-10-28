import Foundation
import os

/// A Herm capability the agent must route through instead of an external app or plain text.
/// Herm owns the list; the `herm` Hermes plugin (integrations/herm) serves it as session rules,
/// the `herm_reference` tool, and tool-call guards. Add or remove a surface in
/// `HermAgentSurfaces.current`; neither the plugin nor any prompt text elsewhere changes.
struct HermAgentSurface: Codable, Equatable, Sendable {
    struct Guard: Codable, Equatable, Sendable {
        /// Hermes tool name and the string argument the pattern is matched against.
        let tool: String
        let argument: String
        /// Case-insensitive Python `re.search` pattern.
        let pattern: String
        /// Returned to the agent as the blocked tool's result.
        let message: String
    }

    let id: String
    /// Frozen into each new session's system prompt; all surfaces share `HermAgentSurfaces.ruleBudget`.
    let rules: String
    /// Served on demand by `herm_reference`.
    var reference: String?
    var guards: [Guard] = []
}

/// The file the plugin reads. Holds Herm preferences and presentation catalogs only.
struct HermAgentManifest: Codable, Equatable, Sendable {
    var version = 1
    var surfaces: [HermAgentSurface]
    /// Hermes session ID → surface ID → reference text that applies only to that session.
    var sessions: [String: [String: String]] = [:]
}

/// Whether Hermes reported the `herm` plugin enabled. Until it does, prompts carry the rules inline.
enum HermPlugin {
    private static let loaded = OSAllocatedUnfairLock(initialState: false)
    static var isLoaded: Bool { loaded.withLock { $0 } }

    /// Updates from a `plugins.list` result; a missing result keeps the inline fallback.
    static func note(_ result: [String: Any]?) {
        let enabled = isEnabled(in: result)
        loaded.withLock { $0 = enabled }
    }

    static func isEnabled(in result: [String: Any]?) -> Bool {
        let rows = result?["plugins"] as? [[String: Any]] ?? []
        return rows.contains { $0["name"] as? String == "herm" && $0["enabled"] as? Bool == true }
    }
}

@MainActor
enum HermAgentSurfaces {
    static let environmentKey = "HERM_AGENT_SURFACES"
    /// Hermes caps one plugin system-prompt section at 4,000 characters.
    static let ruleBudget = 4_000
    static let sessionLimit = 50
    static let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Herm/agent-surfaces.json")

    static func current(defaults: UserDefaults = .standard) -> [HermAgentSurface] {
        [
            GenerativeUIIntegration.agentSurface(defaults: defaults),
            HermesSimulatorPreference.agentSurface(defaults: defaults),
            AgentBrowser.agentSurface(defaults: defaults),
        ].compactMap { $0 }
    }

    private static var sessions: [String: [String: String]] = [:]
    private static var sessionOrder: [String] = []
    private static var written: Data?
    private static var observer: NSObjectProtocol?

    /// Keeps the manifest current and returns the environment for a Herm-launched Hermes backend.
    static func startPublishing() -> [String: String] {
        if observer == nil {
            // Settings are @AppStorage toggles; republishing is a no-op unless the encoded manifest changed.
            observer = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { publish() } }
        }
        publish()
        return [environmentKey: fileURL.path]
    }

    /// Records reference text that applies to one Hermes session, such as its loaded record IDs.
    static func note(sessionID: String?, surface: String, reference: String?) {
        guard let sessionID, !sessionID.isEmpty, sessions[sessionID]?[surface] != reference else { return }
        sessions[sessionID, default: [:]][surface] = reference
        sessionOrder.removeAll { $0 == sessionID }
        sessionOrder.append(sessionID)
        while sessionOrder.count > sessionLimit { sessions.removeValue(forKey: sessionOrder.removeFirst()) }
        if observer != nil { publish() }
    }

    static func manifest(defaults: UserDefaults = .standard) -> HermAgentManifest {
        HermAgentManifest(surfaces: current(defaults: defaults), sessions: sessions.filter { !$0.value.isEmpty })
    }

    private static func publish() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(manifest()), data != written else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            written = data
        } catch {
            DebugLog.write(
                "agent surfaces: write failed: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))")
        }
    }
}
