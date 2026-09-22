import AppKit
import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct ConversationMessageRowTests {
    private func makeRow(
        message: ChatMessage,
        isStreamingMessage: Bool = false,
        activeBotProfileID: String? = nil,
        botRosterRevision: Int = 0
    ) -> ConversationMessageRow {
        ConversationMessageRow(
            message: message,
            isStreamingMessage: isStreamingMessage,
            streamingText: nil,
            activeBotProfileID: activeBotProfileID,
            botsByID: [:],
            avatarImages: [:],
            botRosterRevision: botRosterRevision,
            onImagePreview: { _ in }
        )
    }

    @Test func identicalMessageValuesAreEqual() {
        let message = ChatMessage(role: .hermes, text: "hello")
        let first = makeRow(message: message)
        let second = makeRow(message: message)
        #expect(first == second)
    }

    @Test func everyComparedFieldBreaksEquality() {
        let base = ChatMessage(role: .hermes, text: "hello")

        #expect(makeRow(message: base) != makeRow(message: ChatMessage(role: .hermes, text: "changed")))
        #expect(makeRow(message: base) != makeRow(message: ChatMessage(role: .user, text: "hello")))
        #expect(makeRow(message: base) != makeRow(message: ChatMessage(role: .hermes, text: "hello", image: NSImage())))
        #expect(makeRow(message: base) != makeRow(message: ChatMessage(role: .hermes, text: "hello", isSteering: true)))
        #expect(makeRow(message: base) != makeRow(message: ChatMessage(role: .hermes, text: "hello", steeringStatus: "SENT")))
        #expect(makeRow(message: base) != makeRow(message: ChatMessage(role: .hermes, text: "hello", isError: true)))
        #expect(makeRow(message: base) != makeRow(message: ChatMessage(role: .hermes, text: "hello", botProfileID: "bot")))
        #expect(makeRow(message: base) != makeRow(message: ChatMessage(role: .hermes, text: "hello", botDisplayName: "Bot")))
        #expect(makeRow(message: base) != makeRow(message: ChatMessage(role: .hermes, text: "hello", responseDuration: 1.5)))
        #expect(makeRow(message: base) != makeRow(message: base, isStreamingMessage: true))
        #expect(makeRow(message: base) != makeRow(message: base, activeBotProfileID: "profile"))
        #expect(makeRow(message: base) != makeRow(message: base, botRosterRevision: 1))
    }

    @Test func messageActionsAreUniqueAndHaveHoverLabels() {
        let actions = ConversationMessageActionKind.allCases

        #expect(actions.count == 4)
        #expect(Set(actions.map(\.id)).count == actions.count)
        #expect(Set(actions.map(\.icon)).count == actions.count)
        #expect(actions.map(\.label) == [
            "Copy message",
            "Read message aloud",
            "Branch from this message",
            "Refresh this response"
        ])
        #expect(LucideIconName.from(systemName: "speaker.wave.2") == .audioLines)
    }

    @Test func messageActionStateTracksOnlyTheInitiatingAction() async {
        let state = ConversationMessageActionState()
        let messageID = UUID()

        #expect(state.pendingAction(for: messageID) == nil)
        state.run(messageID, action: .refresh) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(state.pendingAction(for: messageID) == .refresh)
        #expect(state.pendingActions.count == 1)

        try? await Task.sleep(for: .milliseconds(40))
        #expect(state.pendingAction(for: messageID) == nil)
    }

    @Test func incompleteSessionMarksSessionActionsUnavailable() {
        let message = ChatMessage(role: .hermes, text: "hello")
        let row = ConversationMessageRow(
            message: message,
            isStreamingMessage: false,
            streamingText: nil,
            activeBotProfileID: nil,
            botsByID: [:],
            avatarImages: [:],
            botRosterRevision: 0,
            onImagePreview: { _ in },
            areSessionActionsAvailable: false
        )

        #expect(!row.areSessionActionsAvailable)
    }

    @Test func metadataLabelsAreComputedOnceAtInit() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let message = ChatMessage(role: .hermes, text: "body", timestamp: timestamp, responseDuration: 95)

        #expect(message.timeLabel == HumanDateFormatting.timeOnly(timestamp))
        #expect(message.durationLabel == ResponseDurationFormatting.string(seconds: 95))
        #expect(ChatMessage(role: .hermes, text: "body").durationLabel == nil)
    }
}
