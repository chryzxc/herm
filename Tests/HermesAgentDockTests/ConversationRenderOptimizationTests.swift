import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct ConversationRenderOptimizationTests {
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
}
