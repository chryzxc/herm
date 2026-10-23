import Foundation
import Testing

@testable import Herm

struct SessionBotActivityTests {
    @MainActor @Test func botLiveSessionNeedsOneOpenSessionStartedAfterTheDM() {
        let sent = Date(timeIntervalSince1970: 1_000)
        let older: [String: Any] = ["id": "old", "started_at": 900.0, "ended_at": NSNull()]
        let ended: [String: Any] = ["id": "done", "started_at": 1_010.0, "ended_at": 1_020.0]
        let live: [String: Any] = ["id": "live", "started_at": 1_002.0, "ended_at": NSNull()]
        #expect(DockModel.liveBotSessionID(in: [older, ended, live], dispatchedAt: sent) == "live")
        #expect(
            DockModel.liveBotSessionID(in: [live, ["id": "twin", "started_at": 1_003.0]], dispatchedAt: sent) == nil)
        #expect(DockModel.liveBotSessionID(in: [older], dispatchedAt: sent) == nil)
    }

    @MainActor @Test func botLiveStepIsTheNewestToolCall() {
        let call = { (name: String, args: String) in
            #"[{"id": "x", "type": "function", "function": {"name": "\#(name)", "arguments": "\#(args)"}}]"#
        }
        let rows: [[String: Any]] = [
            ["id": 1, "role": "assistant", "content": "", "tool_calls": call("read_file", #"{\"path\": \"a.txt\"}"#)],
            ["id": 2, "role": "tool", "content": "{}", "tool_call_id": "x", "tool_name": "read_file"],
            [
                "id": 3, "role": "assistant", "content": "",
                "tool_calls": call("terminal", #"{\"command\": \"git diff\"}"#),
            ],
            ["id": 4, "role": "tool", "content": "{}", "tool_call_id": "x", "tool_name": "terminal"],
        ]
        #expect(
            DockModel.latestBotStep(in: rows)
                == AgentActivityPresentation.toolActivityTitle(name: "terminal", context: "git diff"))
        #expect(DockModel.latestBotStep(in: [["id": 1, "role": "user", "content": "go"]]) == nil)
    }

    @Test func activityIsSessionScopedAndNewestUpdateFirst() {
        let records = [
            BotActivityRecord(
                id: "old", originSessionID: "s1", botID: "forge", botName: "Forge", summary: "Old", state: .completed,
                createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 20)),
            BotActivityRecord(
                id: "other", originSessionID: "s2", botID: "cypher", botName: "Cypher", summary: "Other",
                state: .working, createdAt: Date(timeIntervalSince1970: 30), updatedAt: Date(timeIntervalSince1970: 40)),
            BotActivityRecord(
                id: "new", originSessionID: "s1", botID: "forge", botName: "Forge", summary: "New", state: .working,
                createdAt: Date(timeIntervalSince1970: 50), updatedAt: Date(timeIntervalSince1970: 60)),
        ]

        let snapshot = SessionBotActivityPresentation.snapshot(records: records, sessionID: "s1")

        #expect(snapshot.list.map(\.id) == ["new", "old"])
        #expect(snapshot.kanban[.working]?.map(\.id) == ["new"])
        #expect(snapshot.kanban[.completed]?.map(\.id) == ["old"])
    }

    @Test func allLifecycleStatesHaveKanbanColumnsAndStatusIsTextual() {
        let states = BotActivityState.allCases
        let records = states.enumerated().map { index, state in
            BotActivityRecord(
                id: "r\(index)", originSessionID: "s1", botID: "forge", botName: "Forge", summary: state.label,
                state: state, createdAt: .distantPast, updatedAt: Date(timeIntervalSince1970: Double(index)))
        }

        let snapshot = SessionBotActivityPresentation.snapshot(records: records, sessionID: "s1")

        #expect(BotActivityState.allCases.count == 6)
        #expect(snapshot.kanban.count == 6)
        #expect(Set(snapshot.list.map(\.state)) == Set(states))
        #expect(BotActivityState.failed.label == "Failed")
    }

    @Test func missingSessionHasTruthfulEmptyProjection() {
        let snapshot = SessionBotActivityPresentation.snapshot(records: [], sessionID: nil)
        #expect(snapshot.list.isEmpty)
        #expect(snapshot.emptyMessage == "No bot work in this session yet.")
    }

    @Test func storeRoundTripsSessionScopedRecords() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bot-activity-\(UUID().uuidString).json")
        let store = BotActivityStore(fileURL: url)
        let record = BotActivityRecord(
            id: "persisted", originSessionID: "session-a", botID: "forge", botName: "Forge", summary: "Persist me",
            state: .working)
        let writer = BotActivityWriter(store: store)
        await writer.enqueue(["session-a": [record]])
        await writer.flush()
        let loaded = try #require(store.load()["session-a"]?.first)
        #expect(loaded.id == record.id)
        #expect(loaded.originSessionID == record.originSessionID)
        #expect(loaded.state == record.state)
        #expect(loaded.summary == record.summary)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func exactKanbanReferencesStayHiddenFromBotRowsButSurvivePersistence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bot-kanban-reference-\(UUID().uuidString).json")
        let store = BotActivityStore(fileURL: url)
        let reference = BotActivityRecord(
            id: "kanban-reference:s1:t_8b7bdcac",
            originSessionID: "s1",
            botID: "kanban-reference",
            botName: "Hermes Kanban",
            summary: "Exact Hermes card reference",
            state: .queued,
            linkedCardID: "t_8b7bdcac"
        )
        store.saveEncoded(try #require(store.encoded(["s1": [reference]])))
        let restored = try #require(store.load()["s1"]?.first)
        #expect(restored.isKanbanReference)
        #expect(SessionBotActivityPresentation.snapshot(records: [restored], sessionID: "s1").list.isEmpty)
        try? FileManager.default.removeItem(at: url)
    }

    @Test @MainActor func botDispatchRecognizesMessageAgentAndHermesChatCommands() {
        #expect(
            DockModel.botDispatch(toolName: "message_agent", args: ["target": "@Sentry", "message": "review"])! == (
                "sentry", "review"
            ))
        #expect(
            DockModel.botDispatch(
                toolName: "terminal", args: ["command": "hermes -p forge chat -Q --query-file /tmp/brief-x.md --in ~"])!
                == ("forge", "Brief: brief-x.md"))
        #expect(
            DockModel.botDispatch(toolName: "terminal", args: ["command": "hermes -p sentry chat -q 'check CRX'"])!
                .summary == "check CRX")
        #expect(DockModel.botDispatch(toolName: "terminal", args: ["command": "hermes chat -q hi"]) == nil)
    }

    @Test @MainActor func foregroundBotChatCompletesFromItsOwnResult() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bot-dispatch-\(UUID().uuidString).json")
        let model = DockModel(
            initialSessionID: "origin", botActivityFileURL: url,
            rpcClient: SessionBotActivityRPCClient(relaySessionID: "unused"))
        model.recordBotDispatch(
            toolCallID: "c1", toolName: "terminal", args: ["command": "hermes -p sentry chat -q 'check'"])
        model.bindBotDispatch(toolCallID: "c1", result: #"{"output": "LGTM", "exit_code": 0, "error": null}"#)
        #expect(model.botActivityBySessionID["origin"]?.first?.state == .completed)
        #expect(model.botActivityBySessionID["origin"]?.first?.result == "LGTM")
        #expect(model.workingBotDispatches.isEmpty)
        model.shutdown()
        try? FileManager.default.removeItem(at: url)
    }

    @Test @MainActor func kanbanAssignmentFollowsItsCard() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bot-dispatch-\(UUID().uuidString).json")
        let model = DockModel(
            initialSessionID: "origin", botActivityFileURL: url,
            rpcClient: SessionBotActivityRPCClient(relaySessionID: "unused"))
        #expect(DockModel.botDispatch(toolName: "kanban_create", args: ["title": "x"]) == nil)
        model.recordBotDispatch(
            toolCallID: "k1", toolName: "kanban_create", args: ["assignee": "@Sentry", "title": "Review PR"])
        model.bindBotDispatch(toolCallID: "k1", result: #"{"ok": true, "task_id": "t_cd4daccd", "status": "ready"}"#)
        #expect(model.workingBotDispatches.first?.linkedCardID == "t_cd4daccd")
        #expect(model.workingBotDispatches.first?.botID == "sentry")
        await model.reconcileKanbanAssignments { _ in ("running", nil) }
        #expect(model.workingBotDispatches.first?.state == .working)
        await model.reconcileKanbanAssignments { _ in ("done", "Approved") }
        #expect(model.workingBotDispatches.isEmpty)
        #expect(model.botActivityBySessionID["origin"]?.first?.result == "Approved")
        model.shutdown()
        try? FileManager.default.removeItem(at: url)
    }

    @Test @MainActor func batchedProcessNoticeCompletesEveryBot() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bot-dispatch-\(UUID().uuidString).json")
        let model = DockModel(
            initialSessionID: "origin", botActivityFileURL: url,
            rpcClient: SessionBotActivityRPCClient(relaySessionID: "unused"))
        model.recordBotDispatch(
            toolCallID: "c1", toolName: "terminal", args: ["command": "hermes -p sentry chat -q 'a'"])
        model.recordBotDispatch(
            toolCallID: "c2", toolName: "terminal", args: ["command": "hermes -p forge chat -q 'b'"])
        model.bindBotDispatch(
            toolCallID: "c1", result: #"{"output": "Background process started", "session_id": "proc_aaa111"}"#)
        model.bindBotDispatch(
            toolCallID: "c2", result: #"{"output": "Background process started", "session_id": "proc_bbb222"}"#)
        model.completeBotDispatch(
            from:
                "[IMPORTANT: 2 background processes completed. Treat these results as one batch.]\n\n[IMPORTANT: Background process proc_aaa111 completed normally (exit code 0).\nCommand: x\nOutput:\nONE\n]\n\n[IMPORTANT: Background process proc_bbb222 completed normally (exit code 0).\nCommand: y\nOutput:\nTWO\n]"
        )
        #expect(model.workingBotDispatches.isEmpty)
        #expect(model.botActivityBySessionID["origin"]?.map(\.result) == ["ONE", "TWO"])
        model.shutdown()
        try? FileManager.default.removeItem(at: url)
    }

    @Test @MainActor func botDispatchCompletesFromItsProcessNotice() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bot-dispatch-\(UUID().uuidString).json")
        let model = DockModel(
            initialSessionID: "origin", botActivityFileURL: url,
            rpcClient: SessionBotActivityRPCClient(relaySessionID: "unused"))
        model.recordBotDispatch(
            toolCallID: "c1", toolName: "terminal", args: ["command": "hermes -p sentry chat -Q --query-file b.md"])
        #expect(model.workingBotDispatches.map(\.botID) == ["sentry"])
        model.bindBotDispatch(
            toolCallID: "c1",
            result: #"{"output": "Background process started", "session_id": "proc_abc123", "error": null}"#)
        model.completeBotDispatch(
            from:
                "[IMPORTANT: Background process proc_abc123 completed normally (exit code 0).\nCommand: hermes -p sentry chat\nOutput:\nAPPROVED\n\nsession_id: 20261019_013550_afadee\n]"
        )
        let record = model.botActivityBySessionID["origin"]?.first
        #expect(record?.state == .completed)
        #expect(record?.result == "APPROVED")
        #expect(record?.botChatSessionID == "20261019_013550_afadee")
        #expect(model.workingBotDispatches.isEmpty)
        model.shutdown()
        try? FileManager.default.removeItem(at: url)
    }

    @Test @MainActor func approvalAndClarificationEventsPauseAndResumeBotActivity() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bot-lifecycle-\(UUID().uuidString).json")
        let rpc = SessionBotActivityRPCClient(relaySessionID: "bot-session")
        let model = DockModel(initialSessionID: "origin", botActivityFileURL: url, rpcClient: rpc)
        model.sendDirectBotRequest(profileID: "forge", displayName: "Forge", text: "work")
        for _ in 0..<50 where model.botActivityBySessionID["origin"]?.first?.botChatSessionID == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.botActivityBySessionID["origin"]?.first?.state == .working)
        model.receiveGatewayEvent(
            "approval.request",
            params: ["session_id": "bot-session", "payload": ["title": "Approve", "detail": "Continue"]])
        #expect(model.botActivityBySessionID["origin"]?.first?.state == .waiting)
        model.resolveApproval(for: "bot-session")
        #expect(model.botActivityBySessionID["origin"]?.first?.state == .working)
        model.shutdown()
        try? FileManager.default.removeItem(at: url)
    }

    @Test @MainActor func directBotPromptTransportFailureFailsOriginActivity() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bot-transport-failure-\(UUID().uuidString).json")
        let rpc = SessionBotActivityRPCClient(promptError: true)
        let model = DockModel(initialSessionID: "origin", botActivityFileURL: url, rpcClient: rpc)

        model.sendDirectBotRequest(profileID: "forge", displayName: "Forge", text: "work")
        try await waitUntilActivity(model) { $0.state == .failed }

        #expect(model.botActivityBySessionID["origin"]?.first?.state == .failed)
        model.shutdown()
        try? FileManager.default.removeItem(at: url)
    }

    @Test @MainActor func acknowledgedBotPromptIsSubmittedOnlyOnce() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bot-async-relay-\(UUID().uuidString).json")
        let rpc = SessionBotActivityRPCClient(relaySessionID: "bot-session")
        let model = DockModel(initialSessionID: "origin", botActivityFileURL: url, rpcClient: rpc)

        model.sendDirectBotRequest(profileID: "forge", displayName: "Forge", text: "work")
        try await waitUntilActivity(model) { $0.state == .working }

        #expect(rpc.requests.filter { $0 == "prompt.submit" }.count == 1)
        #expect(model.status == .idle)
        model.shutdown()
        try? FileManager.default.removeItem(at: url)
    }

    @Test @MainActor func completedBotActivityStaysCompletedAfterNewChat() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bot-completed-relay-\(UUID().uuidString).json")
        let rpc = SessionBotActivityRPCClient()
        let model = DockModel(initialSessionID: "origin", botActivityFileURL: url, rpcClient: rpc)

        model.sendDirectBotRequest(profileID: "forge", displayName: "Forge", text: "work")
        try await waitUntilActivity(model) { $0.state == .working }
        model.receiveGatewayEvent(
            "message.complete", params: ["session_id": "bot-session", "payload": ["text": "Done"]])
        #expect(model.botActivityBySessionID["origin"]?.first?.state == .completed)
        model.newChat()

        #expect(model.botActivityBySessionID["origin"]?.first?.state == .completed)
        model.shutdown()
        try? FileManager.default.removeItem(at: url)
    }

    @Test @MainActor func directPromptUsesProvidedBotChatSessionID() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bot-fallback-session-\(UUID().uuidString).json")
        let rpc = SessionBotActivityRPCClient()
        let model = DockModel(initialSessionID: "origin", botActivityFileURL: url, rpcClient: rpc)

        model.sendDirectBotRequest(profileID: "forge", displayName: "Forge", text: "work", chatSessionID: "forge-chat")
        for _ in 0..<50 where !rpc.requests.contains(where: { $0 == "prompt.submit" }) {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(rpc.sessionResumeIDs == ["forge-chat"])
        #expect(rpc.requests.filter { $0 == "prompt.submit" }.count == 1)
        #expect(model.botActivityBySessionID["origin"]?.first?.botChatSessionID == "forge-chat")
        model.shutdown()
        try? FileManager.default.removeItem(at: url)
    }

    @Test @MainActor func pendingPDFIsClearedWhenStartingNewChat() throws {
        let pdfURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pending-session-switch-\(UUID().uuidString).pdf")
        try Data([0]).write(to: pdfURL)
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        let model = DockModel(
            initialSessionID: "origin", botActivityFileURL: pdfURL.appendingPathExtension("activity.json"))
        model.stagePDFFile(at: pdfURL)
        #expect(model.pendingPDFURL == pdfURL)

        model.newChat()

        #expect(model.pendingPDFURL == nil)
        #expect(model.pendingPDFError == nil)
        model.shutdown()
    }

    @Test @MainActor func clarificationExpiryCancelsMatchingBotActivityWithResult() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bot-clarification-expiry-\(UUID().uuidString).json")
        let rpc = SessionBotActivityRPCClient(relaySessionID: "bot-session")
        let model = DockModel(initialSessionID: "origin", botActivityFileURL: url, rpcClient: rpc)

        model.sendDirectBotRequest(profileID: "forge", displayName: "Forge", text: "work")
        try await waitUntilActivity(model) { $0.state == .working }
        model.receiveGatewayEvent(
            "clarification.request",
            params: [
                "session_id": "bot-session",
                "payload": ["request_id": "clarify-1", "question": "Continue?"],
            ])
        model.receiveGatewayEvent(
            "clarification.expire",
            params: [
                "session_id": "bot-session",
                "payload": ["request_id": "clarify-1"],
            ])

        let record = try #require(model.botActivityBySessionID["origin"]?.first)
        #expect(record.state == .canceled)
        #expect(record.result == "This question expired before Hermes received an answer.")
        model.shutdown()
        try? FileManager.default.removeItem(at: url)
    }

    @Test @MainActor func sessionSwitchPreventsDelayedResumeFailureFromOverwritingCanceledActivity() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bot-session-switch-\(UUID().uuidString).json")
        let rpc = SessionBotActivityRPCClient(resumeErrorAfterSwitch: true)
        let model = DockModel(initialSessionID: "origin", botActivityFileURL: url, rpcClient: rpc)

        model.sendDirectBotRequest(profileID: "forge", displayName: "Forge", text: "work")
        try await waitUntilActivity(model) { $0.state == .queued }
        model.newChat()
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.botActivityBySessionID["origin"]?.first?.state == .canceled)
        model.shutdown()
        try? FileManager.default.removeItem(at: url)
    }

    @Test @MainActor func dockModelLoadsPersistedActivityAtInitialization() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dock-bot-activity-\(UUID().uuidString).json")
        let store = BotActivityStore(fileURL: url)
        let record = BotActivityRecord(
            id: "reload", originSessionID: "session-reentry", botID: "cypher", botName: "Cypher", summary: "Reload me")
        store.saveEncoded(try #require(store.encoded(["session-reentry": [record]])))
        let model = DockModel(initialSessionID: "session-reentry", botActivityFileURL: url)
        let loaded = try #require(model.botActivityBySessionID["session-reentry"]?.first)
        #expect(loaded.id == record.id)
        #expect(loaded.originSessionID == record.originSessionID)
        #expect(loaded.summary == record.summary)
        model.shutdown()
    }
}

