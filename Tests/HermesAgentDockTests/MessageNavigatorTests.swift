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

    func testJumpWindowCentersTargetAndStaysBounded() {
        let totalCount = 400

        let centered = ConversationMessageWindow.jumpWindow(aroundIndex: 200, totalCount: totalCount)
        XCTAssertEqual(centered.lowerBound, 200 - ConversationMessageWindow.jumpContextAbove)
        XCTAssertEqual(centered.upperBound, 200 + 1 + ConversationMessageWindow.jumpContextBelow)
        XCTAssertTrue(centered.contains(200))

        let topEdge = ConversationMessageWindow.jumpWindow(aroundIndex: 0, totalCount: totalCount)
        XCTAssertEqual(topEdge, 0..<(1 + ConversationMessageWindow.jumpContextBelow))

        let bottomEdge = ConversationMessageWindow.jumpWindow(aroundIndex: totalCount - 1, totalCount: totalCount)
        XCTAssertEqual(bottomEdge.lowerBound, totalCount - 1 - ConversationMessageWindow.jumpContextAbove)
        XCTAssertEqual(bottomEdge.upperBound, totalCount)

        let clampedPastEnd = ConversationMessageWindow.jumpWindow(aroundIndex: 1_000, totalCount: totalCount)
        XCTAssertTrue(clampedPastEnd.contains(totalCount - 1))

        for index in stride(from: 0, to: totalCount, by: 7) {
            let window = ConversationMessageWindow.jumpWindow(aroundIndex: index, totalCount: totalCount)
            XCTAssertLessThanOrEqual(
                window.count,
                2 * ConversationMessageWindow.pageSize + 1,
                "window at index \(index) exceeded the jump bound"
            )
            XCTAssertTrue(window.contains(index))
        }

        XCTAssertEqual(ConversationMessageWindow.jumpWindow(aroundIndex: 0, totalCount: 0), 0..<0)
    }

    func testVisibleRangeClampsStaleRangesAgainstShrunkTranscript() {
        XCTAssertEqual(
            ConversationMessageWindow.visibleRange(380..<500, totalCount: 390),
            380..<390
        )
        XCTAssertEqual(
            ConversationMessageWindow.visibleRange(100..<110, totalCount: 40),
            39..<40
        )
        XCTAssertEqual(
            ConversationMessageWindow.visibleRange(-5..<3, totalCount: 40),
            0..<3
        )
        XCTAssertEqual(ConversationMessageWindow.visibleRange(0..<10, totalCount: 0), 0..<0)
        XCTAssertEqual(ConversationMessageWindow.visibleRange(0..<0, totalCount: 0), 0..<0)
    }

    func testRevealLaterSlidesBoundedUnderRepeatedClicks() {
        let totalCount = 400
        var range = ConversationMessageWindow.jumpWindow(aroundIndex: 19, totalCount: totalCount)
        var visibleSpan: ClosedRange<Int> = 20...31
        var exposedUpperBounds: [Int] = [range.upperBound]

        for _ in 0..<40 {
            let next = ConversationMessageWindow.revealLater(
                range,
                totalCount: totalCount,
                visibleSpan: visibleSpan
            )
            XCTAssertLessThanOrEqual(
                next.count,
                ConversationMessageWindow.maxMountedRowCount,
                "mounted window grew past the hard cap"
            )
            XCTAssertEqual(
                next.upperBound,
                min(range.upperBound + ConversationMessageWindow.pageSize, totalCount),
                "each click must expose exactly one page of new rows"
            )
            XCTAssertLessThanOrEqual(
                next.lowerBound,
                visibleSpan.lowerBound,
                "visible rows must never be trimmed"
            )
            exposedUpperBounds.append(next.upperBound)
            range = next
            visibleSpan = (max(range.upperBound - ConversationMessageWindow.pageSize, range.lowerBound))...(range.upperBound - 1)
        }

        XCTAssertEqual(range.upperBound, totalCount)
        for (before, after) in zip(exposedUpperBounds, exposedUpperBounds.dropFirst()) {
            guard before < totalCount else { continue }
            XCTAssertLessThan(before, after, "a click failed to expose new rows")
        }
    }

    func testRevealLaterEventuallyReachesTheTranscriptEnd() {
        let totalCount = 400
        var range = ConversationMessageWindow.jumpWindow(aroundIndex: 19, totalCount: totalCount)
        var visibleSpan: ClosedRange<Int> = 20...31

        for _ in 0..<60 {
            range = ConversationMessageWindow.revealLater(
                range,
                totalCount: totalCount,
                visibleSpan: visibleSpan
            )
            let spanLower = max(range.upperBound - ConversationMessageWindow.pageSize, range.lowerBound)
            visibleSpan = spanLower...(range.upperBound - 1)
        }

        XCTAssertEqual(range.upperBound, totalCount)
        XCTAssertLessThanOrEqual(range.count, ConversationMessageWindow.maxMountedRowCount)
    }

    func testRevealEarlierSlidesBoundedUnderRepeatedClicks() {
        let totalCount = 400
        var range = ConversationMessageWindow.tailRange(totalCount: totalCount)
        var visibleSpan: ClosedRange<Int> = range.lowerBound...(range.lowerBound + ConversationMessageWindow.pageSize - 1)
        var lowerBounds: [Int] = []

        for _ in 0..<40 {
            let next = ConversationMessageWindow.revealEarlier(
                range,
                totalCount: totalCount,
                visibleSpan: visibleSpan
            )
            XCTAssertLessThanOrEqual(
                next.count,
                ConversationMessageWindow.maxMountedRowCount,
                "mounted window grew past the hard cap"
            )
            XCTAssertEqual(
                next.lowerBound,
                max(range.lowerBound - ConversationMessageWindow.pageSize, 0),
                "each click must expose exactly one page of new rows"
            )
            XCTAssertGreaterThanOrEqual(
                next.upperBound,
                visibleSpan.upperBound + 1,
                "visible rows must never be trimmed"
            )
            lowerBounds.append(next.lowerBound)
            range = next
            visibleSpan = range.lowerBound...(range.lowerBound + ConversationMessageWindow.pageSize - 1)
        }

        XCTAssertEqual(range.lowerBound, 0)
        XCTAssertEqual(lowerBounds.first, 388 - ConversationMessageWindow.pageSize)
        XCTAssertEqual(lowerBounds.last, 0)
    }

    func testAlternatingRevealsSlideWithoutGrowthRatchet() {
        let totalCount = 400
        var range = ConversationMessageWindow.jumpWindow(aroundIndex: 19, totalCount: totalCount)
        var visibleSpan: ClosedRange<Int> = 20...31

        for step in 0..<20 {
            if step.isMultiple(of: 2) {
                range = ConversationMessageWindow.revealLater(range, totalCount: totalCount, visibleSpan: visibleSpan)
            } else {
                range = ConversationMessageWindow.revealEarlier(range, totalCount: totalCount, visibleSpan: visibleSpan)
            }
            XCTAssertLessThanOrEqual(range.count, ConversationMessageWindow.maxMountedRowCount)
            visibleSpan = (range.lowerBound + 8)...(range.lowerBound + 11)
        }

        XCTAssertLessThanOrEqual(range.count, ConversationMessageWindow.maxMountedRowCount)
    }

    func testUnknownVisibleSpanFallsBackToHardCap() {
        let totalCount = 400
        var range = ConversationMessageWindow.jumpWindow(aroundIndex: 19, totalCount: totalCount)

        for _ in 0..<10 {
            range = ConversationMessageWindow.revealLater(range, totalCount: totalCount, visibleSpan: nil)
            XCTAssertLessThanOrEqual(range.count, ConversationMessageWindow.maxMountedRowCount)
            XCTAssertFalse(range.isEmpty)
        }
    }

    func testRangeAfterCountChangeSlidesLiveTailAndFreezesBrowsingWindow() {
        XCTAssertEqual(
            ConversationMessageWindow.rangeAfterCountChange(
                380..<500,
                oldCount: 500,
                newCount: 503,
                isAtBottom: false
            ),
            380..<500
        )
        XCTAssertEqual(
            ConversationMessageWindow.rangeAfterCountChange(
                380..<500,
                oldCount: 500,
                newCount: 501,
                isAtBottom: true
            ),
            381..<501
        )
        XCTAssertEqual(
            ConversationMessageWindow.rangeAfterCountChange(
                0..<0,
                oldCount: 0,
                newCount: 3,
                isAtBottom: true
            ),
            0..<3
        )
        XCTAssertEqual(
            ConversationMessageWindow.rangeAfterCountChange(
                380..<500,
                oldCount: 500,
                newCount: 390,
                isAtBottom: true
            ),
            380..<500
        )
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
            totalCount: messages.count
        )

        XCTAssertEqual(plan?.messageID, selected.messageID)
        let window = plan?.windowRange ?? 0..<0
        XCTAssertLessThanOrEqual(
            window.count,
            2 * ConversationMessageWindow.pageSize + 1
        )
        XCTAssertTrue(window.contains(19))
        XCTAssertTrue(
            messages[ConversationMessageWindow.visibleRange(window, totalCount: messages.count)]
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
        let window = receivedEffect?.windowRange ?? 0..<0
        XCTAssertLessThanOrEqual(
            window.count,
            2 * ConversationMessageWindow.pageSize + 1
        )
        XCTAssertTrue(window.contains(19))
        XCTAssertFalse(receivedEffect?.isAtBottom ?? true)
        XCTAssertEqual(receivedEffect?.unseenMessageCount, 0)
        XCTAssertEqual(scrolledMessageID, selected.messageID)
        XCTAssertTrue(scrolledAnchorIsCenter)
        XCTAssertTrue(
            messages[ConversationMessageWindow.visibleRange(window, totalCount: messages.count)]
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
