import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

private actor RetryPullRequestTransport: GitHubIssueTransport {
    private var attempts = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        attempts += 1
        if attempts == 1 { throw GitHubCodeHostError.unavailable }
        let url = request.url!
        let row: [String: Any] = [
            "number": 42, "title": "Pull request", "state": "open",
            "head": ["ref": "feature", "sha": "head"], "base": ["ref": "main", "sha": "base"],
            "user": ["login": "ada"],
        ]
        // Detail sections (files, comments, commits, events) are lists; only the pull request itself is a row.
        let body: Any = url.path.hasSuffix("/42") ? row : [Any]()
        return (
            try JSONSerialization.data(withJSONObject: body),
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Suite @MainActor
struct SessionPullRequestPreviewTests {
    @Test func hostedRetryShowsResolvedDetails() async throws {
        let app = NSApplication.shared
        let accessibility = app.value(forKey: "accessibilityEnhancedUserInterface")
        app.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { app.setValue(accessibility, forKey: "accessibilityEnhancedUserInterface") }
        let center = PullRequestCenterModel(api: PullRequestCenterAPI(transport: RetryPullRequestTransport()))
        let repository = GitHubRepositoryReference(
            owner: "owner", name: "repo", webURL: URL(string: "https://github.com/owner/repo")!)
        let reference = GitHubItemReference(repository: repository, number: 42, kind: .pullRequest)
        let host = NSHostingView(
            rootView: SessionPullRequestPreview(reference: reference, onOpenChat: { _ in }, center: center))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func elements(_ element: AnyObject) -> [AnyObject] {
            [element] + (element.accessibilityChildren?() ?? []).flatMap { elements($0 as AnyObject) }
        }
        for _ in 0..<50 {
            host.layoutSubtreeIfNeeded()
            if elements(host).contains(where: { ($0.accessibilityLabel?() ?? "").contains("Retry") }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let retry = try #require(
            elements(host).first {
                $0.accessibilityRole?() == .button
                    && (($0.accessibilityLabel?() ?? "") + ($0.accessibilityTitle?() ?? "")).contains("Retry")
            })
        #expect(retry.accessibilityPerformPress?() == true)
        // Wait for the detail load the retry starts, so its outcome is what the test checks.
        for _ in 0..<250 {
            host.layoutSubtreeIfNeeded()
            if let selected = center.selected, center.filesByID[selected.id] != nil, !center.isLoadingDetail { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(center.selected?.number == 42)
        #expect(center.errorMessage == nil)
        host.layoutSubtreeIfNeeded()
        #expect(!elements(host).contains { ($0.accessibilityLabel?() ?? "").contains("Pull request unavailable") })
    }
    @Test func successfulRetryClearsThePreviousResolveError() async {
        let transport = RetryPullRequestTransport()
        let center = PullRequestCenterModel(api: PullRequestCenterAPI(transport: transport))
        let repository = GitHubRepositoryReference(
            owner: "owner", name: "repo", webURL: URL(string: "https://github.com/owner/repo")!)
        let reference = GitHubItemReference(repository: repository, number: 42, kind: .pullRequest)
        #expect(!(await center.open(reference)))
        #expect(center.errorMessage != nil)
        #expect(await center.open(reference))
        #expect(center.selected?.number == 42)
        #expect(center.errorMessage == nil)
    }
}
