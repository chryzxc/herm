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
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let references = SessionPullRequestReferences.extract(
            texts: [
                "See [change](https://github.com/owner/repo/pull/42). Also #99.",
                #"{"url":"https:\/\/github.com\/owner\/repo\/pull\/42"}"#,
                "https://github.com/owner/other/pull/42",
                "https://github.com/owner/repo/issues/5",
                "https://github.com.evil.test/owner/repo/pull/7",
                "https://github.com/owner/repo/pull/0",
            ], defaults: defaults)
        #expect(references.map(\.title) == ["owner/repo#42", "owner/other#42"])
    }

    @Test func includesCompletedToolResults() {
        let call = ActiveToolCall(
            id: "tool", name: "terminal", input: "gh pr view", context: "", startedAt: Date(),
            result: "https://github.com/owner/repo/pull/8", isComplete: true)
        let texts = SessionPullRequestReferences.texts(
            messages: [ChatMessage(role: .hermes, text: "Fetched the PR.", activity: [call])], activity: [call])
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        #expect(SessionPullRequestReferences.extract(texts: texts, defaults: defaults).map(\.number) == [8])
    }

    @Test func respectsDisabledPRNavigation() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(false, forKey: SidebarVisibilityKey.github)
        #expect(
            SessionPullRequestReferences.extract(
                texts: ["https://github.com/owner/repo/pull/1"], defaults: defaults
            ).isEmpty)
    }

    @Test func replacesReferencesWhenHistoryChanges() {
        let rail = SessionPullRequestRailModel(details: PullRequestDetailStore())
        rail.discover(
            messages: [ChatMessage(role: .hermes, text: "https://github.com/owner/repo/pull/3")], activity: [])
        #expect(rail.references.map(\.number) == [3])
        rail.discover(messages: [ChatMessage(role: .user, text: "Another session")], activity: [])
        #expect(rail.references.isEmpty)
    }
    @Test func failedRefreshRetainsFetchedDetailsAndExposesFailure() async {
        let transport = RailPRTransport()
        let details = PullRequestDetailStore()
        let rail = SessionPullRequestRailModel(api: .init(transport: transport), details: details)
        rail.discover(
            messages: [ChatMessage(role: .hermes, text: "https://github.com/owner/repo/pull/3")], activity: [])
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

}
