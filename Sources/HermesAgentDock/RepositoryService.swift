import Foundation

struct RepositorySnapshot: Equatable {
    var path: String
    var branch: String
    var changedFiles: Int
    var latestCommit: String
    var isGitRepository: Bool

    static let empty = RepositorySnapshot(path: "", branch: "No repository selected", changedFiles: 0, latestCommit: "", isGitRepository: false)
}

enum RepositoryService {
    static func inspect(path: String) async -> RepositorySnapshot {
        let branchResult = await runGit(path: path, arguments: ["branch", "--show-current"])
        guard branchResult.exitCode == 0 else {
            return RepositorySnapshot(path: path, branch: "Not a Git repository", changedFiles: 0, latestCommit: "", isGitRepository: false)
        }
        let statusResult = await runGit(path: path, arguments: ["status", "--porcelain"])
        let commitResult = await runGit(path: path, arguments: ["log", "-1", "--pretty=format:%h %s"])
        let changedFiles = statusResult.output.split(separator: "\n", omittingEmptySubsequences: true).count
        return RepositorySnapshot(path: path, branch: branchResult.output.isEmpty ? "detached HEAD" : branchResult.output, changedFiles: changedFiles, latestCommit: commitResult.output, isGitRepository: true)
    }

    private static func runGit(path: String, arguments: [String]) async -> (output: String, exitCode: Int32) {
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
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (output, process.terminationStatus)
            } catch {
                return ("", 1)
            }
        }.value
    }
}
