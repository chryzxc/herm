import Darwin
import Foundation

enum HermesGitProcessError: Error { case limit, unavailable, unsupported }

final class HermesGitProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
struct HermesGitOutput {
    let data: Data
    let code: Int32
}

enum HermesGitProcess {
    /// A process group lets cancellation terminate Git's network/pack children as well as its parent.
    static func run(
        _ arguments: [String], environment: [String: String], root: URL, deadline: Date, maxBytes: Int,
        cancellation: HermesGitProcessCancellation, maxOutputBytes: Int = 2 * 1_024 * 1_024
    ) throws -> HermesGitOutput {
        if cancellation.isCancelled { throw CancellationError() }
        guard Date.now < deadline else { throw HermesGitProcessError.limit }
        let output = root.appendingPathComponent("process-output")
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, output.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        // stderr is separate so progress or diagnostics cannot be mistaken for machine-readable output.
        let stderr = root.appendingPathComponent("process-error")
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, stderr.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        let argv = (["/usr/bin/git"] + arguments).map { strdup($0) } + [nil]
        let env = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer {
            for pointer in argv { if let pointer { free(pointer) } }
            for pointer in env { if let pointer { free(pointer) } }
        }
        var pid: pid_t = 0
        let spawned = argv.withUnsafeBufferPointer { args in
            env.withUnsafeBufferPointer { vars in
                posix_spawn(&pid, "/usr/bin/git", &actions, &attributes, args.baseAddress!, vars.baseAddress!)
            }
        }
        guard spawned == 0 else { throw HermesGitProcessError.unsupported }
        var status: Int32 = 0
        var failure: Error?
        var nextSizeCheck = Date.distantPast
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if waited < 0 {
                if errno == EINTR { continue }
                failure = HermesGitProcessError.unavailable
                break
            }
            if cancellation.isCancelled {
                failure = CancellationError()
            } else if Date.now >= deadline {
                failure = HermesGitProcessError.limit
            } else if Date.now >= nextSizeCheck {
                nextSizeCheck = .now.addingTimeInterval(0.1)
                if allocatedBytes(root) > maxBytes || fileBytes(output) > maxOutputBytes
                    || fileBytes(stderr) > maxOutputBytes
                {
                    failure = HermesGitProcessError.limit
                }
            }
            if failure != nil {
                kill(-pid, SIGTERM)
                usleep(50_000)
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                break
            }
            usleep(10_000)
        }
        if let failure { throw failure }
        if cancellation.isCancelled { throw CancellationError() }
        guard status & 0x7f == 0 else { throw HermesGitProcessError.unavailable }
        let code = (status >> 8) & 0xff
        guard Date.now < deadline, allocatedBytes(root) <= maxBytes, fileBytes(output) <= maxOutputBytes,
            fileBytes(stderr) <= maxOutputBytes
        else {
            throw HermesGitProcessError.limit
        }
        return HermesGitOutput(data: try Data(contentsOf: output), code: code)
    }
    private static func fileBytes(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
    private static func allocatedBytes(_ root: URL) -> Int {
        guard
            let files = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total = 0
        for case let url as URL in files {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { total += fileBytes(url) }
        }
        return total
    }
}
