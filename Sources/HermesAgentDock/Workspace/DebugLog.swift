import Foundation

/// `swift run` launches the executable directly from `.build`, which is not a
/// macOS application bundle. UserNotifications asserts in that environment,
/// so notification setup and delivery are available only to the packaged app.
enum HermesAppRuntime {
    static var supportsUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }
}

@MainActor
enum DebugLog {
    static var onLine: ((String) -> Void)?
    private static let writer = DebugLogWriter()
    private static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/HermesAgentDock.log")

    static func write(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] event=\(persistentEventName(for: message))\n"
        print(line, terminator: "")
        onLine?(line.trimmingCharacters(in: .newlines))
        writer.append(line, to: fileURL)
    }

    /// Temporary state-transition diagnostics. The full message is available
    /// only to the in-memory debug panel; durable output is metadata-only.
    static func writeDiagnostic(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let inMemoryLine = "[\(timestamp)] diagnostic=\(message)"
        print(inMemoryLine)
        onLine?(inMemoryLine)
        let persistentLine = "[\(timestamp)] event=diagnostic\n"
        writer.append(persistentLine, to: fileURL)
    }

    /// Persistent diagnostics deliberately retain only a bounded event category.
    /// Hermes payloads, backend output, tool data, paths, and error text remain
    /// runtime-only and must never cross this boundary.
    static func persistentEventName(for message: String) -> String {
        let prefixes: [(String, String)] = [
            ("backend", "backend"),
            ("connect", "connect"),
            ("receive", "receive"),
            ("request", "request"),
            ("send", "send"),
            ("event", "event"),
            ("model", "model"),
            ("workspace", "workspace"),
            ("voice", "voice"),
            ("composer", "composer"),
            ("status item", "status_item"),
            ("panel", "panel")
        ]
        let lowercased = message.lowercased()
        return prefixes.first(where: { lowercased.hasPrefix($0.0) })?.1 ?? "diagnostic"
    }
}

private final class DebugLogWriter {
    private let queue = DispatchQueue(label: "com.hermes-agent-dock.log-writer", qos: .utility)
    private let maximumFileSize: UInt64 = 1_048_576

    func append(_ line: String, to fileURL: URL) {
        queue.async { [maximumFileSize] in
            Self.append(line, to: fileURL, maximumFileSize: maximumFileSize)
        }
    }

    private static func append(_ line: String, to fileURL: URL, maximumFileSize: UInt64) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attributes[.size] as? NSNumber,
               size.uint64Value >= maximumFileSize {
                try Data().write(to: fileURL, options: .atomic)
            }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try Data(line.utf8).write(to: fileURL)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            print("[HermesAgentDock] Could not write log file: \(error.localizedDescription)")
        }
    }
}
