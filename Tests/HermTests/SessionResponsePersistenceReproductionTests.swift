import Foundation
import Testing

@testable import Herm

@MainActor
private final class ResponsePersistenceRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var interruptResponse: [String: Any] = ["status": "interrupted"]
    var holdInterrupt = false
    var interruptIsHeld = false
    var interruptContinuation: CheckedContinuation<Void, Never>?
    var resumeRows: [[String: Any]] = []
    var resumeRunning = false
    var holdNextConnect = false
    private(set) var connectIsHeld = false
    private var connectContinuation: CheckedContinuation<Void, Never>?
    var effortContinuation: CheckedContinuation<Void, Never>?
    var effortReturned = false
    private(set) var requests: [(method: String, params: [String: Any])] = []

    func connect() async throws {
        guard holdNextConnect else { return }
        holdNextConnect = false
        connectIsHeld = true
        await withCheckedContinuation { continuation in
            connectContinuation = continuation
        }
        connectIsHeld = false
    }

    func releaseConnect() {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        switch method {
        case "config.set":
            await withCheckedContinuation { effortContinuation = $0 }
            effortReturned = true
            return ["key": "reasoning", "value": "high", "scope": "session"]
        case "session.resume":
            return [
                "session_id": params["session_id"] as? String ?? "", "messages": resumeRows, "running": resumeRunning,
            ]
        case "session.interrupt":
            if holdInterrupt {
                interruptIsHeld = true
                await withCheckedContinuation { interruptContinuation = $0 }
            }
            return interruptResponse
        case "prompt.submit":
            return ["status": "streaming"]
        default:
            return [:]
        }
    }

    func close() {}
}

@MainActor
struct SessionResponsePersistenceReproductionTests {
    @Test func delayedEffortMutationCannotOverwriteRecoveredDestination() async throws {
        let rpc = ResponsePersistenceRPCClient()
        let model = DockModel(rpcClient: rpc)
        defer { model.delegationMonitoringTask?.cancel() }
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        model.updateSessionReasoning(.high)
        try await waitFor { rpc.effortContinuation != nil }

        let snapshot = SessionComposerDraft(
            text: "recovered destination draft", images: [], pdfURL: nil, contexts: [], replyQuote: nil,
            attachmentError: nil, pdfError: nil)
        let owner = SessionComposerDraft.Key(profileID: model.composerDraftKey.profileID, sessionID: "other")
        model.pendingSessionSends.append(
            SessionPendingSend(
                id: UUID(), owner: owner, snapshot: snapshot,
                message: ChatMessage(role: .user, text: snapshot.text), baselineRowID: 0, phase: .notSent))
        #expect(await model.resumeSession(session("other"), reportFailure: true))
        model.receiveGatewayEvent(
            "session.info", params: ["session_id": "other", "payload": ["reasoning_effort": "low"]])
        expect(model.draft == "recovered destination draft")
        expect(model.sessionReasoningVariant == .low)
        let originReads = rpc.requests.filter {
            $0.method == "config.get" && $0.params["session_id"] as? String == "origin"
        }.count

        rpc.effortContinuation?.resume()
        rpc.effortContinuation = nil
        try await waitFor { rpc.effortReturned }
        await Task.yield()
        expect(model.sessionID == "other")
        expect(model.sessionReasoningVariant == .low)
        expect(model.draft == "recovered destination draft")
        expect(
            rpc.requests.filter {
                $0.method == "config.get" && $0.params["session_id"] as? String == "origin"
            }.count == originReads)
    }
    // Evaluate outside the macro so failure diagnostics cannot reflect the model's cached user history.
    private func expect(_ condition: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(condition, sourceLocation: sourceLocation)
    }

