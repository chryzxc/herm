import XCTest
@testable import Herm

final class ConversationScrollMetricsTests: XCTestCase {
    func testLongTranscriptInitiallyRendersOnlyRecentExactWindow() {
        let messages = (0..<500).map { index in
            ChatMessage(role: .hermes, text: "message \(index)")
        }

        let range = ConversationMessageWindow.visibleRange(
            ConversationMessageWindow.tailRange(totalCount: messages.count),
            totalCount: messages.count
        )
        let visible = messages[range]

        XCTAssertEqual(visible.count, ConversationMessageWindow.initialLimit)
        XCTAssertEqual(visible.first?.text, "message 488")
        XCTAssertEqual(visible.last?.text, "message 499")
    }

    func testMessageRevisionIsComputedOnceAndStable() {
        let message = ChatMessage(role: .hermes, text: "**stable** markdown")
        XCTAssertEqual(message.contentRevision, message.contentRevision)
        XCTAssertNotEqual(
            message.contentRevision,
            ChatMessage(role: .hermes, text: "different markdown").contentRevision
        )
    }

    func testRevealingHistoryAddsOneBoundedPage() {
        let tail = ConversationMessageWindow.tailRange(totalCount: 500)

        let firstReveal = ConversationMessageWindow.revealEarlier(tail, totalCount: 500, visibleSpan: nil)
        XCTAssertEqual(firstReveal.lowerBound, tail.lowerBound - ConversationMessageWindow.pageSize)
        XCTAssertEqual(firstReveal.count, ConversationMessageWindow.initialLimit + ConversationMessageWindow.pageSize)

        var range = firstReveal
        for _ in 0..<40 {
            range = ConversationMessageWindow.revealEarlier(range, totalCount: 500, visibleSpan: nil)
            XCTAssertLessThanOrEqual(range.count, ConversationMessageWindow.maxMountedRowCount)
        }
        XCTAssertEqual(range.lowerBound, 0)
    }

    func testSessionReplacementDropsExpandedHistoryWindow() {
        let replacement = ConversationMessageWindow.rangeForSessionReplacement(totalCount: 500)
        XCTAssertEqual(replacement, ConversationMessageWindow.tailRange(totalCount: 500))
        XCTAssertLessThan(
            replacement.count,
            ConversationMessageWindow.maxMountedRowCount
        )
    }

    func testRepinningCompactsExpandedHistory() {
        let expandedTail = ConversationMessageWindow.tailRange(totalCount: 500, limit: 120)
        XCTAssertTrue(ConversationMessageWindow.shouldCompactAfterRepinning(
            wasAtBottom: false,
            isAtBottom: true,
            range: expandedTail,
            totalCount: 500
        ))
        XCTAssertEqual(
            ConversationMessageWindow.compactedRange(totalCount: 500),
            ConversationMessageWindow.tailRange(totalCount: 500)
        )
    }

    func testPinnedOrUnexpandedHistoryDoesNotCompact() {
        let expandedTail = ConversationMessageWindow.tailRange(totalCount: 500, limit: 120)
        let narrowTail = ConversationMessageWindow.tailRange(totalCount: 500)
        let historyWindow = ConversationMessageWindow.jumpWindow(aroundIndex: 200, totalCount: 500)

        XCTAssertFalse(ConversationMessageWindow.shouldCompactAfterRepinning(
            wasAtBottom: true,
            isAtBottom: true,
            range: expandedTail,
            totalCount: 500
        ))
        XCTAssertFalse(ConversationMessageWindow.shouldCompactAfterRepinning(
            wasAtBottom: false,
            isAtBottom: true,
            range: narrowTail,
            totalCount: 500
        ))
        XCTAssertFalse(ConversationMessageWindow.shouldCompactAfterRepinning(
            wasAtBottom: false,
            isAtBottom: false,
            range: expandedTail,
            totalCount: 500
        ))
        XCTAssertFalse(ConversationMessageWindow.shouldCompactAfterRepinning(
            wasAtBottom: false,
            isAtBottom: true,
            range: historyWindow,
            totalCount: 500
        ))
    }

    func testCompactedRangeDoesNotExceedShortTranscript() {
        XCTAssertEqual(
            ConversationMessageWindow.compactedRange(totalCount: 5),
            0..<5
        )
    }

    func testAppendWhileReadingHistoryFreezesWindowWithStartPreserved() {
        let oldRange: Range<Int> = 380..<500
        let newRange = ConversationMessageWindow.rangeAfterCountChange(
            oldRange,
            oldCount: 500,
            newCount: 503,
            isAtBottom: false
        )

        XCTAssertEqual(newRange, oldRange)
    }

    func testAppendAtBottomKeepsWindowBounded() {
        XCTAssertEqual(
            ConversationMessageWindow.rangeAfterCountChange(
                380..<500,
                oldCount: 500,
                newCount: 501,
                isAtBottom: true
            ),
            381..<501
        )
    }

    func testAppendAtBottomOfShortTranscriptStopsGrowingAtInitialLimit() {
        var range: Range<Int> = 0..<3
        for count in 3..<200 {
            range = ConversationMessageWindow.rangeAfterCountChange(
                range,
                oldCount: count,
                newCount: count + 1,
                isAtBottom: true
            )
        }
        XCTAssertEqual(range, (200 - ConversationMessageWindow.initialLimit)..<200)
    }

    func testLiveTailIsDerivedFromTheWindowEdge() {
        XCTAssertTrue(ConversationMessageWindow.isLiveTail(488..<500, totalCount: 500))
        XCTAssertFalse(ConversationMessageWindow.isLiveTail(380..<480, totalCount: 500))
        XCTAssertTrue(ConversationMessageWindow.isLiveTail(0..<0, totalCount: 0))
        XCTAssertFalse(ConversationMessageWindow.isLiveTail(380..<500, totalCount: 501))
    }

