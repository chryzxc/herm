import Foundation
import Testing

@testable import Herm

@Suite @MainActor
struct GitHubMarkdownLinkTests {
    @Test func routesOverviewLinks() {
        for (path, kind) in [("pull", GitHubItemKind.pullRequest), ("issues", .issue)] {
            let reference = GitHubMarkdownLink.reference(for: URL(string: "https://github.com/owner/repo/\(path)/42")!)
            #expect(reference?.kind == kind)
            #expect(reference?.number == 42)
            #expect(reference?.repository.id == "owner/repo")
        }
    }

    @Test func preservesUnsupportedDestinationsInBrowser() {
        for value in [
            "https://github.com/owner/repo/pull/42/files",
            "https://github.com/owner/repo/issues/42#issuecomment-123",
            "https://github.com/owner/repo/pull/42?tab=files",
            "https://github.com.evil.test/owner/repo/pull/42",
            "http://github.com/owner/repo/pull/42",
            "https://github.com/owner/repo/issues/0",
            "https://github.com/owner/repo/issues/new",
        ] {
            #expect(GitHubMarkdownLink.reference(for: URL(string: value)!) == nil)
        }
    }
}
