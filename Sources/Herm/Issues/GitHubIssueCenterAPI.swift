import Foundation
import SwiftUI

struct GitHubIssueCenterAPI: Sendable {
    let client: GitHubClient

    init(transport: any GitHubIssueTransport = GitHubClient.sharedSession) {
        self.client = GitHubClient(transport: transport)
    }

    func resolve(_ reference: GitHubItemReference, localPaths: [String: String]) async throws -> GitHubIssueRecord {
        guard let row = try await request(path: reference.issuePath) as? [String: Any],
            let record = GitHubIssueParser.parse(row, localPaths: localPaths)
        else { throw GitHubRequestError.malformed }
        return record
    }

    func viewer() async -> Result<String, PullRequestCenterFailure> {
        do {
            guard let row = try await request(path: "/user") as? [String: Any],
                let login = row["login"] as? String,
                !login.isEmpty
            else { throw GitHubCodeHostError.malformedResponse }
            return .success(login)
        } catch {
            return .failure(PullRequestCenterFailure(repository: "GitHub account"))
        }
    }

    func searchIssues(viewerLogin: String?, localPaths: [String: String]) async -> Result<
        [GitHubIssueRecord], PullRequestCenterFailure
    > {
        do {
            // The All view is intentionally scoped to the signed-in user's
            // authored and assigned issues. Never fall back to a global open
            // issue search, which can expose unrelated repository activity.
            guard let viewerLogin = viewerLogin?.trimmingCharacters(in: .whitespacesAndNewlines),
                !viewerLogin.isEmpty
            else {
                return .failure(PullRequestCenterFailure(repository: "GitHub issue search"))
            }
            async let authored = search("is:issue is:open author:\(viewerLogin)", localPaths: localPaths)
            async let assigned = search("is:issue is:open assignee:\(viewerLogin)", localPaths: localPaths)
            var unique: [String: GitHubIssueRecord] = [:]
            for issue in try await authored + assigned { unique[issue.id] = issue }
            return .success(Array(unique.values))
        } catch { return .failure(PullRequestCenterFailure(repository: "GitHub issue search")) }
    }

