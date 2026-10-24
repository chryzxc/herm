import Testing

@testable import Herm

@MainActor
struct BrowserPageContextTests {
    @Test func snapshotIncludesTabAndSelectionWithoutInventingAgentAccess() {
        let context = BrowserPageContext.make(
            url: "https://example.com/page#section", title: "Example", targetID: "tab-2", selection: "Selected words")
        #expect(context.body.contains("Shared browser tab ID: tab-2"))
        #expect(context.body.contains("https://example.com/page#section"))
        #expect(context.body.contains("Selected words"))
        #expect(context.body.contains("untrusted"))
        let fallback = BrowserPageContext.make(url: "https://example.com", title: "", targetID: nil, selection: "")
        #expect(!fallback.body.contains("Shared browser tab"))
        #expect(!fallback.body.contains("Selected text:"))
        #expect(fallback.title == "example.com")
    }

    @Test func attachingPreservesDraftAndRefreshesOneRemovableChipWithoutSending() throws {
        let model = DockModel(initialSessionID: "browser-context")
        let key = try #require(model.browserSessionKey)
        model.draft = "Explain this error"
        let count = model.messages.count
        let first = BrowserPageContext.make(
            url: "https://example.com", title: "Page", targetID: "tab", selection: "old")
        model.attachBrowserPage(first, owner: key)
        model.attachBrowserPage(
            BrowserPageContext.make(url: "https://example.com", title: "Page", targetID: "tab", selection: "new"),
            owner: key)
        #expect(model.attachedContexts.count == 1)
        #expect(model.attachedContexts[0].body.contains("new"))
        #expect(model.draft == "Explain this error")
        #expect(model.messages.count == count)
        #expect(!model.isSending)
        model.removeAttachedContext(first)
        #expect(model.attachedContexts.isEmpty)
    }

    @Test func staleSessionCannotAttachToAnotherConversation() {
        let model = DockModel(initialSessionID: "current")
        model.attachBrowserPage(
            BrowserPageContext.make(url: "https://example.com", title: "Page", targetID: nil, selection: ""),
            owner: .init(profileID: nil, sessionID: "previous"))
        #expect(model.attachedContexts.isEmpty)
    }
}
