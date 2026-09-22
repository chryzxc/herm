import CryptoKit
import Foundation

enum RepositoryFileStatus: String, Equatable {
    case modified, added, deleted, renamed, untracked, conflicted, unknown
}

struct RepositoryFileChange: Identifiable, Equatable {
    let path: String
    let status: RepositoryFileStatus
    let isStaged: Bool
    let renameSource: String?
    var id: String { "\(isStaged ? "staged" : "worktree"):\(path)" }
}

/// A compact, deterministic tree projection for the Changes explorer. It is
/// intentionally limited to files Git reports as changed; browsing arbitrary
/// project files stays outside the Dock's source-control surface.
struct RepositoryExplorerEntry: Identifiable, Equatable {
    let path: String
    let depth: Int
    let isDirectory: Bool
    let change: RepositoryFileChange?

    var id: String { "\(isDirectory ? "directory" : "file"):\(path)" }
}

struct ProjectFileEntry: Identifiable, Equatable {
    let path: String
    let depth: Int
    let isDirectory: Bool
    var id: String { "\(isDirectory ? "directory" : "file"):\(path)" }
}

struct RepositoryChangeSnapshot: Equatable {
    let repositoryID: String
    let headRevision: String?
    let branch: String
    let files: [RepositoryFileChange]
    let refreshedAt: Date

    var changedFiles: Int { files.count }
    var stagedCount: Int { files.filter(\.isStaged).count }
    var unstagedCount: Int { files.filter { !$0.isStaged && $0.status != .untracked }.count }
    var untrackedCount: Int { files.filter { $0.status == .untracked }.count }
    var conflictedCount: Int { files.filter { $0.status == .conflicted }.count }
}

struct RepositoryDiff: Equatable {
    let path: String
    let text: String
    let isTruncated: Bool
    let isStaged: Bool
}

struct RepositoryBlameCommit: Identifiable, Equatable {
    let hash: String
    let author: String
    let authoredAt: Date?
    let summary: String
    let isUncommitted: Bool

    var id: String { hash }

    var shortHash: String {
        String(hash.prefix(8))
    }
}

struct RepositoryBlameLine: Identifiable, Equatable {
    let lineNumber: Int
    let text: String
    let commit: RepositoryBlameCommit

    var id: Int { lineNumber }
}

struct RepositoryBlameDocument: Equatable {
    let path: String
    let lines: [RepositoryBlameLine]
}

enum RepositoryBlameResult: Equatable {
    case available(RepositoryBlameDocument)
    case unavailable(String)
}

/// A bounded, UTF-8 text file projection for the Dock's inline code workspace.
/// The repository remains the canonical owner; this is only an ephemeral editor
/// draft rendered inside the menu-bar popover.
struct RepositoryFileDocument: Identifiable, Equatable {
    let path: String
    let contents: String
    let byteCount: Int

    var id: String { path }
}

enum RepositoryDiffAuditSeverity: String, Equatable {
    case blocker, warning, note
}

struct RepositoryDiffAuditFinding: Identifiable, Equatable {
    let ruleID: String
    let severity: RepositoryDiffAuditSeverity
    let path: String
    let line: Int?
    let title: String
    let detail: String

    var id: String { "\(path):\(line ?? 0):\(ruleID)" }
}

enum RepositoryReviewCompleteness: String, Equatable {
    case complete, partial
}

struct RepositoryReviewFile: Identifiable, Equatable {
    let change: RepositoryFileChange
    let findings: [RepositoryDiffAuditFinding]
    let isTruncated: Bool
    let isBinary: Bool
    let isReadable: Bool
    let contentIdentity: String?
    var id: String { change.id }
}

struct RepositoryReviewSnapshot: Equatable {
    let repositoryID: String
    let headRevision: String?
    let fingerprint: String
    let files: [RepositoryReviewFile]
    let completeness: RepositoryReviewCompleteness
    let refreshedAt: Date
    let omittedFileCount: Int

