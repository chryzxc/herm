import Foundation
import Testing

@testable import Herm

@MainActor
private final class PullRequestMutationFake: PullRequestMutationExecuting {
    var commentCalls = 0
    var statusCalls = 0

    func postComment(_ body: String, on record: PullRequestRecord) async -> PullRequestComment? {
        commentCalls += 1
        return nil
    }

    func updateStatus(_ status: PullRequestStatus, for record: PullRequestRecord) async -> PullRequestRecord? {
        statusCalls += 1
        return nil
    }
}

private final class GitHubTokenResolverProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func resolve() -> String? {
        lock.lock()
        count += 1
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.05)
        return "token"
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

struct RepositoryCodeWorkspaceTests {
    @Test func repositoryShimmerTravelsOnlyLeadingToTrailingWithinEachCycle() {
        let width: CGFloat = 600
        let times = stride(from: 0.0, through: 1.5, by: 0.3)
        let offsets = times.map { RepositoryShimmerMotion.offset(containerWidth: width, at: $0) }

        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $0.0 < $0.1 })
        #expect(offsets.first == -RepositoryShimmerMotion.bandWidth(for: width))
        #expect(
            RepositoryShimmerMotion.offset(containerWidth: width, at: RepositoryShimmerMotion.duration) == offsets.first
        )
    }

    @Test func sessionRepositoryScopeKeepsSessionsDistinctForOnePath() {
        let first = SessionRepositoryScope(sessionID: "session-a", repositoryPath: "/workspace/repo")
        let second = SessionRepositoryScope(sessionID: "session-b", repositoryPath: "/workspace/repo")
        #expect(first != second)
        #expect(first.identity != second.identity)
    }

    @MainActor
    @Test func pullRequestMutationRequestDoesNotCallExecutorUntilConfirmed() async {
        let fake = PullRequestMutationFake()
        let center = PullRequestCenterModel(mutationExecutor: fake)
        let record = PullRequestRecord(
            repository: GitHubRepositoryReference(
                owner: "owner", name: "repo", webURL: URL(string: "https://github.com/owner/repo")!),
            localPath: "/tmp/repo", number: 7, title: "Improve reliability", body: "", author: "owner",
            authorAvatarURL: nil, headBranch: "feature", baseBranch: "main", updatedAt: nil, isDraft: true,
            webURL: nil, requestedReviewers: [], comments: 0, additions: nil, deletions: nil, changedFiles: nil,
            checks: [], reviews: []
        )
        let coordinator = PullRequestMutationCoordinator()

        coordinator.requestComment("Please add coverage.", for: record)
        #expect(fake.commentCalls == 0)
        #expect(coordinator.pending != nil)

        _ = await coordinator.confirm(using: center)
        #expect(fake.commentCalls == 1)
        #expect(coordinator.pending == nil)

        coordinator.requestStatus(.readyForReview, for: record)
        #expect(fake.statusCalls == 0)
        coordinator.cancel()
        #expect(fake.statusCalls == 0)
        #expect(coordinator.pending == nil)
    }

    @MainActor
    @Test func pullRequestDetailLoadsCanRunForSeparateSelections() {
        let center = PullRequestCenterModel()
        #expect(center.beginDetailLoad(for: "repository#1"))
        #expect(center.beginDetailLoad(for: "repository#2"))
        #expect(!center.beginDetailLoad(for: "repository#1"))

        #expect(center.isLoadingDetail)
        center.finishDetailLoad(for: "repository#1")
        #expect(center.isLoadingDetail)
        center.finishDetailLoad(for: "repository#2")
        #expect(!center.isLoadingDetail)
    }

    @Test func concurrentGitHubTokenRequestsShareOneResolver() async {
        let cache = GitHubTokenCache(ttl: 60)
        let probe = GitHubTokenResolverProbe()

        async let first = cache.token { probe.resolve() }
        async let second = cache.token { probe.resolve() }
        async let third = cache.token { probe.resolve() }
        let values = await [first, second, third]

        #expect(values == ["token", "token", "token"])
        #expect(probe.callCount == 1)
    }

    @Test func githubPullRequestFilesResponsePreservesChangedFiles() {
        let payload: Any = [
            [
                "filename": "Sources/App/Main.swift",
                "status": "modified",
                "additions": 4,
                "deletions": 2,
                "patch": "@@ -1 +1 @@\\n-old\\n+new",
                "blob_url": "https://github.com/owner/repo/blob/main/Sources/App/Main.swift",
            ]
        ]

        let files = PullRequestCenterAPI.parseFilesPayload(payload)

        #expect(files?.count == 1)
        #expect(files?.first?.path == "Sources/App/Main.swift")
        #expect(files?.first?.additions == 4)
        #expect(files?.first?.deletions == 2)
        #expect(files?.first?.patch?.contains("+new") == true)
    }

    @Test func pullRequestFilesProjectionDistinguishesUnavailableFromEmpty() {
        #expect(PullRequestFilesProjection.state(files: nil, isLoading: false, expectedFileCount: nil) == .unavailable)
        #expect(PullRequestFilesProjection.state(files: [], isLoading: false, expectedFileCount: nil) == .unavailable)
        #expect(PullRequestFilesProjection.state(files: [], isLoading: false, expectedFileCount: 2) == .unavailable)
        #expect(PullRequestFilesProjection.state(files: [], isLoading: false, expectedFileCount: 0) == .empty)
        #expect(PullRequestFilesProjection.state(files: nil, isLoading: true, expectedFileCount: nil) == .loading)
        #expect(PullRequestFilesProjection.state(files: [], isLoading: true, expectedFileCount: 2) == .loading)
    }

    @Test func pullRequestFileTreeGroupsNestedPaths() {
        let files = [
            PullRequestFile(
                path: "Sources/App/Main.swift", status: "modified", additions: 1, deletions: 2, patch: nil, webURL: nil),
            PullRequestFile(path: "README.md", status: "modified", additions: 3, deletions: 0, patch: nil, webURL: nil),
        ]
        let tree = PullRequestFileTreeBuilder.make(files: files)
        #expect(tree.map(\.id) == ["README.md", "Sources", "Sources/App", "Sources/App/Main.swift"])
        #expect(tree.first(where: { $0.id == "Sources/App" })?.isDirectory == true)
        #expect(tree.first(where: { $0.id == "Sources/App/Main.swift" })?.depth == 2)
    }

    @Test func pullRequestDiffParserClassifiesAndPairsChangedRuns() {
        let patch = "@@ -1,2 +1,2 @@\n-old value\n+new value\n unchanged"
        let lines = PullRequestDiffPresentation.lines(patch)
        #expect(lines.map(\.kind) == [.hunk, .deletion, .addition, .context])
        let rows = PullRequestDiffPresentation.splitRows(lines)
        #expect(rows.count == 3)
        #expect(rows[1].left?.text == "-old value")
        #expect(rows[1].right?.text == "+new value")

        let additionOnly = PullRequestDiffPresentation.splitRows(PullRequestDiffPresentation.lines("+new file"))
        #expect(additionOnly.count == 1)
        #expect(additionOnly[0].left == nil)
        #expect(additionOnly[0].right?.kind == .addition)
    }

    @Test func pullRequestReviewPreferencesPersistAndToggleExpandedFiles() {
        let suiteName = "hermes-review-preferences-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = PullRequestReviewPreferenceStore(defaults: defaults)
        #expect(first.diffMode == .unified)
        #expect(first.showsFileTree == false)
        #expect(first.wordWrap)
        first.diffMode = .split
        first.wordWrap = false
        first.toggleExpanded("README.md")
        let second = PullRequestReviewPreferenceStore(defaults: defaults)
        #expect(second.diffMode == .split)
        #expect(!second.wordWrap)
        #expect(second.expandedFileIDs == Set(["README.md"]))
        second.toggleExpanded("README.md")
        #expect(second.expandedFileIDs.isEmpty)
    }

    @Test func changesBrowserDoesNotExposeAnEditorSaveCallback() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Herm/Repository/RepositoryChangesBrowser.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(!source.contains("onSave:"))
        #expect(!source.contains("saveDocument"))
    }

    @Test func parsesGitHubSSHAndHTTPSRemotes() {
        #expect(GitHubRemoteParser.parse("git@github.com:owner/repo.git")?.id == "owner/repo")
        #expect(
            GitHubRemoteParser.parse("https://github.com/owner/repo")?.webURL.absoluteString
                == "https://github.com/owner/repo")
        #expect(GitHubRemoteParser.parse("ssh://git@github.com/owner/repo.git")?.id == "owner/repo")
        #expect(GitHubRemoteParser.parse("ssh://other@github.com/owner/repo.git") == nil)
        #expect(GitHubRemoteParser.parse("https://token@github.com/owner/repo.git") == nil)
        #expect(GitHubRemoteParser.parse("https://gitlab.com/owner/repo") == nil)
        #expect(GitHubRemoteParser.parse("git@github.com:owner/../secrets.git") == nil)
    }
    @Test func documentURLStaysWithinTheSelectedRepository() {
        #expect(
            RepositoryService.documentURL(repositoryPath: "/workspace/project", filePath: "Sources/App.swift")?.path
                == "/workspace/project/Sources/App.swift")
        #expect(
            RepositoryService.documentURL(repositoryPath: "/workspace/project", filePath: "../outside.swift") == nil)
        #expect(RepositoryService.documentURL(repositoryPath: "/workspace/project", filePath: "/outside.swift") == nil)
    }

    @Test func documentURLRejectsSymlinkEscapesOutsideRepository() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hermes-document-root-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hermes-document-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"), withDestinationURL: outside)

        #expect(RepositoryService.documentURL(repositoryPath: root.path, filePath: "linked/secret.txt") == nil)
    }

    @Test func documentURLRejectsInRepositorySymlinkComponents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hermes-document-in-repo-\(UUID().uuidString)")
        let realDirectory = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "valid".write(to: realDirectory.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"), withDestinationURL: realDirectory)

        #expect(RepositoryService.documentURL(repositoryPath: root.path, filePath: "linked/App.swift") == nil)
    }

    @Test func projectExplorerDoesNotDescendIntoSymlinkedDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hermes-project-root-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hermes-project-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try "valid".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"), withDestinationURL: outside)

        let entries = await RepositoryService.projectFiles(path: root.path)

        #expect(!entries.contains { $0.path == "linked" })
        #expect(!entries.contains { $0.path == "linked/secret.txt" })
    }

    @Test func projectExplorerHidesGeneratedTreesUntilRequested() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hermes-project-generated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".cache"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "let value = 1".write(
            to: root.appendingPathComponent("Sources/App.swift"), atomically: true, encoding: .utf8)
        try "generated".write(to: root.appendingPathComponent(".cache/state.json"), atomically: true, encoding: .utf8)
        try "dependency".write(
            to: root.appendingPathComponent("node_modules/package.json"), atomically: true, encoding: .utf8)

        let defaultEntries = await RepositoryService.projectFiles(path: root.path)
        #expect(defaultEntries.contains { $0.path == "Sources/App.swift" })
        #expect(!defaultEntries.contains { $0.path.hasPrefix(".cache") })
        #expect(!defaultEntries.contains { $0.path.hasPrefix("node_modules") })
        #expect(!defaultEntries.contains { $0.path.hasPrefix(".git") })

        let generatedEntries = await RepositoryService.projectFiles(path: root.path, includeGenerated: true)
        #expect(generatedEntries.contains { $0.path == ".cache/state.json" })
        #expect(generatedEntries.contains { $0.path == "node_modules" })
        #expect(!generatedEntries.contains { $0.path.hasPrefix(".git") })
    }

    @Test func explorerWorkspaceUsesBoundedNavigatorSizing() {
        #expect(ExplorerWorkspaceMetrics.initialNavigatorWidth == 280)
        #expect(ExplorerWorkspaceMetrics.minimumNavigatorWidth == 220)
        #expect(ExplorerWorkspaceMetrics.maximumNavigatorWidth == 360)
        #expect(ExplorerWorkspaceMetrics.minimumEditorWidth == 480)
    }

    @Test func loadAndSaveDocumentRejectSymlinkEscapes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hermes-document-load-save-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hermes-document-load-save-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"), withDestinationURL: outside)

        let loaded = await RepositoryService.loadDocument(path: root.path, filePath: "linked/secret.txt")
        let saved = await RepositoryService.saveDocument(
            path: root.path, filePath: "linked/secret.txt", contents: "overwritten")

        #expect(loaded == nil)
        #expect(saved == false)
        #expect(try String(contentsOf: outside.appendingPathComponent("secret.txt"), encoding: .utf8) == "secret")
    }

    @Test func documentSizeLimitIsExplicit() {
        #expect(RepositoryService.maxDocumentBytes == 256_000)
    }

    @Test func blameModeHasExplicitLineBound() {
        #expect(RepositoryService.maxBlameLines == 10_000)
    }

    @Test func parsesPorcelainBlameWithRepeatedMetadataAndBlankLines() {
        let committedHash = String(repeating: "a", count: 40)
        let output = """
            \(committedHash) 1 1 2
            author Ada Lovelace
            author-time 1700000000
            author-tz +0000
            summary Add parser
            filename Sources/App.swift
            \tlet first = true
            \(committedHash) 2 2 1
            author Ada Lovelace
            author-time 1700000000
            author-tz +0000
            summary Add parser
            filename Sources/App.swift
            \t
            \(String(repeating: "0", count: 40)) 3 3 1
            author Working Tree
            author-time 1700000000
            author-tz +0000
            summary Temporary change
            filename Sources/App.swift
            \tlet changed = true
            """

        let document = RepositoryService.parseBlamePorcelain(output, path: "Sources/App.swift")

        #expect(document?.path == "Sources/App.swift")
        #expect(document?.lines.count == 3)
        #expect(document?.lines[0].commit.author == "Ada Lovelace")
        #expect(document?.lines[0].commit.summary == "Add parser")
        #expect(document?.lines[1].text.isEmpty == true)
        #expect(document?.lines[2].commit.isUncommitted == true)
        #expect(document?.lines[2].commit.author == "Not committed yet")
        #expect(document?.lines[2].commit.summary == "Working tree changes")
    }

    @Test func malformedBlamePorcelainIsRejected() {
        #expect(RepositoryService.parseBlamePorcelain("not porcelain output", path: "App.swift") == nil)
        #expect(RepositoryService.parseBlamePorcelain("abc 1 1 1\nauthor Missing source", path: "App.swift") == nil)
    }

    @Test func blameRejectsUnsafePathsWithoutRunningGit() async {
        let absolute = await RepositoryService.blame(path: "/tmp/project", filePath: "/etc/passwd")
        let traversal = await RepositoryService.blame(path: "/tmp/project", filePath: "../outside.swift")

        #expect(absolute == .unavailable("Blame is unavailable for this file path."))
        #expect(traversal == .unavailable("Blame is unavailable for this file path."))
    }

    @Test func blameReturnsSafeUnavailableResultForMissingRepository() async {
        let result = await RepositoryService.blame(path: "/tmp/does-not-exist", filePath: "App.swift")

        #expect(result == .unavailable("Blame is unavailable for untracked, binary, or non-Git files."))
    }

    @Test func blameRejectsFilesOverTheLineLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-blame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("Large.swift")
        try String(repeating: "let value = true\n", count: RepositoryService.maxBlameLines + 1)
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(runGit(path: root.path, arguments: ["init", "-q"]))
        #expect(runGit(path: root.path, arguments: ["config", "user.email", "tests@example.com"]))
        #expect(runGit(path: root.path, arguments: ["config", "user.name", "Hermes Tests"]))
        #expect(runGit(path: root.path, arguments: ["add", "Large.swift"]))
        #expect(runGit(path: root.path, arguments: ["commit", "-qm", "large fixture"]))

        let result = await RepositoryService.blame(path: root.path, filePath: "Large.swift")

        #expect(result == .unavailable("Blame is unavailable for files over 10,000 lines."))
    }

    @Test func blameReadsTrackedWorkingTreeContents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hermes-blame-tracked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Title\n\nTracked content\n".write(
            to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        #expect(runGit(path: root.path, arguments: ["init", "-q"]))
        #expect(runGit(path: root.path, arguments: ["config", "user.email", "tests@example.com"]))
        #expect(runGit(path: root.path, arguments: ["config", "user.name", "Hermes Tests"]))
        #expect(runGit(path: root.path, arguments: ["add", "README.md"]))
        #expect(runGit(path: root.path, arguments: ["commit", "-qm", "tracked README"]))

        let result = await RepositoryService.blame(path: root.path, filePath: "README.md")

        guard case .available(let document) = result else {
            Issue.record("Expected tracked README blame to be available, got \(result)")
            return
        }
        #expect(document.lines.map(\.text) == ["# Title", "", "Tracked content"])
    }

    private func runGit(path: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", path] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

}
