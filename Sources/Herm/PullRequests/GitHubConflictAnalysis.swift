import Darwin
import Foundation

struct GitHubConflictAnalysis: Equatable, Sendable {
    let headRevision: String
    let baseRevision: String
    let files: [String]
    let hasConflicts: Bool
    let complete: Bool
    let analyzedAt: Date
    func matches(_ record: PullRequestRecord) -> Bool {
        headRevision == record.headRevision && baseRevision == record.baseRevision
    }
}

enum GitHubConflictError: Error, LocalizedError {
    case unavailable, changed, limit, unsupported
    var errorDescription: String? {
        switch self {
        case .unavailable: "Conflict files could not be analyzed. Check GitHub access or open the PR on GitHub."
        case .changed: "The PR or base branch changed. Refresh before analyzing again."
        case .limit: "Conflict analysis reached its time or size limit. Open the PR on GitHub to continue."
        case .unsupported: "This Git installation cannot analyze conflicts. Open the PR on GitHub."
        }
    }
}

/// All objects and refs are written into a private disposable bare repository, never a user's checkout.
struct GitHubConflictService: Sendable {
    var timeout: TimeInterval = 120
    var maxBytes = 512 * 1_024 * 1_024
    func analyze(_ record: PullRequestRecord, sourceURL: URL? = nil) async throws -> GitHubConflictAnalysis {
        guard let head = record.headRevision, let base = record.baseRevision,
            Self.validRevision(head), Self.validRevision(base), record.number > 0
        else { throw GitHubConflictError.unavailable }
        let token = sourceURL == nil ? await GitHubCodeHostService.localGitHubToken() : nil
        let cancellation = GitHubProcessCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "herm-conflicts-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: root) }
                let repository = root.appendingPathComponent("repository.git", isDirectory: true)
                let deadline = Date.now.addingTimeInterval(timeout)
                var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
                environment["GIT_CONFIG_NOSYSTEM"] = "1"
                environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
                environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
                environment["GIT_TERMINAL_PROMPT"] = "0"
                environment["GIT_ASKPASS"] = "/usr/bin/false"
                environment["GIT_CONFIG_COUNT"] = token == nil ? "2" : "3"
                environment["GIT_CONFIG_KEY_0"] = "core.hooksPath"
                environment["GIT_CONFIG_VALUE_0"] = "/dev/null"
                environment["GIT_CONFIG_KEY_1"] = "credential.helper"
                environment["GIT_CONFIG_VALUE_1"] = ""
                if let token {
                    environment["GIT_CONFIG_KEY_2"] = "http.https://github.com/.extraHeader"
                    environment["GIT_CONFIG_VALUE_2"] =
                        "Authorization: Basic " + Data(("x-access-token:" + token).utf8).base64EncodedString()
                }
                func run(_ arguments: [String], allowConflicts: Bool = false) throws -> GitHubGitOutput {
                    let result = try GitHubGitProcess.run(
                        arguments, environment: environment, root: root, deadline: deadline, maxBytes: maxBytes,
                        cancellation: cancellation)
                    guard result.code == 0 || (allowConflicts && result.code == 1) else {
                        throw GitHubConflictError.unavailable
                    }
                    return result
                }
                _ = try run(["init", "--bare", "--quiet", repository.path])
                let prefix = ["-C", repository.path]
                _ = try run(prefix + ["check-ref-format", "refs/heads/" + record.baseBranch])
                let remote = sourceURL ?? record.repository.webURL.appendingPathExtension("git")
                guard remote.isFileURL || (remote.scheme == "https" && remote.host == "github.com") else {
                    throw GitHubConflictError.unavailable
                }
                _ = try run(prefix + ["remote", "add", "origin", remote.absoluteString])
                _ = try run(prefix + ["config", "remote.origin.promisor", "true"])
                _ = try run(prefix + ["config", "remote.origin.partialclonefilter", "blob:none"])
                _ = try run(
                    prefix + [
                        "fetch", "--no-tags", "--filter=blob:none", "origin",
                        "+refs/heads/\(record.baseBranch):refs/heads/herm-base",
                        "+refs/pull/\(record.number)/head:refs/heads/herm-head",
                    ])
                let actualBase = String(
                    decoding: try run(prefix + ["rev-parse", "refs/heads/herm-base"]).data, as: UTF8.self
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                let actualHead = String(
                    decoding: try run(prefix + ["rev-parse", "refs/heads/herm-head"]).data, as: UTF8.self
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard actualHead == head, actualBase == base else { throw GitHubConflictError.changed }
                let result = try run(
                    prefix + ["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", base, head],
                    allowConflicts: true)
                return try Self.parse(result.data, exitCode: result.code, head: head, base: base)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }
    static func validRevision(_ value: String) -> Bool {
        [40, 64].contains(value.count) && value.allSatisfy(\.isHexDigit)
    }
    static func parse(_ data: Data, exitCode: Int32, head: String, base: String) throws -> GitHubConflictAnalysis {
        guard exitCode == 0 || exitCode == 1 else { throw GitHubConflictError.unavailable }
        let parts = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true).map(
            String.init)
        guard let tree = parts.first, validRevision(tree) else { throw GitHubConflictError.unavailable }
        let files = Array(Set(parts.dropFirst())).sorted()
        guard files.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else {
            throw GitHubConflictError.unavailable
        }
        return GitHubConflictAnalysis(
            headRevision: head, baseRevision: base, files: files, hasConflicts: exitCode == 1,
            complete: exitCode == 0 || !files.isEmpty, analyzedAt: .now)
    }
}

private final class GitHubProcessCancellation: @unchecked Sendable {
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
private struct GitHubGitOutput {
    let data: Data
    let code: Int32
}

private enum GitHubGitProcess {
    /// A process group lets cancellation terminate Git's network/pack children as well as its parent.
    static func run(
        _ arguments: [String], environment: [String: String], root: URL, deadline: Date, maxBytes: Int,
        cancellation: GitHubProcessCancellation
    ) throws -> GitHubGitOutput {
        if cancellation.isCancelled { throw CancellationError() }
        guard Date.now < deadline else { throw GitHubConflictError.limit }
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
            argv.forEach { if let pointer = $0 { free(pointer) } }
            env.forEach { if let pointer = $0 { free(pointer) } }
        }
        var pid: pid_t = 0
        let spawned = argv.withUnsafeBufferPointer { args in
            env.withUnsafeBufferPointer { vars in
                posix_spawn(&pid, "/usr/bin/git", &actions, &attributes, args.baseAddress!, vars.baseAddress!)
            }
        }
        guard spawned == 0 else { throw GitHubConflictError.unsupported }
        var status: Int32 = 0
        var failure: Error?
        while waitpid(pid, &status, WNOHANG) == 0 {
            if cancellation.isCancelled {
                failure = CancellationError()
            } else if Date.now >= deadline || allocatedBytes(root) > maxBytes || fileBytes(output) > 2 * 1_024 * 1_024
                || fileBytes(stderr) > 2 * 1_024 * 1_024
            {
                failure = GitHubConflictError.limit
            }
            if failure != nil {
                kill(-pid, SIGTERM)
                usleep(50_000)
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                break
            }
            usleep(100_000)
        }
        if let failure { throw failure }
        if cancellation.isCancelled { throw CancellationError() }
        guard status & 0x7f == 0 else { throw GitHubConflictError.unavailable }
        let code = (status >> 8) & 0xff
        guard Date.now < deadline, allocatedBytes(root) <= maxBytes, fileBytes(output) <= 2 * 1_024 * 1_024 else {
            throw GitHubConflictError.limit
        }
        return GitHubGitOutput(data: try Data(contentsOf: output), code: code)
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
