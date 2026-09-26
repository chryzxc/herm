import Foundation
import Testing
@testable import Herm

struct SessionBotActivityTests {
    @Test func activityIsSessionScopedAndNewestUpdateFirst() {
        let records = [
            BotActivityRecord(id: "old", originSessionID: "s1", botID: "forge", botName: "Forge", summary: "Old", state: .completed, createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 20)),
            BotActivityRecord(id: "other", originSessionID: "s2", botID: "cypher", botName: "Cypher", summary: "Other", state: .working, createdAt: Date(timeIntervalSince1970: 30), updatedAt: Date(timeIntervalSince1970: 40)),
            BotActivityRecord(id: "new", originSessionID: "s1", botID: "forge", botName: "Forge", summary: "New", state: .working, createdAt: Date(timeIntervalSince1970: 50), updatedAt: Date(timeIntervalSince1970: 60))
        ]

        let snapshot = SessionBotActivityPresentation.snapshot(records: records, sessionID: "s1")

        #expect(snapshot.list.map(\.id) == ["new", "old"])
        #expect(snapshot.kanban[.working]?.map(\.id) == ["new"])
        #expect(snapshot.kanban[.completed]?.map(\.id) == ["old"])
    }

    @Test func allLifecycleStatesHaveKanbanColumnsAndStatusIsTextual() {
        let states = BotActivityState.allCases
        let records = states.enumerated().map { index, state in
            BotActivityRecord(id: "r\(index)", originSessionID: "s1", botID: "forge", botName: "Forge", summary: state.label, state: state, createdAt: .distantPast, updatedAt: Date(timeIntervalSince1970: Double(index)))
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bot-activity-\(UUID().uuidString).json")
        let store = BotActivityStore(fileURL: url)
        let record = BotActivityRecord(id: "persisted", originSessionID: "session-a", botID: "forge", botName: "Forge", summary: "Persist me", state: .working)
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bot-kanban-reference-\(UUID().uuidString).json")
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

    @Test @MainActor func approvalAndClarificationEventsPauseAndResumeBotActivity() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bot-lifecycle-\(UUID().uuidString).json")
        let rpc = SessionBotActivityRPCClient(relaySessionID: "bot-session")
        let model = DockModel(initialSessionID: "origin", botActivityFileURL: url, rpcClient: rpc)
        model.sendDirectBotRequest(profileID: "forge", displayName: "Forge", text: "work")
        for _ in 0..<50 where model.botActivityBySessionID["origin"]?.first?.botChatSessionID == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.botActivityBySessionID["origin"]?.first?.state == .working)
        model.receiveGatewayEvent("approval.request", params: ["session_id": "bot-session", "payload": ["title": "Approve", "detail": "Continue"]])
        #expect(model.botActivityBySessionID["origin"]?.first?.state == .waiting)
        model.resolveApproval(for: "bot-session")
        #expect(model.botActivityBySessionID["origin"]?.first?.state == .working)
        model.shutdown()
        try? FileManager.default.removeItem(at: url)
    }

    @Test @MainActor func directBotPromptTransportFailureFailsOriginActivity() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bot-transport-failure-\(UUID().uuidString).json")
        let rpc = SessionBotActivityRPCClient(relayError: true)
        let model = DockModel(initialSessionID: "origin", botActivityFileURL: url, rpcClient: rpc)

        model.sendDirectBotRequest(profileID: "forge", displayName: "Forge", text: "work")
        try await waitUntilActivity(model) { $0.state == .failed }

        #expect(model.botActivityBySessionID["origin"]?.first?.state == .failed)
        model.shutdown()
        try? FileManager.default.removeItem(at: url)
    }

    @Test @MainActor func acknowledgedAsyncRelayDoesNotSubmitTheTurnAgain() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bot-async-relay-\(UUID().uuidString).json")
        let rpc = SessionBotActivityRPCClient(relayReply: "", relaySessionID: "bot-session")
        let model = DockModel(initialSessionID: "origin", botActivityFileURL: url, rpcClient: rpc)

        model.sendDirectBotRequest(profileID: "forge", displayName: "Forge", text: "work")
        try await waitUntilActivity(model) { $0.state == .working }

        #expect(rpc.requests.filter { $0 == "prompt.submit" }.isEmpty)
        #expect(model.status == .idle)
        model.shutdown()
        try? FileManager.default.removeItem(at: url)
    }

    @Test @MainActor func completedRelayActivityStaysCompletedAfterNewChat() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bot-completed-relay-\(UUID().uuidString).json")
        let rpc = SessionBotActivityRPCClient(relayReply: "Done")
        let model = DockModel(initialSessionID: "origin", botActivityFileURL: url, rpcClient: rpc)

        model.sendDirectBotRequest(profileID: "forge", displayName: "Forge", text: "work")
        try await waitUntilActivity(model) { $0.state == .completed }
        model.newChat()

        #expect(model.botActivityBySessionID["origin"]?.first?.state == .completed)
        model.shutdown()
        try? FileManager.default.removeItem(at: url)
    }

    @Test @MainActor func acknowledgedRelayUsesProvidedBotChatSessionIDWithoutResubmitting() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bot-fallback-session-\(UUID().uuidString).json")
        let rpc = SessionBotActivityRPCClient()
        let model = DockModel(initialSessionID: "origin", botActivityFileURL: url, rpcClient: rpc)

        model.sendDirectBotRequest(profileID: "forge", displayName: "Forge", text: "work", chatSessionID: "forge-chat")
        for _ in 0..<50 where !rpc.requests.contains(where: { $0 == "bot_relay.deliver" }) {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(rpc.sessionResumeIDs.isEmpty)
        #expect(rpc.requests.filter { $0 == "prompt.submit" }.isEmpty)
        #expect(model.botActivityBySessionID["origin"]?.first?.botChatSessionID == "forge-chat")
        model.shutdown()
        try? FileManager.default.removeItem(at: url)
    }

    @Test @MainActor func pendingPDFIsClearedWhenStartingNewChat() throws {
        let pdfURL = FileManager.default.temporaryDirectory.appendingPathComponent("pending-session-switch-\(UUID().uuidString).pdf")
        try Data([0]).write(to: pdfURL)
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        let model = DockModel(initialSessionID: "origin", botActivityFileURL: pdfURL.appendingPathExtension("activity.json"))
        model.stagePDFFile(at: pdfURL)
        #expect(model.pendingPDFURL == pdfURL)

        model.newChat()

        #expect(model.pendingPDFURL == nil)
        #expect(model.pendingPDFError == nil)
        model.shutdown()
    }

    @Test @MainActor func clarificationExpiryCancelsMatchingBotActivityWithResult() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bot-clarification-expiry-\(UUID().uuidString).json")
        let rpc = SessionBotActivityRPCClient(relaySessionID: "bot-session")
        let model = DockModel(initialSessionID: "origin", botActivityFileURL: url, rpcClient: rpc)

        model.sendDirectBotRequest(profileID: "forge", displayName: "Forge", text: "work")
        try await waitUntilActivity(model) { $0.state == .working }
        model.receiveGatewayEvent("clarification.request", params: [
            "session_id": "bot-session",
            "payload": ["request_id": "clarify-1", "question": "Continue?"]
        ])
        model.receiveGatewayEvent("clarification.expire", params: [
            "session_id": "bot-session",
            "payload": ["request_id": "clarify-1"]
        ])

        let record = try #require(model.botActivityBySessionID["origin"]?.first)
        #expect(record.state == .canceled)
        #expect(record.result == "This question expired before Hermes received an answer.")
        model.shutdown()
        try? FileManager.default.removeItem(at: url)
    }

    @Test @MainActor func sessionSwitchPreventsDelayedResumeFailureFromOverwritingCanceledActivity() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bot-session-switch-\(UUID().uuidString).json")
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dock-bot-activity-\(UUID().uuidString).json")
        let store = BotActivityStore(fileURL: url)
        let record = BotActivityRecord(id: "reload", originSessionID: "session-reentry", botID: "cypher", botName: "Cypher", summary: "Reload me")
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
    let relayError: Bool
    let resumeErrorAfterSwitch: Bool
    let relayReply: String?
    let relaySessionID: String?
    private(set) var requests: [String] = []
    private(set) var sessionResumeIDs: [String] = []

    init(
        promptError: Bool = false,
        relayError: Bool = false,
        resumeErrorAfterSwitch: Bool = false,
        relayReply: String? = nil,
        relaySessionID: String? = nil
    ) {
        self.promptError = promptError
        self.relayError = relayError
        self.resumeErrorAfterSwitch = resumeErrorAfterSwitch
        self.relayReply = relayReply
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
                throw NSError(domain: "Hermes", code: 408, userInfo: [NSLocalizedDescriptionKey: "delayed resume failure"])
            }
            return ["session_id": "bot-session", "session_key": BotService.canonicalBotChatTitle, "messages": []]
        case "bot_relay.deliver":
            if relayError {
                throw NSError(domain: "Hermes", code: 503, userInfo: [NSLocalizedDescriptionKey: "relay transport failed"])
            }
            var result: [String: Any] = [:]
            if let relayReply { result["reply"] = relayReply }
            if let relaySessionID { result["session_id"] = relaySessionID }
            return result
        case "prompt.submit":
            if promptError {
                throw NSError(domain: "Hermes", code: 503, userInfo: [NSLocalizedDescriptionKey: "prompt transport failed"])
            }
            return [:]
        default:
            return [:]
        }
    }

    func close() {}
}

@MainActor
private func waitUntilActivity(_ model: DockModel, _ condition: @escaping (BotActivityRecord) -> Bool, timeout: TimeInterval = 2) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let record = model.botActivityBySessionID.values.flatMap({ $0 }).first, condition(record) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}
