import Combine
import Foundation
import Testing

@testable import Herm

@MainActor
private final class ClarificationResponseRPCClient: HermesRPCClientProtocol {
    struct Call {
        let method: String
        let params: [String: Any]
    }

    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var calls: [Call] = []
    var suspendFirstSessionRead = false
    var firstSessionRead: CheckedContinuation<[String: Any], Never>?
    var sessions: [[String: Any]] = []
    var agents: [[String: Any]] = []
    var promptTokens = 0
    private(set) var httpPaths: [String] = []

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        httpPaths.append(path)
        return ["data": [[String: Any]](), "has_more": false]
    }

    func connect() async throws {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append(Call(method: method, params: params))
        if method == "session.active_list" {
            if suspendFirstSessionRead {
                suspendFirstSessionRead = false
                return await withCheckedContinuation { firstSessionRead = $0 }
            }
            return ["sessions": sessions]
        }
        if method == "session.list" { return ["data": [[String: Any]](), "has_more": false] }
        if method == "projects.tree" { return ["projects": [[String: Any]]()] }
        if method == "delegation.status" { return ["agents": agents] }
        if method == "shell.exec" { return ["stdout": "{\"total_tokens\":\(promptTokens)}", "code": 0] }
        return [:]
    }

    func close() {}
}

@MainActor
struct ControlCenterAttentionTests {
    @Test func restoredCompletedItemTargetsItsSession() {
        let reference = ControlCenterModel.restoredAttentionReference(for: "completed:session-42")

        #expect(reference.source == .hermesSession)
        #expect(reference.sourceID == "session-42")
        #expect(reference.sessionID == "session-42")
    }

    @Test func restoredSpecializedItemsKeepTheirSource() {
        let approval = ControlCenterModel.restoredAttentionReference(for: "approval:session-approval")
        let reminder = ControlCenterModel.restoredAttentionReference(for: "reminder:reminder-1")

        #expect(approval.source == .hermesApproval)
        #expect(approval.sessionID == "session-approval")
        #expect(reminder.source == .appleReminder)
        #expect(reminder.sourceID == "reminder-1")
    }

    @Test func sessionAttentionProjectionExcludesOtherSessions() {
        let model = ControlCenterModel()
        model.ingestEvent(
            "approval.request",
            params: [
                "session_id": "session-a",
                "payload": ["command": "echo A"],
            ])
        model.ingestEvent(
            "approval.request",
            params: [
                "session_id": "session-b",
                "payload": ["command": "echo B"],
            ])

        #expect(model.attention(for: "session-a").count == 1)
        #expect(model.attention(for: "session-a").first?.detail == "echo A")
        #expect(model.attention(for: "session-b").count == 1)
        #expect(model.attention(for: "session-b").first?.detail == "echo B")
        #expect(model.attention(for: "session-missing").isEmpty)
        #expect(model.openAttention(for: "session-a").map(\.detail) == ["echo A"])
        #expect(model.openAttention(for: "session-b").map(\.detail) == ["echo B"])
        #expect(model.openAttention(for: "session-missing").isEmpty)
    }

    @Test func approvalEventsExposeActionTitleAndDetails() {
        let model = ControlCenterModel()

        model.ingestEvent(
            "approval.request",
            params: [
                "session_id": "session-approval-title",
                "payload": [
                    "title": "Review repository activity",
                    "command": "gh api repos/example/project/events",
                    "description": "network access",
                ],
            ])

        #expect(model.attention.first?.title == "Review repository activity")
        #expect(model.attention.first?.detail == "gh api repos/example/project/events")
    }

    @Test func approvalEventsShowExactCommandInsteadOfSafetyCategory() {
        let model = ControlCenterModel()

        model.ingestEvent(
            "approval.request",
            params: [
                "session_id": "session-recursive-delete",
                "payload": [
                    "command": "rm -rf -- .omo",
                    "description": "recursive delete",
                    "pattern_key": "recursive delete",
                ],
            ])

        let item = model.attention.first
        #expect(item?.title == "Run command")
        #expect(item?.detail == "rm -rf -- .omo")
    }

