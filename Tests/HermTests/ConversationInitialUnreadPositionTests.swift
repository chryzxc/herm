import AppKit
import Testing

@testable import Herm

@MainActor
struct ConversationInitialUnreadPositionTests {
    @Test(arguments: [false, true], [false, true])
    func firstReadySnapshotMountsUnreadInsteadOfTail(delayed: Bool, cached: Bool) {
        let model = DockModel(initialSessionID: "initial-unread")
        defer { model.delegationMonitoringTask?.cancel() }
        model.messages = (0..<100).map { ChatMessage(role: .hermes, text: "Reply \($0)") }
        let target = model.messages[20].id
        if delayed && cached {
            model.sessionTranscriptPreview = .init(
                messages: Array(model.messages.suffix(12)), rowIDs: [:], references: [:], pendingImages: [])
        }
        model.sessionTranscriptLoadState = delayed ? (cached ? .refreshing : .loading) : .ready
        model.unreadDividerMessageID = delayed ? nil : target
        let coordinator = ConversationTranscriptCoordinator()
        let source = ConversationTranscriptSource(
            model: model, bots: BotModeModel(), actions: ConversationMessageActionState(),
            voice: VoiceOutput(), coordinator: coordinator)
        defer { source.suspend() }
        if delayed {
            #expect(source.snapshot.rows.isEmpty)
            #expect(coordinator.mountedRange.isEmpty)
            model.unreadDividerMessageID = target
            model.sessionTranscriptPreview = nil
            model.sessionTranscriptLoadState = .ready
            source.refresh()
        }
        #expect(source.snapshot.unreadDividerMessageID == target)
        #expect(source.snapshot.range == ConversationMessageWindow.jumpWindow(aroundIndex: 20, totalCount: 100))
        #expect(source.snapshot.rows.contains { $0.message.id == target })
        #expect(!coordinator.presentation.isAtBottom)
        let generation = coordinator.generation
        model.unreadDividerMessageID = nil
        source.refresh()
        model.unreadDividerMessageID = model.messages[40].id
        source.refresh()
        #expect(source.snapshot.unreadDividerMessageID == model.messages[40].id)
        #expect(coordinator.generation == generation)
    }
}
