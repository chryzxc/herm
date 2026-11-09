import Foundation

/// A place the window can show; enough to reopen it from the toolbar's back and forward buttons.
struct NavigationDestination: Equatable {
    var surface: DockPopover.FullscreenSurface
    /// Set only for `.global`.
    var tab: ControlTab?
    /// Set only for `.conversation`.
    var sessionID: String?
    /// Set only for the GitHub surfaces (`.pullRequests`, `.issues`).
    var gitHubSection: GitHubWorkspaceSection? = nil
    /// The pull request, issue, or repository selected inside `gitHubSection`.
    var gitHubItemID: String? = nil
}

/// Back/forward stack of visited destinations, like a browser's.
struct NavigationHistory {
    static let limit = 50
    private var entries: [NavigationDestination] = []
    private var index = -1

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < entries.count }

    /// Records a settled destination. Revisiting the current one is a no-op, so replaying
    /// back/forward does not rewrite history; a new place drops the forward entries.
    mutating func record(_ destination: NavigationDestination) {
        guard entries.indices.contains(index) else {
            entries = [destination]
            index = 0
            return
        }
        guard entries[index] != destination else { return }
        // A page that only now auto-selected its first item is the same visit, not a new one.
        var unselected = destination
        unselected.gitHubItemID = nil
        if entries[index].gitHubItemID == nil, entries[index] == unselected {
            entries[index] = destination
            return
        }
        entries.removeSubrange((index + 1)...)
        entries.append(destination)
        if entries.count > Self.limit { entries.removeFirst() }
        index = entries.count - 1
    }

    mutating func back() -> NavigationDestination? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }

    mutating func forward() -> NavigationDestination? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }
}
