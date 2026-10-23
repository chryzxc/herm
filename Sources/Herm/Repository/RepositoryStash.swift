import Foundation

struct RepositoryStash: Identifiable, Equatable, Sendable {
    var id: String { reference + ":" + hash }
    let hash: String
    let reference: String
    let subject: String
    let date: Date
}

enum RepositoryStashOperation: String, Sendable {
    case apply = "Apply"
    case pop = "Pop"
    case drop = "Delete"
}

extension RepositoryService {
    static func stashes(path: String) async -> [RepositoryStash]? {
        let result = await runGit(
            path: path, arguments: ["stash", "list", "-z", "--format=%H%x00%gd%x00%gs%x00%ct"], trimOutput: false)
        guard result.exitCode == 0 else { return nil }
        return parseStashes(result.output)
    }

    static func parseStashes(_ output: String) -> [RepositoryStash]? {
        if output.isEmpty { return [] }
        var fields = output.split(separator: "\0", omittingEmptySubsequences: false)
        if fields.last == "" { fields.removeLast() }
        guard fields.count.isMultiple(of: 4) else { return nil }
        var entries: [RepositoryStash] = []
        for offset in stride(from: 0, to: fields.count, by: 4) {
            let hash = String(fields[offset])
            let reference = String(fields[offset + 1])
            guard isStashHash(hash), reference.hasPrefix("stash@{"), reference.hasSuffix("}"),
                let timestamp = TimeInterval(fields[offset + 3]), timestamp.isFinite
            else { return nil }
            entries.append(
                RepositoryStash(
                    hash: hash, reference: reference, subject: String(fields[offset + 2]),
                    date: Date(timeIntervalSince1970: timestamp)))
        }
        return entries
    }

    static func stashDiff(path: String, stash: RepositoryStash) async -> (text: String, isTruncated: Bool)? {
        guard isStashHash(stash.hash) else { return nil }
        let result = await runGit(
            path: path,
            arguments: [
                "stash", "show", "--patch", "--include-untracked", "--no-ext-diff", "--no-textconv", stash.hash,
            ], trimOutput: false)
        guard result.exitCode == 0 else { return nil }
        return boundDiff(result.output)
    }

    static func createStash(path: String, message: String, includeUntracked: Bool) async -> String? {
        guard !message.contains("\0") else { return "Enter a valid stash message." }
        var arguments = ["stash", "push"]
        if includeUntracked { arguments.append("--include-untracked") }
        if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { arguments += ["--message", message] }
        let result = await runGit(path: path, arguments: arguments)
        return result.exitCode == 0
            ? nil
            : "Could not create the stash. Commit an initial revision and resolve conflicts or index locks, then retry."
    }

    static func updateStash(path: String, stash: RepositoryStash, operation: RepositoryStashOperation) async -> String?
    {
        guard isStashHash(stash.hash), let current = await stashes(path: path),
            current.contains(where: { $0.hash == stash.hash })
        else {
            return "This stash is no longer available. Refresh and try again."
        }
        if operation != .drop {
            let result = await runGit(path: path, arguments: ["stash", "apply", "--index", stash.hash])
            guard result.exitCode == 0 else {
                return
                    "The stash could not be fully restored. It has been kept. Check Source Control for conflicts or local changes before retrying."
            }
        }
        if operation != .apply {
            // Stash indices move when another entry is added or removed. Resolve the selected hash again.
            guard let refreshed = await stashes(path: path),
                let selected = refreshed.first(where: { $0.hash == stash.hash })
            else {
                return "The stash list changed. Refresh to check whether the selected stash still exists."
            }
            let result = await runGit(path: path, arguments: ["stash", "drop", selected.reference])
            guard result.exitCode == 0 else { return "Could not delete the stash. Refresh the stash list and retry." }
        }
        return nil
    }

    private static func isStashHash(_ hash: String) -> Bool {
        (hash.count == 40 || hash.count == 64) && hash.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}