    var findings: [RepositoryDiffAuditFinding] { files.flatMap(\.findings) }
    var blockerCount: Int { findings.filter { $0.severity == .blocker }.count }
    var warningCount: Int { findings.filter { $0.severity == .warning }.count }
    var noteCount: Int { findings.filter { $0.severity == .note }.count }
}

struct RepositoryWorktreeSummary: Identifiable, Equatable {
    let path: String
    let displayName: String
    let branch: String?
    let headRevision: String?
    let isDetached: Bool
    let isLocked: Bool
    let isPrunable: Bool
    let snapshot: RepositorySnapshot?
    var id: String { RepositorySnapshot.stableID(path: path) }
}

/// A deliberately small pre-commit signal pass over added diff lines. It never
/// returns source text, so credential-like values cannot leak into the UI.
enum RepositoryDiffAuditor {
    static func audit(_ diff: RepositoryDiff) -> [RepositoryDiffAuditFinding] {
        var results: [RepositoryDiffAuditFinding] = []
        var newLine: Int?

        for row in diff.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if row.hasPrefix("@@") {
                newLine = newLineStart(from: row)
                continue
            }
            guard let line = newLine else { continue }
            if row.hasPrefix("+") && !row.hasPrefix("+++") {
                let source = String(row.dropFirst())
                results.append(contentsOf: findings(in: source, path: diff.path, line: line))
                newLine = line + 1
            } else if row.hasPrefix("-") && !row.hasPrefix("---") {
                continue
            } else {
                newLine = line + 1
            }
        }
        return results
    }

    private static func findings(in source: String, path: String, line: Int) -> [RepositoryDiffAuditFinding] {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        var result: [RepositoryDiffAuditFinding] = []

        if trimmed.hasPrefix("<<<<<<<") || trimmed.hasPrefix("=======") || trimmed.hasPrefix(">>>>>>>") {
            result.append(finding("conflict-marker", .blocker, path, line, "Conflict marker added", "Resolve the merge marker before committing."))
        }
        if looksLikeCredentialAssignment(lower) {
            result.append(finding("credential-assignment", .blocker, path, line, "Possible credential added", "Inspect this line for a hardcoded secret. The value is intentionally hidden."))
        }
        if lower.contains("console.log(") || lower.contains("debugger;") || lower.contains("breakpoint()") || lower.contains("nslog(") || lower.contains("print(") {
            result.append(finding("debug-statement", .warning, path, line, "Debug statement added", "Confirm the diagnostic output is intentional."))
        }
        if lower.contains("todo") || lower.contains("fixme") {
            result.append(finding("unfinished-marker", .note, path, line, "Unfinished-work marker added", "Review the TODO or FIXME before shipping."))
        }
        if lower.range(of: #"^except\s*:"#, options: .regularExpression) != nil {
            result.append(finding("bare-except", .warning, path, line, "Bare except clause added", "Catch a specific exception or document why a broad catch is required."))
        }
        return result
    }

    private static func looksLikeCredentialAssignment(_ lower: String) -> Bool {
        let keyTerms = ["api_key", "api-key", "apikey", "secret", "password", "passwd", "access_token", "auth_token", "private_key"]
        guard keyTerms.contains(where: lower.contains) else { return false }
        return lower.contains("=") || lower.contains(":")
    }

    private static func newLineStart(from hunk: String) -> Int? {
        guard let plus = hunk.firstIndex(of: "+") else { return nil }
        let suffix = hunk[hunk.index(after: plus)...]
        let digits = suffix.prefix(while: { $0.isNumber })
        return Int(digits)
    }

    private static func finding(_ ruleID: String, _ severity: RepositoryDiffAuditSeverity, _ path: String, _ line: Int, _ title: String, _ detail: String) -> RepositoryDiffAuditFinding {
        RepositoryDiffAuditFinding(ruleID: ruleID, severity: severity, path: path, line: line, title: title, detail: detail)
    }
}

