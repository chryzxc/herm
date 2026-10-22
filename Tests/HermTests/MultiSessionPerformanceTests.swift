import Combine
import Foundation
import Testing
@testable import Herm

@MainActor
struct MultiSessionPerformanceTests {
    @Test func backgroundToolBurstsDoNotInvalidateTheOpenConversation() {
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("multi-session-\(UUID().uuidString).json"),
            initialSessionID: "open-session"
        )
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }

        for index in 0..<100 {
            model.receiveGatewayEvent("tool.call", params: [
                "session_id": "background-\(index % 5)",
                "payload": ["name": "terminal", "args": ["command": "echo \(index)"]]
            ])
        }

        #expect(publications == 0)
        #expect(model.sessionActivityLabels.count == 5)
        #expect(model.messages.isEmpty)
        #expect(model.activeToolCalls.isEmpty)
        withExtendedLifetime(subscription) {}
    }

    @Test func activitySubscribersReceiveCurrentAliasedLabelsAndOnlyChangedValues() {
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("multi-session-\(UUID().uuidString).json"),
            initialSessionID: "open-session"
        )
        model.storageIDsByRuntimeID["runtime-background"] = "stored-background"
        let payload: [String: Any] = ["name": "terminal", "args": ["command": "echo ready"]]
        model.updateSessionActivityLabel(sessionID: "runtime-background", type: "tool.call", payload: payload)

        var snapshots: [[String: String]] = []
        let subscription = model.sessionActivityLabelChanges.sink { snapshots.append($0) }
        #expect(snapshots.count == 1)
        #expect(snapshots.first?["stored-background"]?.isEmpty == false)
        #expect(snapshots.first?["runtime-background"] == nil)

        model.updateSessionActivityLabel(sessionID: "runtime-background", type: "tool.call", payload: payload)
        #expect(snapshots.count == 1)
        model.updateSessionActivityLabel(sessionID: "runtime-background", type: "message.complete", payload: [:])
        #expect(snapshots.count == 2)
        #expect(snapshots.last == [:])
        #expect(model.sessionActivityLabels.isEmpty)
        model.updateSessionActivityLabel(sessionID: "runtime-background", type: "message.start", payload: [:])
        #expect(snapshots.count == 2)
        withExtendedLifetime(subscription) {}
    }
}
