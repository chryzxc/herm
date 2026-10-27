import Testing

@testable import Herm

@MainActor
struct SessionMessageTabsTests {
    @Test func openingSelectsAndDeduplicatesMessages() {
        let tabs = SessionMessageTabs()
        let first = ChatMessage(role: .hermes, text: "First message")
        let second = ChatMessage(role: .user, text: "Second message")
        tabs.open(first, in: "workspace")
        tabs.open(second, in: "workspace")
        tabs.open(first, in: "workspace")
        #expect(tabs.tabs["workspace"]?.map(\.id) == [first.id, second.id])
        #expect(tabs.selection["workspace"] == first.id)
        #expect(tabs.openRequest == "workspace")
    }

    @Test func messageTabTitlesKeepTheWholeFirstLine() {
        let title = "PR #5564 is mergeable and targets the correct release branch"
        let message = ChatMessage(role: .hermes, text: title + "\nFurther details")
        #expect(SessionPreviewContent.message(message).title == title)
        #expect(SessionPreviewContent.message(ChatMessage(role: .user, text: "")).title == "Message")
    }

    @Test func workspacesKeepIndependentMessagesAndSelections() {
        let tabs = SessionMessageTabs()
        let message = ChatMessage(role: .hermes, text: "Reference")
        for workspace in ["backend-a:profile-a:session", "backend-a:profile-b:session", "backend-b:profile-a:session"] {
            tabs.open(message, in: workspace)
        }
        tabs.close(message.id, in: "backend-a:profile-a:session")
        #expect(tabs.tabs["backend-a:profile-a:session"] == nil)
        #expect(tabs.selection["backend-a:profile-a:session"] == nil)
        #expect(tabs.tabs["backend-a:profile-b:session"]?.count == 1)
        #expect(tabs.selection["backend-b:profile-a:session"] == message.id)
    }

    @Test func closingSelectedTabFallsBackAndClosingBackgroundTabKeepsSelection() {
        let tabs = SessionMessageTabs()
        let first = ChatMessage(role: .user, text: "One")
        let second = ChatMessage(role: .hermes, text: "Two")
        tabs.open(first, in: "workspace")
        tabs.open(second, in: "workspace")
        tabs.close(first.id, in: "workspace")
        #expect(tabs.selection["workspace"] == second.id)
        tabs.open(first, in: "workspace")
        tabs.close(first.id, in: "workspace")
        #expect(tabs.selection["workspace"] == second.id)
        tabs.select(nil, in: "workspace")
        #expect(tabs.selection["workspace"] == nil)
        #expect(tabs.tabs["workspace"]?.count == 1)
        tabs.close(second.id, in: "workspace")
        #expect(tabs.tabs["workspace"] == nil)
    }
    @Test func typedPreviewsDeduplicateRefreshAndKeepKindsSeparate() throws {
        let tabs = SessionMessageTabs()
        var call = ActiveToolCall(
            id: "same-id", name: "terminal", input: "pwd", context: "Project", startedAt: .now, isComplete: false)
        let message = ChatMessage(role: .hermes, text: "Response")
        tabs.open(.tool(call), in: "workspace")
        let toolID = try #require(tabs.selection["workspace"])
        call.isComplete = true
        call.result = "/project"
        tabs.open(.tool(call), in: "workspace")
        #expect(tabs.selection["workspace"] == toolID)
        #expect(tabs.tabs["workspace"]?.count == 1)
        if case .tool(let refreshed) = tabs.tabs["workspace"]?.first?.content {
            #expect(refreshed.result == "/project")
        } else {
            Issue.record("Expected refreshed tool preview")
        }
        tabs.open(.activity(message, [call]), in: "workspace")
        tabs.open(message, in: "workspace")
        #expect(tabs.tabs["workspace"]?.count == 3)
        tabs.close(message.id, in: "workspace")
        #expect(tabs.tabs["workspace"]?.count == 2)
        tabs.close(toolID, in: "workspace")
        #expect(tabs.tabs["workspace"]?.count == 1)
    }

}
