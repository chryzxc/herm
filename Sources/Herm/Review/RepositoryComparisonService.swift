import CryptoKit
import Foundation

struct RepositoryComparison {
    enum Scope: String, CaseIterable, Identifiable {
        case working = "Working tree"
        case staged = "Staged"
        case branch = "Branch"
        case commit = "Commit"
        var id: String { rawValue }
    }
    let title: String
    let revision: String
    let files: [String]
    let arguments: [String]
    let fingerprint: String
    let partial: Bool
    var renameSources: [String: String] = [:]
    var identity: String { revision + ":" + fingerprint + ":" + arguments.joined(separator: " ") }
}

enum RepositoryComparisonService {
    static func references(path: String) async -> [String] {
        let result = await RepositoryService.runGit(
            path: path, arguments: ["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"])
        guard result.exitCode == 0 else { return [] }
        return Array(result.output.split(separator: "\n").map(String.init).prefix(500))
    }
    static func load(path: String, scope: RepositoryComparison.Scope, reference: String, ignoreWhitespace: Bool)
        async throws -> RepositoryComparison
    {
        let head = await RepositoryService.runGit(path: path, arguments: ["rev-parse", "--verify", "HEAD"])
        guard head.exitCode == 0 else {
            throw QuickDraftError.message("The selected folder has no readable Git revision.")
        }
        var arguments = ["diff", "--no-ext-diff", "--find-renames"]
        var revision = head.output
        switch scope {
        case .working: break
        case .staged: arguments.append("--cached")
        case .branch, .commit:
            guard !reference.isEmpty, reference.count <= 256, !reference.contains("\n") else {
                throw QuickDraftError.message("Choose a valid Git reference.")
            }
            let resolved = await RepositoryService.runGit(
                path: path, arguments: ["rev-parse", "--verify", "--end-of-options", reference + "^{commit}"])
            guard resolved.exitCode == 0 else {
                throw QuickDraftError.message(
                    "The comparison reference is unavailable locally. No fetch was performed.")
            }
            revision = resolved.output
            if scope == .branch {
                let base = await RepositoryService.runGit(path: path, arguments: ["merge-base", revision, head.output])
                guard base.exitCode == 0 else {
                    throw QuickDraftError.message("These branches have no readable common ancestor.")
                }
                arguments += [base.output, head.output]
                revision = base.output + ".." + head.output
            } else {
                arguments = ["show", "--format=", "--no-ext-diff", "--find-renames", resolved.output]
            }
        }
        if ignoreWhitespace { arguments.insert("--ignore-all-space", at: 1) }
        let list = await RepositoryService.runGit(
            path: path, arguments: arguments + ["--name-status", "-z"], trimOutput: false)
        guard list.exitCode == 0 else { throw QuickDraftError.message("The Git comparison could not be loaded.") }
        let changes = namedChanges(list.output)
        var paths = changes.paths
        if scope == .working {
            let untracked = await RepositoryService.runGit(
                path: path, arguments: ["ls-files", "--others", "--exclude-standard", "-z"], trimOutput: false)
            paths += untracked.output.split(separator: "\0").map(String.init).filter(
                RepositoryService.isSafeRelativePath)
        }
        paths = Array(Set(paths)).sorted()
        return RepositoryComparison(
            title: scope.rawValue, revision: revision, files: Array(paths.prefix(200)), arguments: arguments,
            fingerprint: (scope == .working || scope == .staged) ? await fingerprint(path) : revision,
            partial: paths.count > 200, renameSources: changes.renames)
    }

    static func namedChanges(_ output: String) -> (paths: [String], renames: [String: String]) {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        var paths: [String] = []
        var renames: [String: String] = [:]
        while index + 1 < fields.count {
            let status = fields[index]
            let path = fields[index + 1]
            index += 2
            if status.hasPrefix("R") || status.hasPrefix("C") {
                guard index < fields.count else { break }
                let destination = fields[index]
                index += 1
                if RepositoryService.isSafeRelativePath(path), RepositoryService.isSafeRelativePath(destination) {
                    paths.append(destination)
                    renames[destination] = path
                }
            } else if RepositoryService.isSafeRelativePath(path) {
                paths.append(path)
            }
        }
        return (paths, renames)
    }

