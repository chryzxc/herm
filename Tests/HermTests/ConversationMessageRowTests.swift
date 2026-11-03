import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct ConversationMessageRowTests {
    private func makeRow(
        message: ChatMessage,
        isStreamingMessage: Bool = false,
        activeBotProfileID: String? = nil,
        botRosterRevision: Int = 0,
        actionTarget: MessageNavigatorTarget? = nil
    ) -> ConversationMessageRow {
        ConversationMessageRow(
            message: message,
            isStreamingMessage: isStreamingMessage,
            streamingText: nil,
            activeBotProfileID: activeBotProfileID,
            botsByID: [:],
            avatarImages: [:],
            botRosterRevision: botRosterRevision,
            onImagePreview: { _ in },
            actionTarget: actionTarget
        )
    }

    @Test func identicalMessageValuesAreEqual() {
        let message = ChatMessage(role: .hermes, text: "hello")
        let first = makeRow(message: message)
        let second = makeRow(message: message)
        #expect(first == second)
    }

    @Test func sessionChangesRefreshMessageActionClosures() {
        let message = ChatMessage(role: .hermes, text: "saved reply")
        let original = MessageNavigatorTarget(sessionID: "original", messageID: message.id)
        let resumed = MessageNavigatorTarget(sessionID: "resumed", messageID: message.id)
        #expect(makeRow(message: message, actionTarget: original) == makeRow(message: message, actionTarget: original))
        #expect(makeRow(message: message, actionTarget: original) != makeRow(message: message, actionTarget: resumed))
    }

    @Test func everyComparedFieldBreaksEquality() {
        let base = ChatMessage(role: .hermes, text: "hello")

        #expect(makeRow(message: base) != makeRow(message: ChatMessage(role: .hermes, text: "changed")))
        #expect(makeRow(message: base) != makeRow(message: ChatMessage(role: .user, text: "hello")))
        #expect(makeRow(message: base) != makeRow(message: ChatMessage(role: .hermes, text: "hello", image: NSImage())))
        #expect(makeRow(message: base) != makeRow(message: ChatMessage(role: .hermes, text: "hello", isSteering: true)))
        #expect(
            makeRow(message: base)
                != makeRow(message: ChatMessage(role: .hermes, text: "hello", steeringStatus: "SENT")))
        #expect(makeRow(message: base) != makeRow(message: ChatMessage(role: .hermes, text: "hello", isError: true)))
        #expect(
            makeRow(message: base) != makeRow(message: ChatMessage(role: .hermes, text: "hello", botProfileID: "bot")))
        #expect(
            makeRow(message: base) != makeRow(message: ChatMessage(role: .hermes, text: "hello", botDisplayName: "Bot"))
        )
        #expect(
            makeRow(message: base) != makeRow(message: ChatMessage(role: .hermes, text: "hello", responseDuration: 1.5))
        )
        #expect(makeRow(message: base) != makeRow(message: base, isStreamingMessage: true))
        #expect(makeRow(message: base) != makeRow(message: base, activeBotProfileID: "profile"))
        #expect(makeRow(message: base) != makeRow(message: base, botRosterRevision: 1))
    }

    @Test func messageActionsAreUniqueAndHaveHoverLabels() {
        let actions = ConversationMessageActionKind.allCases

        #expect(Set(actions.map(\.id)).count == actions.count)
        #expect(Set(actions.map(\.icon)).count == actions.count)
        #expect(
            actions.map(\.label) == [
                "Copy message",
                "Read message aloud",
                "Branch from this message",
                "Refresh this response",
                "Reply to this message",
                "Pin message",
            ])
    }

    @Test func messageActionStateTracksOnlyTheInitiatingAction() async throws {
        let state = ConversationMessageActionState()
        let messageID = UUID()

        #expect(state.pendingAction(for: messageID) == nil)
        state.run(messageID, action: .refresh) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(state.pendingAction(for: messageID) == .refresh)
        #expect(state.pendingActions.count == 1)

        let deadline = Date().addingTimeInterval(5)
        while state.pendingAction(for: messageID) != nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
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

        #expect(message.timeLabel == timestamp.formatted(date: .abbreviated, time: .shortened))
        #expect(message.durationLabel == ResponseDurationFormatting.string(seconds: 95))
        #expect(ChatMessage(role: .hermes, text: "body").durationLabel == nil)
    }

    #if DEBUG
        @Test func hoverUpdatesProductionTimestampWithoutReevaluatingMessage() async throws {
            for message in [
                ChatMessage(role: .user, text: "hello"),
                ChatMessage(role: .hermes, text: "**answer**", responseDuration: 2, tokenCount: 42),
                ChatMessage(role: .hermes, text: "failure", isError: true),
            ] {
                let hover = ConversationRowHoverPresentation()
                let row = ConversationMessageRow(
                    message: message, isStreamingMessage: false, streamingText: nil,
                    activeBotProfileID: nil, botsByID: [:], avatarImages: [:],
                    botRosterRevision: 0, onImagePreview: { _ in }, hoverPresentation: hover
                )
                try await checkHover(
                    row.equatable(), hover: hover, parent: "message", leaf: "timestamp",
                    resting: message.isError ? 1 : 0, hovering: 1)
            }
        }

        @Test func hoverUpdatesSystemAndFeedBackgroundWithoutReevaluatingContent() async throws {
            for expanded in [false, true] {
                let systemHover = ConversationRowHoverPresentation()
                let system = SystemEventCard(
                    event: SystemEvent(label: "System"), text: "**Headline**\nFull detail",
                    timeLabel: "12:00", isExpanded: expanded, hoverPresentation: systemHover
                )
                try await checkHover(
                    system, hover: systemHover, parent: "system", leaf: "background",
                    resting: expanded ? 0.05 : 0, hovering: 0.05)
                let feedHover = ConversationRowHoverPresentation()
                let feed = FeedEventRow(
                    event: SystemEvent(label: "Feed", isFeed: true), line: FeedLine("**Headline**\nFull detail"),
                    timeLabel: "12:00", botsByID: [:], avatarImages: [:],
                    isExpanded: expanded, hoverPresentation: feedHover
                )
                try await checkHover(
                    feed, hover: feedHover, parent: "feed", leaf: "background",
                    resting: expanded ? 0.05 : 0, hovering: 0.05)
            }
        }

        private func checkHover<Content: View>(
            _ content: Content, hover: ConversationRowHoverPresentation,
            parent: String, leaf: String, resting: Double, hovering: Double
        ) async throws {
            let recorder = RowEvaluationRecorder()
            let host = NSHostingView(
                rootView: content.environment(
                    \.conversationRowEvaluation,
                    { name, value in
                        recorder.values[name, default: []].append(value)
                    }))
            host.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            // Slow runners can evaluate the first frame late, so take the baseline once the count stops moving.
            var parentCount = -1
            for _ in 0..<20 where recorder.values[parent, default: []].count != parentCount {
                parentCount = recorder.values[parent, default: []].count
                try await settle(host)
            }
            #expect(parentCount > 0)
            #expect(recorder.values[leaf]?.last == resting)
            let size = host.fittingSize
            let identities = nativeViewIdentities(host)
            for entered in [true, false, true, false] {
                hover.isHovering = entered
                try await settle(host)
                #expect(recorder.values[leaf]?.last == (entered ? hovering : resting))
                #expect(recorder.values[parent, default: []].count == parentCount)
                #expect(host.fittingSize == size)
                #expect(nativeViewIdentities(host) == identities)
            }
            print(
                "Hover evaluations \(parent): \(recorder.values.mapValues { $0.count }); \(leaf): \(recorder.values[leaf] ?? [])"
            )
        }

        private func settle(_ host: NSView) async throws {
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        private func nativeViewIdentities(_ view: NSView) -> [ObjectIdentifier] {
            [ObjectIdentifier(view)] + view.subviews.flatMap(nativeViewIdentities)
        }
    #endif
}

@MainActor
private final class RowEvaluationRecorder {
    var values: [String: [Double]] = [:]
}
