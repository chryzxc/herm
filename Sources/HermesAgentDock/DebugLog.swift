import Foundation

@MainActor
enum DebugLog {
    static var onLine: ((String) -> Void)?
    private static let writer = DebugLogWriter()
    private static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/HermesAgentDock.log")

    static func write(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        print(line, terminator: "")
        onLine?(line.trimmingCharacters(in: .newlines))
        writer.append(line, to: fileURL)
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
        } catch {
            print("[HermesAgentDock] Could not write log file: \(error.localizedDescription)")
        }
    }
}
