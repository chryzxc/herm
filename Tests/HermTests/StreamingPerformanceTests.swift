import AppKit
import Combine
import Foundation
import Testing

@testable import Herm

@MainActor
private final class StreamingAttachmentRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var requests: [(method: String, params: [String: Any])] = []
    var redirectStatus = "redirected"

    func connect() async throws {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        if method == "session.redirect" { return ["status": redirectStatus] }
        return [:]
    }

    func close() {}
}

@MainActor
struct StreamingPerformanceTests {
    @Test func midTurnTextRedirectsAndLandsAsPlainUserMessageBelowStreamedOutput() async throws {
        let client = StreamingAttachmentRPCClient()
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "redirect-\(UUID().uuidString).json"),
            initialSessionID: "redirect-session",
            rpcClient: client
        )
        model.status = .working
        model.isSending = true
        model.receiveGatewayEvent("message.start", params: ["session_id": "redirect-session", "payload": [:]])
        model.receiveGatewayEvent(
            "message.delta", params: ["session_id": "redirect-session", "payload": ["delta": "Before"]])
        model.draft = "Check the logs instead"

        model.submitComposerInput()

        #expect(model.draft.isEmpty)
        #expect(model.queuedPrompts.isEmpty)
        #expect(model.messages.map(\.role) == [.hermes, .user, .hermes])
        #expect(model.messages[0].text == "Before")
        #expect(model.messages[1].text == "Check the logs instead")
        #expect(model.messages[1].isSteering == false)
        #expect(model.streamingMessageIDForPresentation == model.messages[2].id)

        let deadline = Date().addingTimeInterval(2)
        while !client.requests.contains(where: { $0.method == "session.redirect" }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.messages.count == 3)
        #expect(model.queuedPrompts.isEmpty)
    }

    @Test func rejectedRedirectQueuesTextAndSendsItWhenTheTurnSettles() async throws {
        let client = StreamingAttachmentRPCClient()
        client.redirectStatus = "rejected"
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "redirect-\(UUID().uuidString).json"),
            initialSessionID: "redirect-reject-session",
            rpcClient: client
        )
        model.status = .working
        model.isSending = true
        model.draft = "Also update the docs"

        model.submitComposerInput()
        let deadline = Date().addingTimeInterval(2)
        while model.queuedPrompts.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.queuedPrompts.map(\.text) == ["Also update the docs"])
        #expect(!model.messages.contains { $0.text == "Also update the docs" })

        model.receiveGatewayEvent(
            "message.complete", params: ["session_id": "redirect-reject-session", "payload": ["text": "Done"]])

        #expect(model.queuedPrompts.isEmpty)
        #expect(model.isSending)
        #expect(model.messages.last?.text == "Also update the docs")
    }

    @Test func attachmentsDuringATurnStayWithTheirQueuedTextAndCanBeRemoved() {
        let model = DockModel(initialSessionID: "queue-image-session")
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "queue-image-\(UUID().uuidString).png")
        model.pendingImages = [ImageAttachment(image: NSImage(size: NSSize(width: 2, height: 2)), fileURL: imageURL)]
        model.draft = "Use this image"
        model.status = .working
        model.isSending = true

        model.submitComposerInput()

        #expect(model.draft.isEmpty)
        #expect(model.pendingImages.isEmpty)
        #expect(!model.messages.contains { $0.text == "Use this image" })
        #expect(model.queuedPrompts.count == 1)
        #expect(model.queuedPrompts.first?.text == "Use this image")
        #expect(model.queuedPrompts.first?.images.count == 1)

        model.removeQueuedPrompt(model.queuedPrompts[0].id)
        #expect(model.queuedPrompts.isEmpty)
    }

    @Test func toolEventOfATurnAlreadyRunningAtAttachOpensTheLiveRow() {
        let model = DockModel(initialSessionID: "attached-mid-turn")
        model.messages = [ChatMessage(role: .user, text: "commit it")]
        model.receiveGatewayEvent(
            "tool.start",
            params: [
                "session_id": "attached-mid-turn",
                "payload": ["id": "t1", "name": "patch"],
            ])

        #expect(model.status == .working)
        #expect(model.messages.last?.role == .hermes)
        #expect(model.streamingMessageIDForPresentation == model.messages.last?.id)
        #expect(model.activeToolCalls.map(\.name) == ["patch"])
        model.receiveGatewayEvent("message.start", params: ["session_id": "attached-mid-turn", "payload": [:]])
        #expect(model.messages.count == 2)
    }

    @Test func responseStartAfterAcceptedSteeringCannotReuseOutgoingImageRow() {
        let model = DockModel(initialSessionID: "steering-boundary-session")
        let image = NSImage(size: NSSize(width: 2, height: 2))
        model.messages = [ChatMessage(role: .hermes, text: "Earlier response")]
        model.receiveGatewayEvent(
            "message.start",
            params: [
                "session_id": "steering-boundary-session",
                "payload": [:],
            ])
        model.messages.append(ChatMessage(role: .user, text: "Use this image", image: image))
        model.receiveGatewayEvent(
            "message.complete",
            params: [
                "session_id": "steering-boundary-session",
                "payload": [:],
            ])
        model.receiveGatewayEvent(
            "message.start",
            params: [
                "session_id": "steering-boundary-session",
                "payload": [:],
            ])

        #expect(model.messages.last?.role == .hermes)
        #expect(model.messages.dropLast().last?.images.count == 1)
        #expect(model.streamingMessageIDForPresentation == model.messages.last?.id)
    }

    @Test func duplicateResponseStartAfterAcceptedSteeringKeepsActiveStreamBoundary() {
        let model = DockModel(initialSessionID: "steering-duplicate-start-session")
        model.messages = [ChatMessage(role: .hermes, text: "Earlier response")]

        model.receiveGatewayEvent(
            "message.start",
            params: [
                "session_id": "steering-duplicate-start-session",
                "payload": [:],
            ])
        let activeResponseID = model.streamingMessageIDForPresentation
        model.messages.append(
            ChatMessage(
                role: .user,
                text: "Use this image",
                image: NSImage(size: NSSize(width: 2, height: 2)),
                isSteering: true,
                steeringStatus: "QUEUED"
            ))

        model.receiveGatewayEvent(
            "message.start",
            params: [
                "session_id": "steering-duplicate-start-session",
                "payload": [:],
            ])

        #expect(model.streamingMessageIDForPresentation == activeResponseID)
        #expect(model.messages.filter { $0.role == .hermes }.count == 2)
        #expect(model.messages.last?.isSteering == true)
        #expect(model.messages.last?.steeringStatus == "QUEUED")
        #expect(model.messages.firstIndex(where: { $0.id == activeResponseID }) ?? -1 < model.messages.count - 1)

        model.receiveGatewayEvent(
            "message.complete",
            params: [
                "session_id": "steering-duplicate-start-session",
                "payload": [:],
            ])
        model.receiveGatewayEvent(
            "message.start",
            params: [
                "session_id": "steering-duplicate-start-session",
                "payload": [:],
            ])

        #expect(model.messages.filter { $0.role == .hermes }.count == 3)
        #expect(model.streamingMessageIDForPresentation != activeResponseID)
        let newResponseIndex = model.messages.lastIndex(where: { $0.role == .hermes }) ?? -1
        let steerIndex = model.messages.firstIndex(where: { $0.isSteering }) ?? -1
        #expect(steerIndex >= 0)
        #expect(steerIndex < newResponseIndex)
    }

    @Test func sendingWithoutAnExplicitNewChatDoesNotCreateOrMutateASession() {
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "session-creation-(UUID().uuidString).json"))
        model.draft = "This must not implicitly create a session"

        model.send()

        #expect(model.sessionID == nil)
        #expect(model.messages.isEmpty)
        #expect(model.draft == "This must not implicitly create a session")
        #expect(!model.isSending)
    }

    @Test func streamedDeltasDoNotPublishDockModelChanges() {
        let sessionID = "stream-silence"
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "stream-silence-(UUID().uuidString).json"),
            initialSessionID: sessionID
        )
        var publishes = 0
        let cancellable = model.objectWillChange.sink { _ in publishes += 1 }
        model.receiveGatewayEvent("message.start", params: ["session_id": sessionID, "payload": ["model": "test"]])
        let publishesAfterStart = publishes

        for index in 0..<1_000 {
            model.receiveGatewayEvent(
                "message.delta", params: ["session_id": sessionID, "payload": ["delta": " \(index)"]])
        }

        #expect(publishes == publishesAfterStart)
        withExtendedLifetime(cancellable) {}
    }

    @Test func visionErrorSplitAcrossFlushesIsStillDetected() {
        let sessionID = "vision-split"
        let model = DockModel(initialSessionID: sessionID)
        model.receiveGatewayEvent("message.start", params: ["session_id": sessionID, "payload": [:]])
        model.receiveGatewayEvent(
            "message.delta", params: ["session_id": sessionID, "payload": ["delta": "Error: model does not sup"]])
        model.flushStreamingMessage()
        #expect(!model.streamingMessageIsVisionNotice)
        model.receiveGatewayEvent(
            "message.delta", params: ["session_id": sessionID, "payload": ["delta": "port images."]])
        model.flushStreamingMessage()
        #expect(model.streamingMessageIsVisionNotice)
    }

    @Test func streamedDeltasPublishExactTextOnlyAtCompletionBoundary() {
        let sessionID = "stream-session"
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "stream-(UUID().uuidString).json"),
            initialSessionID: sessionID
        )
        model.receiveGatewayEvent("message.start", params: ["session_id": sessionID, "payload": ["model": "test"]])

        let parts = (0..<10_000).map { index in index.isMultiple(of: 2) ? "é" : " (index % 10)" }
        for part in parts {
            model.receiveGatewayEvent("message.delta", params: ["session_id": sessionID, "payload": ["delta": part]])
        }

        #expect(model.recentEvents.allSatisfy { $0.type != "message.delta" })
        model.receiveGatewayEvent("message.complete", params: ["session_id": sessionID, "payload": [:]])
        #expect(model.messages.last?.text == parts.joined())
        #expect(model.conversationActivityPhase == .idle)
    }

    @Test func completionErrorAppearsInTranscriptAndReleasesSendingState() {
        let sessionID = "quota-session"
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "quota-(UUID().uuidString).json"),
            initialSessionID: sessionID
        )
        model.receiveGatewayEvent("message.start", params: ["session_id": sessionID, "payload": [:]])
        model.receiveGatewayEvent(
            "message.complete",
            params: [
                "session_id": sessionID,
                "payload": ["error": "HTTP 429: The usage limit has been reached"],
            ])

        #expect(model.messages.count == 1)
        #expect(model.messages.last?.isError == true)
        #expect(model.messages.last?.text == "HTTP 429: The usage limit has been reached")
        #expect(model.status == .idle)
        #expect(!model.isSending)
    }

    @Test func structuredCompletionErrorUsesNestedMessage() {
        #expect(
            DockModel.messageCompletionError(from: [
                "error": ["message": "The usage limit has been reached", "code": "rate_limit"]
            ]) == "The usage limit has been reached")
    }

    @Test func staleScheduledStreamingFlushCannotChangeAReplacedConversation() async {
        let sessionID = "stream-session"
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "stream-(UUID().uuidString).json"),
            initialSessionID: sessionID
        )
        model.receiveGatewayEvent("message.start", params: ["session_id": sessionID, "payload": [:]])
        model.receiveGatewayEvent("message.delta", params: ["session_id": sessionID, "payload": ["delta": "old"]])
        model.newChat()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.messages.isEmpty)
    }

    @Test func streamedDeltasDoNotMutateTheTranscriptArrayBeforeCompletion() async {
        let sessionID = "stream-isolated"
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "stream-(UUID().uuidString).json"),
            initialSessionID: sessionID
        )
        model.receiveGatewayEvent("message.start", params: ["session_id": sessionID, "payload": [:]])
        let placeholderMessage = model.messages.last

        for part in ["Hel", "lo ", "stream", "ing"] {
            model.receiveGatewayEvent("message.delta", params: ["session_id": sessionID, "payload": ["delta": part]])
        }

        // The transcript array must stay untouched per delta so DockModel
        // observers are not re-rendered at the streaming cadence.
        #expect(model.messages.last?.text == "")
        #expect(model.messages.last?.id == placeholderMessage?.id)
        for _ in 0..<50 where !model.streamingText.text.contains("streaming") {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.streamingText.text == "Hello streaming")

        model.receiveGatewayEvent("message.complete", params: ["session_id": sessionID, "payload": [:]])
        #expect(model.messages.last?.text == "Hello streaming")
        #expect(model.streamingText.text.isEmpty)
    }

    @Test func reasoningDeltasCoalesceIntoTheReasoningState() async {
        let sessionID = "reason-session"
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "reason-(UUID().uuidString).json"),
            initialSessionID: sessionID
        )
        model.receiveGatewayEvent("reasoning.start", params: ["session_id": sessionID, "payload": [:]])
        for part in ["plan", " ", "step"] {
            model.receiveGatewayEvent("reasoning.delta", params: ["session_id": sessionID, "payload": ["delta": part]])
        }
        #expect(model.reasoningState?.text.isEmpty == true)

        for _ in 0..<50 where model.reasoningState?.text != "plan step" {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.reasoningState?.text == "plan step")

        model.receiveGatewayEvent("reasoning.complete", params: ["session_id": sessionID, "payload": [:]])
        #expect(model.reasoningState?.isComplete == true)
        #expect(model.reasoningState?.text == "plan step")
    }

    @Test func reasoningFlushesLeaveTheThinkingStepUnchangedUntilItCompletes() async {
        let sessionID = "thinking-step"
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "thinking-\(UUID().uuidString).json"),
            initialSessionID: sessionID
        )
        model.receiveGatewayEvent("message.start", params: ["session_id": sessionID, "payload": [:]])
        model.receiveGatewayEvent("reasoning.delta", params: ["session_id": sessionID, "payload": ["delta": "plan"]])
        for _ in 0..<50 where model.liveReasoning.text != "plan" {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let opened = model.streamingTurnActivity
        #expect(opened.count == 1)

        model.receiveGatewayEvent("reasoning.delta", params: ["session_id": sessionID, "payload": ["delta": " step"]])
        for _ in 0..<50 where model.liveReasoning.text != "plan step" {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // TurnActivityView's equality holds across flushes; only the live leaf sees the text.
        #expect(model.liveReasoning.text == "plan step")
        #expect(model.streamingTurnActivity == opened)

        model.receiveGatewayEvent("reasoning.complete", params: ["session_id": sessionID, "payload": [:]])
        #expect(model.streamingTurnActivity.first?.isComplete == true)
        #expect(model.streamingTurnActivity.first?.result == "plan step")
    }

    @Test func agentPresentationSnapshotIsSharedAndStableAcrossConsumers() {
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "agents-\(UUID().uuidString).json"))
        model.activeSubagents = (0..<8).map { index in
            HermesSubagent(
                id: "agent-\(index)",
                parentID: index == 1 ? "agent-0" : nil,
                goal: "Task \(index)",
                status: index < 4 ? "running" : "complete",
                toolCount: index
            )
        }
        let first = model.agentPresentationSnapshot
        let second = model.agentPresentationSnapshot
        #expect(first == second)
        #expect(first.displayedSubagents.count == 8)
        #expect(first.activeAgentIDs.count == 4)
    }

    @Test func markdownBlocksMatchAcrossStreamingBoundaries() {
        let streaming = StreamingText()
        let source =
            "# Heading\n\n" + String(repeating: "**bold** and `code` words. ", count: 200)
            + "\n\n```swift\nlet value = 1\n\n" + String(repeating: "// code\n", count: 700)
            + "```\n\n> Quote\n\n- Item with *emphasis*"
        var remainder = source[...]
        while !remainder.isEmpty {
            let delta = remainder.prefix(37)
            streaming.appendPresentation(String(delta))
            remainder = remainder.dropFirst(delta.count)
        }
        #expect(streaming.chunks.map(\.text).joined() == source)
        let streamed = streaming.chunks.flatMap { MarkdownMessageView.renderBlocks(for: $0.text) }
        #expect(streamed == MarkdownMessageView.renderBlocks(for: source))
    }

    @Test func blankLinesInsideAnOpenFenceNeverPromoteCodeToProse() {
        for marker in ["```", "~~~~", "````"] {
            let streaming = StreamingText()
            let source = marker + "swift\n" + String(repeating: "let x = 1\n\n", count: 1_000)
            streaming.appendPresentation(source)
            #expect(streaming.chunks.count > 1)
            #expect(
                streaming.chunks.dropFirst().allSatisfy { chunk in
                    if case .fencedCode(let chunkMarker, let length, let language) = chunk.context {
                        return String(repeating: String(chunkMarker), count: length) == String(marker.prefix(length))
                            && language == "swift"
                    }
                    return false
                })
            #expect(MarkdownMessageView.codeBlockLanguages(in: source).first == "swift")
            streaming.appendPresentation("\n" + marker + "\n\nDone")
            #expect(streaming.chunks.count == 2)
            #expect(streaming.chunks.map(\.text).joined() == streaming.text)
        }
    }

    @Test func shorterFenceAndBackticksWithTextRemainCode() {
        let source = "````swift\n```\n```not a closing fence\nlet value = 1\n````"
        #expect(
            MarkdownMessageView.renderBlocks(for: source) == [
                .code("```\n```not a closing fence\nlet value = 1", language: "swift")
            ])
    }

    @Test func incompleteMarkdownIsRenderedWithoutChangingSource() {
        let streaming = StreamingText()
        streaming.appendPresentation("# Title\n\n**complete** and **partial")
        #expect(
            MarkdownMessageView.renderBlocks(for: streaming.chunks[0].text)
                == MarkdownMessageView.renderBlocks(for: streaming.text))
        streaming.appendPresentation(" bold**")
        guard case .paragraph(let text) = MarkdownMessageView.renderBlocks(for: streaming.text).last else {
            Issue.record("Expected a Markdown paragraph")
            return
        }
        #expect(String(text.characters) == "complete and partial bold")
        #expect(streaming.text.hasSuffix("**partial bold**"))
    }

    @Test func smallPresentationAppendRemainsOneMutableTail() {
        let streaming = StreamingText()
        streaming.appendPresentation("short response")

        #expect(streaming.chunks.count == 1)
        #expect(streaming.chunks[0].isMutableTail)
        #expect(streaming.chunks.map(\.text).joined() == streaming.text)
    }

    @Test func paragraphBoundaryPromotesStablePrefixWithoutChangingText() {
        let streaming = StreamingText()
        let prefix = String(repeating: "a", count: 4_096)
        let value = prefix + "\n\n" + String(repeating: "b", count: 5_000)
        streaming.appendPresentation(value)

        #expect(streaming.chunks.count == 2)
        #expect(streaming.chunks[0].isMutableTail == false)
        #expect(streaming.chunks[1].isMutableTail)
        #expect(streaming.chunks.map(\.text).joined() == value)
    }

    @Test func stableChunksRemainStableWhenTailGrows() {
        let streaming = StreamingText()
        streaming.appendPresentation(
            String(repeating: "a", count: 4_096) + "\n\n" + String(repeating: "b", count: 5_000)
        )
        let stable = streaming.chunks[0]
        let oldTailRevision = streaming.chunks[1].revision

        streaming.appendPresentation(" and more")

        #expect(streaming.chunks[0] == stable)
        #expect(streaming.chunks[1].revision > oldTailRevision)
        #expect(streaming.chunks.map(\.text).joined() == streaming.text)
    }

    @Test func largeTextWithoutParagraphBoundaryStaysBoundedAndExact() {
        let streaming = StreamingText()
        let value = String(repeating: "a", count: 20_000)
        streaming.appendPresentation(value)

        #expect(streaming.chunks.count > 1)
        #expect(streaming.chunks.last?.isMutableTail == true)
        #expect(streaming.chunks.last?.text.utf8.count ?? .max <= StreamingChunkPolicy.maxMutableTailBytes)
        #expect(streaming.text == value)
        #expect(streaming.chunks.map(\.text).joined() == value)
    }

    @Test func unicodePromotionNeverSplitsACharacter() {
        let streaming = StreamingText()
        let value = String(repeating: "🙂", count: 8_000)
        streaming.appendPresentation(value)

        #expect(streaming.text == value)
        #expect(streaming.chunks.map(\.text).joined() == value)
        #expect(streaming.chunks.last?.text.utf8.count ?? .max <= StreamingChunkPolicy.maxMutableTailBytes)
    }

    @Test func promotedContinuationKeepsTheOriginalFenceMarker() {
        let streaming = StreamingText()
        let prefix =
            "````swift\n"
            + String(repeating: "``` literal code\nlet value = 1\n", count: 500)
        let source = prefix + "````\n"
        streaming.appendPresentation(prefix)
        streaming.appendPresentation("````\n")

        #expect(streaming.text == source)
        #expect(streaming.chunks.map(\.text).joined() == source)
        #expect(
            streaming.chunks.contains { chunk in
                if case .fencedCode(let marker, let length, let language) = chunk.context {
                    return marker == "`" && length == 4 && language == "swift"
                }
                return false
            })
    }

    @Test func replacementAndClearNeverReuseRenderedChunkRevisions() {
        let streaming = StreamingText()
        let prefix = String(repeating: "a", count: 4_096) + "\n\n"
        streaming.appendPresentation(prefix + String(repeating: "b", count: 5_000))
        let old = streaming.chunks
        streaming.replacePresentation(with: prefix.uppercased() + String(repeating: "c", count: 5_000))
        #expect(streaming.chunks[0] != old[0])
        #expect(streaming.chunks[1] != old[1])
        let previousTail = streaming.chunks.last
        streaming.clearPresentation()
        streaming.appendPresentation("different response")
        #expect(streaming.chunks.last != previousTail)
    }

    @Test func completionSnapshotSurvivesLiveRowHandoff() {
        let streaming = StreamingText()
        let source = String(repeating: "A completed response. ", count: 600)
        streaming.appendPresentation(source)
        streaming.retainCompletionPresentation()
        let expected = streaming.chunks
        streaming.clearLivePresentation()

        #expect(streaming.text.isEmpty)
        #expect(streaming.chunks.isEmpty)
        #expect(streaming.completionChunks(matching: source) == expected)
        #expect(streaming.completionChunks(matching: "different") == nil)
    }

    @Test func completionReconciliationAppendsOnlyTheMissingSuffix() {
        let streaming = StreamingText()
        let prefix = String(repeating: "stable ", count: 1_400)
        streaming.appendPresentation(prefix)
        let stableIDs = streaming.chunks.filter { !$0.isMutableTail }.map(\.id)

        streaming.reconcilePresentation(with: prefix + "final")

        #expect(streaming.text == prefix + "final")
        #expect(streaming.chunks.filter { !$0.isMutableTail }.map(\.id) == stableIDs)
    }

    @Test func replacementResetsPreviousChunks() {
        let streaming = StreamingText()
        streaming.appendPresentation(String(repeating: "a", count: 4_096) + "\n\nold")

        streaming.replacePresentation(with: "replacement")

        #expect(streaming.chunks.count == 1)
        #expect(streaming.chunks[0].isMutableTail)
        #expect(streaming.chunks[0].text == "replacement")
        #expect(streaming.text == "replacement")
    }

    @Test func clearPresentationResetsCanonicalTextAndChunks() {
        let streaming = StreamingText()
        streaming.appendPresentation("response")

        streaming.clearPresentation()

        #expect(streaming.text.isEmpty)
        #expect(streaming.chunks.isEmpty)
    }

    @Test func longUnfinishedInlineSpansSplitAtTheLastSafeWhitespace() throws {
        for opening in ["`", "``", "[", "*", "_"] {
            let prefix = "Safe **bold** and `code` words. "
            let source = prefix + opening + String(repeating: "unfinished words ", count: 700)
            let boundary = try #require(StreamingChunkPolicy.promotionBoundary(in: source))
            #expect(String(source[..<boundary]) == prefix)
        }
    }

    @Test func closedAndEscapedInlineSpansRetainWhitespaceBoundaries() throws {
        for prefix in ["`closed code` ", "[closed link](url) ", "\\*escaped ", "\\ whitespace ", "👩🏽‍💻 café "] {
            let source = prefix + "`" + String(repeating: "unfinished words ", count: 700)
            let boundary = try #require(StreamingChunkPolicy.promotionBoundary(in: source))
            #expect(String(source[..<boundary]) == prefix)
        }
        let source = "`" + String(repeating: "unfinished words ", count: 1_000)
        let boundary = try #require(StreamingChunkPolicy.promotionBoundary(in: source))
        #expect(source[..<boundary].utf8.count == StreamingChunkPolicy.maxMutableTailBytes)
    }

    @Test func chunkPromotionUsesStrictMutableTailThreshold() {
        let exact = String(repeating: "a", count: StreamingChunkPolicy.maxMutableTailBytes)
        #expect(StreamingChunkPolicy.promotionBoundary(in: exact) == nil)

        let promoted = exact + "\n\nmore"
        #expect(StreamingChunkPolicy.promotionBoundary(in: promoted) != nil)
    }
}
