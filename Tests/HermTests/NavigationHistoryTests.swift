import Testing

@testable import Herm

struct NavigationHistoryTests {
    private func page(_ tab: ControlTab) -> NavigationDestination {
        NavigationDestination(surface: .global, tab: tab, sessionID: nil)
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
