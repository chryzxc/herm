import Foundation
import Testing

@testable import Herm

struct SessionActivityInspectorTests {
    @Test func ordinaryTextDoesNotInvalidateExecutionInputsAndBotIDsStayStable() {
        let id = UUID()
        let first = ChatMessage(id: id, role: .hermes, text: "Hello")
        let delta = ChatMessage(id: id, role: .hermes, text: "Hello again")
        #expect(
            SessionActivityInspectorPresentation.transcript([first], originSessionID: "s")
                == SessionActivityInspectorPresentation.transcript([delta], originSessionID: "s"))
        let bot = ChatMessage(id: id, role: .hermes, text: "Report", botProfileID: "luna")
        let one = SessionActivityInspectorPresentation.transcript([bot], originSessionID: "s")
        let two = SessionActivityInspectorPresentation.transcript([bot], originSessionID: "s")
        #expect(one == two)
        #expect(one.first?.botReply?.id == "message:\(id)")
    }

    @Test func emptySessionScopeCannotLeakBotRecordsAndKnownResultsAreDeduplicated() {
        let record = BotActivityRecord(
            id: "dispatch", originSessionID: "s", botID: "luna", botName: "Luna", summary: "Review",
            state: .completed, result: "Report")
        let transcript = SessionActivityInspectorPresentation.transcript(
            [
                ChatMessage(role: .hermes, text: "Report", botProfileID: "luna")
            ], originSessionID: "s")
        #expect(
            SessionActivityInspectorPresentation.scopedBots(
                records: [record], transcript: transcript, sessionIDs: []
            ).isEmpty)
        #expect(
            SessionActivityInspectorPresentation.scopedBots(
                records: [record], transcript: transcript, sessionIDs: ["s"]
            ).map(\.id) == ["dispatch"])
    }

    @Test func liveToolCompletionReplacesRestoredRunningCopy() {
        let started = Date(timeIntervalSince1970: 10)
        let running = ActiveToolCall(
            id: "t", name: "read", input: "file", context: "file", startedAt: started, result: nil, isComplete: false)
        var completed = running
        completed.isComplete = true
        completed.result = "done"
        completed.completedAt = Date(timeIntervalSince1970: 20)
        let transcript = SessionActivityInspectorPresentation.transcript(
            [
                ChatMessage(role: .hermes, text: "", activity: [running])
            ], originSessionID: "s")
        let calls = SessionActivityInspectorPresentation.calls(
            transcript: transcript, live: [completed])
        #expect(calls.count == 1)
        #expect(calls.first?.isComplete == true)
        #expect(calls.first?.result == "done")
    }

    @Test @MainActor func projectionIgnoresTextUpdatesAndSwitchesSessionWithoutLeaks() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "activity-inspector-\(UUID()).json")
        let model = DockModel(
            sessionAgentStateFileURL: url.appendingPathExtension("agents"), initialSessionID: "one",
            botActivityFileURL: url)
        let control = ControlCenterModel()
        let inspector = SessionActivityInspectorModel()
        model.messages = [ChatMessage(role: .hermes, text: "Hello")]
        model.backgroundTasks = [
            HermesBackgroundTask(
                id: "bg", parentSessionID: "one", prompt: "Review", kind: .review, status: .running,
                startedAt: .now)
        ]
        inspector.update(model: model, control: control, sessionID: "one")
        let count = inspector.projectionCount
        model.messages = [ChatMessage(role: .hermes, text: "Hello again")]
        inspector.update(model: model, control: control, sessionID: "one")
        #expect(inspector.projectionCount == count)
        #expect(inspector.snapshot.work.map(\.id) == ["background:bg"])
        model.sessionID = "two"
        model.sessionStorageID = "two"
        model.kanbanAttributionSessionID = "two"
        inspector.update(model: model, control: control, sessionID: "two")
        #expect(inspector.snapshot.timeline.isEmpty)
        #expect(inspector.snapshot.work.isEmpty)
    }

    @Test func historyFiltersKeepUnknownStatusesOnlyInAllAndSearchDetails() {
        let row = SessionActivityOverviewPresentation.TimelineRow(
            id: "r", source: .bot, title: "Review", status: "paused_by_runtime", actor: "Luna",
            timestamp: nil, detail: "Check parser.swift", diffPreview: nil,
            durationSeconds: nil, startedAt: nil, completedAt: nil
        )
        #expect(SessionActivityInspectorPresentation.Filter(query: "parser", source: .bot).matches(row))
        #expect(!SessionActivityInspectorPresentation.Filter(source: .session).matches(row))
        #expect(!SessionActivityInspectorPresentation.Filter(status: .active).matches(row))
        #expect(!SessionActivityInspectorPresentation.Filter(status: .finished).matches(row))
    }
    @Test func completedBotResultsRemainInspectableAndDifferentBotsAreNotMerged() {
        let at = Date(timeIntervalSince1970: 20)
        let record = BotActivityRecord(id: "dispatch", originSessionID: "s", botID: "luna", botName: "Luna", summary: "Review", state: .completed, updatedAt: at, result: "Report")
        let transcript = SessionActivityInspectorPresentation.transcript([
            ChatMessage(role: .hermes, text: "Report", botProfileID: "forge")
        ], originSessionID: "s")
        let records = SessionActivityInspectorPresentation.scopedBots(records: [record], transcript: transcript, sessionIDs: ["s"])
        let snapshot = SessionActivityOverviewPresentation.makeSnapshot(
            agentSnapshot: AgentPresentationSnapshot(displayedSubagents: [], pipeline: [], activityCountsByAgentID: [:], activeAgentIDs: [], revision: 0),
            botRecords: records, kanbanTasks: []
        )
        #expect(snapshot.timeline.count == 2)
        #expect(snapshot.timeline.allSatisfy { $0.detail == "Report" })
        #expect(snapshot.timeline.first { $0.id == "bot:dispatch" }?.completedAt == at)
    }

    @Test @MainActor func longHistoryDoesNotReprojectForTextAndActiveCardsAndErrorsStaySearchable() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("activity-long-\(UUID()).json")
        let model = DockModel(sessionAgentStateFileURL: url.appendingPathExtension("agents"), initialSessionID: "s", botActivityFileURL: url)
        let control = ControlCenterModel()
        let inspector = SessionActivityInspectorModel()
        let calls = (0..<3_000).map { index in
            ActiveToolCall(id: "call-\(index)", name: "read", input: "File \(index)", context: "file", startedAt: Date(timeIntervalSince1970: Double(index)), result: "Read", isComplete: true)
        }
        let id = UUID()
        model.messages = [ChatMessage(id: id, role: .hermes, text: "First", activity: calls)]
        control.sessionKanbanSessionID = "s"
        control.sessionKanbanTasks = [KanbanTaskSummary(id: "card", title: "Ship", status: "running", detail: nil, priority: nil, assignee: nil, latestEventAt: .now)]
        inspector.update(model: model, control: control, sessionID: "s")
        #expect(inspector.filteredHistory.count == 3_001)
        let count = inspector.projectionCount
        for index in 0..<10 {
            model.messages = [ChatMessage(id: id, role: .hermes, text: "Delta \(index)", activity: calls)]
            inspector.update(model: model, control: control, sessionID: "s")
        }
        #expect(inspector.projectionCount == count)
        inspector.filter(.init(source: .kanban, status: .active))
        #expect(inspector.filteredHistory.map(\.title) == ["Ship"])
        model.messages.append(ChatMessage(role: .hermes, text: "Connection unavailable", isError: true))
        inspector.update(model: model, control: control, sessionID: "s")
        inspector.filter(.init(query: "Connection", status: .attention))
        #expect(inspector.filteredHistory.map(\.title) == ["Session error"])
        control.sessionKanbanSessionID = "another"
        inspector.update(model: model, control: control, sessionID: "s")
        inspector.filter(.init(source: .kanban))
        #expect(inspector.filteredHistory.isEmpty)
    }

}
