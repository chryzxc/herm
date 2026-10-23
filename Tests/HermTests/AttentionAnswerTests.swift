import AppKit
import Foundation
import Testing

@testable import Herm

@MainActor
private final class AttentionAnswerRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var requests: [(String, [String: Any])] = []
    var pending: CheckedContinuation<[String: Any], Error>?
    var pendingApprovals: [[String: Any]] = []
    var openRequests: [[String: Any]]?

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        if method == "approval.pending" { return ["approvals": pendingApprovals] }
        if method == "session.events.since" { return openRequests.map { ["open_requests": $0] } ?? [:] }
        if ["approval.respond", "request.answer"].contains(method) {
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return [:]
    }
}

@MainActor
struct AttentionAnswerTests {
    private func makeModel(_ rpc: AttentionAnswerRPC) -> DockModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return DockModel(
            sessionAgentStateFileURL: root.appendingPathComponent("agents.json"),
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            initialSessionID: "current", botActivityFileURL: root.appendingPathComponent("bots.json"),
            rpcClient: rpc)
    }

    private func ask(
        _ model: DockModel, session: String = "current", id: String = "question",
        approval: Bool = false,
        profile: String = "builder"
    ) throws -> AttentionRequest {
        model.receiveGatewayEvent(
            approval ? "approval.request" : "clarify.request",
            params: [
                "session_id": session,
                "payload": [
                    "profile": profile, "request_id": id, "question": "Which environment?",
                    "choices": ["Staging", "Production"], "command": "git push",
                ],
            ])
        return try #require(model.sessionAttention[session]?.responseTarget)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for the answer")
    }

    @Test func currentQuickAnswerPreservesWorkspaceAndBlocksOtherAnswerSurfaces() async throws {
        let rpc = AttentionAnswerRPC()
        let model = makeModel(rpc)
        let request = try ask(model)
        model.draft = "Workspace draft"
        let image = ImageAttachment(
            image: NSImage(size: NSSize(width: 2, height: 2)),
            fileURL: URL(fileURLWithPath: "/tmp/workspace-image.png"))
        model.pendingImages = [image]
        let pdf = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        defer { try? FileManager.default.removeItem(at: pdf) }
        model.stagePDFFile(at: pdf)
        model.answerAttention(request, choice: "Staging")
        model.answerAttention(request, choice: "Production")
        model.respondToClarification("Production")
        try await waitUntil { rpc.pending != nil }
        #expect(rpc.requests.filter { $0.0 == "request.answer" }.count == 1)
        #expect(model.attentionAnswers[request] == .sending("Staging"))
        let params = try #require(rpc.requests.first { $0.0 == "request.answer" }?.1)
        #expect(params["profile"] as? String == "builder")
        #expect(params["id"] as? String == "question")
        #expect((params["result"] as? [String: String])?["answer"] == "Staging")
        rpc.pending?.resume(returning: ["status": "ok"])
        rpc.pending = nil
        try await waitUntil { model.sessionAttention["current"] == nil }
        #expect(model.draft == "Workspace draft")
        #expect(model.pendingImages.map(\.id) == [image.id])
        #expect(model.pendingPDFURL == pdf)
        #expect(model.clarificationQuestion == nil)
        #expect(model.status == .working)
    }

    @Test func lateApprovalAcknowledgmentCannotClearReplacementOrAnotherProfile() async throws {
        let rpc = AttentionAnswerRPC()
        let model = makeModel(rpc)
        let old = try ask(model, session: "background", id: "old", approval: true)
        model.answerAttention(old, choice: ApprovalChoice.once)
        try await waitUntil { rpc.pending != nil }
        let replacement = try ask(
            model, session: "background", id: "new", approval: true, profile: "research")
        rpc.pending?.resume(returning: ["resolved": 1])
        rpc.pending = nil
        await Task.yield()
        #expect(model.sessionAttention["background"]?.responseTarget == replacement)
        #expect(model.attentionAnswers[old] == nil)
        model.answerAttention(old, choice: ApprovalChoice.deny)
        await Task.yield()
        #expect(rpc.requests.filter { $0.0 == "approval.respond" }.count == 1)
        let params = try #require(rpc.requests.first { $0.0 == "approval.respond" }?.1)
        #expect(params["session_id"] as? String == "background")
        #expect(params["request_id"] as? String == "old")
        #expect(params["profile"] as? String == "builder")
    }

    @Test func knownRefusalKeepsRequestAndAllowsExplicitRetry() async throws {
        let rpc = AttentionAnswerRPC()
        let model = makeModel(rpc)
        let request = try ask(model, session: "background", approval: true)
        model.answerAttention(request, choice: ApprovalChoice.once)
        try await waitUntil { rpc.pending != nil }
        rpc.pending?.resume(
            throwing: NSError(
                domain: "Hermes", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Approval rejected"]))
        rpc.pending = nil
        try await waitUntil {
            model.attentionAnswers[request] == .failed(ApprovalChoice.once, "Approval rejected")
        }
        #expect(model.sessionAttention["background"] != nil)
        model.answerAttention(request, choice: ApprovalChoice.once)
        try await waitUntil { rpc.pending != nil }
        rpc.pending?.resume(returning: ["resolved": 1])
        rpc.pending = nil
        try await waitUntil { model.sessionAttention["background"] == nil }
        #expect(rpc.requests.filter { $0.0 == "approval.respond" }.count == 2)
    }

    @Test func ambiguousResponsePreservesRequestAndDoesNotResubmit() async throws {
        let rpc = AttentionAnswerRPC()
        let model = makeModel(rpc)
        let request = try ask(model, session: "background")
        model.answerAttention(request, choice: "Staging")
        try await waitUntil { rpc.pending != nil }
        rpc.pending?.resume(returning: [:])
        rpc.pending = nil
        try await waitUntil {
            if case .uncertain = model.attentionAnswers[request] { return true }
            return false
        }
        model.answerAttention(request, choice: "Staging")
        await Task.yield()
        #expect(model.sessionAttention["background"] != nil)
        #expect(rpc.requests.filter { $0.0 == "request.answer" }.count == 1)
    }

    @Test func expiredAnswerClearsOnlyItsQuestionAndPreservesWorkspaceDraft() async throws {
        let rpc = AttentionAnswerRPC()
        let model = makeModel(rpc)
        let request = try ask(model)
        _ = try ask(model, session: "background", id: "other")
        model.draft = "Keep this"
        model.answerAttention(request, choice: "Staging")
        try await waitUntil { rpc.pending != nil }
        rpc.pending?.resume(returning: ["status": "expired"])
        rpc.pending = nil
        try await waitUntil { model.sessionAttention["current"] == nil }
        #expect(model.sessionAttention["background"]?.requestID == "other")
        #expect(model.clarificationQuestion == nil)
        #expect(model.clarificationResponseError?.contains("expired") == true)
        #expect(model.draft == "Keep this")
        #expect(model.status == .idle)
    }

    @Test func lateExpirationCannotDismissNewApproval() throws {
        let model = makeModel(AttentionAnswerRPC())
        _ = try ask(model, id: "old", approval: true)
        let replacement = try ask(model, id: "new", approval: true)
        model.receiveGatewayEvent(
            "approval.expire",
            params: [
                "session_id": "current", "payload": ["request_id": "old"],
            ])
        #expect(model.sessionAttention["current"]?.responseTarget == replacement)
    }

    @Test func uncertainApprovalRequiresFreshPendingReadBeforeRetry() async throws {
        let rpc = AttentionAnswerRPC()
        let model = makeModel(rpc)
        let request = try ask(model, session: "background", approval: true)
        model.answerAttention(request, choice: ApprovalChoice.once)
        try await waitUntil { rpc.pending != nil }
        rpc.pending?.resume(throwing: HermesGateway.GatewayError.disconnected)
        rpc.pending = nil
        try await waitUntil {
            if case .uncertain = model.attentionAnswers[request] { return true }
            return false
        }
        rpc.pendingApprovals = [["request_id": request.requestID]]
        model.recheckAttention(request)
        try await waitUntil { model.attentionAnswers[request] == nil }
        let check = try #require(rpc.requests.first { $0.0 == "approval.pending" }?.1)
        #expect(check["session_id"] as? String == "background")
        #expect(check["profile"] as? String == "builder")
        model.answerAttention(request, choice: ApprovalChoice.deny)
        try await waitUntil { rpc.pending != nil }
        rpc.pending?.resume(returning: ["resolved": 1])
        rpc.pending = nil
        try await waitUntil { model.sessionAttention["background"] == nil }
    }

    @Test func serverCancellationMatchesApprovalWithoutClearingItsReplacement() throws {
        let model = makeModel(AttentionAnswerRPC())
        func deliver(_ serverID: String, _ approvalID: String) throws {
            let event = try #require(
                HermesGateway.event(forServerRequest: [
                    "id": serverID, "method": "approval",
                    "params": ["session_id": "current", "request_id": approvalID, "command": "git push"],
                ]))
            model.receiveGatewayEvent(event.type, params: event.params)
        }
        try deliver("srq-old", "tool-old")
        try deliver("srq-new", "tool-new")
        model.receiveGatewayEvent(
            "approval.expire", params: ["session_id": "current", "payload": ["request_id": "srq-old"]])
        #expect(model.sessionAttention["current"]?.requestID == "tool-new")
        model.receiveGatewayEvent(
            "approval.expire", params: ["session_id": "current", "payload": ["request_id": "srq-new"]])
        #expect(model.sessionAttention["current"] == nil)
    }

    @Test func uncertainClarificationRequiresValidOpenRequestsBeforeRetry() async throws {
        let rpc = AttentionAnswerRPC()
        let model = makeModel(rpc)
        let request = try ask(model, session: "background")
        model.answerAttention(request, choice: "Staging")
        try await waitUntil { rpc.pending != nil }
        rpc.pending?.resume(throwing: HermesGateway.GatewayError.disconnected)
        rpc.pending = nil
        try await waitUntil {
            if case .uncertain = model.attentionAnswers[request] { return true }
            return false
        }
        model.recheckAttention(request)
        try await waitUntil {
            rpc.requests.contains { $0.0 == "session.events.since" }
                && model.attentionAnswers[request]?.blocksSubmission == true
        }
        await Task.yield()
        #expect(model.sessionAttention["background"] != nil)
        rpc.openRequests = [
            ["id": "question", "method": "clarify", "params": ["session_id": "background"]]
        ]
        // Wait for the malformed first read to restore uncertain state.
        try await waitUntil {
            if case .uncertain = model.attentionAnswers[request] { return true }
            return false
        }
        model.recheckAttention(request)
        try await waitUntil { model.attentionAnswers[request] == nil }
        #expect(model.sessionAttention["background"] != nil)
        model.answerAttention(request, choice: "Production")
        try await waitUntil { rpc.pending != nil }
        rpc.pending?.resume(throwing: HermesGateway.GatewayError.disconnected)
        rpc.pending = nil
        try await waitUntil {
            if case .uncertain = model.attentionAnswers[request] { return true }
            return false
        }
        rpc.openRequests = []
        model.recheckAttention(request)
        try await waitUntil { model.sessionAttention["background"] == nil }
        #expect(rpc.requests.filter { $0.0 == "request.answer" }.count == 2)
    }
}
