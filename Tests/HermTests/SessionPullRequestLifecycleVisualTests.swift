import AppKit
import SwiftUI
import Testing

@testable import Herm

private actor DelayedPRTransport: GitHubIssueTransport {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        started = true
        await withCheckedContinuation { continuation = $0 }
        let row: [String: Any] = [
            "number": 42, "title": "Late result", "state": "open",
            "head": ["ref": "feature"], "base": ["ref": "main"], "user": ["login": "ada"],
        ]
        return (
            try JSONSerialization.data(withJSONObject: row),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite @MainActor
struct SessionPullRequestLifecycleVisualTests {
    @Test func switchingHostedPreviewDiscardsLateResolve() async throws {
        _ = NSApplication.shared
        let transport = DelayedPRTransport()
        let center = PullRequestCenterModel(api: PullRequestCenterAPI(transport: transport))
        let repository = GitHubRepositoryReference(
            owner: "owner", name: "repo", webURL: URL(string: "https://github.com/owner/repo")!)
        let reference = GitHubItemReference(repository: repository, number: 42, kind: .pullRequest)
        let host = NSHostingView(
            rootView: AnyView(
                SessionPullRequestPreview(
                    reference: reference, onOpenChat: { _ in }, center: center)))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<100 {
            if await transport.started { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await transport.started)
        host.rootView = AnyView(Text("Different session"))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        await transport.release()
        try await Task.sleep(for: .milliseconds(150))
        #expect(center.selected == nil)
        #expect(center.errorMessage == nil)
    }

    @Test func inlineItemDisplaysCachedAndUnavailableMetadata() async throws {
        let app = NSApplication.shared
        let accessibility = app.value(forKey: "accessibilityEnhancedUserInterface")
        app.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { app.setValue(accessibility, forKey: "accessibilityEnhancedUserInterface") }
        let repository = GitHubRepositoryReference(
            owner: "owner", name: "repo", webURL: URL(string: "https://github.com/owner/repo")!)
        let reference = GitHubItemReference(repository: repository, number: 42, kind: .pullRequest)
        let record = PullRequestRecord(
            repository: repository, localPath: "", number: 42, title: "Fetched title",
            body: "", author: "ada", authorAvatarURL: nil, headBranch: "feature", baseBranch: "main",
            updatedAt: nil, isDraft: false, webURL: nil, requestedReviewers: [], comments: 0,
            additions: 4, deletions: 2, changedFiles: 1, checks: [], reviews: [])
        let host = NSHostingView(
            rootView: AnyView(
                SessionRailPullRequestItem(
                    reference: reference, record: record, failure: nil, onViewPullRequest: { _ in true }
                ).dockThemedRoot()))
        host.frame = NSRect(x: 0, y: 0, width: 330, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func labels(_ element: AnyObject) -> String {
            (element.accessibilityLabel?() ?? "") + " " + (element.accessibilityTitle?() ?? "") + " "
                + String(describing: element.accessibilityValue?() ?? "") + " "
                + (element.accessibilityChildren?() ?? []).map { labels($0 as AnyObject) }.joined(separator: " ")
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(labels(host).contains("feature → main"))
        #expect(labels(host).contains("By ada"))
        host.rootView = AnyView(
            SessionRailPullRequestItem(
                reference: reference, record: record, failure: "Network error", onViewPullRequest: { _ in true }
            ).dockThemedRoot())
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(labels(host).contains("Last fetched details"))
        #expect(labels(host).contains("By ada"))
        host.rootView = AnyView(
            SessionRailPullRequestItem(
                reference: reference, record: nil, failure: "Network error", onViewPullRequest: { _ in true }
            ).dockThemedRoot())
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(labels(host).contains("Details unavailable"))
    }
}
