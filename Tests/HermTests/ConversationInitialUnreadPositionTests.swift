import AppKit
import Testing

@testable import Herm

@MainActor
struct ConversationInitialUnreadPositionTests {
    @Test(arguments: [false, true])
    func firstReadySnapshotMountsUnreadInsteadOfTail(delayed: Bool) {
        let model = DockModel(initialSessionID: "initial-unread")
        defer { model.delegationMonitoringTask?.cancel() }
        model.messages = (0..<100).map { ChatMessage(role: .hermes, text: "Reply \($0)") }
        let target = model.messages[20].id
        model.sessionTranscriptLoadState = delayed ? .loading : .ready
        model.unreadDividerMessageID = delayed ? nil : target
        let coordinator = ConversationTranscriptCoordinator()
        let source = ConversationTranscriptSource(
            model: model, bots: BotModeModel(), actions: ConversationMessageActionState(),
            voice: VoiceOutput(), coordinator: coordinator)
        defer { source.suspend() }
        if delayed {
            model.unreadDividerMessageID = target
            model.sessionTranscriptLoadState = .ready
            source.refresh()
        }
        #expect(source.snapshot.unreadDividerMessageID == target)
        #expect(source.snapshot.range == ConversationMessageWindow.jumpWindow(aroundIndex: 20, totalCount: 100))
        #expect(source.snapshot.rows.contains { $0.message.id == target })
        #expect(!coordinator.presentation.isAtBottom)
        let generation = coordinator.generation
        source.refresh()
        #expect(coordinator.generation == generation)
    }
}