struct RepositorySnapshot: Equatable {
    var path: String
    var branch: String
    var changedFiles: Int
    var latestCommit: String
    var isGitRepository: Bool
    var repositoryID: String
    var headRevision: String?
    var stagedFiles: Int
    var unstagedFiles: Int
    var untrackedFiles: Int
    var conflictedFiles: Int
    var aheadCount: Int?
    var behindCount: Int?
    var worktreeCount: Int
    var stashCount: Int
    var operation: String?
    var refreshedAt: Date
    var isStale: Bool

    init(path: String, branch: String, changedFiles: Int, latestCommit: String, isGitRepository: Bool, repositoryID: String? = nil, headRevision: String? = nil, stagedFiles: Int = 0, unstagedFiles: Int = 0, untrackedFiles: Int = 0, conflictedFiles: Int = 0, aheadCount: Int? = nil, behindCount: Int? = nil, worktreeCount: Int = 0, stashCount: Int = 0, operation: String? = nil, refreshedAt: Date = .now, isStale: Bool = false) {
        self.path = path
        self.branch = branch
        self.changedFiles = changedFiles
        self.latestCommit = latestCommit
        self.isGitRepository = isGitRepository
        self.repositoryID = repositoryID ?? Self.stableID(path: path)
        self.headRevision = headRevision
        self.stagedFiles = stagedFiles
        self.unstagedFiles = unstagedFiles
        self.untrackedFiles = untrackedFiles
        self.conflictedFiles = conflictedFiles
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.worktreeCount = worktreeCount
        self.stashCount = stashCount
        self.operation = operation
        self.refreshedAt = refreshedAt
        self.isStale = isStale
    }

    static let empty = RepositorySnapshot(path: "", branch: "No repository selected", changedFiles: 0, latestCommit: "", isGitRepository: false)

