import Foundation
import Testing
@testable import Herm

struct GitHubIssueTests {
    @Test func parsesIssueAndPreservesSafeMarkdownSource() {
        let issue = GitHubIssueParser.parse([
            "number": 19,
            "title": "Add issue workspace",
            "body": "**Details** [docs](https://example.com/docs)",
            "state": "open",
            "html_url": "https://github.com/owner/repo/issues/19",
            "updated_at": "2026-09-20T12:00:00Z",
            "user": ["login": "ada"],
            "repository": ["full_name": "owner/repo"],
            "assignee": ["login": "ada"]
        ])
        #expect(issue?.id == "github:owner/repo#19")
        #expect(issue?.body.contains("**Details**") == true)
        #expect(issue?.webURL?.absoluteString.hasSuffix("/issues/19") == true)
        #expect(issue?.assignee == "ada")
    }

    @MainActor @Test func issueFiltersAreGitHubAuthoritativeAndSearchable() {
        let repository = GitHubRepositoryReference(owner: "owner", name: "repo", webURL: URL(string: "https://github.com/owner/repo")!)
        let authored = GitHubIssueRecord(repository: repository, localPath: "/repo", number: 1, title: "Authored bug", body: "", state: "open", author: "ada", assignee: "bob", updatedAt: nil, webURL: nil)
        let assigned = GitHubIssueRecord(repository: repository, localPath: "/repo", number: 2, title: "Assigned task", body: "", state: "open", author: "bob", assignee: "ada", assignees: ["ada"], updatedAt: nil, webURL: nil)
        let model = IssueCenterModel()
        model.records = [authored, assigned]
        model.viewerLogin = "ada"
        model.filter = .authored
        #expect(model.visible.map(\.number) == [1])
        model.filter = .assigned
        #expect(model.visible.map(\.number) == [2])
        model.filter = .all
        model.query = "assigned"
        #expect(model.visible.map(\.number) == [2])
        model.query = ""
        model.repositoryScope = "owner/repo"
        #expect(model.visible.count == 2)
    }

    @MainActor @Test func issueVisibleRowsRemainNewestFirstAndResetFiltersRepairsSelection() {
        let repository = GitHubRepositoryReference(owner: "owner", name: "repo", webURL: URL(string: "https://github.com/owner/repo")!)
        let older = GitHubIssueRecord(repository: repository, localPath: "/repo", number: 1, title: "Older", body: "", state: "open", author: "ada", assignee: nil, updatedAt: Date(timeIntervalSince1970: 10), webURL: nil)
        let newer = GitHubIssueRecord(repository: repository, localPath: "/repo", number: 2, title: "Newer", body: "", state: "open", author: "ada", assignee: nil, updatedAt: Date(timeIntervalSince1970: 20), webURL: nil)
        let model = IssueCenterModel()
        model.records = [older, newer]
        model.selectedIssueID = older.id
        model.query = "newer"
        model.repairSelection()
        #expect(model.selectedIssueID == newer.id)
        model.filter = .assigned
        model.resetFilters()
        #expect(model.filter == .all)
        #expect(model.query.isEmpty)
        #expect(model.repositoryScope == nil)
        #expect(model.visible.map(\.number) == [2, 1])
        #expect(model.selectedIssueID == newer.id)
    }

    @Test func issueRowMetadataUsesSentenceCaseAssignmentAndOmitsMissingTime() {
        let assigned = GitHubIssueRowMetadata.make(repository: "owner/repo", assignees: ["ada", "bob"], updated: "2 min ago")
        #expect(assigned.values == ["owner/repo", "Assigned to ada, bob", "2 min ago"])
        let unassigned = GitHubIssueRowMetadata.make(repository: "owner/repo", assignees: [], updated: nil)
        #expect(unassigned.values == ["owner/repo", "Unassigned"])
        let viewer = GitHubIssueRowMetadata.make(repository: "owner/repo", assignees: ["Ada", "bob"], updated: nil, viewer: "ada")
        #expect(viewer.assignment == "Assigned to you, bob")
    }

    @MainActor @Test func parserPreservesSecondaryAssignees() {
        let issue = GitHubIssueParser.parse([
            "number": 20, "title": "Co-assigned", "state": "open",
            "repository": ["full_name": "owner/repo"],
            "user": ["login": "bob"],
            "assignees": [["login": "bob"], ["login": "ada"]],
            "assignee": ["login": "bob"]
        ])
        #expect(issue?.assignees == ["bob", "ada"])

        let model = IssueCenterModel()
        model.records = [issue!]
        model.viewerLogin = "ada"
        model.filter = .assigned
        #expect(model.visible.map(\.number) == [20])
    }

