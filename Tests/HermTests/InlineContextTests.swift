import AppKit
import Testing

@testable import Herm

@MainActor
private final class InlineContextRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
}

@MainActor
struct InlineContextTests {
    @Test func editorRoundTripAndPromptExpansionKeepUnicode() throws {
        var context = ChatContext(id: "excerpt", title: "Terminal excerpt", body: "selected output")
        context.inlineToken = "\u{E000}"
        let source = "日本語 \u{E000} 🐈"
        let rendered = InlineContextCodec.render(source, contexts: [context])
        #expect(rendered.length == (source as NSString).length)
        #expect(InlineContextCodec.serialize(rendered) == source)
        #expect(ChatContext.prompt(source, contexts: [context]) == "日本語 selected output 🐈")
        #expect(try JSONDecoder().decode(ChatContext.self, from: JSONEncoder().encode(context)) == context)
    }

    @Test func deletingAttachmentDeletesItsContextWithoutTouchingText() {
        let model = DockModel(rpcClient: InlineContextRPC())
        defer { model.shutdown() }
        var context = ChatContext(id: "excerpt", title: "Excerpt", body: "context")
        context.inlineToken = "\u{E000}"
        model.attachedContexts = [context]
        model.draft = "keep this"
        model.removeDeletedInlineContexts()
        #expect(model.attachedContexts.isEmpty)
        #expect(model.draft == "keep this")
    }

    @Test func restoredTokensDoNotCollideWithExistingDraft() {
        let model = DockModel(rpcClient: InlineContextRPC())
        defer { model.shutdown() }
        var old = ChatContext(id: "old", title: "Old", body: "old context")
        old.inlineToken = "\u{E000}"
        var restored = ChatContext(id: "restored", title: "Restored", body: "new context")
        restored.inlineToken = "\u{E000}"
        model.draft = "Existing \u{E000}"
        model.attachedContexts = [old]
        model.restoreCapturedText("Saved \u{E000}", contexts: [restored])
        #expect(model.attachedContexts.count == 2)
        #expect(model.attachedContexts[0].inlineToken != model.attachedContexts[1].inlineToken)
        let prompt = ChatContext.prompt(model.draft, contexts: model.attachedContexts)
        #expect(prompt.contains("Existing old context"))
        #expect(prompt.contains("Saved new context"))
    }
}
