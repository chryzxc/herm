import XCTest
@testable import HermesAgentDock

final class MessageNavigatorTests: XCTestCase {
    func testBuildsStableSessionScopedTargetsAndBoundedPreviews() {
        let sessionID = "session-a"
        let messageID = UUID()
        let messages = [
            ChatMessage(id: messageID, role: .user, text: "A very long message " + String(repeating: "x", count: 220)),
            ChatMessage(role: .hermes, text: "assistant response")
        ]

        let items = MessageNavigator.items(messages: messages, sessionID: sessionID, previewLimit: 32)

        XCTAssertEqual(items.map(\.target), [
            MessageNavigatorTarget(sessionID: sessionID, messageID: messageID),
            MessageNavigatorTarget(sessionID: sessionID, messageID: messages[1].id)
        ])
        XCTAssertEqual(items[0].ordinal, 1)
        XCTAssertLessThanOrEqual(items[0].preview.count, 32)
        XCTAssertTrue(items[0].preview.hasSuffix("…"))
        XCTAssertEqual(items[0].roleLabel, "You")
    }

    func testSearchMatchesMarkdownImagesToolsAndClarificationTextWithoutChangingOrder() {
        let messages = [
            ChatMessage(role: .hermes, text: "**Markdown** answer"),
            ChatMessage(role: .user, text: "Please inspect the image"),
            ChatMessage(role: .hermes, text: "Tool result: compiler passed"),
            ChatMessage(role: .hermes, text: "Clarification needed: choose a branch")
        ]
        let items = MessageNavigator.items(messages: messages, sessionID: "session-a")

        XCTAssertEqual(
            MessageNavigator.search(items: items, query: "compiler").map(\.messageID),
            [messages[2].id]
        )
        XCTAssertEqual(
            MessageNavigator.search(items: items, query: "MARKDOWN").map(\.messageID),
            [messages[0].id]
        )
        XCTAssertEqual(
            MessageNavigator.search(items: items, query: "  ").map(\.messageID),
            items.map(\.messageID)
        )
    }

    @MainActor
    func testKeyboardDownFromNoSelectionChoosesFirstFilteredMessage() {
        XCTAssertEqual(
            MessageNavigatorView.nextSelectionIndex(direction: .down, currentIndex: nil, count: 3),
            0
        )
    }

    func testSelectionAndViewportUpdatesCannotCrossSessions() {
        let messageID = UUID()
        let targetA = MessageNavigatorTarget(sessionID: "session-a", messageID: messageID)
        let targetB = MessageNavigatorTarget(sessionID: "session-b", messageID: messageID)

        XCTAssertEqual(MessageNavigator.target(for: messageID, sessionID: "session-a"), targetA)
        XCTAssertNil(MessageNavigator.target(for: messageID, sessionID: "session-a", visibleIn: [targetB]))
        XCTAssertEqual(
            MessageNavigator.nearestVisibleTarget(
                to: targetA,
                visibleTargets: [targetB, targetA]
            ),
            targetA
        )
    }

    func testTranscriptWindowUsesCanonicalNavigatorProjection() {
        let messages = [ChatMessage(role: .hermes, text: "response")]

        XCTAssertEqual(
            ConversationMessageWindow.navigatorItems(messages: messages, sessionID: "session-a"),
            MessageNavigator.items(messages: messages, sessionID: "session-a")
        )
    }

    func testBoundedPreviewMatchesUnboundedNormalizationForWhitespaceHeavyOpenings() {
        let whitespaceOpening = String(repeating: "\n\t ", count: 600)
        let text = whitespaceOpening + String(repeating: "content ", count: 80)
        let unbounded = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(MessageNavigator.boundedPreview(text, limit: 32), String(unbounded.prefix(31)) + "…")
    }

    func testBoundedPreviewTruncatesIndentedCodeStyleBodies() {
        let text = "    indented code line one\n    indented code line two\n"
            + String(repeating: "plain continuation line\n", count: 100)
        let unbounded = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(MessageNavigator.boundedPreview(text, limit: 40), String(unbounded.prefix(39)) + "…")
    }

    func testItemsProjectionIsMemoizedUntilContentChanges() {
        let messages = [ChatMessage(role: .hermes, text: "first response")]

        let initial = MessageNavigator.items(messages: messages, sessionID: "memo-session")
        XCTAssertEqual(MessageNavigator.items(messages: messages, sessionID: "memo-session"), initial)

        let updated = MessageNavigator.items(
            messages: messages + [ChatMessage(role: .user, text: "follow-up")],
            sessionID: "memo-session"
        )
        XCTAssertEqual(updated.count, 2)
        XCTAssertEqual(updated.first, initial.first)
        XCTAssertEqual(updated[1].roleLabel, "You")
    }

