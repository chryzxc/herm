import Foundation
import Testing

@testable import Herm

private actor InspectorIssueTransport: GitHubIssueTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        guard url.path.hasSuffix("/issues/42") else { throw GitHubCodeHostError.unavailable }
        let row: [String: Any] = [
            "number": 42, "title": "Example issue", "state": "open",
            "repository": ["full_name": "owner/repo"],
            "body": "Description", "user": ["login": "ada"],
            "html_url": "https://github.com/owner/repo/issues/42", "labels": [], "assignees": [],
        ]
        return (
            try JSONSerialization.data(withJSONObject: row),
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Suite @MainActor
struct GitHubInspectorTests {
    @Test func selectionsBelongToTheirChatAndFailuresKeepPreviousItem() async {
        let store = GitHubInspectorStore(transport: InspectorIssueTransport())
        let repository = GitHubRepositoryReference(
            owner: "owner", name: "repo", webURL: URL(string: "https://github.com/owner/repo")!)
        let issue = GitHubItemReference(repository: repository, number: 42, kind: .issue)
        #expect(await store.open(issue, session: "chat-a"))
        #expect(store.item(for: "chat-a")?.reference == issue)
        #expect(store.item(for: "chat-b") == nil)
        let revision = store.revision
        let missing = GitHubItemReference(repository: repository, number: 99, kind: .issue)
        #expect(await store.open(missing, session: "chat-a") == false)
        #expect(store.item(for: "chat-a")?.reference == issue)
        #expect(store.revision == revision)
        #expect(await store.open(issue, session: "chat-b"))
        #expect(store.item(for: "chat-a") !== store.item(for: "chat-b"))
    }
}
