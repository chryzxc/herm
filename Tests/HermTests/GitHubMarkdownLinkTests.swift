import Foundation
import Testing

@testable import Herm

@Suite @MainActor
struct GitHubMarkdownLinkTests {
    @Test func routesEnabledOverviewLinks() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        for (path, kind) in [("pull", GitHubItemKind.pullRequest), ("issues", .issue)] {
            let reference = GitHubMarkdownLink.reference(
                for: URL(string: "https://github.com/owner/repo/\(path)/42")!, defaults: defaults)
            #expect(reference?.kind == kind)
            #expect(reference?.number == 42)
            #expect(reference?.repository.id == "owner/repo")
        }
        defaults.set(false, forKey: SidebarVisibilityKey.pullRequests)
        #expect(
            GitHubMarkdownLink.reference(for: URL(string: "https://github.com/owner/repo/pull/42")!, defaults: defaults)
                == nil)
        #expect(
            GitHubMarkdownLink.reference(
                for: URL(string: "https://github.com/owner/repo/issues/42")!, defaults: defaults) != nil)
        defaults.set(false, forKey: SidebarVisibilityKey.issues)
        #expect(
            GitHubMarkdownLink.reference(
                for: URL(string: "https://github.com/owner/repo/issues/42")!, defaults: defaults) == nil)
    }

    @Test func preservesUnsupportedDestinationsInBrowser() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        for value in [
            "https://github.com/owner/repo/pull/42/files",
            "https://github.com/owner/repo/issues/42#issuecomment-123",
            "https://github.com/owner/repo/pull/42?tab=files",
            "https://github.com.evil.test/owner/repo/pull/42",
            "http://github.com/owner/repo/pull/42",
            "https://github.com/owner/repo/issues/0",
            "https://github.com/owner/repo/issues/new",
        ] {
            #expect(GitHubMarkdownLink.reference(for: URL(string: value)!, defaults: defaults) == nil)
        }
    }
}
