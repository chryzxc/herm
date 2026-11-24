import Combine
import Foundation
import Testing

@testable import Herm

private actor RailPRTransport: GitHubIssueTransport {
    var unavailable = false
    func fail() { unavailable = true }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if unavailable { throw GitHubRequestError.unavailable }
        if request.url!.path.hasSuffix("/reviews") {
            return (
                Data("[]".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let row: [String: Any] = [
            "number": 3, "title": "Fetched PR", "state": "open", "body": "Description",
            "user": ["login": "ada"], "head": ["ref": "feature"], "base": ["ref": "main"],
            "html_url": "https://github.com/owner/repo/pull/3",
        ]
        return (
            try JSONSerialization.data(withJSONObject: row),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Suite @MainActor
struct SessionPullRequestRailTests {
    @Test func hidesRailAndToggleWhenTheConversationColumnIsTooNarrow() {
        for width in [CGFloat(0), 448, 515, 799] {
            #expect(ConversationWorkspaceMetrics.sessionRailWidth(availableWidth: width) == 0)
        }
        for width in [CGFloat(800), 850, 900, 1_200] {
            let rail = ConversationWorkspaceMetrics.sessionRailWidth(availableWidth: width)
            #expect(rail >= 320 && rail <= 360)
            #expect(width - rail >= 480)
        }
        #expect(ConversationWorkspaceMetrics.sessionRailWidth(availableWidth: 800) == 320)
        #expect(ConversationWorkspaceMetrics.sessionRailWidth(availableWidth: 1_200) == 360)
    }

    @Test func localChangesAreScopedAndCountStagedFilesOnce() {
        let path = "/tmp/rail-project"
        var repository = RepositorySnapshot(
            path: path, branch: "main", changedFiles: 3, latestCommit: "", isGitRepository: true)
        let files = [
            RepositoryFileChange(path: "file.swift", status: .modified, isStaged: true, renameSource: nil),
            RepositoryFileChange(path: "file.swift", status: .modified, isStaged: false, renameSource: nil),
            RepositoryFileChange(path: "new.swift", status: .untracked, isStaged: false, renameSource: nil),
        ]
        let snapshot = RepositoryChangeSnapshot(
            repositoryID: repository.repositoryID, headRevision: "abc123", branch: "main", files: files,
            refreshedAt: .now)
        #expect(
            SessionRailChangeSummary.make(path: path, repository: repository, changes: snapshot)
                == SessionRailChangeSummary(
                    repositoryName: "rail-project", fileCount: 2, untrackedCount: 1, files: files))
        #expect(SessionRailChangeSummary.make(path: "/tmp/other", repository: repository, changes: snapshot) == nil)
        #expect(SessionRailChangeSummary.make(path: path, repository: repository, changes: nil) == nil)
        let clean = RepositoryChangeSnapshot(
            repositoryID: repository.repositoryID, headRevision: "abc123", branch: "main", files: [], refreshedAt: .now)
        #expect(SessionRailChangeSummary.make(path: path, repository: repository, changes: clean) == nil)
        repository.isStale = true
        #expect(SessionRailChangeSummary.make(path: path, repository: repository, changes: snapshot) == nil)
    }

    @Test func extractsAndDeduplicatesPRsWithoutGuessingBareNumbers() {
        let references = SessionPullRequestReferences.extract(
            texts: [
                "See [change](https://github.com/owner/repo/pull/42). Also #99.",
                #"{"url":"https:\/\/github.com\/owner\/repo\/pull\/42"}"#,
                "https://github.com/owner/other/pull/42",
                "https://github.com/owner/repo/issues/5",
                "https://github.com.evil.test/owner/repo/pull/7",
                "https://github.com/owner/repo/pull/0",
            ])
        #expect(references.map(\.title) == ["owner/repo#42", "owner/other#42"])
    }

    @Test func includesCompletedToolResults() async {
        let call = ActiveToolCall(
            id: "tool", name: "terminal", input: "gh pr view", context: "", startedAt: Date(),
            result: "https://github.com/owner/repo/pull/8", isComplete: true)
        let rail = SessionPullRequestRailModel(details: PullRequestDetailStore())
        await rail.discover(
            messages: [ChatMessage(role: .hermes, text: "Fetched the PR.", activity: [call])], revision: 1)
        await rail.discoverActivity([call], revision: 1)
        #expect(rail.references.map(\.number) == [8])
    }

    @Test func broadToolResultsDoNotLinkOtherSessionsPullRequests() async {
        let unrelated = "https://github.com/owner/repo/pull/7 https://github.com/owner/repo/pull/8"
        let calls = ["gh pr list --state all", "gh search prs", "cat session-history.json"].enumerated().map {
            ActiveToolCall(
                id: "tool-\($0.offset)", name: "terminal", input: $0.element, context: "", startedAt: .now,
                result: unrelated, isComplete: true)
        }
        let rail = SessionPullRequestRailModel(details: PullRequestDetailStore())
        await rail.discover(
            messages: [ChatMessage(role: .hermes, text: "Checked repository activity.", activity: calls)],
            revision: 1)
        await rail.discoverActivity(calls, revision: 1)
        #expect(rail.references.isEmpty)
        await rail.discover(
            messages: [ChatMessage(role: .user, text: "Work on https://github.com/owner/repo/pull/9")], revision: 2)
        #expect(rail.references.map(\.number) == [9])
    }

    @Test func nonGhToolInputsDoNotLinkPullRequests() async {
        let fetch = ActiveToolCall(
            id: "fetch", name: "web_extract", input: "https://github.com/axios/axios/pull/1", context: "",
            startedAt: .now, result: nil, isComplete: false, args: ["url": "https://github.com/axios/axios/pull/2"])
        let rail = SessionPullRequestRailModel(details: PullRequestDetailStore())
        await rail.discoverActivity([fetch], revision: 1)
        #expect(rail.references.isEmpty)
    }

    @Test func targetedToolInputsAndCreatedPullRequestsStayLinked() async {
        let targeted = ActiveToolCall(
            id: "target", name: "terminal", input: "gh pr view https://github.com/owner/repo/pull/8", context: "",
            startedAt: .now,
            result: "Related: https://github.com/owner/repo/pull/99", isComplete: true)
        let created = ActiveToolCall(
            id: "create", name: "terminal", input: "gh pr create --title Fix", context: "", startedAt: .now,
            result: "https://github.com/owner/repo/pull/10", isComplete: true)
        let rail = SessionPullRequestRailModel(details: PullRequestDetailStore())
        await rail.discoverActivity([targeted, created], revision: 1)
        #expect(rail.references.map(\.number) == [8, 10])
    }

    @Test func replacesReferencesWhenHistoryChanges() async {
        let rail = SessionPullRequestRailModel(details: PullRequestDetailStore())
        let id = UUID()
        await rail.discover(
            messages: [ChatMessage(id: id, role: .hermes, text: "https://github.com/owner/repo/pull/3")], revision: 1)
        #expect(rail.references.map(\.number) == [3])
        await rail.discover(messages: [ChatMessage(id: id, role: .hermes, text: "Revised answer")], revision: 2)
        #expect(rail.references.isEmpty)
    }

    @Test func liveToolResultsSurviveTransientActivityAndFollowHistory() async {
        let rail = SessionPullRequestRailModel(details: PullRequestDetailStore())
        let otherRail = SessionPullRequestRailModel(details: PullRequestDetailStore())
        var call = ActiveToolCall(
            id: "tool", name: "terminal", input: "gh pr view", context: "", startedAt: .now,
            result: nil, isComplete: false)
        await rail.discoverActivity([call], revision: 1)
        #expect(rail.references.isEmpty)
        call.result = "https://github.com/owner/repo/pull/3"
        await rail.discoverActivity([call], revision: 1)
        await rail.discoverActivity([], revision: 1)
        let message = ChatMessage(role: .user, text: "Start with https://github.com/owner/repo/pull/2")
        let otherMessage = ChatMessage(role: .user, text: "Start with https://github.com/owner/repo/pull/7")
        async let first: Void = rail.discover(messages: [message], revision: 1)
        async let second: Void = otherRail.discover(messages: [otherMessage], revision: 1)
        _ = await (first, second)
        #expect(rail.references.map(\.number) == [2, 3])
        #expect(otherRail.references.map(\.number) == [7])
        await rail.discover(messages: [message], revision: 2)
        #expect(rail.references.map(\.number) == [2])
        #expect(otherRail.references.map(\.number) == [7])
    }
    @Test func failedRefreshRetainsFetchedDetailsAndExposesFailure() async {
        let transport = RailPRTransport()
        let details = PullRequestDetailStore()
        let rail = SessionPullRequestRailModel(api: .init(transport: transport), details: details)
        await rail.discover(
            messages: [ChatMessage(role: .hermes, text: "https://github.com/owner/repo/pull/3")], revision: 1)
        await rail.refresh()
        let id = "github:owner/repo#3"
        #expect(details.records[id]?.title == "Fetched PR")
        #expect(rail.failures.isEmpty)
        await transport.fail()
        await rail.refresh()
        #expect(details.records[id]?.title == "Fetched PR")
        #expect(rail.failures[id] != nil)
        #expect(!rail.isRefreshing)
    }

    @Test func sharedDetailUpdatesOnlyReachRailsReferencingTheirPullRequest() async throws {
        let details = PullRequestDetailStore()
        let rail = SessionPullRequestRailModel(api: .init(transport: RailPRTransport()), details: details)
        let otherRail = SessionPullRequestRailModel(details: details)
        await rail.discover(
            messages: [ChatMessage(role: .hermes, text: "https://github.com/owner/repo/pull/3")], revision: 1)
        await otherRail.discover(
            messages: [ChatMessage(role: .hermes, text: "https://github.com/owner/repo/pull/7")], revision: 1)
        var ownUpdates = 0
        var unrelatedUpdates = 0
        let own = rail.visibleRecordChanges.sink { _ in ownUpdates += 1 }
        let unrelated = otherRail.visibleRecordChanges.sink { _ in unrelatedUpdates += 1 }
        defer {
            own.cancel()
            unrelated.cancel()
        }

        await rail.refresh()
        #expect(ownUpdates == 1)
        #expect(unrelatedUpdates == 0)
        #expect(try #require(details.records["github:owner/repo#3"]).title == "Fetched PR")
    }

}
