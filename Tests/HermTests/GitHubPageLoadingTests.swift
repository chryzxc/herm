import Foundation
import Testing
@testable import Herm

private actor GitHubPageTransport: GitHubIssueTransport {
    private let responses: [String: Data]
    private var paths: [String] = []
    private var activeSearches = 0
    private(set) var peakSearches = 0

    init(responses: [String: Any]) throws {
        self.responses = try responses.mapValues { try JSONSerialization.data(withJSONObject: $0) }
    }

    func count(_ path: String) -> Int { paths.filter { $0 == path }.count }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let path = url.path
        paths.append(path)
        let isSearch = path == "/search/issues"
        if isSearch {
            activeSearches += 1
            peakSearches = max(peakSearches, activeSearches)
        }
        defer { if isSearch { activeSearches -= 1 } }
        try await Task.sleep(for: .milliseconds(30))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        let key = query.map { "\(path)?\($0)" } ?? path
        guard let data = responses[key] else { throw GitHubCodeHostError.unavailable }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

struct GitHubPageLoadingTests {
    private var searchRow: [String: Any] {
        ["number": 19, "title": "Improve loading", "state": "open", "body": "Summary",
         "repository": ["full_name": "owner/repo"], "user": ["login": "ada"],
         "updated_at": "2026-10-01T00:00:00Z"]
    }

    private func pullRequestTransport() throws -> GitHubPageTransport {
        var other = searchRow
        other["number"] = 20
        return try GitHubPageTransport(responses: [
            "/user": ["login": "ada"],
            "/search/issues?is:pr is:open author:ada": ["items": [searchRow, other]],
            "/search/issues?is:pr is:open review-requested:ada": ["items": [searchRow]],
            "/repos/owner/repo/pulls/19": [
                "number": 19, "title": "Improve loading", "user": ["login": "ada"],
                "head": ["ref": "feature", "sha": "abc"], "base": ["ref": "main"],
                "changed_files": 1, "requested_reviewers": [["login": "ada"]]
            ],
            "/repos/owner/repo/commits/abc/check-runs": ["check_runs": [
                ["id": 1, "name": "Tests", "status": "completed", "conclusion": "failure"]
            ]],
            "/repos/owner/repo/pulls/19/reviews": [["id": 2, "state": "APPROVED", "user": ["login": "bob"]]],
            "/repos/owner/repo/pulls/19/files": [["filename": "README.md", "status": "modified"]],
            "/repos/owner/repo/issues/19/comments": [],
            "/repos/owner/repo/pulls/19/commits": [],
            "/repos/owner/repo/issues/19/events": []
        ])
    }

    // Constructing the API without an actor hop guards against protocol-wide UI isolation.
    @Test func pullRequestReadTransportDoesNotRequireTheUIActor() async throws {
        let api = PullRequestCenterAPI(transport: try pullRequestTransport())
        #expect(await api.viewer() == "ada")
    }

    @MainActor @Test func pullRequestListFinishesWithoutFetchingEveryDetail() async throws {
        let transport = try pullRequestTransport()
        let center = PullRequestCenterModel(api: PullRequestCenterAPI(transport: transport))
        await center.refresh(projects: [])

        #expect(center.hasLoaded)
        #expect(!center.isRefreshing)
        #expect(center.records.count == 2)
        #expect(await transport.count("/repos/owner/repo/pulls/19") == 0)
        #expect(await transport.count("/repos/owner/repo/pulls/20") == 0)
        center.filter = .reviewing
        #expect(center.visible.map(\.number) == [19])
    }

    @MainActor @Test func visibleRowAndSelectionShareMetadataAndRefreshInvalidatesIt() async throws {
        let transport = try pullRequestTransport()
        let center = PullRequestCenterModel(api: PullRequestCenterAPI(transport: transport))
        await center.refresh(projects: [])
        let record = try #require(center.records.first { $0.number == 19 })
        center.selectedID = record.id

        async let row = center.loadSummary(for: record)
        async let selection: Void = center.loadSelectedDetail()
        _ = await (row, selection)
        await center.loadSummary(for: record)

        #expect(await transport.count("/repos/owner/repo/pulls/19") == 1)
        #expect(await transport.count("/repos/owner/repo/commits/abc/check-runs") == 1)
        #expect(await transport.count("/repos/owner/repo/pulls/19/reviews") == 1)
        #expect(await transport.count("/repos/owner/repo/pulls/20") == 0)
        #expect(center.selected?.headBranch == "feature")
        #expect(center.selected?.readinessLabel == "CHECKS FAILED")
        #expect(center.filesByID[record.id]?.count == 1)

        await center.refreshSelectedDetail()
        #expect(await transport.count("/repos/owner/repo/pulls/19") == 2)
        await center.refresh(projects: [])
        await center.loadSummary(for: record)
        #expect(await transport.count("/repos/owner/repo/pulls/19") == 3)
    }

    @MainActor @Test func issueSearchesOverlapAndRefreshUpdatesCachedDetail() async throws {
        var assigned = searchRow
        assigned["assignees"] = [["login": "ada"]]
        let transport = try GitHubPageTransport(responses: [
            "/user": ["login": "ada"],
            "/search/issues?is:issue is:open author:ada": ["items": [assigned]],
            "/search/issues?is:issue is:open assignee:ada": ["items": [assigned]],
            "/repos/owner/repo/issues/19": assigned
        ])
        let center = IssueCenterModel(api: GitHubIssueCenterAPI(transport: transport))
        async let first: Void = center.refresh(projects: [])
        async let duplicate: Void = center.refresh(projects: [])
        _ = await (first, duplicate)

        #expect(await transport.count("/user") == 1)
        #expect(await transport.peakSearches == 2)
        #expect(center.records.count == 1)
        center.filter = .assigned
        #expect(center.visible.map(\.number) == [19])
        await center.loadSelectedDetail()
        await center.loadSelectedDetail()
        #expect(await transport.count("/repos/owner/repo/issues/19") == 1)
        await center.refresh(projects: [])
        #expect(center.detailByID.isEmpty)
        await center.loadSelectedDetail()
        #expect(await transport.count("/repos/owner/repo/issues/19") == 2)
    }

    @MainActor @Test func emptyPullRequestResultIsLoadedAndConcurrentRefreshesAreShared() async throws {
        let transport = try GitHubPageTransport(responses: [
            "/user": ["login": "ada"],
            "/search/issues?is:pr is:open author:ada": ["items": []],
            "/search/issues?is:pr is:open review-requested:ada": ["items": []]
        ])
        let center = PullRequestCenterModel(api: PullRequestCenterAPI(transport: transport))
        async let first: Void = center.refresh(projects: [])
        async let duplicate: Void = center.refresh(projects: [])
        _ = await (first, duplicate)
        #expect(await transport.count("/user") == 1)
        #expect(center.hasLoaded)
        #expect(center.records.isEmpty)
        #expect(!center.isRefreshing)
        #expect(center.errorMessage == nil)
    }
}
