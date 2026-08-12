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

/// Short-lived, raw activity diagnostics used to reconcile Hermes event
/// ownership. Unlike `DebugLog`, this intentionally retains event payloads;
/// it is owner-only, reset for every app launch, and never shown in the app.
/// Send it only when you are comfortable sharing the tool inputs and outputs
/// that Hermes emitted during the captured run.
enum ActivityAttributionTrace {
    static let fileURL: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return root
            .appendingPathComponent("HermesAgentDock", isDirectory: true)
            .appendingPathComponent("activity-attribution-trace.jsonl")
    }()

    private static let queue = DispatchQueue(label: "com.hermes-agent-dock.activity-attribution-trace", qos: .utility)
    private static let maximumFileSize: UInt64 = 5 * 1_024 * 1_024

    static func reset() {
        queue.sync {
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: fileURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            } catch {
                print("[HermesAgentDock] Could not reset activity trace: \(error.localizedDescription)")
            }
        }
    }

    static func append(_ stage: String, fields: [String: Any]) {
        var entry = fields
        entry["timestamp"] = ISO8601DateFormatter().string(from: Date())
        entry["stage"] = stage
        guard JSONSerialization.isValidJSONObject(entry),
              let encoded = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {
            print("[HermesAgentDock] Could not encode activity trace entry for \(stage)")
            return
        }
        let line = encoded + Data("\n".utf8)
        queue.async {
            do {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                   let size = attributes[.size] as? NSNumber,
                   size.uint64Value + UInt64(line.count) >= maximumFileSize {
                    try Data().write(to: fileURL, options: .atomic)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            } catch {
                print("[HermesAgentDock] Could not write activity trace: \(error.localizedDescription)")
            }
        }
    }
}