    @Test func refreshEventsCoalesceWithoutLosingTheirKinds() {
        let model = ControlCenterModel()
        model.ingestEvent("process.changed", params: ["session_id": "session-a"])
        model.ingestEvent("process.changed", params: ["session_id": "session-b"])
        model.ingestEvent("cron.changed", params: ["session_id": "session-a"])
        #expect(Set(model.pendingEventRefreshes.map(\.kind)) == ["process.changed", "cron.changed"])
        #expect(
            Set(model.pendingEventRefreshes.filter { $0.kind == "process.changed" }.compactMap(\.sessionID))
                == ["session-a", "session-b"])
        model.eventRefreshTask?.cancel()
    }

    @Test func visibleSessionDoesNotReadFocusedDetailsForForeignEvents() async throws {
        let client = ClarificationResponseRPCClient()
        let rpc = HermesControlRPC(client: client)
        let model = ControlCenterModel(rpc: rpc, capabilities: [])
        let dock = DockModel(initialSessionID: "front", loadArchives: false, rpcClient: client)
        defer { dock.shutdown() }
        dock.sessionProfileID = "front-profile"
        dock.presentationDemand.update(UUID(), visible: true)
        model.dockModel = dock
        model.cli = HermesCLIAdapter(rpc: rpc)
        model.processSessionID = "front"
        model.developmentContext = .init(
            path: "/work/repo", branch: "main", changedFiles: 0, latestCommit: "", isGitRepository: true)
        model.ingestEvent("process.changed", params: ["session_id": "other"])
        model.ingestEvent("message.complete", params: ["session_id": "front", "profile": "other-profile"])
        model.ingestEvent("message.complete", params: [:])
        let refresh = try #require(model.eventRefreshTask)
        await refresh.value
        #expect(client.calls.map(\.method) == ["session.active_list"])
    }

    @Test func toolProgressDoesNotRebuildAttention() {
        let suite = "attention-tool-progress-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ControlCenterModel(presentationDefaults: defaults)
        model.upsertAttention(
            AttentionItem(
                id: "approval:earlier", reference: .init(source: .hermesApproval, sourceID: "earlier"),
                kind: .approval, title: "Pending approval", detail: "Review the request",
                createdAt: .distantPast, state: .open, actions: [.approve]))

        model.ingestEvent("tool.call", params: ["session_id": "background", "payload": ["name": "terminal"]])
        model.ingestEvent("tool.result", params: ["session_id": "background"])
        #expect(model.attention.isEmpty)

        model.ingestEvent("approval.request", params: ["session_id": "background"])
        #expect(Set(model.attention.map(\.id)) == ["approval:earlier", "approval:background"])
    }

    @Test func hiddenMessageRefreshOnlyReadsSharedSessionsWithoutPublishingUnchangedState() async {
        let client = ClarificationResponseRPCClient()
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client), capabilities: [])
        let dock = DockModel(rpcClient: client)
        model.bind(to: dock)
        model.projectProfileScopeUnavailable = false
        model.verification = VerificationSummary(state: .notApplicable, evidence: nil)
        model.promptBudget = PromptBudgetSummary(totalTokens: 0, tokenLimit: nil, percent: nil, model: nil)
        model.recordProjectionSuccess("sessions")
        model.recordProjectionSuccess("projects")
        model.recordProjectionSuccess("latest.activity")
        model.recordProjectionSuccess("agents")
        model.recordProjectionSuccess("prompt.budget")
        model.ingestEvent("message.complete", params: ["session_id": "session-a"])
        await model.eventRefreshTask?.value
        try? await Task.sleep(for: .milliseconds(500))
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        model.ingestEvent("message.complete", params: ["session_id": "session-a"])
        model.ingestEvent("process.changed", params: ["session_id": "session-a"])
        await model.eventRefreshTask?.value
        try? await Task.sleep(for: .milliseconds(200))
        #expect(publications == 0)
        #expect(client.calls.contains { $0.method == "session.active_list" })
        #expect(!client.calls.contains { $0.method == "projects.tree" })
        #expect(!client.httpPaths.contains { $0.hasPrefix("/api/sessions?") })
        #expect(!client.calls.contains { $0.method == "shell.exec" })
        withExtendedLifetime(subscription) {}
    }

    @Test func boundEventsPublishChangedSessionsAgentsAndPromptBudget() async throws {
        let client = ClarificationResponseRPCClient()
        let model = ControlCenterModel()
        let dock = DockModel(initialSessionID: "runtime-a", loadArchives: false, rpcClient: client)
        defer { dock.shutdown() }
        dock.sessionStorageID = "session-a"
        model.bind(to: dock)
        model.visibleSidebarTabs[UUID()] = .core
        dock.presentationDemand.update(UUID(), visible: true)
        model.projectProfileScopeUnavailable = false
        model.verification = VerificationSummary(state: .notApplicable, evidence: nil)
        client.sessions = [["id": "session-a", "title": "Changed"]]
        client.agents = [["id": "agent-a", "status": "running"]]
        client.promptTokens = 42
        model.ingestEvent("message.complete", params: ["session_id": "session-a"])
        model.ingestEvent("process.changed", params: ["session_id": "session-a"])
        await model.eventRefreshTask?.value
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.activeSessions.first?.title == "Changed")
        #expect(model.activeAgents.first?.id == "agent-a")
        #expect(model.promptBudget?.totalTokens == 42)
        #expect(client.calls.contains { $0.method == "shell.exec" })
    }

    @Test func unchangedProjectsRecoverFromError() async {
        let client = ClarificationResponseRPCClient()
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client), capabilities: [])
        let dock = DockModel(rpcClient: client)
        model.dockModel = dock
        model.projectProfileScopeUnavailable = false
        model.recordProjectionSuccess("projects")
        model.recordProjectionFailure("projects", error: "temporary failure")
        await model.refreshEventActivity()
        #expect(model.refreshState(for: "projects")?.error == nil)
        #expect(model.refreshState(for: "projects")?.isStale == false)
    }

    @Test func eventReadsAreSerializedAcrossOverlappingEvents() async throws {
        let client = ClarificationResponseRPCClient()
        client.suspendFirstSessionRead = true
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client), capabilities: [])
        let dock = DockModel(rpcClient: client)
        model.dockModel = dock
        model.recordProjectionSuccess("sessions")
        model.recordProjectionSuccess("agents")
        model.ingestEvent("process.changed", params: ["session_id": "a"])
        let task = try #require(model.eventRefreshTask)
        for _ in 0..<100 where client.firstSessionRead == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        let firstRead = try #require(client.firstSessionRead)
        model.ingestEvent("process.changed", params: ["session_id": "a"])
        try await Task.sleep(for: .milliseconds(500))
        #expect(client.calls.filter { $0.method == "session.active_list" }.count == 1)
        firstRead.resume(returning: ["sessions": [["id": "old", "title": "Old"]]])
        await task.value
        #expect(client.calls.filter { $0.method == "session.active_list" }.count == 2)
        #expect(model.activeSessions.isEmpty)
    }

    @Test func completedResponsesDoNotAppearAsNeedsMeAttention() {
        let model = ControlCenterModel()

        model.ingestEvent(
            "message.complete",
            params: [
                "session_id": "session-complete",
                "payload": [:],
            ])

        #expect(model.openAttention(for: "session-complete").isEmpty)
    }

    @Test func clarificationEventsExposeAResponseAction() {
        let model = ControlCenterModel()

        model.ingestEvent(
            "clarification.request",
            params: [
                "session_id": "session-clarify",
                "payload": ["question": "Which account should I use?"],
            ])

        let item = model.attention.first
        #expect(item?.kind == .clarification)
        #expect(item?.detail == "Which account should I use?")
        #expect(item?.actions.contains(.respond) == true)
    }

    @Test func clarificationEventsPreserveSuggestedResponses() {
        let model = ControlCenterModel()

        model.ingestEvent(
            "clarify.request",
            params: [
                "session_id": "session-clarify-choices",
                "payload": [
                    "question": "Which approach should I take?",
                    "choices": ["Use the first approach", "Use the second approach"],
                ],
            ])

        #expect(model.attention.first?.choices == ["Use the first approach", "Use the second approach"])
    }

    @Test func clarificationEventsPreserveHermesRequestIdentity() {
        let model = ControlCenterModel()

        model.ingestEvent(
            "clarify.request",
            params: [
                "session_id": "session-clarify-request",
                "payload": [
                    "request_id": "clarify-42",
                    "question": "Which environment?",
                ],
            ])

        #expect(model.attention.first?.reference.sessionID == "session-clarify-request")
        #expect(model.attention.first?.reference.clarificationRequestID == "clarify-42")
    }

    @Test func partialClarificationEventPreservesExistingRequestIdentity() {
        let model = ControlCenterModel()

        model.ingestEvent(
            "clarify.request",
            params: [
                "session_id": "session-clarify-partial",
                "payload": [
                    "request_id": "clarify-preserved-42",
                    "question": "Which environment?",
                ],
            ])
        model.ingestEvent(
            "clarification.request",
            params: [
                "session_id": "session-clarify-partial",
                "payload": ["message": "Please choose an environment."],
            ])

        #expect(model.attention.first?.reference.clarificationRequestID == "clarify-preserved-42")
    }

    @Test func respondingToClarificationUsesRequestIdentityAndResolvesAfterRPC() async {
        let client = ClarificationResponseRPCClient()
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let sessionID = "session-clarify-response-\(UUID().uuidString)"
        model.ingestEvent(
            "clarify.request",
            params: [
                "session_id": sessionID,
                "payload": [
                    "request_id": "clarify-response-42",
                    "question": "Which environment?",
                ],
            ])
        let item = try! #require(model.attention.first)

        model.respond(to: item, action: .respond, response: "production")
        for _ in 0..<20 { await Task.yield() }

        let clarificationCalls = client.calls.filter { $0.method == "request.answer" }
        #expect(clarificationCalls.count == 1)
        #expect(clarificationCalls.first?.params["id"] as? String == "clarify-response-42")
        #expect((clarificationCalls.first?.params["result"] as? [String: Any])?["answer"] as? String == "production")
        #expect(model.attention.first?.state == .resolved)
    }

    @Test func respondingToClarificationWithoutUsableRequestIdentityFailsSafely() async {
        let client = ClarificationResponseRPCClient()
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let sessionID = "session-clarify-invalid-\(UUID().uuidString)"
        model.ingestEvent(
            "clarify.request",
            params: [
                "session_id": sessionID,
                "payload": ["question": "Which environment?"],
            ])
        let item = try! #require(model.attention.first)

        model.respond(to: item, action: .respond, response: "production")
        for _ in 0..<20 { await Task.yield() }

        #expect(client.calls.filter { $0.method == "request.answer" }.isEmpty)
        #expect(model.attention.first?.state == .open)
    }

    @Test func respondingToClarificationWithWhitespaceRequestIdentityFailsSafely() async {
        let client = ClarificationResponseRPCClient()
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let sessionID = "session-clarify-whitespace-\(UUID().uuidString)"
        model.ingestEvent(
            "clarify.request",
            params: [
                "session_id": sessionID,
                "payload": [
                    "request_id": "   ",
                    "question": "Which environment?",
                ],
            ])
        let item = try! #require(model.attention.first)

        model.respond(to: item, action: .respond, response: "production")
        for _ in 0..<20 { await Task.yield() }

        #expect(client.calls.filter { $0.method == "request.answer" }.isEmpty)
        #expect(model.attention.first?.state == .open)
    }

    @Test func partialAttentionEventsPreserveExistingDetail() {
        let model = ControlCenterModel()

        model.ingestEvent(
            "approval.request",
            params: [
                "session_id": "session-approval",
                "payload": ["command": "delete the temporary export"],
            ])
        model.ingestEvent(
            "approval.request",
            params: [
                "session_id": "session-approval",
                "payload": [:],
            ])

        #expect(model.attention.first?.detail == "delete the temporary export")
    }

    @Test func reminderProjectionUsesStableAppleReference() {
        let reminder = ReminderSummary(
            id: "rem-1", title: "Call back", list: "Personal", dueDate: Date(), isOverdue: true)
        let item = ControlCenterModel.reminderAttention(for: reminder)

        #expect(item.id == "reminder:rem-1")
        #expect(item.reference == ControlReference(source: .appleReminder, sourceID: "rem-1"))
        #expect(item.kind == .reminder)
        #expect(item.actions.contains(.complete))
    }

    @Test func overdueRemindersRankBeforeOrdinaryReminders() {
        let overdue = ControlCenterModel.reminderAttention(
            for: ReminderSummary(id: "overdue", title: "Urgent", list: nil, dueDate: Date(), isOverdue: true))
        let ordinary = ControlCenterModel.reminderAttention(
            for: ReminderSummary(id: "ordinary", title: "Later", list: nil, dueDate: Date(), isOverdue: false))

        #expect(ControlCenterModel.attentionRank(overdue) < ControlCenterModel.attentionRank(ordinary))
    }
}
