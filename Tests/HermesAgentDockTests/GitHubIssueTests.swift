import Foundation
import Testing
@testable import HermesAgentDock

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
    }

    @MainActor @Test func issueCenterReportsInitialUnavailableInsteadOfEmptySuccess() async {
        let model = IssueCenterModel(api: GitHubIssueCenterAPI(transport: IssueTestTransport(failing: true)))
        await model.refresh(projects: [])
        #expect(model.records.isEmpty)
        #expect(model.hasLoaded == false)
        #expect(model.errorMessage?.contains("unavailable") == true)
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
    private(set) var paths: [String] = []

    init(responses: [String: Any] = [:], failing: Bool = false) {
        self.responses = responses
        self.failing = failing
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        paths.append(request.url?.path ?? "")
        if failing { throw GitHubCodeHostError.unavailable }
        let payload = responses[request.url?.path ?? ""] ?? [String: Any]()
        let data = try JSONSerialization.data(withJSONObject: payload)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
