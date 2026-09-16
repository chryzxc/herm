import XCTest
@testable import HermesAgentDock

final class ConversationScrollMetricsTests: XCTestCase {
    func testLongTranscriptInitiallyRendersOnlyRecentExactWindow() {
        let messages = (0..<500).map { index in
            ChatMessage(role: .hermes, text: "message \(index)")
        }

        let visible = ConversationMessageWindow.visibleMessages(
            messages,
            limit: ConversationMessageWindow.initialLimit
        )

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
        XCTAssertEqual(
            ConversationMessageWindow.revealedLimit(
                currentLimit: ConversationMessageWindow.initialLimit,
                totalCount: 500
            ),
            ConversationMessageWindow.initialLimit + ConversationMessageWindow.pageSize
        )
        XCTAssertEqual(
            ConversationMessageWindow.revealedLimit(currentLimit: 420, totalCount: 500),
            420 + ConversationMessageWindow.pageSize
        )
    }

    func testSessionReplacementDropsExpandedHistoryWindow() {
        XCTAssertEqual(
            ConversationMessageWindow.limitForSessionReplacement(),
            ConversationMessageWindow.initialLimit
        )
        XCTAssertLessThan(
            ConversationMessageWindow.limitForSessionReplacement(),
            ConversationMessageWindow.revealedLimit(currentLimit: 440, totalCount: 500)
        )
    }

    func testRepinningCompactsExpandedHistory() {
        XCTAssertTrue(ConversationMessageWindow.shouldCompactAfterRepinning(
            wasAtBottom: false,
            isAtBottom: true,
            currentLimit: 120,
            totalCount: 500
        ))
        XCTAssertEqual(ConversationMessageWindow.compactedLimit(totalCount: 500), 12)
    }

    func testPinnedOrUnexpandedHistoryDoesNotCompact() {
        XCTAssertFalse(ConversationMessageWindow.shouldCompactAfterRepinning(
            wasAtBottom: true,
            isAtBottom: true,
            currentLimit: 120,
            totalCount: 500
        ))
        XCTAssertFalse(ConversationMessageWindow.shouldCompactAfterRepinning(
            wasAtBottom: false,
            isAtBottom: true,
            currentLimit: 12,
            totalCount: 500
        ))
        XCTAssertFalse(ConversationMessageWindow.shouldCompactAfterRepinning(
            wasAtBottom: false,
            isAtBottom: false,
            currentLimit: 120,
            totalCount: 500
        ))
    }

    func testCompactedLimitDoesNotExceedShortTranscript() {
        XCTAssertEqual(ConversationMessageWindow.compactedLimit(totalCount: 5), 5)
    }

    func testAppendWhileReadingEarlierPreservesVisibleStartIndex() {
        let oldCount = 500
        let oldLimit = 120
        let oldStart = oldCount - oldLimit
        let newCount = 503
        let newLimit = ConversationMessageWindow.limitAfterCountChange(
            currentLimit: oldLimit,
            oldCount: oldCount,
            newCount: newCount,
            isAtBottom: false
        )

        XCTAssertEqual(newCount - newLimit, oldStart)
    }

    func testAppendAtBottomKeepsWindowBounded() {
        XCTAssertEqual(
            ConversationMessageWindow.limitAfterCountChange(
                currentLimit: 120,
                oldCount: 500,
                newCount: 501,
                isAtBottom: true
            ),
            120
        )
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

    func testTopEdgeLoadsOnlyOneArmedPage() {
        XCTAssertTrue(ConversationMessageWindow.shouldLoadEarlier(
            topMinY: 0,
            hiddenCount: 380,
            isArmed: true
        ))
        XCTAssertFalse(ConversationMessageWindow.shouldLoadEarlier(
            topMinY: 0,
            hiddenCount: 380,
            isArmed: false
        ))
        XCTAssertFalse(ConversationMessageWindow.shouldLoadEarlier(
            topMinY: -ConversationMessageWindow.topLoadThreshold - 1,
            hiddenCount: 380,
            isArmed: true
        ))
    }

    func testTopEdgeRearmsOnlyAfterScrollingAway() {
        XCTAssertFalse(ConversationMessageWindow.shouldRearmTopTrigger(topMinY: -40))
        XCTAssertTrue(ConversationMessageWindow.shouldRearmTopTrigger(
            topMinY: -ConversationMessageWindow.topRearmDistance - 1
        ))
    }

    func testSentinelAtViewportBottomCountsAsAtBottom() {
        XCTAssertTrue(ConversationScrollMetrics.isAtBottom(bottomMaxY: 720, viewportHeight: 720))
    }

    func testTransientStreamingGrowthStaysSticky() {
        XCTAssertTrue(ConversationScrollMetrics.isAtBottom(bottomMaxY: 780, viewportHeight: 720))
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
