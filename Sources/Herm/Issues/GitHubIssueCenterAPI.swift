import Foundation
import SwiftUI

struct GitHubIssueCenterAPI: Sendable {
    let client: GitHubClient

    init(transport: any GitHubIssueTransport = URLSession(configuration: .ephemeral)) {
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
        async let authored = try? searchPage("is:issue is:open author:\(viewer)", localPaths: localPaths)
        async let other = try? searchPage("is:issue is:open assignee:\(viewer)", localPaths: localPaths)
        let (a, b) = await (authored, other)
        try Task.checkCancellation()
        guard a != nil || b != nil else { throw GitHubRequestError.unavailable }
        var unique = Dictionary((a?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in b?.items ?? [] { unique[row.id] = row }
        var coverage = GitHubCoverage(
            loaded: unique.count,
            partial: a == nil || b == nil || a?.coverage.partial == true || b?.coverage.partial == true)
        coverage.loaded = unique.count
        return GitHubPage(items: Array(unique.values), coverage: coverage)
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
