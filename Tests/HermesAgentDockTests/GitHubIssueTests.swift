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
        let assigned = GitHubIssueRecord(repository: repository, localPath: "/repo", number: 2, title: "Assigned task", body: "", state: "open", author: "bob", assignee: "ada", updatedAt: nil, webURL: nil)
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

    @Test func issueContextIsStableAndExplicit() {
        let context = IssueContext(repositoryID: "owner/repo", number: 19, title: "Add issue workspace", webURL: URL(string: "https://github.com/owner/repo/issues/19"))
        #expect(context.id == "github:owner/repo#19")
        #expect(context.prompt.contains("Issue #19"))
        #expect(context.prompt.contains("Do not modify files unless I ask"))
    }
}
