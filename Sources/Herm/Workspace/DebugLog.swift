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
    private static let writer = DebugLogWriter()
    private static let enabled = ProcessInfo.processInfo.environment["HERMES_DOCK_DEBUG_LOGS"] == "1"
        || ProcessInfo.processInfo.arguments.contains("--perf-trace")
    private static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Herm.log")
    // Allocated once: write() fires for every gateway event while responses
    // stream, and ISO8601DateFormatter construction is far too expensive for
    // that hot path.
    private static let timestampFormatter = ISO8601DateFormatter()

    static func write(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "[\(timestampFormatter.string(from: Date()))] event=\(persistentEventName(for: message()))\n"
        writer.append(line, to: fileURL)
    }

    /// Temporary state-transition diagnostics. The full message is available
    /// only to the console output; durable output is metadata-only.
    static func writeDiagnostic(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let timestamp = timestampFormatter.string(from: Date())
        writer.append(
            "[\(timestamp)] event=diagnostic\n",
            to: fileURL,
            consoleLine: "[\(timestamp)] diagnostic=\(message())\n"
        )
    }

    /// Numeric performance metrics contain no prompt, tool, path, or response
    /// data, so they can be retained verbatim for local profiling.
    static func writePerformance(_ fields: @autoclosure () -> String) {
        guard enabled else { return }
        writer.append("[\(timestampFormatter.string(from: Date()))] event=perf \(fields())\n", to: fileURL)
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

/// Aggregates hot UI signals once per second. It deliberately does not publish
/// SwiftUI state: tracing must not itself invalidate the popover being measured.
@MainActor
final class ConversationPerformanceMonitor {
    let instanceID: String
    private var startedAt = Date()
    private var modelPublications = 0
    private var scrollBoundsUpdates = 0
    private var streamingUpdates = 0
    private var scrollSettledEvents = 0
    private(set) var transcriptEvaluations = 0
    private(set) var pageTransactions = 0
    private(set) var anchorCorrections = 0

    init(instanceID: String = UUID().uuidString.prefix(8).description) {
        self.instanceID = instanceID
    }

    func recordTranscriptEvaluation() { transcriptEvaluations += 1 }
    func recordPageTransaction() { pageTransactions += 1 }
    func recordAnchorCorrection() { anchorCorrections += 1 }

    func recordModelPublication() { modelPublications += 1; flushIfNeeded() }
    func recordScrollBoundsUpdate() { scrollBoundsUpdates += 1; flushIfNeeded() }
    func recordStreamingUpdate() { streamingUpdates += 1; flushIfNeeded() }
    func recordScrollSettled() { scrollSettledEvents += 1; flushIfNeeded() }

    private func flushIfNeeded() {
        guard Date().timeIntervalSince(startedAt) >= 1 else { return }
        DebugLog.writePerformance(
            "conversation instance=\(instanceID) model_publications=\(modelPublications) scroll_bounds=\(scrollBoundsUpdates) scroll_settled=\(scrollSettledEvents) streaming=\(streamingUpdates) transcript_evaluations=\(transcriptEvaluations) pages=\(pageTransactions) anchor_corrections=\(anchorCorrections) markdown_sync_parses=\(MarkdownRenderDocumentCache.parseCount) markdown_prefetched=\(MarkdownRenderDocumentCache.prefetchedDocuments) measurement_hits=\(NativeMarkdownCompletedHeightCache.hits) measurement_misses=\(NativeMarkdownCompletedHeightCache.misses)"
        )
        startedAt = Date()
        modelPublications = 0
        scrollBoundsUpdates = 0
        streamingUpdates = 0
        scrollSettledEvents = 0
    }
}

/// Appends durable log lines on a background queue. Console output happens on
/// that queue too: print() performs synchronous stdio I/O and would otherwise
/// block the main actor for every gateway event while responses stream.
/// Mutable state is confined to the serial `queue`.
private final class DebugLogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.chryzxc.Herm.log-writer", qos: .utility)
    private let maximumFileSize: UInt64 = 1_048_576
    private let sizeCheckInterval = 256
    private var openFileURL: URL?
    private var handle: FileHandle?
    private var appendsSinceSizeCheck = 0

    func append(_ line: String, to fileURL: URL, consoleLine: String? = nil) {
        queue.async { self.appendOnQueue(line, to: fileURL, consoleLine: consoleLine) }
    }

    private func appendOnQueue(_ line: String, to fileURL: URL, consoleLine: String?) {
        do {
            try openHandleIfNeeded(for: fileURL)
            guard let handle else { return }
            print(consoleLine ?? line, terminator: "")
            try handle.write(contentsOf: Data(line.utf8))
            appendsSinceSizeCheck += 1
            if appendsSinceSizeCheck >= sizeCheckInterval {
                appendsSinceSizeCheck = 0
                try rotateIfNeeded(fileURL: fileURL)
            }
        } catch {
            closeHandle()
            print("[Herm] Could not write log file: \(error.localizedDescription)")
        }
    }

    private func openHandleIfNeeded(for fileURL: URL) throws {
        guard handle == nil || openFileURL != fileURL else { return }
        closeHandle()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try Data().write(to: fileURL)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        let newHandle = try FileHandle(forWritingTo: fileURL)
        try newHandle.seekToEnd()
        handle = newHandle
        openFileURL = fileURL
    }

    private func rotateIfNeeded(fileURL: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes[.size] as? NSNumber, size.uint64Value >= maximumFileSize else { return }
        closeHandle()
        try Data().write(to: fileURL, options: .atomic)
        try openHandleIfNeeded(for: fileURL)
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
        openFileURL = nil
    }
}
