import Foundation

/// Text lines in tracked working-tree and staged changes, measured together against HEAD.
struct RepositoryChangeLineSummary: Equatable {
    var additions = 0
    var deletions = 0
    var binaryFiles = 0

    static func parse(_ output: String) -> Self? {
        var summary = Self()
        var rows = output.split(separator: "\0").makeIterator()
        while let row = rows.next() {
            let columns = row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else { return nil }
            if columns[2].isEmpty {
                // Renames carry their old and new paths in the following NUL-delimited fields.
                guard let oldPath = rows.next(), !oldPath.isEmpty, let newPath = rows.next(), !newPath.isEmpty else {
                    return nil
                }
            }
            if columns[0] == "-", columns[1] == "-" {
                summary.binaryFiles += 1
            } else {
                guard let added = Int(columns[0]), let deleted = Int(columns[1]), added >= 0, deleted >= 0 else {
                    return nil
                }
                let (additions, additionsOverflow) = summary.additions.addingReportingOverflow(added)
                let (deletions, deletionsOverflow) = summary.deletions.addingReportingOverflow(deleted)
                guard !additionsOverflow, !deletionsOverflow else { return nil }
                summary.additions = additions
                summary.deletions = deletions
            }
        }
        return summary
    }
}

extension RepositoryService {
    static func changeLineSummary(path: String, changes: RepositoryChangeSnapshot) async -> RepositoryChangeLineSummary?
    {
        guard changes.repositoryID == RepositorySnapshot.stableID(path: path), let head = changes.headRevision else {
            return nil
        }
        let result = await runGit(
            path: path,
            arguments: ["diff", "--no-ext-diff", "--no-textconv", "--find-renames", "--numstat", "-z", head, "--"],
            trimOutput: false)
        guard result.exitCode == 0 else { return nil }
        return RepositoryChangeLineSummary.parse(result.output)
    }
}
