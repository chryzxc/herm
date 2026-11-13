import AppKit
import Testing

@testable import Herm

@MainActor
struct ConversationTranscriptSourceTests {
    @Test func deliveryStatusProjectionUpdatesAndIsScopedToOwner() {
        let model = DockModel(initialSessionID: "owner")
        defer { model.delegationMonitoringTask?.cancel() }
        let message = ChatMessage(role: .user, text: "hello")
        model.messages = [message]
        let snapshot = SessionComposerDraft(
            text: "hello", images: [], pdfURL: nil, contexts: [], replyQuote: nil,
            attachmentError: nil, pdfError: nil)
        model.pendingSessionSends.append(
            SessionPendingSend(
                id: UUID(), owner: model.composerDraftKey, snapshot: snapshot, message: message,
                baselineRowID: 0, phase: .submitting))
        let source = ConversationTranscriptSource(
            model: model, bots: BotModeModel(), actions: ConversationMessageActionState(),
            voice: VoiceOutput(), coordinator: ConversationTranscriptCoordinator())
        #expect(source.snapshot.context.deliveryStates[message.id] == .sending)
        model.pendingSessionSends[0].phase = .uncertain
        source.refresh()
        #expect(source.snapshot.context.deliveryStates[message.id] == .unconfirmed)
        model.sessionID = "other"
        model.sessionStorageID = "other"
        source.refresh()
        #expect(source.snapshot.context.deliveryStates.isEmpty)
    }

