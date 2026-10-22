import AppKit
import Testing

@testable import Herm

@MainActor
struct ConversationTranscriptSourceTests {
    @Test func onlyRelevantChangesPublishAndOnlyMountedRowsGetDescriptors() async throws {
        let model = DockModel(initialSessionID: "source-test")
        model.messages = (0..<500).map { ChatMessage(role: .hermes, text: "Message \($0)") }
        let coordinator = ConversationTranscriptCoordinator()
        coordinator.reset(sessionID: model.sessionID, totalCount: 500, bubbleCount: 500)
        let source = ConversationTranscriptSource(
            model: model, bots: BotModeModel(),
            actions: ConversationMessageActionState(), voice: VoiceOutput(), coordinator: coordinator)
        #expect(source.snapshot.rows.count == 12)
        model.sessions = []
        model.isLoadingSessions = true
        model.runtimeConfigurationError = "Unrelated configuration refresh"
        try await Task.sleep(for: .milliseconds(20))
        #expect(source.publicationCount == 0)
        model.status = model.status
        try await Task.sleep(for: .milliseconds(20))
        #expect(source.publicationCount == 0)
        model.approvalText = "Review a synthetic action"
        model.isRespondingToApproval = true
        try await Task.sleep(for: .milliseconds(20))
        #expect(source.publicationCount == 1)
        #expect(source.snapshot.context.approvalText == model.approvalText)
        #expect(source.snapshot.context.respondingToApproval)
        model.streamingText.appendPresentation("A chunk stays in the streaming leaf")
        try await Task.sleep(for: .milliseconds(20))
        #expect(source.publicationCount == 1)
        coordinator.jump(to: 250)
        try await Task.sleep(for: .milliseconds(20))
        #expect(source.snapshot.range == 238..<263)
        #expect(source.snapshot.rows.count == 25)
        #expect(source.snapshot.rows.first?.message.id == model.messages[238].id)
    }

    @Test func unmountedSourceCancelsWorkAndRefreshesCanonicalStateOnReturn() async throws {
        let model = DockModel(initialSessionID: "one")
        let source = ConversationTranscriptSource(model: model, bots: BotModeModel(),
            actions: ConversationMessageActionState(), voice: VoiceOutput(), coordinator: ConversationTranscriptCoordinator())
        source.suspend()
        model.approvalText = "Changed while unmounted"
        try await Task.sleep(for: .milliseconds(20))
        #expect(source.publicationCount == 0)
        source.resume()
        #expect(source.snapshot.context.approvalText == model.approvalText)
        #expect(source.publicationCount == 1)
    }

    @Test func rowDescriptorsNoticeMetadataChangesWithoutBodyRevisions() {
        let id = UUID()
        let first = ChatMessage(id: id, role: .hermes, text: "Stable body", timestamp: Date(timeIntervalSince1970: 0))
        let updated = ChatMessage(id: id, role: .hermes, text: first.text, timestamp: first.timestamp, tokenCount: 100)
        #expect(first.contentRevision == updated.contentRevision)
        #expect(ConversationTranscriptSnapshot.Row(index: 0, message: first) != .init(index: 0, message: updated))
    }

    @Test func retainedPromptsRejectSessionAndRequestReplacement() {
        let model = DockModel(initialSessionID: "one")
        model.approvalText = "Original approval"
        model.clarificationQuestion = "Original question"
        model.clarificationRequestID = "request-one"
        let original = ConversationPromptState(model: model)
        #expect(original.matchesApproval(in: model))
        #expect(original.matchesClarification(in: model))
        model.approvalText = "Replacement approval"
        model.clarificationRequestID = "request-two"
        #expect(!original.matchesApproval(in: model))
        #expect(!original.matchesClarification(in: model))
        model.sessionID = "two"
        #expect(!original.matchesPrompt(in: model))
    }

    @Test func retainedActionsResolveTheCurrentMessageAndRejectAnotherSession() {
        let model = DockModel(initialSessionID: "one")
        let id = UUID()
        model.messages = [ChatMessage(id: id, role: .hermes, text: "Old")]
        let source = ConversationTranscriptSource(
            model: model, bots: BotModeModel(),
            actions: ConversationMessageActionState(), voice: VoiceOutput(),
            coordinator: ConversationTranscriptCoordinator())
        let target = MessageNavigatorTarget(sessionID: "one", messageID: id)
        model.messages = [ChatMessage(id: id, role: .hermes, text: "Current")]
        source.perform(.reply, target: target)
        #expect(model.replyQuote?.snippet == "Current")
        model.replyQuote = nil
        model.sessionID = "two"
        source.perform(.reply, target: target)
        #expect(model.replyQuote == nil)
    }
}
