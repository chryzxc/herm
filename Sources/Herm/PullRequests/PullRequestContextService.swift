import Foundation

/// Resolves provider refs once and validates source against the displayed patch before expanding.
struct PullRequestContextService: Sendable {
    let client: GitHubClient

    func expand(record: PullRequestRecord, file: PullRequestFile, patch: String, lines: Int) async throws -> String {
        guard let head = record.headRevision, let base = record.baseRevision,
            GitHubConflictService.validRevision(head), GitHubConflictService.validRevision(base),
            RepositoryService.isSafeRelativePath(file.path)
        else { throw GitHubRequestError.changed }
        try await verify(record)
        guard
            let comparison = try await client.request(
                record.repository.apiRepositoryPath + "/compare/\(base)...\(head)") as? [String: Any],
            let mergeBase = (comparison["merge_base_commit"] as? [String: Any])?["sha"] as? String,
            GitHubConflictService.validRevision(mergeBase)
        else { throw GitHubRequestError.malformed }
        let headRepository: GitHubRepositoryReference
        if let url = file.webURL, url.host == "github.com" {
            let parts = url.path.split(separator: "/").map(String.init)
            if parts.count > 4, parts[2] == "blob", parts[3] == head,
                let repository = GitHubReferenceParser.repository(parts[0] + "/" + parts[1])
            {
                headRepository = repository
            } else {
                headRepository = record.repository
            }
        } else {
            headRepository = record.repository
        }
        async let old = source(
            repository: record.repository, revision: mergeBase, path: file.previousPath ?? file.path,
            absent: file.status == "added")
        async let new = source(
            repository: headRepository, revision: head, path: file.path, absent: file.status == "removed")
        let sources = try await (old, new)
        let expanded = try await Task.detached(priority: .userInitiated) {
            try DiffContextExpansion.expand(
                patch: patch, oldSource: sources.0, newSource: sources.1, additionalContext: max(0, lines - 3))
        }.value
        try await verify(record)
        return expanded
    }
    private func verify(_ record: PullRequestRecord) async throws {
        guard
            let row = try await client.request(record.repository.apiRepositoryPath + "/pulls/\(record.number)")
                as? [String: Any],
            (row["head"] as? [String: Any])?["sha"] as? String == record.headRevision,
            (row["base"] as? [String: Any])?["sha"] as? String == record.baseRevision
        else { throw GitHubRequestError.changed }
    }
    private func source(repository: GitHubRepositoryReference, revision: String, path: String, absent: Bool)
        async throws -> String
    {
        if absent { return "" }
        guard RepositoryService.isSafeRelativePath(path) else { throw GitHubRequestError.malformed }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed),
            let row = try await client.request(
                repository.apiRepositoryPath + "/contents/" + encoded, query: ["ref": revision]) as? [String: Any],
            row["type"] as? String == "file", let size = row["size"] as? Int, (0...256_000).contains(size),
            row["encoding"] as? String == "base64", let content = row["content"] as? String,
            let bytes = Data(base64Encoded: content, options: .ignoreUnknownCharacters), bytes.count <= 256_000,
            let source = String(data: bytes, encoding: .utf8)
        else { throw GitHubRequestError.unavailable }
        return source
    }
}
