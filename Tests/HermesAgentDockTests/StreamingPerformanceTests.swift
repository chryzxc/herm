import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct StreamingPerformanceTests {
    @Test func streamedDeltasPublishExactTextOnlyAtCompletionBoundary() {
        let model = DockModel(sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("stream-(UUID().uuidString).json"))
        model.receiveGatewayEvent("message.start", params: ["payload": ["model": "test"]])

        let parts = (0..<10_000).map { index in index.isMultiple(of: 2) ? "é" : " (index % 10)" }
        for part in parts {
            model.receiveGatewayEvent("message.delta", params: ["payload": ["delta": part]])
        }

        #expect(model.recentEvents.allSatisfy { $0.type != "message.delta" })
        model.receiveGatewayEvent("message.complete", params: ["payload": [:]])
        #expect(model.messages.last?.text == parts.joined())
        #expect(model.conversationActivityPhase == .idle)
    }

    @Test func staleScheduledStreamingFlushCannotChangeAReplacedConversation() async {
        let model = DockModel(sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("stream-(UUID().uuidString).json"))
        model.receiveGatewayEvent("message.start", params: ["payload": [:]])
        model.receiveGatewayEvent("message.delta", params: ["payload": ["delta": "old"]])
        model.newChat()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.messages.isEmpty)
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