    private func session(_ id: String) -> HermesSession {
        HermesSession(id: id, title: id, preview: "", startedAt: nil, messageCount: 0, source: "test")
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    @Test func refusedStopMustNotClaimSuccessOrDiscardContinuingOutput() async throws {
        let rpc = ResponsePersistenceRPCClient()
        rpc.interruptResponse = ["status": "not_interrupted", "interrupted": false]
        let model = DockModel(rpcClient: rpc)
        defer { model.delegationMonitoringTask?.cancel() }
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        model.receiveGatewayEvent("message.start", params: ["session_id": "origin", "payload": [:]])
        model.receiveGatewayEvent(
            "message.delta", params: ["session_id": "origin", "payload": ["delta": "Still working"]])
        let streamingID = try #require(model.streamingMessageIDForPresentation)

        await model.stop()?.value

        expect(model.interruptState.isFailed)
        expect(model.isSending)
        expect(model.streamingMessageIDForPresentation == streamingID)
        expect(!model.isDiscardingStoppedTurn)
        model.receiveGatewayEvent(
            "message.delta", params: ["session_id": "origin", "payload": ["delta": " after refusal"]])
        expect(model.streamingMessageBuffer.contains("after refusal"))
    }

    @Test func stopMustKeepTheOriginProfileWhenNavigationWinsTheTaskRace() async throws {
        let rpc = ResponsePersistenceRPCClient()
        let model = DockModel(rpcClient: rpc)
        defer { model.delegationMonitoringTask?.cancel() }
        let origin = HermesSession(
            id: "origin", profileID: "alpha", title: "Origin", preview: "", startedAt: nil, messageCount: 0,
            source: "test")
        let other = HermesSession(
            id: "other", profileID: "beta", title: "Other", preview: "", startedAt: nil, messageCount: 0,
            source: "test")
        #expect(await model.resumeSession(origin, reportFailure: true))

        let stop = model.stop()
        #expect(await model.resumeSession(other, reportFailure: true))
        await stop?.value

        let request = try #require(rpc.requests.first { $0.method == "session.interrupt" })
        #expect(request.params["session_id"] as? String == "origin")
        #expect(request.params["profile"] as? String == "alpha")
    }

    @Test func acknowledgedMessageWithoutStartMustSurviveNavigationOrShowAnError() async throws {
        let rpc = ResponsePersistenceRPCClient()
        let model = DockModel(rpcClient: rpc)
        defer { model.delegationMonitoringTask?.cancel() }
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        model.draft = "Keep this acknowledged message"
        var reportedSubmission = false
        var submissionError: String?
        model.send(onSubmission: { error in
            reportedSubmission = true
            submissionError = error
        })
        try await waitFor { reportedSubmission }
        #expect(submissionError == nil)
        expect(model.messages.contains { $0.role == .user && $0.text == "Keep this acknowledged message" })
        expect(model.streamingMessageIDForPresentation == nil)

        #expect(await model.resumeSession(session("other"), reportFailure: true))
        #expect(await model.resumeSession(session("origin"), reportFailure: true))

        expect(
            model.messages.contains { $0.role == .user && $0.text == "Keep this acknowledged message" }
                && model.messages.contains { $0.text.localizedCaseInsensitiveContains("could not confirm") })
    }

    @Test func olderIdenticalStoredMessageDoesNotHideUnconfirmedSend() {
        let model = DockModel(rpcClient: ResponsePersistenceRPCClient())
        defer { model.delegationMonitoringTask?.cancel() }
        let old = ChatMessage(role: .user, text: "Repeated prompt")
        let pending = ChatMessage(role: .user, text: "Repeated prompt")
        model.pendingSessionSends.append(
            SessionPendingSend(
                id: UUID(), owner: model.composerDraftKey,
                snapshot: SessionComposerDraft(
                    text: "Repeated prompt", images: [], pdfURL: nil, contexts: [], replyQuote: nil,
                    attachmentError: nil, pdfError: nil), message: pending, baselineRowID: 7))
        let visible = model.reconcilePendingSends(for: model.composerDraftKey, restored: [old], rowIDs: [7: old.id])
        expect(visible.contains { $0.id == pending.id })
        expect(model.pendingSessionSends.count == 1)
    }

    @Test func submittedPayloadMatchesParsedResumeRow() async throws {
        let rpc = ResponsePersistenceRPCClient()
        let model = DockModel(rpcClient: rpc)
        defer { model.delegationMonitoringTask?.cancel() }
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        let payload = "Question\n\n@file:/tmp/reference.txt"
        let snapshot = SessionComposerDraft(
            text: "Question", images: [], pdfURL: nil, contexts: [], replyQuote: nil,
            attachmentError: nil, pdfError: nil)
        model.pendingSessionSends.append(
            SessionPendingSend(
                id: UUID(), owner: model.composerDraftKey, snapshot: snapshot,
                message: ChatMessage(role: .user, text: "Question"), baselineRowID: 0,
                submittedText: payload, phase: .acknowledged))
        rpc.resumeRows = [["row_id": 1, "role": "user", "content": payload]]
        #expect(await model.resumeSession(session("other"), reportFailure: true))
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        expect(model.pendingSessionSends.isEmpty)
        expect(model.messages.filter { $0.role == .user }.count == 1)
    }

    @Test func recalledMemoryDoesNotDuplicateConfirmedMessageOnReturn() async throws {
        let rpc = ResponsePersistenceRPCClient()
        let model = DockModel(rpcClient: rpc)
        defer { model.delegationMonitoringTask?.cancel() }
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        let prompt = "Fix this error"
        model.pendingSessionSends.append(
            SessionPendingSend(
                id: UUID(), owner: model.composerDraftKey,
                snapshot: SessionComposerDraft(
                    text: prompt, images: [], pdfURL: nil, contexts: [], replyQuote: nil,
                    attachmentError: nil, pdfError: nil),
                message: ChatMessage(role: .user, text: prompt), baselineRowID: 0,
                submittedText: prompt, phase: .acknowledged))
        rpc.resumeRows = [
            [
                "row_id": 1, "role": "user",
                "content": prompt + "\n\n<memory-context>\n"
                    + "[System note: The following is recalled memory context, NOT new user input. Background.]\n"
                    + "Recall\n</memory-context>",
            ]
        ]
        #expect(await model.resumeSession(session("other"), reportFailure: true))
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        expect(model.pendingSessionSends.isEmpty)
        expect(model.messages.filter { $0.role == .user }.map(\.text) == [prompt])
        expect(!model.messages.contains { $0.text.contains("could not confirm") })
        expect(
            DockModel.userTextWithoutRecalledMemory("Explain <memory-context> tags") == "Explain <memory-context> tags")
    }

    @Test func capacityKeepsDequeuedPromptAndAttachments() async throws {
        let rpc = ResponsePersistenceRPCClient()
        let model = DockModel(rpcClient: rpc)
        defer { model.delegationMonitoringTask?.cancel() }
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        let snapshot = SessionComposerDraft(
            text: "pending", images: [], pdfURL: nil, contexts: [], replyQuote: nil,
            attachmentError: nil, pdfError: nil)
        for _ in 0..<256 {
            model.pendingSessionSends.append(
                SessionPendingSend(
                    id: UUID(), owner: model.composerDraftKey, snapshot: snapshot,
                    message: ChatMessage(role: .user, text: "pending"), baselineRowID: 0))
        }
        let pdf = URL(fileURLWithPath: "/tmp/queued.pdf")
        let queued = QueuedPrompt(sessionID: "origin", text: "queued", images: [], pdfURL: pdf)
        model.queuedPrompts = [queued]
        model.drainQueuedPromptIfIdle()
        expect(model.queuedPrompts.first?.id == queued.id)
        expect(model.queuedPrompts.first?.pdfURL == pdf)
        expect(!rpc.requests.contains { $0.method == "prompt.submit" })
    }

    @Test func recoveryWaitsUntilNewerDraftIsConsumed() async throws {
        let rpc = ResponsePersistenceRPCClient()
        let model = DockModel(rpcClient: rpc)
        defer { model.delegationMonitoringTask?.cancel() }
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        let snapshot = SessionComposerDraft(
            text: "older", images: [], pdfURL: nil, contexts: [], replyQuote: nil,
            attachmentError: nil, pdfError: nil)
        model.pendingSessionSends.append(
            SessionPendingSend(
                id: UUID(), owner: model.composerDraftKey, snapshot: snapshot,
                message: ChatMessage(role: .user, text: "older"), baselineRowID: 0, phase: .notSent))
        model.draft = "newer"
        model.send()
        expect(model.draft == "older")
    }

    @Test func recoveryWaitsForAllComposerContentAfterTextIsCleared() async throws {
        let rpc = ResponsePersistenceRPCClient()
        let model = DockModel(rpcClient: rpc)
        defer { model.delegationMonitoringTask?.cancel() }
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        let snapshot = SessionComposerDraft(
            text: "older", images: [], pdfURL: nil, contexts: [], replyQuote: nil,
            attachmentError: nil, pdfError: nil)
        model.pendingSessionSends.append(
            SessionPendingSend(
                id: UUID(), owner: model.composerDraftKey, snapshot: snapshot,
                message: ChatMessage(role: .user, text: "older"), baselineRowID: 0, phase: .notSent))
        model.draft = "newer"
        model.pendingPDFURL = URL(fileURLWithPath: "/tmp/newer.pdf")
        model.attachedContexts = [ChatContext(id: "new", title: "New", body: "context")]
        model.replyQuote = ReplyQuote(author: "Herm", text: "quote")
        model.draft = ""
        model.restorePendingSendIfPossible(for: model.composerDraftKey)
        expect(model.draft.isEmpty && !model.composerIsEmptyForRecovery)
        model.pendingPDFURL = nil
        model.attachedContexts = []
        model.restorePendingSendIfPossible(for: model.composerDraftKey)
        expect(model.draft.isEmpty && !model.composerIsEmptyForRecovery)
        model.replyQuote = nil
        expect(model.composerIsEmptyForRecovery)
        model.restorePendingSendIfPossible(for: model.composerDraftKey)
        expect(model.draft == "older")
    }

    @Test func acceptedStopSurvivesNavigationAndDoesNotAffectOtherSession() async throws {
        let rpc = ResponsePersistenceRPCClient()
        let model = DockModel(rpcClient: rpc)
        defer { model.delegationMonitoringTask?.cancel() }
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        model.receiveGatewayEvent("message.start", params: ["session_id": "origin", "payload": [:]])
        model.receiveGatewayEvent(
            "message.delta", params: ["session_id": "origin", "payload": ["delta": "Before stop"]])
        await model.stop()?.value
        expect(!model.isSending)
        #expect(await model.resumeSession(session("other"), reportFailure: true))
        model.receiveGatewayEvent("message.start", params: ["session_id": "other", "payload": [:]])
        model.receiveGatewayEvent(
            "message.delta", params: ["session_id": "other", "payload": ["delta": "Other reply"]])
        model.receiveGatewayEvent(
            "message.delta", params: ["session_id": "origin", "payload": ["delta": "Late output"]])
        expect(model.streamingMessageBuffer == "Other reply")
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        model.receiveGatewayEvent(
            "message.delta", params: ["session_id": "origin", "payload": ["delta": "Late output"]])
        model.receiveGatewayEvent(
            "message.complete", params: ["session_id": "origin", "payload": ["text": "Late output"]])
        expect(!model.isSending)
        expect(!model.messages.contains { $0.text.contains("Late output") })
        #expect(await model.resumeSession(session("other"), reportFailure: true))
        model.receiveGatewayEvent("message.start", params: ["session_id": "other", "payload": [:]])
        model.receiveGatewayEvent(
            "message.delta", params: ["session_id": "other", "payload": ["delta": "Still works"]])
        expect(model.isSending && model.streamingMessageBuffer == "Still works")
    }

    @Test func refusedStopAfterReturnAppearsOnOrigin() async throws {
        let rpc = ResponsePersistenceRPCClient()
        rpc.holdInterrupt = true
        rpc.interruptResponse = ["status": "not_interrupted"]
        rpc.resumeRunning = true
        let model = DockModel(rpcClient: rpc)
        defer {
            model.delegationMonitoringTask?.cancel()
            rpc.interruptContinuation?.resume()
        }
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        let stop = model.stop()
        try await waitFor { rpc.interruptIsHeld }
        #expect(await model.resumeSession(session("other"), reportFailure: true))
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        rpc.interruptContinuation?.resume()
        rpc.interruptContinuation = nil
        await stop?.value
        expect(model.interruptState.isFailed)
    }

    @Test func navigationBeforeSubmissionMustReturnTheUnsentDraftToItsOrigin() async throws {
        let rpc = ResponsePersistenceRPCClient()
        let model = DockModel(rpcClient: rpc)
        defer { model.delegationMonitoringTask?.cancel() }
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        rpc.holdNextConnect = true
        defer { rpc.releaseConnect() }
        model.draft = "Recover my unsent message"
        var reportedSubmission = false
        var submissionError: String?
        model.send(onSubmission: { error in
            reportedSubmission = true
            submissionError = error
        })
        try await waitFor { rpc.connectIsHeld }
        expect(model.messages.contains { $0.text == "Recover my unsent message" })

        #expect(await model.resumeSession(session("other"), reportFailure: true))
        rpc.releaseConnect()
        try await waitFor { reportedSubmission }
        #expect(submissionError != nil)
        #expect(!rpc.requests.contains { $0.method == "prompt.submit" })
        expect(model.draft.isEmpty)
        #expect(await model.resumeSession(session("origin"), reportFailure: true))

        expect(model.draft == "Recover my unsent message")
    }
}
