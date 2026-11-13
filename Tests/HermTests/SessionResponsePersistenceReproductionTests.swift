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
    var historyRows: [[String: Any]] = []
    private(set) var historyPaths: [String] = []
    var historyFails = false
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

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        historyPaths.append(path)
        if historyFails { throw HermesGateway.GatewayError.malformedResponse }
        return ["messages": historyRows]
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

        expect(model.messages.contains { $0.role == .user && $0.text == "Keep this acknowledged message" })
        expect(!model.messages.contains { $0.text.localizedCaseInsensitiveContains("could not confirm") })
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
        expect(visible.unmatchedMessages.contains { $0.id == pending.id })
        expect(model.pendingSessionSends.count == 1)
    }

    @Test func unresolvedSendDoesNotCreateAnAssistantWarning() {
        let model = DockModel(rpcClient: ResponsePersistenceRPCClient())
        defer { model.delegationMonitoringTask?.cancel() }
        let snapshot = SessionComposerDraft(
            text: "unconfirmed", images: [], pdfURL: nil, contexts: [], replyQuote: nil,
            attachmentError: nil, pdfError: nil)
        model.pendingSessionSends.append(
            SessionPendingSend(
                id: UUID(), owner: model.composerDraftKey, snapshot: snapshot,
                message: ChatMessage(role: .user, text: snapshot.text), baselineRowID: 0))
        let visible = model.reconcilePendingSends(for: model.composerDraftKey, restored: [], rowIDs: [:])
        #expect(visible.unmatchedMessages.allSatisfy { $0.role == .user })
        #expect(model.pendingSessionSends.count == 1)
    }

    @Test func earlierCompletionCannotConfirmLaterQueuedSend() {
        let model = DockModel(rpcClient: ResponsePersistenceRPCClient())
        defer { model.delegationMonitoringTask?.cancel() }
        let owner = model.composerDraftKey
        let snapshot = SessionComposerDraft(
            text: "same", images: [], pdfURL: nil, contexts: [], replyQuote: nil,
            attachmentError: nil, pdfError: nil)
        let first = ChatMessage(role: .user, text: "same")
        let second = ChatMessage(role: .user, text: "same")
        let firstID = UUID()
        model.pendingSessionSends = [
            SessionPendingSend(id: firstID, owner: owner, snapshot: snapshot, message: first, baselineRowID: 10),
            SessionPendingSend(
                id: UUID(), owner: owner, snapshot: snapshot, message: second, baselineRowID: 10,
                phase: .acknowledged, acceptedStatus: "queued"),
        ]
        model.confirmPendingSend(firstID, owner: owner, receipt: ["user_row_id": 11])

        let assistant = UUID()
        model.applyMessagePinReceipt(
            ["complete": true, "user_row_id": 11, "final_assistant_row_id": 12],
            assistantMessageID: assistant)
        #expect(model.pendingSessionSends.count == 1)
        #expect(model.storedMessageReferences[second.id] == nil)
        #expect(model.transcriptMessageIDsByRowID[11] == first.id)
        #expect(model.storedMessageReferences[assistant]?.rowID == 12)
    }

    @Test func prependedStoredRowResolvesItsPendingSend() {
        let model = DockModel(rpcClient: ResponsePersistenceRPCClient())
        defer { model.delegationMonitoringTask?.cancel() }
        let message = ChatMessage(role: .user, text: "stored prompt")
        let tail = ChatMessage(role: .hermes, text: "tail")
        let snapshot = SessionComposerDraft(
            text: message.text, images: [], pdfURL: nil, contexts: [], replyQuote: nil,
            attachmentError: nil, pdfError: nil)
        model.messages = [message, tail]
        model.pendingSessionSends.append(
            SessionPendingSend(
                id: UUID(), owner: model.composerDraftKey, snapshot: snapshot, message: message, baselineRowID: 10))
        model.prependEarlierTranscript(
            [["row_id": 11, "role": "user", "content": message.text]],
            cursor: TranscriptHistoryCursor(storageSessionID: "stored", profileID: nil))
        #expect(model.pendingSessionSends.isEmpty)
        #expect(model.messages.filter { $0.role == .user }.count == 1)
        #expect(model.storedMessageReferences[message.id]?.rowID == 11)
        #expect(model.messages.last?.id == tail.id)
    }

    @Test func prependedClaimedOrOlderRowCannotResolveAnotherSend() {
        let model = DockModel(rpcClient: ResponsePersistenceRPCClient())
        defer { model.delegationMonitoringTask?.cancel() }
        let owner = model.composerDraftKey
        let snapshot = SessionComposerDraft(
            text: "same", images: [], pdfURL: nil, contexts: [], replyQuote: nil,
            attachmentError: nil, pdfError: nil)
        let first = UUID()
        let second = UUID()
        for id in [first, second] {
            model.pendingSessionSends.append(
                SessionPendingSend(
                    id: id, owner: owner, snapshot: snapshot,
                    message: ChatMessage(role: .user, text: "same"), baselineRowID: 10))
        }
        model.confirmPendingSend(first, owner: owner, receipt: ["user_row_id": 11])
        let cursor = TranscriptHistoryCursor(storageSessionID: "stored", profileID: nil)
        model.prependEarlierTranscript([["row_id": 11, "role": "user", "content": "same"]], cursor: cursor)
        model.prependEarlierTranscript([["row_id": 10, "role": "user", "content": "same"]], cursor: cursor)
        #expect(model.pendingSessionSends.contains { $0.id == second })
        model.prependEarlierTranscript([["row_id": 12, "role": "user", "content": "same"]], cursor: cursor)
        #expect(!model.pendingSessionSends.contains { $0.id == second })
    }

    @Test func repeatedChecksCannotReuseAnIdenticalStoredRow() {
        let model = DockModel(rpcClient: ResponsePersistenceRPCClient())
        defer { model.delegationMonitoringTask?.cancel() }
        let owner = model.composerDraftKey
        let snapshot = SessionComposerDraft(
            text: "same", images: [], pdfURL: nil, contexts: [], replyQuote: nil,
            attachmentError: nil, pdfError: nil)
        for _ in 0..<2 {
            model.pendingSessionSends.append(
                SessionPendingSend(
                    id: UUID(), owner: owner, snapshot: snapshot,
                    message: ChatMessage(role: .user, text: "same"), baselineRowID: 10))
        }
        let stored = ChatMessage(role: .user, text: "same")
        _ = model.reconcilePendingSends(for: owner, restored: [stored], rowIDs: [11: stored.id])
        #expect(model.pendingSessionSends.count == 1)
        _ = model.reconcilePendingSends(for: owner, restored: [stored], rowIDs: [11: stored.id])
        #expect(model.pendingSessionSends.count == 1)
    }

    @Test func rowClaimsAreOwnerScopedAndRestrictedMatchesAreExact() {
        let model = DockModel(rpcClient: ResponsePersistenceRPCClient())
        defer { model.delegationMonitoringTask?.cancel() }
        let owner = model.composerDraftKey
        let other = SessionComposerDraft.Key(profileID: owner.profileID, sessionID: "other")
        let snapshot = SessionComposerDraft(
            text: "same", images: [], pdfURL: nil, contexts: [], replyQuote: nil,
            attachmentError: nil, pdfError: nil)
        let first = UUID()
        let second = UUID()
        let third = UUID()
        for (id, key) in [(first, owner), (second, owner), (third, other)] {
            model.pendingSessionSends.append(
                SessionPendingSend(
                    id: id, owner: key, snapshot: snapshot,
                    message: ChatMessage(role: .user, text: "same"), baselineRowID: 10))
        }
        let row11 = ChatMessage(role: .user, text: "same")
        let row12 = ChatMessage(role: .user, text: "same")
        let result = model.reconcilePendingSends(
            for: owner, restored: [row11, row12], rowIDs: [11: row11.id, 12: row12.id], restrictedTo: [second])
        #expect(result.resolved.first?.sendID == second)
        #expect(result.resolved.first?.rowID == 11)
        model.clearMessagePins()
        model.confirmPendingSend(first, owner: owner, receipt: ["user_row_id": 11])
        #expect(model.pendingSessionSends.contains { $0.id == first })
        model.confirmPendingSend(third, owner: other, receipt: ["user_row_id": 11])
        #expect(!model.pendingSessionSends.contains { $0.id == third })
        #expect(model.deliveryRowClaims[owner]?[11] == second)
        #expect(model.deliveryRowClaims[other]?[11] == third)
        #expect(model.storedMessageReferences.isEmpty)
        let later = model.reconcilePendingSends(
            for: owner, restored: [row11, row12],
            rowIDs: [11: row11.id, 12: row12.id])
        #expect(later.resolved.first?.sendID == first)
        #expect(later.resolved.first?.rowID == 12)
    }

    @Test func profilesWithSameSessionOwnIndependentRowClaims() {
        let model = DockModel(rpcClient: ResponsePersistenceRPCClient())
        defer { model.delegationMonitoringTask?.cancel() }
        model.sessionStorageID = "shared"
        let snapshot = SessionComposerDraft(
            text: "same", images: [], pdfURL: nil, contexts: [], replyQuote: nil,
            attachmentError: nil, pdfError: nil)
        var owners: [SessionComposerDraft.Key] = []
        var ids: [UUID] = []
        for profile in ["alpha", "beta"] {
            model.sessionProfileID = profile
            let owner = model.composerDraftKey
            let id = UUID()
            let message = ChatMessage(role: .user, text: "same")
            model.pendingSessionSends.append(
                SessionPendingSend(id: id, owner: owner, snapshot: snapshot, message: message, baselineRowID: 10))
            model.confirmPendingSend(id, owner: owner, receipt: ["user_row_id": 11])
            #expect(model.storedMessageReferences[message.id]?.rowID == 11)
            owners.append(owner)
            ids.append(id)
            model.clearMessagePins()
        }
        #expect(owners[0].sessionID == owners[1].sessionID)
        #expect(owners[0].profileID != owners[1].profileID)
        #expect(model.deliveryRowClaims[owners[0]]?[11] == ids[0])
        #expect(model.deliveryRowClaims[owners[1]]?[11] == ids[1])
        #expect(model.pendingSessionSends.isEmpty)
    }

    @Test func unassociatedCompletionLeavesUserPending() {
        let model = DockModel(rpcClient: ResponsePersistenceRPCClient())
        defer { model.delegationMonitoringTask?.cancel() }
        let snapshot = SessionComposerDraft(
            text: "pending", images: [], pdfURL: nil, contexts: [], replyQuote: nil,
            attachmentError: nil, pdfError: nil)
        let message = ChatMessage(role: .user, text: "pending")
        model.pendingSessionSends.append(
            SessionPendingSend(
                id: UUID(), owner: model.composerDraftKey, snapshot: snapshot,
                message: message, baselineRowID: 0))
        for receipt: [String: Any]? in [
            nil, ["complete": false, "user_row_id": 1],
            ["complete": true, "user_row_id": true], ["complete": true, "user_row_id": 42],
        ] {
            model.applyMessagePinReceipt(receipt, assistantMessageID: nil)
        }
        #expect(model.pendingSessionSends.count == 1)
        #expect(model.storedMessageReferences[message.id] == nil)
    }

    @Test func receiptsConfirmOnlyTheMatchingOwnerAndPositiveInteger() {
        let model = DockModel(rpcClient: ResponsePersistenceRPCClient())
        defer { model.delegationMonitoringTask?.cancel() }
        let owner = model.composerDraftKey
        let other = SessionComposerDraft.Key(profileID: owner.profileID, sessionID: "other")
        let snapshot = SessionComposerDraft(
            text: "receipt", images: [], pdfURL: nil, contexts: [], replyQuote: nil,
            attachmentError: nil, pdfError: nil)
        let id = UUID()
        let message = ChatMessage(role: .user, text: snapshot.text)
        model.pendingSessionSends.append(
            SessionPendingSend(id: id, owner: owner, snapshot: snapshot, message: message, baselineRowID: 0))
        for invalid: Any in [true, 0, -1, "3", 1.5] {
            model.confirmPendingSend(id, owner: owner, receipt: ["user_row_id": invalid])
            #expect(model.pendingSessionSends.count == 1)
        }
        model.confirmPendingSend(id, owner: other, receipt: ["user_row_id": 42])
        #expect(model.pendingSessionSends.count == 1)
        model.confirmPendingSend(id, owner: owner, receipt: ["user_row_id": 42])
        #expect(model.pendingSessionSends.isEmpty)
        #expect(model.storedMessageReferences[message.id]?.rowID == 42)
    }

    @Test func legacyAliasSurvivesEmptyCheckAndUnrelatedPrepend() async throws {
        let rpc = ResponsePersistenceRPCClient()
        let model = DockModel(rpcClient: rpc)
        defer { model.delegationMonitoringTask?.cancel() }
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        let snapshot = SessionComposerDraft(
            text: "legacy", images: [], pdfURL: nil, contexts: [], replyQuote: nil,
            attachmentError: nil, pdfError: nil)
        let id = UUID()
        let optimistic = ChatMessage(role: .user, text: "legacy")
        model.pendingSessionSends.append(
            SessionPendingSend(
                id: id, owner: model.composerDraftKey, snapshot: snapshot, message: optimistic,
                baselineRowID: 10, phase: .uncertain))
        rpc.resumeRows = [["role": "user", "content": "legacy"]]
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        let alias = try #require(model.messages.first(where: { $0.text == "legacy" })?.id)
        #expect(alias != optimistic.id)
        #expect(model.pendingSessionSends.first?.visibleMessageID == alias)
        await model.checkDeliveryStatus()
        #expect(model.pendingSessionSends.first?.visibleMessageID == alias)
        let unseen = ChatMessage(role: .user, text: "legacy")
        _ = model.reconcilePendingSends(for: model.composerDraftKey, restored: [unseen], rowIDs: [:])
        #expect(model.pendingSessionSends.first?.visibleMessageID == alias)
        model.prependEarlierTranscript(
            [["row_id": 4, "role": "user", "content": "unrelated"]],
            cursor: TranscriptHistoryCursor(storageSessionID: "origin", profileID: nil))
        #expect(model.pendingSessionSends.first?.visibleMessageID == alias)
        model.confirmPendingSend(id, owner: model.composerDraftKey, receipt: ["user_row_id": 11])
        #expect(model.storedMessageReferences[alias]?.rowID == 11)
        #expect(model.storedMessageReferences[optimistic.id] == nil)
    }

    @Test func replacingTranscriptClearsObsoleteLegacyAlias() async throws {
        let rpc = ResponsePersistenceRPCClient()
        let model = DockModel(rpcClient: rpc)
        defer { model.delegationMonitoringTask?.cancel() }
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        let snapshot = SessionComposerDraft(
            text: "legacy", images: [], pdfURL: nil, contexts: [], replyQuote: nil,
            attachmentError: nil, pdfError: nil)
        let optimistic = ChatMessage(role: .user, text: "legacy")
        model.pendingSessionSends.append(
            SessionPendingSend(
                id: UUID(), owner: model.composerDraftKey, snapshot: snapshot, message: optimistic,
                baselineRowID: 10, phase: .uncertain))
        rpc.resumeRows = [["role": "user", "content": "legacy"]]
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        #expect(model.pendingSessionSends.first?.visibleMessageID != nil)
        rpc.resumeRows = []
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        #expect(model.pendingSessionSends.first?.visibleMessageID == nil)
        #expect(model.messages.contains { $0.id == optimistic.id })
    }

    @Test func repeatedHistoryChecksClaimDistinctRowsAcrossNavigation() async throws {
        let rpc = ResponsePersistenceRPCClient()
        let model = DockModel(rpcClient: rpc)
        defer { model.delegationMonitoringTask?.cancel() }
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        let owner = model.composerDraftKey
        let snapshot = SessionComposerDraft(
            text: "same", images: [], pdfURL: nil, contexts: [], replyQuote: nil,
            attachmentError: nil, pdfError: nil)
        let first = ChatMessage(role: .user, text: "same")
        let second = ChatMessage(role: .user, text: "same")
        model.messages = [first, second]
        for message in [first, second] {
            model.pendingSessionSends.append(
                SessionPendingSend(
                    id: UUID(), owner: owner, snapshot: snapshot, message: message,
                    baselineRowID: 10, phase: .uncertain))
        }
        rpc.historyRows = [["id": 11, "role": "user", "content": "same"]]
        let wrongProfile = SessionComposerDraft.Key(profileID: "other-profile", sessionID: owner.sessionID)
        let pathsBefore = rpc.historyPaths.count
        await model.checkDeliveryStatus(owner: wrongProfile)
        #expect(rpc.historyPaths.count == pathsBefore)
        await model.checkDeliveryStatus()
        #expect(model.storedMessageReferences[first.id]?.rowID == 11)
        #expect(model.storedMessageReferences[second.id] == nil)
        await model.checkDeliveryStatus()
        #expect(model.pendingSessionSends.count == 1)
        #expect(model.storedMessageReferences[second.id] == nil)
        #expect(await model.resumeSession(session("other"), reportFailure: true))
        #expect(model.composerDraftKey != owner)
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        let visible = try #require(model.pendingSessionSends.first?.message.id)
        #expect(visible == second.id)
        rpc.historyRows.append(["id": 12, "role": "user", "content": "same"])
        await model.checkDeliveryStatus()
        #expect(model.pendingSessionSends.isEmpty)
        #expect(model.storedMessageReferences[second.id]?.rowID == 12)
        #expect(model.transcriptMessageIDsByRowID[12] == second.id)
        #expect(model.deliveryRowClaims[owner]?[11] != model.deliveryRowClaims[owner]?[12])
    }

    @Test func checkingDeliveryReadsHistoryWithoutSubmittingAgain() async throws {
        let rpc = ResponsePersistenceRPCClient()
        let model = DockModel(rpcClient: rpc)
        defer { model.delegationMonitoringTask?.cancel() }
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        let snapshot = SessionComposerDraft(
            text: "check me", images: [], pdfURL: nil, contexts: [], replyQuote: nil,
            attachmentError: nil, pdfError: nil)
        let message = ChatMessage(role: .user, text: snapshot.text)
        model.messages.append(message)
        model.pendingSessionSends.append(
            SessionPendingSend(
                id: UUID(), owner: model.composerDraftKey, snapshot: snapshot, message: message,
                baselineRowID: 4, phase: .uncertain))
        rpc.historyRows = [["id": 5, "role": "user", "content": "check me"]]
        let before = rpc.requests.count
        await model.checkDeliveryStatus()
        #expect(rpc.historyPaths.count == 1)
        #expect(rpc.requests.count == before)
        #expect(model.pendingSessionSends.isEmpty)
        #expect(model.storedMessageReferences[message.id]?.rowID == 5)
        #expect(model.messages.filter { $0.id == message.id }.count == 1)
    }

    @Test func failedDeliveryCheckLeavesMessageUnconfirmed() async throws {
        let rpc = ResponsePersistenceRPCClient()
        let model = DockModel(rpcClient: rpc)
        defer { model.delegationMonitoringTask?.cancel() }
        #expect(await model.resumeSession(session("origin"), reportFailure: true))
        let snapshot = SessionComposerDraft(
            text: "check me", images: [], pdfURL: nil, contexts: [], replyQuote: nil,
            attachmentError: nil, pdfError: nil)
        model.pendingSessionSends.append(
            SessionPendingSend(
                id: UUID(), owner: model.composerDraftKey, snapshot: snapshot,
                message: ChatMessage(role: .user, text: snapshot.text), baselineRowID: 0, phase: .uncertain))
        rpc.historyFails = true
        await model.checkDeliveryStatus()
        #expect(model.pendingSessionSends.count == 1)
        #expect(model.deliveryCheckNotes[model.composerDraftKey] == "Status check unavailable")
        #expect(model.deliveryChecksInFlight.isEmpty)
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
