import Foundation
import Testing

@testable import Herm

@MainActor
private final class ConversationApprovalRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var requests: [(String, [String: Any])] = []
    var response: CheckedContinuation<[String: Any], Error>?
    var approvals: [[String: Any]] = []

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        if method == "approval.pending" { return ["approvals": approvals] }
        if method == "approval.respond" {
            return try await withCheckedThrowingContinuation { response = $0 }
        }
        return [:]
    }
}

@MainActor
struct ConversationApprovalTests {
    private func makeModel(_ rpc: ConversationApprovalRPC = ConversationApprovalRPC()) -> DockModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return DockModel(
            sessionAgentStateFileURL: root.appendingPathComponent("agents.json"),
            defaults: UserDefaults(suiteName: UUID().uuidString)!, approvalSoundPlayer: {},
            initialSessionID: "current", botActivityFileURL: root.appendingPathComponent("bots.json"), rpcClient: rpc)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for approval state")
    }

    private func request(_ model: DockModel, session: String, id: String, profile: String = "builder") {
        model.receiveGatewayEvent(
            "approval.request",
            params: [
                "session_id": session,
                "payload": [
                    "profile": profile, "request_id": id, "server_request_id": "server-\(id)",
                    "command": "git status", "reason": "Review command", "choices": ["once", "deny"],
                ],
            ])
    }

    @Test(arguments: [AttentionAction.approve, .deny])
    func controlApprovalWithoutConversationRecordStillResponds(action: AttentionAction) async throws {
        let rpc = ConversationApprovalRPC()
        let model = makeModel(rpc)
        let control = ControlCenterModel(
            rpc: HermesControlRPC(client: rpc), presentationDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        control.dockModel = model
        control.ingestEvent(
            "approval.request", params: ["session_id": "background", "payload": ["command": "git status"]])
        let item = try #require(control.attention.first { $0.reference.sessionID == "background" })
        control.respond(to: item, action: action)
        try await waitUntil { rpc.response != nil }
        #expect(rpc.requests.last?.1["session_id"] as? String == "background")
        #expect(rpc.requests.last?.1["choice"] as? String == (action == .approve ? "once" : "deny"))
        rpc.response?.resume(returning: ["resolved": 1])
        rpc.response = nil
        try await waitUntil { control.attention.first(where: { $0.id == item.id })?.state == .resolved }
    }

    @Test func controlApprovalWithoutRecordDoesNotResolveNewRequest() async throws {
        let rpc = ConversationApprovalRPC()
        let model = makeModel(rpc)
        let control = ControlCenterModel(
            rpc: HermesControlRPC(client: rpc), presentationDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        control.dockModel = model
        control.ingestEvent("approval.request", params: ["session_id": "background", "payload": ["command": "first"]])
        let item = try #require(control.attention.first { $0.reference.sessionID == "background" })
        control.respond(to: item, action: .approve)
        try await waitUntil { rpc.response != nil }
        model.receiveGatewayEvent(
            "approval.request", params: ["session_id": "background", "payload": ["command": "second"]])
        rpc.response?.resume(returning: ["resolved": 1])
        rpc.response = nil
        try await waitUntil { control.pendingActionIDs.isEmpty }
        #expect(model.pendingApprovalsBySessionID["background"] != nil)
        #expect(model.conversationApprovals.last?.resolved == false)
        #expect(control.attention.first(where: { $0.id == item.id })?.state != .resolved)
    }

    @Test func controlApprovalWithoutRecordRejectsMalformedAcknowledgment() async throws {
        let rpc = ConversationApprovalRPC()
        let model = makeModel(rpc)
        let control = ControlCenterModel(
            rpc: HermesControlRPC(client: rpc), presentationDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        control.dockModel = model
        control.ingestEvent("approval.request", params: ["session_id": "background", "payload": ["command": "first"]])
        let item = try #require(control.attention.first { $0.reference.sessionID == "background" })
        control.respond(to: item, action: .deny)
        try await waitUntil { rpc.response != nil }
        rpc.response?.resume(returning: [:])
        rpc.response = nil
        try await waitUntil { control.pendingActionIDs.isEmpty }
        #expect(control.attention.first(where: { $0.id == item.id })?.state != .resolved)
        #expect(control.lastError != nil)
    }

    @Test(arguments: [false, true])
    func controlApprovalMalformedRequiresRecheck(identified: Bool) async throws {
        let rpc = ConversationApprovalRPC()
        let model = makeModel(rpc)
        model.sessionProfileID = "builder"
        if identified {
            request(model, session: "current", id: "one")
        } else {
            model.receiveGatewayEvent(
                "approval.request", params: ["session_id": "current", "payload": ["command": "git status"]])
        }
        let record = try #require(model.currentConversationApproval)
        let control = ControlCenterModel(
            rpc: HermesControlRPC(client: rpc), presentationDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        control.dockModel = model
        let item = AttentionItem(
            id: "approval", reference: .init(source: .hermesApproval, sourceID: "current", sessionID: "current"),
            kind: .approval, title: "Approval", detail: "", createdAt: .now, state: .open, actions: [.approve])
        control.respond(to: item, action: .approve)
        try await waitUntil { rpc.response != nil }
        rpc.response?.resume(returning: [:])
        rpc.response = nil
        try await waitUntil {
            let answer =
                record.target.flatMap { model.attentionAnswers[$0] }
                ?? model.currentConversationApproval?.legacyAnswer
            if case .uncertain = answer { return true }
            return false
        }
        #expect(model.pendingApprovalsBySessionID["current"] != nil)
        #expect(model.currentConversationApproval?.resolved == false)
        control.respond(to: item, action: .approve)
        await Task.yield()
        #expect(rpc.requests.filter { $0.0 == "approval.respond" }.count == 1)
        if let target = record.target {
            rpc.approvals = [["request_id": "one"]]
            model.recheckAttention(target)
            try await waitUntil { model.attentionAnswers[target] == nil }
        } else {
            rpc.approvals = [["command": "git status"]]
            model.recheckLegacyApproval(record.id)
            try await waitUntil { model.currentConversationApproval?.legacyAnswer == nil }
        }
        #expect(rpc.requests.contains { $0.0 == "approval.pending" })
    }

    @Test(arguments: [AttentionAction.approve, .deny])
    func controlApprovalZeroResolvesWithoutResuming(action: AttentionAction) async throws {
        let rpc = ConversationApprovalRPC()
        let model = makeModel(rpc)
        model.receiveGatewayEvent(
            "approval.request", params: ["session_id": "current", "payload": ["command": "git status"]])
        let control = ControlCenterModel(
            rpc: HermesControlRPC(client: rpc), presentationDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        control.dockModel = model
        let item = AttentionItem(
            id: "approval", reference: .init(source: .hermesApproval, sourceID: "current", sessionID: "current"),
            kind: .approval, title: "Approval", detail: "", createdAt: .now, state: .open, actions: [action])
        control.respond(to: item, action: action)
        try await waitUntil { rpc.response != nil }
        rpc.response?.resume(returning: ["resolved": 0])
        rpc.response = nil
        try await waitUntil { model.currentConversationApproval?.resolved == true }
        #expect(model.pendingApprovalsBySessionID["current"] == nil)
        #expect(model.status == .idle)
    }

    @Test func pendingCardPreservesDetailsAndOfferedChoices() throws {
        let model = makeModel()
        model.sessionProfileID = "builder"
        request(model, session: "current", id: "one")
        let record = try #require(model.currentConversationApproval)
        #expect(record.approval.detail == "git status")
        #expect(record.approval.reason == "Review command")
        #expect(record.approval.choices == ["once", "deny"])
        request(model, session: "current", id: "one")
        #expect(model.currentConversationApproval?.id == record.id)
    }

    @Test func replacementAndCancellationKeepExactIdentity() throws {
        let model = makeModel()
        model.sessionProfileID = "builder"
        request(model, session: "current", id: "one")
        let first = try #require(model.currentConversationApproval)
        request(model, session: "current", id: "two")
        let second = try #require(model.currentConversationApproval)
        #expect(first.id != second.id)
        model.resolveApproval(for: "current", requestID: "server-one", resumesWork: false)
        #expect(model.currentConversationApproval == second)
        model.resolveApproval(for: "current", requestID: "server-two", resumesWork: false)
        #expect(model.currentConversationApproval?.resolved == true)
        request(model, session: "current", id: "two")
        #expect(model.currentConversationApproval?.resolved == true)
        #expect(model.pendingApprovalsBySessionID["current"] == nil)
    }

    @Test func resolvedCardDoesNotLeakAcrossProfiles() throws {
        let model = makeModel()
        model.sessionProfileID = "builder"
        request(model, session: "current", id: "one")
        model.resolveApproval(for: "current", requestID: "one", resumesWork: false)
        #expect(model.currentConversationApproval?.resolved == true)
        model.sessionProfileID = "another"
        #expect(model.currentConversationApproval == nil)
        model.sessionProfileID = "builder"
        #expect(model.currentConversationApproval?.resolved == true)
    }

    @Test func legacyUncertainResponseRequiresPendingReadBeforeRetry() async throws {
        let rpc = ConversationApprovalRPC()
        let model = makeModel(rpc)
        model.receiveGatewayEvent(
            "approval.request",
            params: [
                "session_id": "current", "payload": ["command": "git status"],
            ])
        let record = try #require(model.currentConversationApproval)
        model.respondToApproval(ApprovalChoice.once)
        try await waitUntil { rpc.response != nil }
        #expect(rpc.requests.first { $0.0 == "approval.respond" }?.1["request_id"] == nil)
        rpc.response?.resume(throwing: HermesGateway.GatewayError.disconnected)
        rpc.response = nil
        try await waitUntil {
            if case .uncertain = model.currentConversationApproval?.legacyAnswer { return true }
            return false
        }
        model.respondToApproval(ApprovalChoice.once)
        #expect(rpc.requests.filter { $0.0 == "approval.respond" }.count == 1)
        rpc.approvals = [["command": "git status"]]
        model.recheckLegacyApproval(record.id)
        try await waitUntil { model.currentConversationApproval?.legacyAnswer == nil }
        model.respondToApproval(ApprovalChoice.deny)
        try await waitUntil { rpc.response != nil }
        rpc.response?.resume(returning: ["resolved": 1])
        rpc.response = nil
        try await waitUntil { model.currentConversationApproval?.resolved == true }
    }

    @Test func legacyRefusalRemainsRetryable() async throws {
        let rpc = ConversationApprovalRPC()
        let model = makeModel(rpc)
        model.receiveGatewayEvent(
            "approval.request",
            params: [
                "session_id": "current", "payload": ["command": "git status"],
            ])
        model.respondToApproval(ApprovalChoice.once)
        try await waitUntil { rpc.response != nil }
        rpc.response?.resume(throwing: NSError(domain: "Hermes", code: 1))
        rpc.response = nil
        try await waitUntil {
            if case .failed = model.currentConversationApproval?.legacyAnswer { return true }
            return false
        }
        #expect(model.currentConversationApproval?.resolved == false)
        #expect(model.currentConversationApproval?.legacyAnswer?.blocksSubmission == false)
    }

    @Test func notchAnswerPublishesIntoOpenTranscript() async throws {
        let rpc = ConversationApprovalRPC()
        let model = makeModel(rpc)
        model.sessionProfileID = "builder"
        let source = ConversationTranscriptSource(
            model: model, bots: BotModeModel(), actions: ConversationMessageActionState(),
            voice: VoiceOutput(), coordinator: ConversationTranscriptCoordinator())
        request(model, session: "current", id: "one")
        try await waitUntil { source.snapshot.context.conversationApproval != nil }
        let record = try #require(source.snapshot.context.conversationApproval)
        let target = try #require(record.target)
        model.answerAttention(target, choice: ApprovalChoice.once)
        try await waitUntil { rpc.response != nil }
        try await waitUntil { source.snapshot.context.approvalAnswer == .sending(ApprovalChoice.once) }
        rpc.response?.resume(returning: ["resolved": 1])
        rpc.response = nil
        try await waitUntil { model.currentConversationApproval?.resolved == true }
        try await waitUntil { source.snapshot.context.conversationApproval == nil }
        #expect(source.snapshot.context.approvalAnswer == nil)
    }

    @Test func inlineAcknowledgmentRetainsResolvedCard() async throws {
        let rpc = ConversationApprovalRPC()
        let model = makeModel(rpc)
        model.sessionProfileID = "builder"
        request(model, session: "current", id: "one")
        let record = try #require(model.currentConversationApproval)
        model.respondToApproval(ApprovalChoice.once)
        model.respondToApproval(ApprovalChoice.deny)
        try await waitUntil { rpc.response != nil }
        let sent = try #require(rpc.requests.first { $0.0 == "approval.respond" }?.1)
        #expect(sent["request_id"] as? String == "one")
        #expect(sent["profile"] as? String == "builder")
        #expect(rpc.requests.filter { $0.0 == "approval.respond" }.count == 1)
        rpc.response?.resume(returning: ["resolved": 1])
        rpc.response = nil
        try await waitUntil { model.currentConversationApproval?.resolved == true }
        #expect(model.currentConversationApproval?.id == record.id)
        #expect(model.currentConversationApproval?.approval == record.approval)
    }

    @Test func resolvedCardSurvivesAliasDiscovery() throws {
        let model = makeModel()
        model.sessionProfileID = "builder"
        request(model, session: "current", id: "one")
        model.resolveApproval(for: "current", requestID: "one", resumesWork: false)
        model.restorePendingApproval(for: ["current", "stored"])
        model.sessionID = "stored"
        model.sessionStorageID = "stored"
        model.kanbanAttributionSessionID = "stored"
        #expect(model.currentConversationApproval?.resolved == true)
    }

    @Test(arguments: [false, true])
    func legacyLateAcknowledgmentCannotResolveAnotherProfile(generationChanged: Bool) async throws {
        let rpc = ConversationApprovalRPC()
        let model = makeModel(rpc)
        model.sessionProfileID = "first"
        model.receiveGatewayEvent(
            "approval.request", params: ["session_id": "current", "payload": ["command": "git status"]])
        let original = try #require(model.currentConversationApproval)
        model.respondToApproval(ApprovalChoice.once)
        try await waitUntil { rpc.response != nil }
        model.sessionProfileID = "second"
        if generationChanged { model.sessionResumeGeneration += 1 }
        model.receiveGatewayEvent(
            "approval.request", params: ["session_id": "current", "payload": ["command": "git status"]])
        let replacement = try #require(model.currentConversationApproval)
        rpc.response?.resume(returning: ["resolved": 1])
        rpc.response = nil
        try await waitUntil {
            guard let old = model.conversationApprovals.first(where: { $0.id == original.id }) else { return false }
            if case .uncertain = old.legacyAnswer { return true }
            return false
        }
        #expect(model.currentConversationApproval?.id == replacement.id)
        #expect(model.currentConversationApproval?.resolved == false)
        #expect(model.pendingApprovalsBySessionID["current"] != nil)
        model.restorePendingApproval(for: ["current", "stored"])
        #expect(model.conversationApprovals.first { $0.id == original.id }?.aliases.contains("stored") == false)
        #expect(model.currentConversationApproval?.aliases.contains("stored") == true)
        model.resolveApproval(for: "current", recordID: original.id)
        #expect(model.pendingApprovalsBySessionID["current"] != nil)
        #expect(model.currentConversationApproval?.resolved == false)
        model.isRespondingToApproval = false
        model.respondToApproval(ApprovalChoice.deny)
        try await waitUntil { rpc.response != nil }
        rpc.response?.resume(returning: ["resolved": 1])
        rpc.response = nil
        try await waitUntil { model.currentConversationApproval?.resolved == true }
        #expect(model.conversationApprovals.first { $0.id == original.id }?.resolved == false)
        #expect(model.currentConversationApproval?.id == replacement.id)
    }

    @Test func backgroundLegacyApprovalUsesSessionOwner() async throws {
        let rpc = ConversationApprovalRPC()
        let model = makeModel(rpc)
        model.sessions = [
            HermesSession(
                id: "background", profileID: "builder", title: "Background", preview: "", startedAt: nil,
                messageCount: 1, source: "herm")
        ]
        model.receiveGatewayEvent(
            "approval.request", params: ["session_id": "background", "payload": ["command": "git status"]])
        model.sessionID = "background"
        model.sessionStorageID = "background"
        model.sessionProfileID = "builder"
        model.restorePendingApproval(for: ["background"])
        #expect(model.currentConversationApproval?.profileID == "builder")
        model.respondToApproval(ApprovalChoice.once)
        try await waitUntil { rpc.response != nil }
        let params = try #require(rpc.requests.first { $0.0 == "approval.respond" }?.1)
        #expect(params["session_id"] as? String == "background")
        #expect(params["profile"] as? String == "builder")
        #expect(params["request_id"] == nil)
        rpc.response?.resume(returning: ["resolved": 1])
        rpc.response = nil
        try await waitUntil { model.currentConversationApproval?.resolved == true }
    }

    @Test func voiceApprovalTracksSharedAnswerAndOmitsResolved() async throws {
        let rpc = ConversationApprovalRPC()
        let model = makeModel(rpc)
        model.sessionProfileID = "builder"
        request(model, session: "current", id: "one")
        let target = try #require(model.currentConversationApproval?.target)
        model.answerAttention(target, choice: ApprovalChoice.once)
        try await waitUntil { rpc.response != nil }
        #expect(model.voiceApproval?.answer == .sending(ApprovalChoice.once))
        rpc.response?.resume(throwing: HermesGateway.GatewayError.disconnected)
        rpc.response = nil
        try await waitUntil {
            if case .uncertain = model.voiceApproval?.answer { return true }
            return false
        }
        rpc.approvals = [["request_id": "one"]]
        model.recheckAttention(target)
        try await waitUntil { model.voiceApproval?.answer == nil }
        #expect(rpc.requests.contains { $0.0 == "approval.pending" })
        model.resolveApproval(for: "current", requestID: "one", resumesWork: false)
        #expect(model.voiceApproval == nil)
    }

    @Test func legacyRecheckDoesNotResolveReplacement() async throws {
        let rpc = ConversationApprovalRPC()
        let model = makeModel(rpc)
        model.receiveGatewayEvent(
            "approval.request",
            params: [
                "session_id": "current", "payload": ["command": "git status"],
            ])
        let old = try #require(model.currentConversationApproval)
        model.respondToApproval(ApprovalChoice.once)
        try await waitUntil { rpc.response != nil }
        rpc.response?.resume(throwing: HermesGateway.GatewayError.disconnected)
        rpc.response = nil
        try await waitUntil {
            if case .uncertain = model.currentConversationApproval?.legacyAnswer { return true }
            return false
        }
        model.receiveGatewayEvent(
            "approval.request",
            params: [
                "session_id": "current", "payload": ["request_id": "replacement", "command": "other"],
            ])
        model.recheckLegacyApproval(old.id)
        #expect(!rpc.requests.contains { $0.0 == "approval.pending" })
        #expect(model.pendingApprovalsBySessionID["current"]?.presentation.requestID == "replacement")
    }
}

extension ConversationApprovalTests {
    @Test func newApprovalReopensAfterAnEarlierDecisionInTheSameSession() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let control = ControlCenterModel(presentationDefaults: defaults)
        control.ingestEvent("approval.request", params: ["session_id": "background", "payload": ["command": "first"]])
        var item = try #require(control.attention.first { $0.reference.sessionID == "background" })
        item.state = .resolved
        control.knownAttention[item.id] = item
        control.persistPresentationState()
        control.rebuildAttention()
        #expect(control.attention.isEmpty)
        // A relaunch restores the earlier decision; Hermes' next request must still surface.
        let restored = ControlCenterModel(presentationDefaults: defaults)
        restored.ingestEvent(
            "approval.request", params: ["session_id": "background", "payload": ["command": "second"]])
        #expect(restored.attention.first { $0.reference.sessionID == "background" }?.detail == "second")
    }
}
