import Foundation
import Testing

@testable import Herm

@MainActor
private final class QuickMessageRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var requests: [(String, [String: Any])] = []
    var reject = false
    var resumedID: String?
    var running = false
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        if method == "prompt.submit", reject {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Request rejected"])
        }
        if method == "session.resume" {
            return ["session_id": resumedID ?? (params["session_id"] as? String ?? ""), "running": running]
        }
        return ["session_id": "created-chat"]
    }
}

@MainActor
struct QuickMessageTests {
    private func makeModel(_ rpc: QuickMessageRPC, sessionID: String? = "current-chat") -> DockModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return DockModel(
            sessionAgentStateFileURL: root.appendingPathComponent("agents.json"),
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            initialSessionID: sessionID,
            botActivityFileURL: root.appendingPathComponent("bots.json"), rpcClient: rpc)
    }

    private func session(_ id: String, profile: String? = nil) -> HermesSession {
        HermesSession(
            id: id, profileID: profile, title: id, preview: "", startedAt: nil, messageCount: 0, source: "herm")
    }

    @Test func sendsToCurrentChatWithoutConsumingWorkspaceDraftOrPDF() async throws {
        let rpc = QuickMessageRPC()
        let model = makeModel(rpc)
        model.draft = "Unfinished workspace message"
        let pdf = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        defer { try? FileManager.default.removeItem(at: pdf) }
        model.stagePDFFile(at: pdf)
        let error: String? = await withCheckedContinuation { continuation in
            model.sendQuickMessage("  Quick request  ", to: session("current-chat")) {
                continuation.resume(returning: $0)
            }
        }
        #expect(error == nil)
        let request = rpc.requests.first { $0.0 == "prompt.submit" }
        #expect(request?.1["session_id"] as? String == "current-chat")
        #expect(request?.1["text"] as? String == GenerativeUIIntegration.preparePrompt("Quick request"))
        #expect(model.draft == "Unfinished workspace message")
        #expect(model.pendingPDFURL == pdf)
        #expect(!rpc.requests.contains { $0.0 == "session.create" || $0.0 == "pdf.attach" })
    }

    @Test func rejectedSubmissionReportsFailureAndCanRetry() async {
        let rpc = QuickMessageRPC()
        rpc.reject = true
        let model = makeModel(rpc)
        let error: String? = await withCheckedContinuation { continuation in
            model.sendQuickMessage("Try this", to: session("current-chat")) { continuation.resume(returning: $0) }
        }
        #expect(error?.contains("Request rejected") == true)
        #expect(!model.isSending)
        #expect(model.quickMessageUnavailableReason(for: session("current-chat")) == nil)
    }

    @Test func busyOfflineAndSlashCommandsDoNotSubmit() {
        let rpc = QuickMessageRPC()
        let model = makeModel(rpc)
        for status in [HermesStatus.working, .needsApproval, .needsClarification, .offline] {
            model.status = status
            var error: String?
            model.sendQuickMessage("Hello", to: session("current-chat")) { error = $0 }
            #expect(error != nil)
        }
        model.status = .idle
        var error: String?
        model.sendQuickMessage("/new") { error = $0 }
        #expect(error != nil)
        #expect(rpc.requests.isEmpty)
    }

    @Test func explicitStartChatCreatesSessionAndPreservesDraft() async {
        let rpc = QuickMessageRPC()
        let model = makeModel(rpc)
        model.isSending = true
        model.status = .working
        model.draft = "Workspace draft"
        let error: String? = await withCheckedContinuation { continuation in
            model.sendQuickMessage("First message") { continuation.resume(returning: $0) }
        }
        #expect(error == nil)
        #expect(model.sessionID == "current-chat")
        #expect(model.isSending)
        #expect(model.status == .working)
        #expect(model.draft == "Workspace draft")
        #expect(rpc.requests.last { $0.0 == "prompt.submit" }?.1["session_id"] as? String == "created-chat")
    }
    @Test func repliesToCapturedSessionAndProfileWithoutChangingWorkspace() async {
        let rpc = QuickMessageRPC()
        let model = makeModel(rpc)
        model.draft = "Workspace draft"
        let error: String? = await withCheckedContinuation { continuation in
            model.sendQuickMessage("Reply", to: session("other-chat", profile: "builder")) {
                continuation.resume(returning: $0)
            }
        }
        #expect(error == nil)
        let request = rpc.requests.first { $0.0 == "prompt.submit" }
        #expect(request?.1["session_id"] as? String == "other-chat")
        #expect(request?.1["profile"] as? String == "builder")
        #expect(model.sessionID == "current-chat")
        #expect(model.draft == "Workspace draft")
        #expect(!rpc.requests.contains { $0.0 == "session.create" })
    }

    @Test func mismatchedOrBusyResumeNeverReceivesReply() async {
        for busy in [false, true] {
            let rpc = QuickMessageRPC()
            rpc.running = busy
            rpc.resumedID = busy ? "other-chat" : "wrong-chat"
            let model = makeModel(rpc)
            let error: String? = await withCheckedContinuation { continuation in
                model.sendQuickMessage("Reply", to: session("other-chat")) { continuation.resume(returning: $0) }
            }
            #expect(error != nil)
            #expect(!rpc.requests.contains { $0.0 == "prompt.submit" })
            #expect(model.sessionID == "current-chat")
        }
    }

    @Test func failedNewMessageRetainsCreatedSessionForRetry() async {
        let rpc = QuickMessageRPC()
        rpc.reject = true
        let model = makeModel(rpc)
        var created: HermesSession?
        let firstError: String? = await withCheckedContinuation { continuation in
            model.sendQuickMessage("New message", onCreated: { created = $0 }) { continuation.resume(returning: $0) }
        }
        #expect(firstError != nil)
        #expect(created?.id == "created-chat")
        rpc.reject = false
        let retryError: String? = await withCheckedContinuation { continuation in
            model.sendQuickMessage("New message", to: created) { continuation.resume(returning: $0) }
        }
        #expect(retryError == nil)
        #expect(rpc.requests.filter { $0.0 == "session.create" }.count == 1)
    }

    @Test func draftsStayWithTheirTargetsAndReplyRowStaysVisible() {
        let state = EdgeNotchState()
        state.quickDraft = "New session draft"
        let task = EdgeNotchTask(
            id: "other-chat", title: "Other", phase: .finished,
            statusLabel: "Finished", detail: nil, updatedAt: nil, isCurrent: false,
            isStatusCurrent: true, session: session("other-chat"))
        state.selectQuickTarget(task.session, task: task)
        #expect(state.quickDraft.isEmpty)
        state.quickDraft = "Reply draft"
        state.composing = true
        #expect(state.previewTasks.map(\.id) == ["other-chat"])
        state.selectQuickTarget(nil)
        #expect(state.quickDraft == "New session draft")
        state.selectQuickTarget(task.session, task: task)
        #expect(state.quickDraft == "Reply draft")
    }

}
