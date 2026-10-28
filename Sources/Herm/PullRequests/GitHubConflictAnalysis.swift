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
        let cancellation = HermesGitProcessCancellation()
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
                func run(_ arguments: [String], allowConflicts: Bool = false) throws -> HermesGitOutput {
                    let result: HermesGitOutput
                    do {
                        result = try HermesGitProcess.run(
                            arguments, environment: environment, root: root, deadline: deadline, maxBytes: maxBytes,
                            cancellation: cancellation)
                    } catch HermesGitProcessError.limit {
                        throw GitHubConflictError.limit
                    } catch HermesGitProcessError.unsupported {
                        throw GitHubConflictError.unsupported
                    } catch is HermesGitProcessError {
                        throw GitHubConflictError.unavailable
                    }
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
