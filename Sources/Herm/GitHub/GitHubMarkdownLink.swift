import SwiftUI

/// Only item overview URLs can be represented faithfully by the native pages.
enum GitHubMarkdownLink {
    static func reference(for url: URL, defaults: UserDefaults = .standard) -> GitHubItemReference? {
        guard url.scheme == "https", url.host?.lowercased() == "github.com",
            url.user == nil, url.password == nil, url.port == nil,
            url.query == nil, url.fragment == nil
        else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 4, let number = Int(parts[3]), number > 0 else { return nil }
        let kind: GitHubItemKind
        let key: String
        switch parts[2] {
        case "pull":
            kind = .pullRequest
            key = SidebarVisibilityKey.pullRequests
        case "issues":
            kind = .issue
            key = SidebarVisibilityKey.issues
        default: return nil
        }
        guard defaults.object(forKey: key) == nil || defaults.bool(forKey: key) else { return nil }
        let repository = GitHubRepositoryReference(
            owner: parts[0], name: parts[1],
            webURL: URL(string: "https://github.com")!.appendingPathComponent(parts[0]).appendingPathComponent(parts[1])
        )
        return GitHubItemReference(repository: repository, number: number, kind: kind)
    }
}

/// Bridge native text sections to the SwiftUI link action supplied by their host.
@MainActor
protocol MarkdownLinkHost: AnyObject {
    var markdownOpenURL: OpenURLAction { get }
}

@MainActor
func openMarkdownLink(_ url: URL, from view: NSView) {
    var ancestor: NSView? = view
    while let current = ancestor {
        if let host = current as? MarkdownLinkHost {
            host.markdownOpenURL(url)
            return
        }
        ancestor = current.superview
    }
    InAppBrowser.open(url)
}

private struct MarkdownOpenURLKey: EnvironmentKey {
    static let defaultValue: OpenURLAction? = nil
}

extension EnvironmentValues {
    @MainActor var markdownOpenURL: OpenURLAction {
        get {
            self[MarkdownOpenURLKey.self]
                ?? OpenURLAction {
                    InAppBrowser.open($0)
                    return .handled
                }
        }
        set { self[MarkdownOpenURLKey.self] = newValue }
    }
}