    func testJumpLimitRevealsTargetWhileKeepingWindowBounded() {
        let messages = (1...40).map { _ in ChatMessage(role: .user, text: "message") }

        XCTAssertEqual(
            ConversationMessageWindow.limitToReveal(
                messageOrdinal: 3,
                totalCount: 40,
                currentLimit: 12
            ),
            38
        )
        XCTAssertEqual(
            ConversationMessageWindow.limitToReveal(
                messageOrdinal: 20,
                totalCount: 40,
                currentLimit: 12
            ),
            21
        )
        XCTAssertEqual(
            ConversationMessageWindow.limitToReveal(
                messageOrdinal: 99,
                totalCount: 40,
                currentLimit: 12
            ),
            40
        )

        let revealedLimit = ConversationMessageWindow.limitToReveal(
            messageOrdinal: 20,
            totalCount: messages.count,
            currentLimit: 12
        )
        let visible = ConversationMessageWindow.visibleMessages(messages, limit: revealedLimit)
        XCTAssertTrue(visible.contains { $0.id == messages[19].id })
    }

    func testNavigatorSelectionPlansTranscriptRevealAndExactScrollTarget() {
        let sessionID = "session-a"
        let messages = (1...40).map { index in
            ChatMessage(role: .user, text: "message \(index)")
        }
        let selected = MessageNavigator.items(messages: messages, sessionID: sessionID)[19]

        let plan = ConversationMessageWindow.jumpPlan(
            for: selected,
            sessionID: sessionID,
            totalCount: messages.count,
            currentLimit: ConversationMessageWindow.initialLimit
        )

        XCTAssertEqual(plan?.messageID, selected.messageID)
        XCTAssertEqual(plan?.renderedLimit, 21)
        XCTAssertTrue(
            ConversationMessageWindow.visibleMessages(messages, limit: plan?.renderedLimit ?? 0)
                .contains { $0.id == plan?.messageID }
        )
    }

    @MainActor
    func testNavigatorSelectionDispatchesProductionTranscriptHandoff() async {
        let sessionID = "session-a"
        let messages = (1...40).map { index in
            ChatMessage(role: .user, text: "message \(index)")
        }
        let selected = MessageNavigator.items(messages: messages, sessionID: sessionID)[19]
        var receivedEffect: ConversationMessageJumpEffect?
        var scrolledMessageID: UUID?
        var scrolledAnchorIsCenter = false
        var currentSessionID: String? = sessionID
        let scrollExpectation = expectation(description: "production transcript scroll")

        let productionHandler = DockPopover.transcriptSelectionHandler(
            sessionID: sessionID,
            messages: messages,
            currentLimit: { ConversationMessageWindow.initialLimit },
            currentSessionID: { currentSessionID },
            onEffect: { effect in receivedEffect = effect },
            onScroll: { messageID, anchor in
                scrolledMessageID = messageID
                scrolledAnchorIsCenter = anchor == .center
                scrollExpectation.fulfill()
            }
        )

        MessageNavigatorView.dispatchSelection(selected, onSelect: productionHandler)
        await fulfillment(of: [scrollExpectation], timeout: 1)

        XCTAssertEqual(receivedEffect?.messageID, selected.messageID)
        XCTAssertEqual(receivedEffect?.renderedLimit, 21)
        XCTAssertFalse(receivedEffect?.isAtBottom ?? true)
        XCTAssertEqual(receivedEffect?.unseenMessageCount, 0)
        XCTAssertEqual(scrolledMessageID, selected.messageID)
        XCTAssertTrue(scrolledAnchorIsCenter)
        XCTAssertTrue(
            ConversationMessageWindow.visibleMessages(messages, limit: receivedEffect?.renderedLimit ?? 0)
                .contains { $0.id == receivedEffect?.messageID }
        )
        currentSessionID = "different-session"
        receivedEffect = nil
        scrolledMessageID = nil
        scrolledAnchorIsCenter = false
        let rejectedScrollExpectation = expectation(description: "stale transcript scroll rejected")
        rejectedScrollExpectation.isInverted = true
        MessageNavigatorView.dispatchSelection(selected, onSelect: productionHandler)
        await fulfillment(of: [rejectedScrollExpectation], timeout: 0.2)
        XCTAssertNil(receivedEffect)
        XCTAssertNil(scrolledMessageID)
        XCTAssertFalse(scrolledAnchorIsCenter)
    }
}
