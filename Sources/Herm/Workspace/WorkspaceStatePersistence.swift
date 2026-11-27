import Darwin
import Foundation
import OSLog

enum WorkspaceStatePersistence {
    enum LoadResult {
        case loaded(WorkspaceState)
        case missing
        case unavailable
    }

    private static let logger = Logger(subsystem: "io.github.chryzxc.Herm", category: "WorkspacePersistence")
    static let saveQueue = DispatchQueue(label: "io.github.chryzxc.Herm.workspace-store-save", qos: .utility)

    static func load(_ url: URL) -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let entryIsMissing = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return false }
                var entry = stat()
                return lstat(path, &entry) == -1 && errno == ENOENT
            }
            if (error as NSError).domain == NSCocoaErrorDomain,
                (error as NSError).code == NSFileReadNoSuchFileError, entryIsMissing
            {
                return .missing
            }
            logger.warning("Workspace state could not be read; changes are temporary.")
            return .unavailable
        }
        do {
            return .loaded(try JSONDecoder.workspace.decode(WorkspaceState.self, from: data))
        } catch {
            logger.warning("Workspace state could not be decoded; changes are temporary.")
            return .unavailable
        }
    }

    static func enqueue(_ state: WorkspaceState, to fileURL: URL) {
        saveQueue.async {
            write(state, to: fileURL)
        }
    }

    static func drain(_ queue: DispatchQueue, timeout: DispatchTimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        let finished = DispatchSemaphore(value: 0)
        queue.async { finished.signal() }
        return finished.wait(timeout: deadline) == .success
    }

    @MainActor @discardableResult
    static func flushPendingSaves() -> Bool {
        let finished = drain(saveQueue, timeout: .seconds(1))
        if !finished { logger.warning("Workspace saves did not finish before quit.") }
        return finished
    }

    private static func write(_ state: WorkspaceState, to fileURL: URL) {
        guard let data = try? JSONEncoder.workspace.encode(state) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            let detail = error.localizedDescription
            Task { @MainActor in
                DebugLog.write("workspace: persistence failed: \(detail)")
            }
        }
    }
}
