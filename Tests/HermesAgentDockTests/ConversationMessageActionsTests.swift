import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct ConversationMessageActionsTests {
    @Test func readableTextRemovesMarkdownAffordancesButKeepsContent() {
        let text = ConversationMessageActionState.readableText("# Answer\n\n**Use** [this](https://example.com) and `code`.")

        #expect(text == "Answer\n\nUse this and code.")
    }

    @Test func pendingActionsAreScopedAndDuplicateRunsAreIgnored() async {
        let state = ConversationMessageActionState()
        let firstID = UUID()
        let secondID = UUID()
        var firstRuns = 0
        var secondRuns = 0

        state.run(firstID) {
            firstRuns += 1
            try? await Task.sleep(for: .milliseconds(20))
        }
        state.run(firstID) { firstRuns += 1 }
        state.run(secondID) { secondRuns += 1 }

        #expect(state.isPending(firstID))
        #expect(state.isPending(secondID))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(firstRuns == 1)
        #expect(secondRuns == 1)
        #expect(!state.isPending(firstID))
        #expect(!state.isPending(secondID))
    }
}