    static func patch(path: String, file: String, comparison: RepositoryComparison) async throws -> RepositoryDiff {
        guard RepositoryService.isSafeRelativePath(file) else {
            throw QuickDraftError.message("Invalid repository-relative file.")
        }
        let result = await RepositoryService.runGit(
            path: path,
            arguments: comparison.arguments + ["--unified=3", "--"]
                + [comparison.renameSources[file], file].compactMap { $0 }, trimOutput: false)
        guard result.exitCode == 0 else { throw QuickDraftError.message("The file comparison could not be read.") }
        var output = result.output
        if output.isEmpty, comparison.title == RepositoryComparison.Scope.working.rawValue {
            let fileChange = RepositoryFileChange(path: file, status: .untracked, isStaged: false, renameSource: nil)
            if let untracked = await RepositoryService.diff(path: path, file: fileChange) { output = untracked.text }
        }
        let bounded = RepositoryService.boundDiff(output)
        return RepositoryDiff(
            path: file, text: bounded.text, isTruncated: bounded.isTruncated, isStaged: comparison.title == "Staged")
    }

    static func expandedPatch(
        path: String, file: String, arguments: [String], original: String, lines: Int, renameSource: String? = nil
    ) async throws -> String {
        guard RepositoryService.isSafeRelativePath(file) else { throw QuickDraftError.message("Invalid file path.") }
        if let renameSource, !RepositoryService.isSafeRelativePath(renameSource) {
            throw QuickDraftError.message("Invalid rename source.")
        }
        let selectedPaths = [renameSource, file].compactMap { $0 }
        let before = await fingerprint(path)
        let current = await RepositoryService.runGit(
            path: path, arguments: arguments + ["--unified=3", "--"] + selectedPaths, trimOutput: false)
        guard current.exitCode == 0,
            current.output.trimmingCharacters(in: .whitespacesAndNewlines)
                == original.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw QuickDraftError.message("This comparison changed. Refresh before expanding context.")
        }
        let expanded = await RepositoryService.runGit(
            path: path, arguments: arguments + ["--unified=\(min(200, lines))", "--"] + selectedPaths, trimOutput: false
        )
        guard expanded.exitCode == 0, before == (await fingerprint(path)) else {
            throw QuickDraftError.message("The files changed while context was loading. Refresh to continue.")
        }
        let bounded = RepositoryService.boundDiff(expanded.output)
        guard !bounded.isTruncated else {
            throw QuickDraftError.message("More context exceeds the display limit. Open the source file instead.")
        }
        return bounded.text
    }

    static func fingerprint(_ path: String) async -> String {
        let result = await RepositoryService.runGit(
            path: path, arguments: ["diff", "--no-ext-diff", "--no-textconv", "HEAD"], trimOutput: false)
        let status = await RepositoryService.runGit(
            path: path, arguments: ["status", "--porcelain=v1", "-z"], trimOutput: false)
        let untracked = await RepositoryService.runGit(
            path: path, arguments: ["ls-files", "--others", "--exclude-standard", "-z"], trimOutput: false)
        guard result.exitCode == 0, status.exitCode == 0, untracked.exitCode == 0 else { return UUID().uuidString }
        let files = untracked.output.split(separator: "\0").map(String.init)
        guard files.count <= 200 else { return UUID().uuidString }
        let contents = await Task.detached(priority: .utility) { () -> String? in
            var total = 0
            var hash = SHA256()
            let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            for file in files {
                guard RepositoryService.isSafeRelativePath(file) else { return nil }
                let url = root.appendingPathComponent(file).resolvingSymlinksInPath().standardizedFileURL
                guard url.path.hasPrefix(root.path + "/"),
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                    values.isRegularFile == true,
                    let size = values.fileSize, size <= 32 * 1024 * 1024 - total,
                    let data = try? Data(contentsOf: url, options: .mappedIfSafe)
                else { return nil }
                total += data.count
                hash.update(data: Data(file.utf8))
                hash.update(data: data)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        guard let contents else { return UUID().uuidString }
        return SHA256.hash(data: Data((result.output + status.output + contents).utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