    func testUnreadCountIgnoresTransportOnlyAssistantEntries() {
        let emptyActivity = ChatMessage(role: .hermes, text: "")
        let userMessage = ChatMessage(role: .user, text: "Visible user message")
        let response = ChatMessage(role: .hermes, text: "Visible assistant response")
        let steering = ChatMessage(role: .user, text: "", isSteering: true)

        XCTAssertEqual(
            ConversationUnreadMessagePolicy.renderedMessageCount(
                [emptyActivity, userMessage, response, steering],
                streamingID: nil
            ),
            3
        )
        XCTAssertTrue(
            ConversationUnreadMessagePolicy.rendersMessageBubble(
                emptyActivity,
                streamingID: emptyActivity.id
            )
        )
    }

    func testBodyTextFlagMatchesLegacyTrimmedEmptiness() {
        XCTAssertTrue(ChatMessage(role: .hermes, text: "visible").hasBodyText)
        XCTAssertFalse(ChatMessage(role: .hermes, text: "").hasBodyText)
        XCTAssertFalse(ChatMessage(role: .hermes, text: "  \n\t ").hasBodyText)
    }

    func testUnreadSemanticsWithWhitespaceAndImageOnlyMessages() {
        let whitespaceOnly = ChatMessage(role: .hermes, text: " \n\t ")
        let imageOnly = ChatMessage(role: .user, text: "", images: [NSImage()])
        let streamingPlaceholder = ChatMessage(role: .hermes, text: "")

        XCTAssertEqual(
            ConversationUnreadMessagePolicy.renderedMessageCount(
                [whitespaceOnly, imageOnly, streamingPlaceholder],
                streamingID: nil
            ),
            1
        )
        XCTAssertTrue(
            ConversationUnreadMessagePolicy.rendersMessageBubble(
                imageOnly,
                streamingID: nil
            )
        )
        XCTAssertTrue(
            ConversationUnreadMessagePolicy.rendersMessageBubble(
                streamingPlaceholder,
                streamingID: streamingPlaceholder.id
            )
        )
    }

    func testSentinelAtViewportBottomCountsAsAtBottom() {
        XCTAssertTrue(ConversationScrollMetrics.isAtBottom(bottomMaxY: 720, viewportHeight: 720))
    }

    func testTransientStreamingGrowthStaysSticky() {
        XCTAssertTrue(ConversationScrollMetrics.isAtBottom(bottomMaxY: 780, viewportHeight: 720))
    }

    func testSmallUpwardScrollDoesNotRepinAfterSettling() {
        XCTAssertFalse(ConversationScrollMetrics.isAtBottom(
            topMinY: -120,
            bottomMaxY: 732,
            viewportHeight: 720,
            tolerance: ConversationScrollMetrics.pastEndTolerance
        ))
        XCTAssertTrue(ConversationScrollMetrics.isAtBottom(
            topMinY: -132,
            bottomMaxY: 720,
            viewportHeight: 720,
            tolerance: ConversationScrollMetrics.pastEndTolerance
        ))
    }

    func testPastEndBlankTailIsNotAtBottom() {
        XCTAssertFalse(ConversationScrollMetrics.isAtBottom(bottomMaxY: 600, viewportHeight: 720))
    }

    func testShortTranscriptAtTheOnlyLegalOriginCountsAsAtBottom() {
        XCTAssertTrue(ConversationScrollMetrics.isAtBottom(
            topMinY: 0,
            bottomMaxY: 600,
            viewportHeight: 720
        ))
    }

    func testBlankTailAfterARealScrollDoesNotCountAsAtBottom() {
        XCTAssertFalse(ConversationScrollMetrics.isAtBottom(
            topMinY: -120,
            bottomMaxY: 600,
            viewportHeight: 720
        ))
    }

    func testBlankTailAfterComposerAndApprovalResizeRequiresEndClamp() {
        XCTAssertTrue(ConversationScrollMetrics.isPastEnd(
            topMinY: -120,
            bottomMaxY: 600,
            viewportHeight: 720
        ))
    }

    func testShortTranscriptDoesNotTriggerEndClamp() {
        XCTAssertFalse(ConversationScrollMetrics.isPastEnd(
            topMinY: 0,
            bottomMaxY: 600,
            viewportHeight: 720
        ))
    }

    func testContentStillReachingViewportBottomDoesNotTriggerEndClamp() {
        XCTAssertFalse(ConversationScrollMetrics.isPastEnd(
            topMinY: -120,
            bottomMaxY: 780,
            viewportHeight: 720
        ))
    }

    func testStreamingPresentationCadenceBacksOffForLongResponses() {
        XCTAssertEqual(
            ConversationStreamingPresentationPolicy.flushIntervalMilliseconds(textLength: 100),
            80
        )
        XCTAssertEqual(
            ConversationStreamingPresentationPolicy.flushIntervalMilliseconds(textLength: 4_000),
            120
        )
        XCTAssertEqual(
            ConversationStreamingPresentationPolicy.flushIntervalMilliseconds(textLength: 12_000),
            180
        )
        XCTAssertEqual(
            ConversationStreamingPresentationPolicy.flushIntervalMilliseconds(textLength: 30_000),
            250
        )
    }

    func testScrolledUpPastToleranceIsNotAtBottom() {
        XCTAssertFalse(ConversationScrollMetrics.isAtBottom(bottomMaxY: 720 + ConversationScrollMetrics.atBottomTolerance + 1, viewportHeight: 720))
    }

}
