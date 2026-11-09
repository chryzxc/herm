import Foundation
import Testing

@testable import Herm

actor RepositoryDetailsTransport: GitHubIssueTransport {
    enum Mode: Sendable { case success, commitsDenied, eventsDenied, denied, empty, slow }
    var mode: Mode
    private var requested = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(mode: Mode = .success) { self.mode = mode }
    func setMode(_ mode: Mode) { self.mode = mode }
    func waitForRequest() async {
        if requested { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requested = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
        if mode == .slow { try await Task.sleep(for: .seconds(30)) }
        if request.url!.path == "/search/issues" {
            let q =
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "q" }?.value ?? ""
            #expect(q.hasPrefix("repo:octocat/Herm is:"))
            let total = q.contains("is:pr") ? 4 : 7
            return (
                try JSONSerialization.data(withJSONObject: ["total_count": total, "items": []]),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let isCommits = request.url!.path.hasSuffix("/commits")
        let isEvents = request.url!.path.hasSuffix("/events")
        #expect(isCommits || isEvents || request.url!.path.hasSuffix("/releases"))
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "per_page" }?.value == (isCommits ? "5" : (isEvents ? "10" : "1")))
        if isCommits { #expect(query.first { $0.name == "sha" }?.value == "main") }
        let denied = mode == .denied || (mode == .commitsDenied && isCommits) || (mode == .eventsDenied && isEvents)
        let commits: [[String: Any]] = [
            [
                "sha": String(repeating: "a", count: 40), "author": ["login": "octocat"],
                "commit": [
                    "message": "Improve repository navigation\n\nKeep details focused.",
                    "author": ["name": "Octocat", "date": "2026-10-25T09:00:00Z"],
                ],
            ],
            [
                "sha": String(repeating: "b", count: 40), "author": NSNull(),
                "commit": ["message": "Fix release packaging", "author": ["name": "A contributor"]],
            ],
        ]
        let releases: [[String: Any]] = [
            [
                "name": "Autumn update", "tag_name": "v1.2.0", "draft": false, "prerelease": false,
                "published_at": "2026-10-24T09:00:00Z",
                "html_url": "https://github.com/octocat/Herm/releases/tag/v1.2.0",
            ]
        ]
        let merged: [String: Any] = [
            "id": "2", "type": "PullRequestEvent", "actor": ["login": "octocat"],
            "created_at": "2026-10-26T09:00:00Z",
            "payload": [
                "action": "closed",
                "pull_request": ["number": 12, "merged": true, "title": "Improve repository summaries"],
            ],
        ]
        let events: [[String: Any]] = [
            [
                "id": "1", "type": "PushEvent", "actor": ["login": "octocat"], "created_at": "2026-10-25T09:00:00Z",
                "payload": ["ref": "refs/heads/main"],
            ],
            merged,
            [
                "id": "3", "type": "IssueCommentEvent", "actor": ["login": "contributor"],
                "created_at": "2026-10-24T09:00:00Z",
                "payload": [
                    "action": "created",
                    "issue": ["number": 12, "title": "Improve repository summaries", "pull_request": [:]],
                ],
            ],
            merged,
        ]
        return (
            try JSONSerialization.data(
                withJSONObject: mode == .empty ? [] : (isCommits ? commits : (isEvents ? events : releases))),
            HTTPURLResponse(url: request.url!, statusCode: denied ? 403 : 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

@MainActor
struct GitHubRepositoryDetailsTests {
    private func repository() throws -> GitHubRepositorySummary {
        try GitHubRepositorySummary.parse([
            "full_name": "octocat/Herm", "private": false, "archived": false, "default_branch": "main",
            "permissions": ["pull": true, "push": true, "admin": false], "has_issues": false,
        ])
    }

    @Test func loadsUsefulDetailsAndPreservesPartialAndStaleData() async throws {
        let transport = RepositoryDetailsTransport(mode: .commitsDenied)
        let model = GitHubRepositoryDetailsModel(client: GitHubClient(transport: transport))
        let repository = try repository()
        #expect(repository.access == "Write")
        #expect(repository.hasIssues == false)
        await model.refresh(repository)
        #expect(model.commits == nil)
        #expect(model.commitError != nil)
        #expect(model.release?.tag == "v1.2.0")
        #expect(model.releaseError == nil)
        #expect(model.events?.map(\.id) == ["2", "1", "3"])
        #expect(model.events?.first?.summary == "octocat merged pull request #12")
        #expect(model.activityError == nil)
        #expect(model.openIssues == 7)
        #expect(model.openPullRequests == 4)
        await transport.setMode(.success)
        await model.refresh(repository)
        #expect(model.commits?.count == 2)
        #expect(model.commits?.first?.title == "Improve repository navigation")
        #expect(model.commits?.last?.author == "A contributor")
        #expect(model.commits?.last?.date == nil)
        #expect(model.commitError == nil)
        await transport.setMode(.denied)
        await model.refresh(repository)
        #expect(model.commits?.count == 2)
        #expect(model.release?.tag == "v1.2.0")
        #expect(model.commitError != nil && model.releaseError != nil)
        #expect(model.events?.count == 3 && model.activityError != nil)
        #expect(model.hasLoaded && !model.loading)
    }

    @Test func emptyResponsesAreDistinctFromFailure() async throws {
        let model = GitHubRepositoryDetailsModel(
            client: GitHubClient(transport: RepositoryDetailsTransport(mode: .empty)))
        await model.refresh(try repository())
        #expect(model.commits == [])
        #expect(model.events == [] && model.activityError == nil)
        #expect(model.release == nil)
        #expect(model.commitError == nil && model.releaseError == nil)
        #expect(model.hasLoaded)
    }

    @Test func cancelledSelectionDoesNotPublishDetails() async throws {
        let transport = RepositoryDetailsTransport(mode: .slow)
        let model = GitHubRepositoryDetailsModel(client: GitHubClient(transport: transport))
        let repository = try repository()
        let task = Task { await model.refresh(repository) }
        await transport.waitForRequest()
        task.cancel()
        await task.value
        #expect(!model.hasLoaded && !model.loading)
        #expect(model.commits == nil && model.release == nil && model.events == nil)
        #expect(model.commitError == nil && model.releaseError == nil && model.activityError == nil)
    }

    @Test func activityAccessFailureDoesNotHideOtherDetails() async throws {
        let transport = RepositoryDetailsTransport(mode: .eventsDenied)
        let model = GitHubRepositoryDetailsModel(client: GitHubClient(transport: transport))
        let repository = try repository()
        await model.refresh(repository)
        #expect(model.events == nil && model.activityError != nil)
        #expect(model.commits?.count == 2 && model.release != nil)
        await transport.setMode(.success)
        await model.refresh(repository)
        #expect(model.events?.count == 3 && model.activityError == nil)
    }

    @Test func parsesActivityWithoutInventingTargetsOrMergedState() throws {
        let reference = try repository().reference
        func event(_ type: String, _ payload: [String: Any]) throws -> GitHubRepositoryEvent {
            try GitHubRepositoryEvent.parse(
                [
                    "id": "event", "type": type, "actor": ["login": "octocat"],
                    "created_at": "2026-10-26T09:00:00Z", "payload": payload,
                ], repository: reference)
        }
        let closed = try event(
            "PullRequestEvent", ["action": "closed", "pull_request": ["number": 4, "merged": false]])
        #expect(closed.summary == "octocat closed pull request #4")
        #expect(closed.url.path == "/octocat/Herm/pull/4")
        let approved = try event(
            "PullRequestReviewEvent",
            ["action": "submitted", "pull_request": ["number": 4], "review": ["state": "approved"]])
        #expect(approved.summary == "octocat approved pull request #4")
        let comment = try event(
            "IssueCommentEvent",
            ["action": "created", "issue": ["number": 7, "title": "A question", "html_url": "https://example.com"]])
        #expect(comment.summary == "octocat commented on issue #7")
        #expect(comment.url.host == "github.com" && comment.url.path == "/octocat/Herm/issues/7")
        let push = try event("PushEvent", ["ref": "refs/heads/main"])
        #expect(push.detail == "main")
        let release = try event("ReleaseEvent", ["action": "published", "release": ["tag_name": "v2"]])
        #expect(release.summary == "octocat published a release" && release.detail == "v2")
        let deleted = try event("DeleteEvent", ["ref_type": "branch", "ref": "feature/example"])
        #expect(deleted.summary == "octocat deleted a branch")
        let unknown = try event("FutureEvent", [:])
        #expect(unknown.summary == "octocat · FutureEvent" && unknown.url == reference.webURL)
        #expect(throws: GitHubRequestError.self) {
            try GitHubRepositoryEvent.parse(["id": "missing-fields"], repository: reference)
        }
    }

    @Test func validatesExternalDetailPayloads() throws {
        let repository = try repository()
        #expect(throws: GitHubRequestError.self) {
            try GitHubRepositoryCommit.parse(["sha": "../../settings", "commit": ["message": "Unsafe"]])
        }
        #expect(throws: GitHubRequestError.self) {
            try GitHubRepositoryRelease.parse(
                [
                    "tag_name": "v1", "draft": false, "prerelease": false, "html_url": "https://example.com/release",
                ], repository: repository.reference)
        }
        let draft = try GitHubRepositoryRelease.parse(
            [
                "tag_name": "v2-beta", "name": "", "draft": true, "prerelease": true,
                "html_url": "https://github.com/octocat/Herm/releases/tag/v2-beta",
            ], repository: repository.reference)
        #expect(draft.draft && draft.prerelease && draft.publishedAt == nil)
        #expect(draft.name == "v2-beta")
        let unknown = try GitHubRepositorySummary.parse(["full_name": "owner/repo", "private": true, "archived": false])
        #expect(unknown.access == nil)
    }
}
