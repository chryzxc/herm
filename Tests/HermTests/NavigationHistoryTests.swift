import Testing

@testable import Herm

struct NavigationHistoryTests {
    private func page(_ tab: ControlTab) -> NavigationDestination {
        NavigationDestination(surface: .global, tab: tab, sessionID: nil)
    }

    private func gitHub(_ section: GitHubWorkspaceSection, _ item: String?) -> NavigationDestination {
        NavigationDestination(
            surface: section == .issues ? .issues : .pullRequests, tab: nil, sessionID: nil, gitHubSection: section,
            gitHubItemID: item)
    }

    @Test func gitHubSectionsAndSelectionsAreSeparateVisits() {
        var history = NavigationHistory()
        history.record(gitHub(.pullRequests, nil))
        history.record(gitHub(.pullRequests, "pr-1"))  // auto-selection folds into the same visit
        history.record(gitHub(.pullRequests, "pr-2"))
        history.record(gitHub(.repositories, nil))
        #expect(history.back() == gitHub(.pullRequests, "pr-2"))
        #expect(history.back() == gitHub(.pullRequests, "pr-1"))
        #expect(history.back() == nil)
    }

    @Test func backAndForwardWalkTheVisitedPages() {
        var history = NavigationHistory()
        history.record(page(.kanban))
        history.record(page(.calendar))
        history.record(page(.quota))
        #expect(history.back() == page(.calendar))
        #expect(history.back() == page(.kanban))
        #expect(history.back() == nil)
        #expect(history.forward() == page(.calendar))
        #expect(history.canGoForward)
    }

    @Test func replayingTheCurrentPageKeepsForwardEntriesButANewPageDropsThem() {
        var history = NavigationHistory()
        history.record(page(.kanban))
        history.record(page(.calendar))
        _ = history.back()
        history.record(page(.kanban))
        #expect(history.canGoForward)
        history.record(page(.quota))
        #expect(!history.canGoForward)
        #expect(history.back() == page(.kanban))
    }
}
