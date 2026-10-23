import Foundation
import Testing
@testable import Herm

private actor ReviewerTransport: GitHubIssueTransport {
    var writes: [(String, [String])] = []
    func recorded() -> [(String, [String])] { writes }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let row: Any
        if method != "GET" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            #expect(body["team_reviewers"] == nil)
            writes.append((method, body["reviewers"] as? [String] ?? []))
            row = [:]
        } else if url.path.hasSuffix("/requested_reviewers") {
            row = ["users": [["login": "old"]], "teams": [["slug": "team"]]]
        } else if url.path.hasSuffix("/collaborators") {
            row = [["login": "author", "permissions": ["push": true]],
                   ["login": "reader", "permissions": ["push": false]],
                   ["login": "new", "permissions": ["push": true]]]
        } else if url.path.hasSuffix("/issues/42") {
            row = ["title": "Example"]
        } else { row = ["permissions": ["push": true]] }
        return (try JSONSerialization.data(withJSONObject: row), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

struct PullRequestReviewerTests {
    private var reference: GitHubItemReference {
        GitHubItemReference(repository: GitHubRepositoryReference(owner: "owner", name: "repo", webURL: URL(string: "https://github.com/owner/repo")!), number: 42, kind: .pullRequest)
    }
    @Test func choicesExcludeAuthorAndReadOnlyPeople() async throws {
        let service = PullRequestReviewerService(client: GitHubClient(transport: ReviewerTransport()))
        #expect(try await service.choices(reference, author: "AUTHOR") == ["new"])
    }
    @Test func savesOnlyUserDeltasAndRejectsStaleRequests() async throws {
        let transport = ReviewerTransport()
        let service = PullRequestReviewerService(client: GitHubClient(transport: transport))
        try await service.save(["new"], original: ["old"], reference: reference)
        let writes = await transport.recorded()
        #expect(writes.count == 2)
        #expect(writes[0].0 == "POST" && writes[0].1 == ["new"])
        #expect(writes[1].0 == "DELETE" && writes[1].1 == ["old"])
        await #expect(throws: GitHubRequestError.changed) {
            try await service.save(["new"], original: [], reference: reference)
        }
        #expect(await transport.recorded().count == 2)
    }
}
