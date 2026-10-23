import Foundation
import Testing

@testable import Herm

/// Deliberately finishes a response after cancellation, like an already-delivered network reply.
private actor PausedGitHubTransport: GitHubIssueTransport {
    let pausedPath: String
    private var continuation: CheckedContinuation<Void, Never>?
    private var didPause = false
    private(set) var paths: [String] = []
    private(set) var cancelledResponses = 0

    init(pausedPath: String) { self.pausedPath = pausedPath }
    var isPaused: Bool { continuation != nil }
    func release() {
        continuation?.resume()
        continuation = nil
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        paths.append(url.path)
        if url.path == pausedPath && !didPause {
            didPause = true
            await withCheckedContinuation { continuation = $0 }
        }
        if Task.isCancelled { cancelledResponses += 1 }
        let payload: [String: Any]
        if url.path == "/user" {
            payload = ["login": "ada"]
        } else if url.path == "/search/issues" {
            payload = [
                "items": [
                    [
                        "number": 19, "title": "A PR", "state": "open",
                        "repository": ["full_name": "owner/repo"], "user": ["login": "ada"],
                    ]
                ]
            ]
        } else {
            payload = [
                "number": 19, "title": "Full detail", "head": ["ref": "feature", "sha": "abc"],
                "base": ["ref": "main"], "user": ["login": "ada"],
            ]
        }
        return (
            try JSONSerialization.data(withJSONObject: payload),
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

struct PageLoadCancellationTests {
    private func waitForPause(_ transport: PausedGitHubTransport) async throws {
        for _ in 0..<2_000 {
            if await transport.isPaused { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Request did not reach the controlled pause")
        throw CancellationError()
    }

    @MainActor @Test func cancelledPullRequestRefreshDoesNotStartSearchOrShowFailure() async throws {
        let transport = PausedGitHubTransport(pausedPath: "/user")
        let center = PullRequestCenterModel(api: PullRequestCenterAPI(transport: transport))
        let load = Task { await center.refresh(projects: []) }
        try await waitForPause(transport)
        load.cancel()
        await transport.release()
        await load.value
        #expect(!center.isRefreshing)
        #expect(!center.hasLoaded)
        #expect(center.errorMessage == nil)
        #expect(await transport.paths == ["/user"])
        await center.refresh(projects: [])
        #expect(center.hasLoaded)
        #expect(center.records.count == 1)
    }

    @MainActor @Test func leavingAndReturningToIssuesIgnoresTheOldRefresh() async throws {
        let transport = PausedGitHubTransport(pausedPath: "/user")
        let center = IssueCenterModel(api: GitHubIssueCenterAPI(transport: transport))
        let old = Task { await center.refresh(projects: []) }
        try await waitForPause(transport)
        center.cancelLoads()
        await center.refresh(projects: [])
        let current = center.records
        #expect(center.hasLoaded)
        await transport.release()
        await old.value
        #expect(center.records == current)
        #expect(center.errorMessage == nil)
        #expect(!center.isRefreshing)
    }

    @MainActor @Test func leavingPullRequestsCancelsSharedSummaryAndAllowsRetry() async throws {
        let transport = PausedGitHubTransport(pausedPath: "/repos/owner/repo/pulls/19")
        let center = PullRequestCenterModel(api: PullRequestCenterAPI(transport: transport))
        await center.refresh(projects: [])
        let record = try #require(center.records.first)
        let summary = Task { await center.loadSummary(for: record) }
        try await waitForPause(transport)
        center.cancelLoads()
        await transport.release()
        let abandoned = await summary.value
        #expect(abandoned == nil)
        #expect(center.records.first?.title == "A PR")
        #expect(await transport.cancelledResponses == 1)
        #expect(!(await transport.paths).contains("/repos/owner/repo/commits/abc/check-runs"))
        let retry = await center.loadSummary(for: record)
        #expect(retry?.title == "Full detail")
    }

    @MainActor @Test func cancelledIssueRefreshDoesNotPublishAnError() async throws {
        let transport = PausedGitHubTransport(pausedPath: "/user")
        let center = IssueCenterModel(api: GitHubIssueCenterAPI(transport: transport))
        let load = Task { await center.refresh(projects: []) }
        try await waitForPause(transport)
        load.cancel()
        await transport.release()
        await load.value
        #expect(center.errorMessage == nil)
        #expect(!center.isRefreshing)
        #expect(!center.hasLoaded)
        #expect(await transport.paths == ["/user"])
    }
}

private actor RemoteLookupProbe {
    private(set) var calls = 0
    private var active = 0
    private(set) var peak = 0
    private var pauses = true
    func stopPausing() { pauses = false }
    func resolve(_ path: String) async -> GitHubRepositoryReference? {
        calls += 1
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        if pauses { try? await Task.sleep(for: .seconds(60)) }
        return GitHubRepositoryReference(
            owner: "owner", name: path, webURL: URL(string: "https://github.com/owner/\(path)")!)
    }
}

extension PageLoadCancellationTests {
    @Test func repositoryDiscoveryIsBoundedAndCancellationStopsQueuedProjects() async throws {
        let probe = RemoteLookupProbe()
        let paths = (0..<100).map(String.init)
        let load = Task { await RepositoryService.githubRemotes(paths: paths, resolve: probe.resolve) }
        for _ in 0..<2_000 {
            if await probe.calls >= 4 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        load.cancel()
        _ = await load.value
        #expect(await probe.peak <= 4)
        #expect(await probe.calls == 4)
        await probe.stopPausing()
        let remotes = await RepositoryService.githubRemotes(paths: ["a", "a", "b"], resolve: probe.resolve)
        #expect(Set(remotes.map { $0.1.name }) == ["a", "b"])
    }
}

@MainActor
private final class ArtifactLoadProbe {
    var calls = 0
    var active = 0
    var peak = 0
    var pauses = true
    func messages(_ session: HermesSession, offset: Int) async throws -> [String: Any] {
        calls += 1
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        if pauses { try await Task.sleep(for: .seconds(60)) }
        return ["data": [["role": "assistant", "content": "MEDIA: /tmp/\(session.id).png"]]]
    }
}

extension PageLoadCancellationTests {
    @MainActor @Test func artifactLoadsAreBoundedAndCancelWithoutStartingQueuedSessions() async throws {
        let probe = ArtifactLoadProbe()
        let sessions = (0..<50).map {
            HermesSession(
                id: String($0), title: "Session", preview: "", startedAt: nil, messageCount: 1, source: "test",
                isHidden: false)
        }
        let load = Task { await ArtifactIndexLoader.load(sessions: sessions, messages: probe.messages) }
        for _ in 0..<2_000 {
            if probe.calls >= 4 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        load.cancel()
        let cancelled = await load.value
        #expect(cancelled.isEmpty)
        #expect(probe.calls == 4)
        #expect(probe.active == 0)
        #expect(probe.peak <= 4)

        probe.pauses = false
        let results = await ArtifactIndexLoader.load(sessions: Array(sessions.prefix(6)), messages: probe.messages)
        #expect(results.count == 6)
        #expect(results.allSatisfy { $0.error == nil && $0.records.count == 1 })
        #expect(probe.peak <= 4)
    }
}
