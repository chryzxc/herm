import Foundation
import Testing

@testable import Herm

private actor PullRequestCommitDiffTransport: GitHubIssueTransport {
    let failPage: Int?
    let malformed: Bool
    private(set) var requests: [URLRequest] = []

    init(failPage: Int? = nil, malformed: Bool = false) {
        self.failPage = failPage
        self.malformed = malformed
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = request.url!
        let page =
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "page" }?.value ?? "1"
        let status = Int(page) == failPage ? 403 : 200
        let files: [[String: Any]] =
            malformed
            ? [["status": "modified"]]
            : (0..<(page == "1" ? 100 : 1)).map {
                [
                    "filename": "page-\(page)-\($0).swift", "status": "modified", "additions": 1, "deletions": 1,
                    "patch": "@@ -1 +1 @@\n-old\n+new",
                ]
            }
        let payload: [String: Any] = ["files": files]
        return (
            try JSONSerialization.data(withJSONObject: payload),
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}

struct PullRequestCommitDiffTests {
    private let sha = String(repeating: "a", count: 40)
    private var repository: GitHubRepositoryReference { GitHubReferenceParser.repository("owner/repo")! }

    @Test func loadsOnlyTheSelectedCommitAndPaginatesFiles() async throws {
        let transport = PullRequestCommitDiffTransport()
        let result = try await PullRequestCommitDiffService(client: GitHubClient(transport: transport)).load(
            repository: repository, sha: sha)
        #expect(result.items.count == 101)
        #expect(!result.coverage.partial)
        #expect(result.items.first?.patch == "@@ -1 +1 @@\n-old\n+new")
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.path == "/repos/owner/repo/commits/\(sha)" && $0.httpMethod == "GET" })
    }

    @Test func deniedLaterPageKeepsLoadedFilesWithPartialCoverage() async throws {
        let transport = PullRequestCommitDiffTransport(failPage: 2)
        let result = try await PullRequestCommitDiffService(client: GitHubClient(transport: transport)).load(
            repository: repository, sha: sha)
        #expect(result.items.count == 100)
        #expect(result.coverage.partial)
        #expect(result.coverage.label != nil)
    }

    @Test func deniedInitialPageAndMalformedFilesFailHonestly() async {
        for transport in [PullRequestCommitDiffTransport(failPage: 1), PullRequestCommitDiffTransport(malformed: true)]
        {
            await #expect(throws: GitHubRequestError.self) {
                try await PullRequestCommitDiffService(client: GitHubClient(transport: transport)).load(
                    repository: repository, sha: sha)
            }
        }
    }

    @Test func rejectsUnsafeCommitReferencesBeforeRequesting() async {
        let transport = PullRequestCommitDiffTransport()
        for invalid in ["", "main", "../commits/main", String(repeating: "g", count: 40)] {
            await #expect(throws: GitHubRequestError.malformed) {
                try await PullRequestCommitDiffService(client: GitHubClient(transport: transport)).load(
                    repository: repository, sha: invalid)
            }
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func activityRetainsTheCommitIdentityAndMissingPatchesStayUnavailable() throws {
        let record = try #require(
            PullRequestCenterAPI().parse(
                ["number": 1, "title": "Fixture"], repository: repository, localPath: ""))
        let commit = PullRequestCommit(
            id: sha, message: "Fix timeout", author: "author", authorAvatarURL: nil, committedAt: nil, webURL: nil)
        let item = try #require(record.activityItems(comments: [], commits: [commit], events: []).first)
        #expect(item.commitSHA == sha)
        #expect(item.summary == commit.message)
        let files = try #require(
            PullRequestCenterAPI.parseFilesPayload([
                ["filename": "image.png", "status": "added", "additions": 0, "deletions": 0]
            ]))
        #expect(files.count == 1)
        #expect(files[0].patch == nil)
    }
}