    func workPage(viewer: String, localPaths: [String: String]) async throws -> GitHubPage<GitHubIssueRecord> {
        // Fork exclusion and attached-repository searches overlap the account searches.
        async let forks = forkExclusions()
        async let authored = searchPageResult("is:issue is:open author:\(viewer)", localPaths: localPaths)
        async let other = searchPageResult("is:issue is:open assignee:\(viewer)", localPaths: localPaths)
        async let owned = searchPageResult("is:issue is:open user:\(viewer)", localPaths: localPaths)
        let attached = localPaths.keys.sorted().filter { GitHubReferenceParser.repository($0) != nil }
        // Search allows 30 requests/min; space-separated `repo:` qualifiers OR together, so one
        // query covers a batch of repositories instead of one search per attached repository.
        let batches = stride(from: 0, to: attached.count, by: 10).map {
            attached[$0..<min($0 + 10, attached.count)].map { "repo:\($0)" }.joined(separator: " ")
        }
        async let scoped = Self.concurrentMap(batches) { [self] repositories in
            await searchPageResult("is:issue is:open \(repositories)", localPaths: localPaths)
        }
        let (authoredResult, otherResult, ownedResult) = await (authored, other, owned)
        let a = try? authoredResult.get()
        let b = try? otherResult.get()
        let c = try? ownedResult.get()
        try Task.checkCancellation()
        if a == nil && b == nil && c == nil {
            for result in [authoredResult, otherResult, ownedResult] {
                if case .failure(let error) = result, GitHubAccessRequirement(error: error) != nil { throw error }
            }
            throw GitHubRequestError.unavailable
        }
        var unique = Dictionary((a?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in b?.items ?? [] { unique[row.id] = row }
        for row in c?.items ?? [] { unique[row.id] = row }
        var coverage = GitHubCoverage(
            loaded: unique.count,
            partial: a == nil || b == nil || c == nil || a?.coverage.partial == true || b?.coverage.partial == true
                || c?.coverage.partial == true)
        for result in await scoped {
            try Task.checkCancellation()
            switch result {
            case .success(let page):
                for row in page.items { unique[row.id] = row }
                coverage.partial = coverage.partial || page.coverage.partial
            case .failure:
                coverage.partial = true
            }
        }
        coverage.loaded = unique.count
        return try await excludingForks(
            GitHubPage(items: Array(unique.values), coverage: coverage), forks: try await forks)
    }

    func excludingForks(_ page: GitHubPage<GitHubIssueRecord>) async throws -> GitHubPage<GitHubIssueRecord> {
        try await excludingForks(page, forks: try await forkExclusions())
    }

    /// Lowercased ids of the viewer's forks and their parents; `partial` when any lookup failed.
    private func forkExclusions() async throws -> (excluded: Set<String>, partial: Bool) {
        do {
            let repositories = try await client.pages("/user/repos", query: ["affiliation": "owner"])
            var partial = repositories.coverage.partial
            var forks: [GitHubRepositoryReference] = []
            for row in repositories.rows where row["fork"] as? Bool == true {
                guard let name = row["full_name"] as? String, let reference = GitHubReferenceParser.repository(name)
                else {
                    partial = true
                    continue
                }
                forks.append(reference)
            }
            var excluded = Set(forks.map { $0.id.lowercased() })
            let parents = await Self.concurrentMap(forks) { [client] reference -> String? in
                guard let detail = try? await client.request(reference.apiRepositoryPath) as? [String: Any] else {
                    return nil
                }
                return (detail["parent"] as? [String: Any])?["full_name"] as? String
            }
            try Task.checkCancellation()
            for parent in parents {
                if let parent { excluded.insert(parent.lowercased()) } else { partial = true }
            }
            return (excluded, partial)
        } catch {
            try Task.checkCancellation()
            return ([], true)
        }
    }

    private func excludingForks(
        _ page: GitHubPage<GitHubIssueRecord>, forks: (excluded: Set<String>, partial: Bool)
    ) async throws -> GitHubPage<GitHubIssueRecord> {
        var coverage = page.coverage
        coverage.partial = coverage.partial || forks.partial
        let unique = Dictionary(page.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = Set(unique.values.map(\.repository)).filter { !forks.excluded.contains($0.id.lowercased()) }
        // nil means the fork check failed; those issues are dropped rather than shown unverified.
        let checks = await Self.concurrentMap(Array(candidates)) { [client] repository -> (String, Bool?) in
            let data = try? await client.request(repository.apiRepositoryPath) as? [String: Any]
            return (repository.id, data?["fork"] as? Bool)
        }
        try Task.checkCancellation()
        var kept = Set<String>()
        for (id, isFork) in checks {
            if isFork == false { kept.insert(id) }
            if isFork == nil { coverage.partial = true }
        }
        let items = unique.values.filter { kept.contains($0.repository.id) }
        coverage.loaded = items.count
        return GitHubPage(items: items, coverage: coverage)
    }

    /// Order-preserving map with at most six GitHub requests in flight.
    private static func concurrentMap<T: Sendable, R: Sendable>(
        _ items: [T], _ transform: @escaping @Sendable (T) async -> R
    ) async -> [R] {
        await withTaskGroup(of: (Int, R).self) { group in
            var next = items.enumerated().makeIterator()
            for _ in 0..<6 {
                guard let (index, item) = next.next() else { break }
                group.addTask { (index, await transform(item)) }
            }
            var results: [Int: R] = [:]
            while let (index, result) = await group.next() {
                results[index] = result
                if let (index, item) = next.next() { group.addTask { (index, await transform(item)) } }
            }
            return items.indices.compactMap { results[$0] }
        }
    }

    private func searchPageResult(_ query: String, localPaths: [String: String]) async -> Result<
        GitHubPage<GitHubIssueRecord>, Error
    > {
        do { return .success(try await searchPage(query, localPaths: localPaths)) } catch { return .failure(error) }
    }

    func searchPage(_ query: String, localPaths: [String: String]) async throws -> GitHubPage<GitHubIssueRecord> {
        let page = try await client.pages("/search/issues", query: ["q": query], key: "items", search: true)
        return GitHubPage(
            items: page.rows.compactMap { GitHubIssueParser.parse($0, localPaths: localPaths) }, coverage: page.coverage
        )
    }
    private func search(_ query: String, localPaths: [String: String]) async throws -> [GitHubIssueRecord] {
        try await searchPage(query, localPaths: localPaths).items
    }

    func detail(_ issue: GitHubIssueRecord) async -> GitHubIssueRecord? {
        guard
            let payload = try? await request(path: issue.repository.apiRepositoryPath + "/issues/\(issue.number)")
                as? [String: Any]
        else { return nil }
        return GitHubIssueParser.parse(payload, localPaths: [issue.repository.id: issue.localPath])
    }

    func request(path: String, query: [String: String] = [:], method: String = "GET", body: [String: Any]? = nil)
        async throws -> Any
    {
        try await client.request(path, query: query, method: method, body: body)
    }

}