@MainActor
private final class SessionBotActivityRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    let promptError: Bool
    let resumeErrorAfterSwitch: Bool
    let relaySessionID: String?
    private(set) var requests: [String] = []
    private(set) var sessionResumeIDs: [String] = []

    init(
        promptError: Bool = false,
        resumeErrorAfterSwitch: Bool = false,
        relaySessionID: String? = nil
    ) {
        self.promptError = promptError
        self.resumeErrorAfterSwitch = resumeErrorAfterSwitch
        self.relaySessionID = relaySessionID
    }

    func connect() async throws {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append(method)
        switch method {
        case "session.resume":
            sessionResumeIDs.append(params["session_id"] as? String ?? "")
            if resumeErrorAfterSwitch {
                try await Task.sleep(for: .milliseconds(100))
                throw NSError(
                    domain: "Hermes", code: 408, userInfo: [NSLocalizedDescriptionKey: "delayed resume failure"])
            }
            let requested = params["session_id"] as? String ?? BotService.canonicalBotChatTitle
            let runtime = relaySessionID ?? (requested == BotService.canonicalBotChatTitle ? "bot-session" : requested)
            return [
                "session_id": runtime, "session_key": requested, "messages": [],
                "info": ["profile_name": params["profile"] as? String ?? "default"],
            ]
        case "prompt.submit":
            if promptError {
                throw NSError(
                    domain: "Hermes", code: 503, userInfo: [NSLocalizedDescriptionKey: "prompt transport failed"])
            }
            return ["status": "streaming"]
        default:
            return [:]
        }
    }

    func close() {}
}

@MainActor
private func waitUntilActivity(
    _ model: DockModel, _ condition: @escaping (BotActivityRecord) -> Bool, timeout: TimeInterval = 2
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let record = model.botActivityBySessionID.values.flatMap({ $0 }).first, condition(record) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}
