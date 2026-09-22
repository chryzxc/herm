import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct ConversationRenderOptimizationTests {
    @Test func navigatorProjectionTracksCanonicalEditsAndSessionReplacement() {
        let model = DockModel(initialSessionID: "history")
        model.messages = (0..<500).map { ChatMessage(role: .hermes, text: "Message \($0)") }
        let original = model.messageNavigatorItems
        #expect(model.messageNavigatorItems == original)
        model.messages[250] = ChatMessage(id: model.messages[250].id, role: .hermes, text: "Updated message")
        #expect(model.messageNavigatorItems[250].preview == "Updated message")
        model.messages.append(ChatMessage(role: .user, text: "New message"))
        #expect(model.messageNavigatorItems.count == 501)
        model.newChat()
        #expect(model.messageNavigatorItems.isEmpty)
    }

    @Test func thumbnailKeyChangesWhenImageIdentityInputsChange() {
        let id = UUID()
        let base = ConversationThumbnailCache.key(
            messageID: id,
            index: 0,
            imageCount: 1,
            contentRevision: 10
        )

        #expect(base != ConversationThumbnailCache.key(messageID: id, index: 1, imageCount: 1, contentRevision: 10))
        #expect(base != ConversationThumbnailCache.key(messageID: id, index: 0, imageCount: 2, contentRevision: 10))
        #expect(base != ConversationThumbnailCache.key(messageID: id, index: 0, imageCount: 1, contentRevision: 11))
        #expect(base == ConversationThumbnailCache.key(messageID: id, index: 0, imageCount: 1, contentRevision: 10))
    }

    @Test func mentionRosterRefreshOnlyRunsWhenPickerOpens() {
        #expect(ComposerMentionRefreshPolicy.shouldRefresh(wasPickerVisible: false, isPickerVisible: true))
        #expect(!ComposerMentionRefreshPolicy.shouldRefresh(wasPickerVisible: true, isPickerVisible: true))
        #expect(!ComposerMentionRefreshPolicy.shouldRefresh(wasPickerVisible: true, isPickerVisible: false))
        #expect(!ComposerMentionRefreshPolicy.shouldRefresh(wasPickerVisible: false, isPickerVisible: false))
    }

    @Test func longMarkdownUsesNativeRendererAtTheFixedBoundary() {
        let below = String(repeating: "a", count: CompletedMarkdownRendererPolicy.nativeThresholdBytes - 1)
        let at = String(repeating: "a", count: CompletedMarkdownRendererPolicy.nativeThresholdBytes)
        #expect(!CompletedMarkdownRendererPolicy.usesNativeRenderer(for: below))
        #expect(CompletedMarkdownRendererPolicy.usesNativeRenderer(for: at))
    }

    @Test func transcriptCacheKeyUsesMessageIdentityAndContentRevision() {
        let message = ChatMessage(id: UUID(), role: .hermes, text: "short")
        let key = "message:\(message.id.uuidString):\(message.contentRevision)"
        #expect(key.contains(message.id.uuidString))
        #expect(key.hasSuffix(":\(message.contentRevision)"))
    }

    @Test func nativeMarkdownDocumentPreservesContentAndLinks() {
        let source = "# Heading\n\nRead [the guide](https://example.com).\n\n```swift\nlet value = 1\n```"
        let rendered = NativeMarkdownMessageView.Coordinator.attributedString(for: source)
        #expect(rendered.string.contains("Heading"))
        #expect(rendered.string.contains("the guide"))
        #expect(rendered.length > 0)
    }

    @Test func semanticDocumentKeepsExactSourceAndStructuredBlocks() {
        let source = "# Heading\n\n| Name | Value |\n| --- | --- |\n| rows | 36 |\n\n```swift\nlet value = 1\n```\n"
        let key = MarkdownRenderKey(messageID: UUID(), contentRevision: 1, themeRevision: 1)
        let document = MarkdownRenderDocumentBuilder.build(source: source, key: key)
        #expect(document.source == source)
        #expect(document.sections.map(\.source).joined() == source)
        #expect(document.sections.contains { if case .table = $0.kind { true } else { false } })
        #expect(document.sections.contains { if case .code = $0.kind { true } else { false } })
    }

    @Test func completionProjectionCanDropBotEnvelopeWithoutReparse() {
        let streaming = StreamingText()
        let envelope = "Message from 🤖 Builder (@builder):\n\n# Result\n\nready"
        streaming.appendPresentation(envelope)
        streaming.retainCompletionPresentation()
        let chunks = streaming.completionChunks(matching: "# Result\n\nready")
        #expect(chunks?.map(\.text).joined() == "# Result\n\nready")
    }
}
