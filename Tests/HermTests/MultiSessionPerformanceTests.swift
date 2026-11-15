import Combine
import Foundation
import Testing

@testable import Herm

@MainActor
struct MultiSessionPerformanceTests {
    @Test func boardResolutionCachesPerSessionAndExpiresMisses() async {
        let control = ControlCenterModel()
        let a = KanbanTaskSummary(
            id: "same", boardSlug: "board-a", title: "A", status: "", detail: nil, priority: nil,
            assignee: nil, sessionID: "session-a")
        let b = KanbanTaskSummary(
            id: "same", boardSlug: "board-b", title: "B", status: "", detail: nil, priority: nil,
            assignee: nil, sessionID: "session-b")
        let keyA = SessionTaskBoardKey(taskID: "same", sessionIDs: ["session-a"])
        let keyB = SessionTaskBoardKey(taskID: "same", sessionIDs: ["session-b"])
        let missing = SessionTaskBoardKey(taskID: "missing", sessionIDs: ["session-a"])
        var reads = 0
        let load: @MainActor () async -> [KanbanTaskSummary]? = {
            reads += 1
            return [a, b]
        }
        for _ in 0..<4 {
            #expect(await control.resolveSessionTaskBoard(keyA, load: load) == "board-a")
        }
        #expect(reads == 1)
        #expect(await control.resolveSessionTaskBoard(keyB, load: load) == "board-b")
        #expect(reads == 2)
        #expect(await control.resolveSessionTaskBoard(missing, load: load) == nil)
        #expect(await control.resolveSessionTaskBoard(missing, load: load) == nil)
        #expect(reads == 3)
        control.sessionTaskBoards[missing] = SessionTaskBoardCacheEntry(board: nil, expiresAt: .distantPast)
        #expect(await control.resolveSessionTaskBoard(missing, load: load) == nil)
        #expect(reads == 4)
        control.sessionTaskBoards[keyA] = nil
        #expect(await control.resolveSessionTaskBoard(keyA, load: load) == "board-a")
        #expect(reads == 5)
    }

    @Test func concurrentBoardResolutionSharesInventory() async {
        let control = ControlCenterModel()
        let task = KanbanTaskSummary(
            id: "task", boardSlug: "board", title: "Task", status: "", detail: nil, priority: nil,
            assignee: nil, sessionID: "session")
        var reads = 0
        let load: @MainActor () async -> [KanbanTaskSummary]? = {
            reads += 1
            try? await Task.sleep(for: .milliseconds(100))
            return [task]
        }
        let first = Task { @MainActor in
            await control.resolveSessionTaskBoard(.init(taskID: "task", sessionIDs: ["session"]), load: load)
        }
        let second = Task { @MainActor in
            await control.resolveSessionTaskBoard(.init(taskID: "other", sessionIDs: ["session"]), load: load)
        }
        let results = await (first.value, second.value)
        #expect(results.0 == "board")
        #expect(results.1 == nil)
        #expect(reads == 1)
    }

    @Test func boardlessDetailsResolveAgainstOriginSession() {
        let a = KanbanTaskSummary(
            id: "same", boardSlug: "board-a", title: "A", status: "", detail: nil, priority: nil,
            assignee: nil, sessionID: "session-a")
        let b = KanbanTaskSummary(
            id: "same", boardSlug: "board-b", title: "B", status: "", detail: nil, priority: nil,
            assignee: nil, sessionID: "session-b")
        #expect(
            ControlCenterModel.sessionTaskBoard(taskID: "same", sessionIDs: ["session-a"], tasks: [a, b]) == "board-a")
        #expect(
            ControlCenterModel.sessionTaskBoard(taskID: "same", sessionIDs: ["session-b"], tasks: [a, b]) == "board-b")
        #expect(ControlCenterModel.sessionTaskBoard(taskID: "same", sessionIDs: [], tasks: [a, b]) == nil)
    }

    @Test func backgroundToolBurstsDoNotInvalidateTheOpenConversation() {
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("multi-session-\(UUID().uuidString).json"),
            initialSessionID: "open-session"
        )
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }

        for index in 0..<100 {
            model.receiveGatewayEvent(
                "tool.call",
                params: [
                    "session_id": "background-\(index % 5)",
                    "payload": ["name": "terminal", "args": ["command": "echo \(index)"]],
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