    @MainActor @Test func issueCenterUsesInjectedGitHubBoundaryForViewerSearchAndDetail() async {
        let transport = IssueTestTransport(responses: [
            "/user": ["login": "ada"],
            "/search/issues": ["items": [[
                "number": 19, "title": "From GitHub", "body": "summary", "state": "open",
                "repository": ["full_name": "owner/repo"], "user": ["login": "ada"],
                "assignee": ["login": "ada"], "html_url": "https://github.com/owner/repo/issues/19"
            ]]],
            "/repos/owner/repo/issues/19": [
                "number": 19, "title": "Detailed GitHub issue", "body": "details", "state": "open",
                "repository": ["full_name": "owner/repo"], "user": ["login": "ada"],
                "assignee": ["login": "ada"]
            ]
        ])
        let model = IssueCenterModel(api: GitHubIssueCenterAPI(transport: transport))

        await model.refresh(projects: [])
        #expect(model.viewerLogin == "ada")
        #expect(model.records.map(\.number) == [19])
        model.selectedIssueID = model.records.first?.id
        await model.loadSelectedDetail()
        #expect(model.detailByID[model.records[0].id]?.title == "Detailed GitHub issue")
        #expect(transport.paths.contains("/user"))
        #expect(transport.paths.contains("/search/issues"))
        #expect(transport.paths.contains("/repos/owner/repo/issues/19"))
        #expect(Set(transport.searchQueries) == [
            "is:issue is:open author:ada",
            "is:issue is:open assignee:ada"
        ])
        #expect(transport.searchQueries.contains("is:issue is:open") == false)
    }

    @MainActor @Test func issueCenterReportsInitialUnavailableInsteadOfEmptySuccess() async {
        let model = IssueCenterModel(api: GitHubIssueCenterAPI(transport: IssueTestTransport(failing: true)))
        await model.refresh(projects: [])
        #expect(model.records.isEmpty)
        #expect(model.hasLoaded == false)
        #expect(model.errorMessage?.contains("unavailable") == true)
    }

    @MainActor @Test func issueDetailFailureRetainsSelectedSummaryAndPublishesInlineError() async {
        let repository = GitHubRepositoryReference(owner: "owner", name: "repo", webURL: URL(string: "https://github.com/owner/repo")!)
        let issue = GitHubIssueRecord(repository: repository, localPath: "/repo", number: 1, title: "Summary", body: "Search summary", state: "open", author: "ada", assignee: nil, updatedAt: nil, webURL: nil)
        let model = IssueCenterModel(api: GitHubIssueCenterAPI(transport: IssueTestTransport(failing: true)))
        model.records = [issue]
        model.selectedIssueID = issue.id
        await model.loadSelectedDetail()
        #expect(model.selected?.title == "Summary")
        #expect(model.detailErrorMessage?.contains("Could not refresh") == true)
        #expect(model.loadingDetailID == nil)
    }

    @MainActor @Test func issueCenterKeepsViewerFailureUnavailableEvenWhenSearchSucceeds() async {
        let transport = IssueTestTransport(
            responses: [
                "/search/issues": ["items": [[
                    "number": 21, "title": "Unscoped result", "state": "open",
                    "repository": ["full_name": "owner/repo"], "user": ["login": "ada"]
                ]]]
            ],
            failingPaths: ["/user"]
        )
        let model = IssueCenterModel(api: GitHubIssueCenterAPI(transport: transport))

        await model.refresh(projects: [])

        #expect(model.viewerLogin == nil)
        #expect(model.records.isEmpty)
        #expect(model.hasLoaded == false)
        #expect(model.errorMessage?.contains("unavailable") == true)
        #expect(transport.paths == ["/user"])
    }

    @MainActor @Test func issueCenterPublishesLoadingBeforeRepositoryDiscoveryCompletes() async {
        let model = IssueCenterModel(
            api: GitHubIssueCenterAPI(transport: IssueTestTransport(failing: true)),
            repositoryRemote: { _ in
                try? await Task.sleep(nanoseconds: 100_000_000)
                return nil
            }
        )
        let project = ProjectSummary(id: "project", name: "repo", repoCount: 1, sessionCount: 0, sessionIDs: [], preview: nil, isActive: true)
        let refresh = Task { await model.refresh(projects: [project]) }

        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(model.isRefreshing)
        await refresh.value
    }

    @Test func issueContextIsStableAndExplicit() {
        let context = IssueContext(repositoryID: "owner/repo", number: 19, title: "Add issue workspace", webURL: URL(string: "https://github.com/owner/repo/issues/19"))
        #expect(context.id == "github:owner/repo#19")
        #expect(context.prompt.contains("Issue #19"))
        #expect(context.prompt.contains("Do not modify files unless I ask"))
    }
}

private final class IssueTestTransport: GitHubIssueTransport, @unchecked Sendable {
    private let responses: [String: Any]
    private let failing: Bool
    private let failingPaths: Set<String>
    private(set) var paths: [String] = []
    private(set) var searchQueries: [String] = []

    init(responses: [String: Any] = [:], failing: Bool = false, failingPaths: Set<String> = []) {
        self.responses = responses
        self.failing = failing
        self.failingPaths = failingPaths
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        paths.append(path)
        if path == "/search/issues",
           let url = request.url,
           let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value {
            searchQueries.append(query)
        }
        if failing || failingPaths.contains(path) { throw GitHubCodeHostError.unavailable }
        let payload = responses[request.url?.path ?? ""] ?? [String: Any]()
        let data = try JSONSerialization.data(withJSONObject: payload)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
