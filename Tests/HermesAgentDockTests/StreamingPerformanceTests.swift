import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct StreamingPerformanceTests {
    @Test func sendingWithoutAnExplicitNewChatDoesNotCreateOrMutateASession() {
        let model = DockModel(sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("session-creation-(UUID().uuidString).json"))
        model.draft = "This must not implicitly create a session"

        model.send()

        #expect(model.sessionID == nil)
        #expect(model.messages.isEmpty)
        #expect(model.draft == "This must not implicitly create a session")
        #expect(!model.isSending)
    }

    @Test func streamedDeltasPublishExactTextOnlyAtCompletionBoundary() {
        let sessionID = "stream-session"
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("stream-(UUID().uuidString).json"),
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
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("quota-(UUID().uuidString).json"),
            initialSessionID: sessionID
        )
        model.receiveGatewayEvent("message.start", params: ["session_id": sessionID, "payload": [:]])
        model.receiveGatewayEvent("message.complete", params: [
            "session_id": sessionID,
            "payload": ["error": "HTTP 429: The usage limit has been reached"]
        ])

        #expect(model.messages.count == 1)
        #expect(model.messages.last?.isError == true)
        #expect(model.messages.last?.text == "HTTP 429: The usage limit has been reached")
        #expect(model.status == .idle)
        #expect(!model.isSending)
    }

    @Test func structuredCompletionErrorUsesNestedMessage() {
        #expect(DockModel.messageCompletionError(from: [
            "error": ["message": "The usage limit has been reached", "code": "rate_limit"]
        ]) == "The usage limit has been reached")
    }

    @Test func staleScheduledStreamingFlushCannotChangeAReplacedConversation() async {
        let sessionID = "stream-session"
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("stream-(UUID().uuidString).json"),
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
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("stream-(UUID().uuidString).json"),
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
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("reason-(UUID().uuidString).json"),
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

    @Test func agentPresentationSnapshotIsSharedAndStableAcrossConsumers() {
        let model = DockModel(sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString).json"))
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
}