    static func stableID(path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

enum RepositoryService {
    private static let maxDiffBytes = 48_000
    private static let maxDiffLines = 900
    static let maxDocumentBytes = 256_000
    static let maxReviewFiles = 200
    static let maxConcurrentWorktreeInspections = 8
    static let maxProjectExplorerEntries = 400
    static let maxBlameLines = 10_000

    static func inspect(path: String) async -> RepositorySnapshot {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let branchResult = await runGit(path: normalizedPath, arguments: ["branch", "--show-current"])
        guard branchResult.exitCode == 0 else {
            return RepositorySnapshot(path: normalizedPath, branch: "Not a Git repository", changedFiles: 0, latestCommit: "", isGitRepository: false)
        }
        async let changes = changeSnapshot(path: normalizedPath)
        async let head = runGit(path: normalizedPath, arguments: ["rev-parse", "--short", "HEAD"])
        async let commit = runGit(path: normalizedPath, arguments: ["log", "-1", "--pretty=format:%h %s"])
        async let upstream = runGit(path: normalizedPath, arguments: ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"])
        async let worktrees = runGit(path: normalizedPath, arguments: ["worktree", "list", "--porcelain"])
        async let stashes = runGit(path: normalizedPath, arguments: ["stash", "list"])
        async let operation = operationState(path: normalizedPath)
        let result = await changes
        let headResult = await head
        let commitResult = await commit
        let upstreamResult = await upstream
        let worktreeResult = await worktrees
        let stashResult = await stashes
        let currentOperation = await operation
        let counts = upstreamCounts(upstreamResult)
        return RepositorySnapshot(
            path: normalizedPath,
            branch: branchResult.output.isEmpty ? "detached HEAD" : branchResult.output,
            changedFiles: result.changedFiles,
            latestCommit: commitResult.output,
            isGitRepository: true,
            headRevision: headResult.exitCode == 0 ? headResult.output : nil,
            stagedFiles: result.stagedCount,
            unstagedFiles: result.unstagedCount,
            untrackedFiles: result.untrackedCount,
            conflictedFiles: result.conflictedCount,
            aheadCount: counts?.ahead,
            behindCount: counts?.behind,
            worktreeCount: worktreeResult.output.split(separator: "\n").filter { $0.hasPrefix("worktree ") }.count,
            stashCount: stashResult.output.split(separator: "\n", omittingEmptySubsequences: true).count,
            operation: currentOperation
        )
    }

    /// Returns local branches in the order Git reports them. Keeping this
    /// scoped to local branches makes the picker safe to use with `switch` and
    /// avoids silently creating tracking branches from remotes.
    static func branches(path: String) async -> [String] {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let result = await runGit(path: normalizedPath, arguments: ["branch", "--format=%(refname:short)"])
        guard result.exitCode == 0 else { return [] }
        return result.output
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func githubRemote(path: String) async -> GitHubRepositoryReference? {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let result = await runGit(path: normalizedPath, arguments: ["remote", "get-url", "origin"])
        guard result.exitCode == 0 else { return nil }
        return GitHubRemoteParser.parse(result.output)
    }

    /// Switches the working tree to an existing local branch.
    static func switchBranch(path: String, branch: String) async -> (success: Bool, error: String?) {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !branch.isEmpty, !branch.contains("\0"), !branch.contains("\n") else {
            return (false, "Invalid branch name")
        }
        let result = await runGit(path: normalizedPath, arguments: ["switch", "--no-guess", "--", branch])
        return result.exitCode == 0 ? (true, nil) : (false, result.output.isEmpty ? "Git could not switch branches" : result.output)
    }

    static func changeSnapshot(path: String) async -> RepositoryChangeSnapshot {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let status = await runGit(path: normalizedPath, arguments: ["status", "--porcelain=v1", "-z"])
        let branch = await runGit(path: normalizedPath, arguments: ["branch", "--show-current"])
        let head = await runGit(path: normalizedPath, arguments: ["rev-parse", "--short", "HEAD"])
        let files = status.exitCode == 0 ? parsePorcelainV1(status.output) : []
        return RepositoryChangeSnapshot(repositoryID: RepositorySnapshot.stableID(path: normalizedPath), headRevision: head.exitCode == 0 ? head.output : nil, branch: branch.output.isEmpty ? "detached HEAD" : branch.output, files: files, refreshedAt: .now)
    }

    static func explorerEntries(for files: [RepositoryFileChange]) -> [RepositoryExplorerEntry] {
        var entries: [RepositoryExplorerEntry] = []
        var knownDirectories = Set<String>()
        for file in files.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            let components = file.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            for index in components.indices.dropLast() {
                let directory = components[...index].joined(separator: "/")
                if knownDirectories.insert(directory).inserted {
                    entries.append(RepositoryExplorerEntry(path: directory, depth: index, isDirectory: true, change: nil))
                }
            }
            entries.append(RepositoryExplorerEntry(path: file.path, depth: max(0, components.count - 1), isDirectory: false, change: file))
        }
        return entries
    }

    static func projectFiles(path: String, includeGenerated: Bool = false) async -> [ProjectFileEntry] {
        let root = URL(fileURLWithPath: path).standardizedFileURL
        return await Task.detached(priority: .utility) {
            // Keep the project tree faithful to the filesystem. Hidden
            // project files such as .github, .husky, and dotfiles are useful
            // source files. Generated/dependency trees are omitted by default
            // and can be explicitly requested by the Explorer presentation;
            // dependency folders remain shallow to avoid enormous scans.
            let skippedTrees = Set([".git"])
            let generatedTrees = Set([".cache", ".build", "DerivedData", "node_modules", "build", "dist", "coverage"])
            let shallowTrees = Set(["node_modules", "build", "dist", "coverage"])
            var entries: [ProjectFileEntry] = []

            func visit(_ directory: URL, depth: Int, isRoot: Bool = false) {
                guard let children = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                    options: []
                ) else { return }

                let sortedChildren = children.sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
                var directories: [URL] = []

                // Add every direct child before descending. This guarantees
                // that a large folder cannot consume the entry budget and
                // hide sibling files at the project root.
                for url in sortedChildren {
                    let name = url.lastPathComponent
                    if skippedTrees.contains(name) { continue }
                    if !includeGenerated && generatedTrees.contains(name) { continue }
                    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                    if attributes?[.type] as? FileAttributeType == .typeSymbolicLink { continue }
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                    guard values?.isDirectory == true || values?.isRegularFile == true else { continue }
                    if !isRoot && entries.count >= maxProjectExplorerEntries { continue }
                    let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                    let components = relative.split(separator: "/").map(String.init)
                    guard !components.isEmpty else { continue }
                    let isDirectory = values?.isDirectory == true
                    entries.append(ProjectFileEntry(path: relative, depth: components.count - 1, isDirectory: isDirectory))
                    if isDirectory && !shallowTrees.contains(name) {
                        directories.append(url)
                    }
                }

                for directory in directories {
                    visit(directory, depth: depth + 1)
                }
            }

            visit(root, depth: 0, isRoot: true)
            return entries.sorted { lhs, rhs in
                if lhs.path == rhs.path { return lhs.isDirectory && !rhs.isDirectory }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
        }.value
    }

    static func diff(path: String, file: RepositoryFileChange) async -> RepositoryDiff? {
        guard isSafeRelativePath(file.path) else { return nil }
        let command = diffCommand(for: file)
        let result = await runGit(path: path, arguments: command.arguments)
        guard command.successCodes.contains(result.exitCode) else { return nil }
        let bounded = boundDiff(result.output)
        return RepositoryDiff(path: file.path, text: bounded.text, isTruncated: bounded.isTruncated, isStaged: file.isStaged)
    }

    static func loadDocument(path repositoryPath: String, filePath: String) async -> RepositoryFileDocument? {
        guard let url = documentURL(repositoryPath: repositoryPath, filePath: filePath) else { return nil }
        return await Task.detached(priority: .utility) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let data = try? Data(contentsOf: url),
                  data.count <= maxDocumentBytes,
                  let contents = String(data: data, encoding: .utf8) else { return nil }
            return RepositoryFileDocument(path: filePath, contents: contents, byteCount: data.count)
        }.value
    }

    static func blame(path repositoryPath: String, filePath: String) async -> RepositoryBlameResult {
        guard isSafeRelativePath(filePath) else {
            return .unavailable("Blame is unavailable for this file path.")
        }

        let result = await runGit(
            path: repositoryPath,
            arguments: ["blame", "--line-porcelain", "--", filePath],
            trimOutput: false
        )
        guard result.exitCode == 0 else {
            return .unavailable("Blame is unavailable for untracked, binary, or non-Git files.")
        }

        guard blameLineCount(in: result.output) <= maxBlameLines else {
            return .unavailable("Blame is unavailable for files over \(maxBlameLines.formatted()) lines.")
        }

        guard let document = parseBlamePorcelain(result.output, path: filePath) else {
            return .unavailable("Git returned incomplete blame information for this file.")
        }
        return .available(document)
    }

    /// Writes only a regular UTF-8 file inside the active repository. The
    /// caller refreshes Git projections afterwards; no editor state is stored.
    static func saveDocument(path repositoryPath: String, filePath: String, contents: String) async -> Bool {
        guard let url = documentURL(repositoryPath: repositoryPath, filePath: filePath),
              contents.lengthOfBytes(using: .utf8) <= maxDocumentBytes else { return false }
        return await Task.detached(priority: .utility) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { return false }
            do {
                try Data(contents.utf8).write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        }.value
    }

    static func documentURL(repositoryPath: String, filePath: String) -> URL? {
        guard isSafeRelativePath(filePath) else { return nil }
        let root = URL(fileURLWithPath: repositoryPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let file = root.appendingPathComponent(filePath).standardizedFileURL
        let resolvedFile = file.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(rootPath), resolvedFile.path == file.path else { return nil }
        return file
    }

    static func review(path: String) async -> RepositoryReviewSnapshot? {
        let changes = await changeSnapshot(path: path)
        let inspected = Array(changes.files.prefix(maxReviewFiles))
        let omitted = max(0, changes.files.count - inspected.count)
        var results: [RepositoryReviewFile] = []
        await withTaskGroup(of: RepositoryReviewFile.self) { group in
            var iterator = inspected.makeIterator()
            for _ in 0..<min(4, inspected.count) {
                if let file = iterator.next() { group.addTask { await reviewFile(path: path, file: file) } }
            }
            while let completed = await group.next() {
                results.append(completed)
                if let file = iterator.next() { group.addTask { await reviewFile(path: path, file: file) } }
            }
        }
        results.sort { $0.change.id < $1.change.id }
        let partial = omitted > 0 || results.contains { !$0.isReadable || $0.isTruncated || $0.isBinary }
        let fingerprint = await canonicalFingerprint(path: path, changes: changes)
        return RepositoryReviewSnapshot(repositoryID: changes.repositoryID, headRevision: changes.headRevision, fingerprint: fingerprint, files: results, completeness: partial ? .partial : .complete, refreshedAt: .now, omittedFileCount: omitted)
    }

    /// Stable, content-free identity for baseline invalidation and watch events.
    static func fingerprint(path: String) async -> String? {
        let changes = await changeSnapshot(path: path)
        return await canonicalFingerprint(path: path, changes: changes)
    }

    private static func canonicalFingerprint(path: String, changes: RepositoryChangeSnapshot) async -> String {
        let identities = await withTaskGroup(of: String.self, returning: [String].self) { group in
            var iterator = changes.files.makeIterator()
            for _ in 0..<min(4, changes.files.count) {
                if let file = iterator.next() {
                    group.addTask { "\(file.id)|\(file.status.rawValue)|\(await fileIdentity(path: path, file: file) ?? "unavailable")" }
                }
            }
            var values: [String] = []
            while let value = await group.next() {
                values.append(value)
                if let file = iterator.next() {
                    group.addTask { "\(file.id)|\(file.status.rawValue)|\(await fileIdentity(path: path, file: file) ?? "unavailable")" }
                }
            }
            return values
        }
        return fingerprint(repositoryID: changes.repositoryID, headRevision: changes.headRevision, identities: identities)
    }

    static func fingerprint(repositoryID: String, headRevision: String?, identities: [String]) -> String {
        let input = ([repositoryID, headRevision ?? "no-head"] + identities.sorted()).joined(separator: "\n")
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func worktrees(path: String) async -> [RepositoryWorktreeSummary] {
        let result = await runGit(path: path, arguments: ["worktree", "list", "--porcelain", "-z"])
        guard result.exitCode == 0 else { return [] }
        let records = result.output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var rows: [[String]] = [[]]
        for record in records {
            if record.hasPrefix("worktree "), !rows.last!.isEmpty { rows.append([]) }
            rows[rows.count - 1].append(record)
        }
        return await withTaskGroup(of: RepositoryWorktreeSummary?.self, returning: [RepositoryWorktreeSummary].self) { group in
            var iterator = rows.makeIterator()
            func add(_ row: [String]) {
                group.addTask {
                    guard let worktree = row.first(where: { $0.hasPrefix("worktree ") }) else { return nil }
                    let worktreePath = String(worktree.dropFirst("worktree ".count))
                    let branchRow = row.first(where: { $0.hasPrefix("branch ") })
                    let branch = branchRow.map { URL(fileURLWithPath: String($0.dropFirst("branch ".count))).lastPathComponent }
                    let head = row.first(where: { $0.hasPrefix("HEAD ") }).map { String($0.dropFirst("HEAD ".count).prefix(12)) }
                    let snapshot = await inspect(path: worktreePath)
                    return RepositoryWorktreeSummary(path: worktreePath, displayName: URL(fileURLWithPath: worktreePath).lastPathComponent, branch: branch, headRevision: head, isDetached: branch == nil, isLocked: row.contains(where: { $0 == "locked" || $0.hasPrefix("locked ") }), isPrunable: row.contains(where: { $0.hasPrefix("prunable") }), snapshot: snapshot.isGitRepository ? snapshot : nil)
                }
            }
            for _ in 0..<min(maxConcurrentWorktreeInspections, rows.count) {
                if let row = iterator.next() { add(row) }
            }
            var summaries: [RepositoryWorktreeSummary] = []
            while let summary = await group.next() {
                if let summary { summaries.append(summary) }
                if let row = iterator.next() { add(row) }
            }
            return summaries.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }
    }

    private static func reviewFile(path: String, file: RepositoryFileChange) async -> RepositoryReviewFile {
        let loaded = await diff(path: path, file: file)
        let binary = loaded?.text.contains("Binary files") == true
        let identity = await fileIdentity(path: path, file: file)
        return RepositoryReviewFile(change: file, findings: loaded.map(RepositoryDiffAuditor.audit) ?? [], isTruncated: loaded?.isTruncated ?? false, isBinary: binary, isReadable: loaded != nil, contentIdentity: identity)
    }

    private static func fileIdentity(path: String, file: RepositoryFileChange) async -> String? {
        guard isSafeRelativePath(file.path) else { return nil }
        if file.isStaged {
            let result = await runGit(path: path, arguments: ["rev-parse", ":\(file.path)"])
            return result.exitCode == 0 ? result.output : nil
        }
        if file.status == .deleted { return "deleted" }
        let result = await runGit(path: path, arguments: ["hash-object", "--no-filters", "--", file.path])
        return result.exitCode == 0 ? result.output : nil
    }

    static func diffCommand(for file: RepositoryFileChange) -> (arguments: [String], successCodes: Set<Int32>) {
        if file.status == .untracked {
            // `git diff --no-index` returns 1 when it successfully finds a
            // difference. Comparing with /dev/null keeps new-file review
            // read-only while producing a normal bounded unified diff.
            return (["diff", "--no-index", "--no-ext-diff", "--unified=3", "--", "/dev/null", file.path], [0, 1])
        }
        return ((file.isStaged ? ["diff", "--cached"] : ["diff"]) + ["--no-ext-diff", "--unified=3", "--", file.path], [0])
    }

    static func parsePorcelainV1(_ output: String) -> [RepositoryFileChange] {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var result: [RepositoryFileChange] = []
        var index = 0
        while index < records.count {
            let row = records[index]
            guard row.count >= 4 else { index += 1; continue }
            let chars = Array(row)
            let indexCode = chars[0]
            let worktreeCode = chars[1]
            let path = String(row.dropFirst(3))
            let isRename = indexCode == "R" || indexCode == "C"
            let renameSource = isRename && index + 1 < records.count ? records[index + 1] : nil
            let staged = indexCode != " " && indexCode != "?"
            let worktree = worktreeCode != " " && worktreeCode != "?"
            if indexCode == "?" && worktreeCode == "?" {
                result.append(RepositoryFileChange(path: path, status: .untracked, isStaged: false, renameSource: nil))
            } else if indexCode == "U" || worktreeCode == "U" || (indexCode == "A" && worktreeCode == "A") {
                result.append(RepositoryFileChange(path: path, status: .conflicted, isStaged: staged, renameSource: renameSource))
            } else {
                if staged { result.append(RepositoryFileChange(path: path, status: status(for: indexCode), isStaged: true, renameSource: renameSource)) }
                if worktree { result.append(RepositoryFileChange(path: path, status: status(for: worktreeCode), isStaged: false, renameSource: nil)) }
            }
            index += isRename ? 2 : 1
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func boundDiff(_ value: String) -> (text: String, isTruncated: Bool) {
        let byteBound = String(decoding: value.utf8.prefix(maxDiffBytes), as: UTF8.self)
        let lines = byteBound.split(separator: "\n", omittingEmptySubsequences: false)
        let limitedLines = lines.prefix(maxDiffLines)
        let text = limitedLines.joined(separator: "\n")
        return (text, value.utf8.count > maxDiffBytes || lines.count > maxDiffLines)
    }

    static func parseBlamePorcelain(_ output: String, path: String = "") -> RepositoryBlameDocument? {
        let rows = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lines: [RepositoryBlameLine] = []
        var index = 0

        while index < rows.count {
            let header = rows[index]
            let fields = header.split(separator: " ", omittingEmptySubsequences: true)
            if header.isEmpty && index == rows.index(before: rows.endIndex) {
                break
            }
            guard fields.count >= 3,
                  fields[0].count == 40,
                  Int(fields[2]) != nil else {
                return nil
            }

            let hash = String(fields[0])
            let finalLine = Int(fields[2])!
            var author = "Unknown author"
            var authoredAt: Date?
            var summary = "No commit subject"
            var sourceText: String?
            index += 1

            while index < rows.count {
                let row = rows[index]
                if row.hasPrefix("\t") {
                    sourceText = String(row.dropFirst())
                    index += 1
                    break
                }
                if row.hasPrefix("author ") {
                    author = String(row.dropFirst("author ".count))
                } else if row.hasPrefix("author-time ") {
                    authoredAt = Date(timeIntervalSince1970: TimeInterval(String(row.dropFirst("author-time ".count))) ?? 0)
                } else if row.hasPrefix("summary ") {
                    summary = String(row.dropFirst("summary ".count))
                }
                index += 1
            }

            guard let sourceText else { return nil }
            let isUncommitted = hash.allSatisfy { $0 == "0" }
            let commit = RepositoryBlameCommit(
                hash: hash,
                author: isUncommitted ? "Not committed yet" : author,
                authoredAt: isUncommitted ? nil : authoredAt,
                summary: isUncommitted ? "Working tree changes" : summary,
                isUncommitted: isUncommitted
            )
            lines.append(RepositoryBlameLine(lineNumber: finalLine, text: sourceText, commit: commit))
        }

        guard !lines.isEmpty || output.isEmpty else { return nil }
        return RepositoryBlameDocument(path: path, lines: lines)
    }

    private static func blameLineCount(in output: String) -> Int {
        output.split(separator: "\n", omittingEmptySubsequences: false).reduce(into: 0) { count, row in
            let fields = row.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 3, fields[0].count == 40, Int(fields[2]) != nil {
                count += 1
            }
        }
    }

    private static func status(for code: Character) -> RepositoryFileStatus {
        switch code {
        case "M": .modified
        case "A": .added
        case "D": .deleted
        case "R", "C": .renamed
        case "U": .conflicted
        default: .unknown
        }
    }

    private static func upstreamCounts(_ result: (output: String, exitCode: Int32)) -> (ahead: Int, behind: Int)? {
        guard result.exitCode == 0 else { return nil }
        let parts = result.output.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 2, let ahead = Int(parts[0]), let behind = Int(parts[1]) else { return nil }
        return (ahead, behind)
    }

    private static func operationState(path: String) async -> String? {
        for (file, name) in [("MERGE_HEAD", "Merge"), ("CHERRY_PICK_HEAD", "Cherry-pick"), ("REVERT_HEAD", "Revert"), ("rebase-merge", "Rebase"), ("rebase-apply", "Rebase")] {
            let result = await runGit(path: path, arguments: ["rev-parse", "--git-path", file])
            guard result.exitCode == 0, !result.output.isEmpty else { continue }
            let resolved = URL(fileURLWithPath: path).appendingPathComponent(result.output).path
            if FileManager.default.fileExists(atPath: resolved) { return name }
        }
        return nil
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..") && !path.contains("\0")
    }

    private static func runGit(path: String, arguments: [String], trimOutput: Bool = true) async -> (output: String, exitCode: Int32) {
        await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", path] + arguments
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let rawOutput = String(data: data, encoding: .utf8) ?? ""
                let output = trimOutput ? rawOutput.trimmingCharacters(in: .whitespacesAndNewlines) : rawOutput
                return (output, process.terminationStatus)
            } catch {
                return ("", 1)
            }
        }.value
    }
}