    @Test func navigatorReusesLongHistoryAndUpdatesOffscreenSearchContent() {
        let model = DockModel(initialSessionID: "navigator-owner")
        model.messages = (0..<5_000).map { ChatMessage(role: .hermes, text: "Message \($0)") }
        let source = ConversationTranscriptSource(
            model: model, bots: BotModeModel(),
            actions: ConversationMessageActionState(), voice: VoiceOutput(),
            coordinator: ConversationTranscriptCoordinator())
        let original = source.snapshot.navigator
        for _ in 0..<100 {
            source.refresh()
            #expect(source.snapshot.navigator === original)
        }
        #expect(source.publicationCount == 0)
        #expect(source.snapshot.rows.count == 12)
        let metadata = model.messages[1]
        model.messages[1] = ChatMessage(
            id: metadata.id, role: metadata.role, text: metadata.text,
            timestamp: metadata.timestamp, tokenCount: 50)
        source.refresh()
        #expect(source.snapshot.navigator === original)
        #expect(source.publicationCount == 0)
        model.streamingText.appendPresentation("Only the live leaf observes this")
        model.approvalText = "Current approval"
        source.refresh()
        #expect(source.snapshot.navigator === original)
        #expect(source.snapshot.context.approvalText == "Current approval")

        let old = model.messages[0]
        model.messages[0] = ChatMessage(
            id: old.id, role: old.role, text: "Edited offscreen search needle", timestamp: old.timestamp)
        source.refresh()
        #expect(source.snapshot.navigator !== original)
        #expect(original.items[0].searchText == "Message 0")
        #expect(
            MessageNavigator.search(items: source.snapshot.navigatorItems, query: "needle").map(\.messageID) == [old.id]
        )
        #expect(!source.snapshot.rows.contains { $0.message.id == old.id })
        let edited = source.snapshot.navigator
        model.sessionID = "another-owner"
        source.refresh()
        #expect(source.snapshot.navigator !== edited)
        #expect(source.snapshot.navigatorItems.allSatisfy { $0.sessionID == "another-owner" })
    }

    @Test func navigatorInvalidatesForStoredPromptsAndHistoryPrepend() {
        let model = DockModel(initialSessionID: "navigator-history")
        model.sessionStorageID = "stored-history"
        model.transcriptHistoryCursor = TranscriptHistoryCursor(storageSessionID: "stored-history", profileID: nil)
        model.messages = [ChatMessage(role: .hermes, text: "Loaded reply")]
        let source = ConversationTranscriptSource(
            model: model, bots: BotModeModel(),
            actions: ConversationMessageActionState(), voice: VoiceOutput(),
            coordinator: ConversationTranscriptCoordinator())
        let original = source.snapshot.navigator
        model.transcriptTimeline = [.init(rowID: 7, preview: "Older prompt", timestamp: nil)]
        source.refresh()
        #expect(source.snapshot.navigator !== original)
        #expect(source.snapshot.navigatorItems.first?.storedRowID == 7)
        let stored = source.snapshot.navigator
        let cursor = TranscriptHistoryCursor(storageSessionID: "stored-history", profileID: nil, seenRowIDs: [7])
        model.prependEarlierTranscript([["role": "user", "text": "Older prompt", "row_id": 7]], cursor: cursor)
        source.refresh()
        #expect(source.snapshot.navigator !== stored)
        #expect(source.snapshot.navigatorItems.count == 2)
        #expect(source.snapshot.navigatorItems.allSatisfy { $0.storedRowID == nil })
        #expect(source.snapshot.navigatorItems.first?.messageID == model.messages.first?.id)
        #expect(source.snapshot.navigatorItems.map(\.ordinal) == [1, 2])
    }

    @Test func backgroundBotStepsDoNotPublishIntoTheSelectedSession() async throws {
        let model = DockModel(initialSessionID: "runtime-open")
        model.sessionStorageID = "stored-open"
        let record = BotActivityRecord(
            id: "bot-dispatch:open-tool", originSessionID: "stored-open",
            botID: "bot", botName: "Bot", summary: "Selected-session work", state: .working)
        model.botActivityBySessionID = ["stored-open": [record]]
        model.botLiveSteps = [record.id: "Selected step", "background-record": "Other step"]
        let source = ConversationTranscriptSource(
            model: model, bots: BotModeModel(),
            actions: ConversationMessageActionState(), voice: VoiceOutput(),
            coordinator: ConversationTranscriptCoordinator())
        #expect(source.snapshot.context.botSteps == [record.id: "Selected step"])
        for batch in 0..<5 {
            for index in 0..<8 {
                let id = "background-\(index)"
                let recordID = "bot-dispatch:\(id)"
                model.botActivityBySessionID[id] = [
                    BotActivityRecord(
                        id: recordID, originSessionID: id,
                        botID: "bot", botName: "Bot", summary: "Background batch \(batch)", state: .working)
                ]
                model.botLiveSteps[recordID] = "Background step \(batch)"
            }
            model.botActivityRevision &+= 1
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(source.publicationCount == 0)
        model.botLiveSteps[record.id] = "Updated selected step"
        try await Task.sleep(for: .milliseconds(20))
        #expect(source.publicationCount == 1)
        #expect(source.snapshot.context.botSteps[record.id] == "Updated selected step")
        model.botActivityBySessionID["stored-open"]?[0].state = .completed
        try await Task.sleep(for: .milliseconds(20))
        #expect(source.snapshot.context.workingBots.isEmpty)
        #expect(source.snapshot.context.dispatches["open-tool"]?.state == .completed)
        model.sessionStorageID = "background-0"
        model.sessionID = "runtime-background"
        try await Task.sleep(for: .milliseconds(20))
        #expect(source.snapshot.context.botSteps == ["bot-dispatch:background-0": "Background step 4"])
        #expect(source.snapshot.context.workingBots.first?.originSessionID == "background-0")
    }

    @Test func unmountedStreamingActivityDoesNotRepublishHistoryAndIsCurrentOnReturn() async throws {
        let model = DockModel(initialSessionID: "open")
        model.messages = (0..<500).map { ChatMessage(role: .hermes, text: "Message \($0)") }
        model.streamingMessageID = model.messages.last?.id
        let coordinator = ConversationTranscriptCoordinator()
        coordinator.reset(sessionID: model.transcriptPresentationID, totalCount: 500, bubbleCount: 500)
        coordinator.jump(to: 250)
        let source = ConversationTranscriptSource(
            model: model, bots: BotModeModel(),
            actions: ConversationMessageActionState(), voice: VoiceOutput(), coordinator: coordinator)
        for batch in 0..<5 {
            model.streamingTurnActivity.append(
                ActiveToolCall(
                    id: "tool-\(batch)", name: "terminal",
                    input: "Synthetic tool", context: "", startedAt: .distantPast, isComplete: false))
            model.activityPresentationRevision &+= 1
            model.streamingText.appendPresentation("Incoming chunk \(batch).\n")
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(source.publicationCount == 0)
        #expect(source.snapshot.context.streamingActivity.isEmpty)
        coordinator.jumpToLatest()
        try await Task.sleep(for: .milliseconds(20))
        #expect(source.snapshot.rows.contains { $0.message.id == model.streamingMessageID })
        #expect(source.snapshot.context.streamingActivity == model.streamingTurnActivity)
        let before = source.publicationCount
        model.streamingTurnActivity[0].isComplete = true
        model.activityPresentationRevision &+= 1
        try await Task.sleep(for: .milliseconds(20))
        #expect(source.publicationCount == before + 1)
        #expect(source.snapshot.context.streamingActivity[0].isComplete)
    }

    @Test func onlyRelevantChangesPublishAndOnlyMountedRowsGetDescriptors() async throws {
        let model = DockModel(initialSessionID: "source-test")
        model.messages = (0..<500).map { ChatMessage(role: .hermes, text: "Message \($0)") }
        let coordinator = ConversationTranscriptCoordinator()
        coordinator.reset(sessionID: model.transcriptPresentationID, totalCount: 500, bubbleCount: 500)
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
        let source = ConversationTranscriptSource(
            model: model, bots: BotModeModel(),
            actions: ConversationMessageActionState(), voice: VoiceOutput(),
            coordinator: ConversationTranscriptCoordinator())
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
