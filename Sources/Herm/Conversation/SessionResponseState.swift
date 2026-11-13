import CoreFoundation
import Foundation

struct SessionStopAttempt {
    enum Outcome { case requesting, accepted, failed }
    let id: UUID
    var outcome: Outcome
    var tailPending = true
}

struct SessionPendingSend {
    enum Phase { case preparing, submitting, acknowledged, uncertain, notSent }
    let id: UUID
    var owner: SessionComposerDraft.Key
    let snapshot: SessionComposerDraft
    let message: ChatMessage
    let baselineRowID: Int?
    var submittedText: String? = nil
    var phase: Phase = .preparing
    var acceptedStatus: String? = nil
    var visibleMessageID: UUID? = nil
}

enum MessageDeliveryStatus: Equatable {
    case sending, accepted, queued, unconfirmed

    var label: String {
        switch self {
        case .sending: "Sending…"
        case .accepted: "Accepted"
        case .queued: "Queued"
        case .unconfirmed: "Delivery unconfirmed"
        }
    }
}

struct SessionPendingSendReconciliation {
    struct Resolution {
        let sendID: UUID
        let messageID: UUID
        let rowID: Int
    }
    var unmatchedMessages: [ChatMessage] = []
    var resolved: [Resolution] = []
}

extension DockModel {
    func checkDeliveryStatus(owner: SessionComposerDraft.Key? = nil, generation expectedGeneration: Int? = nil) async {
        let owner = owner ?? composerDraftKey
        guard owner == composerDraftKey,
            expectedGeneration == nil || expectedGeneration == sessionResumeGeneration
        else { return }
        guard let storageID = sessionStorageID, !deliveryChecksInFlight.contains(owner) else { return }
        let generation = sessionResumeGeneration
        let outstanding = pendingSessionSends.filter { $0.owner == owner && $0.phase != .notSent }
        guard !outstanding.isEmpty else { return }
        deliveryChecksInFlight.insert(owner)
        deliveryCheckNotes[owner] = nil
        defer { deliveryChecksInFlight.remove(owner) }
        do {
            let page = try await fetchEarlierTranscriptRows(
                from: TranscriptHistoryCursor(
                    storageSessionID: storageID, profileID: sessionProfileID ?? profileScopeID),
                limit: TranscriptHistoryPaging.pageRowLimit, minimumDisplayRows: Int.max)
            let (parsed, _) = await Self.parseMessagesOffMain(
                page.rows, defaultBotProfileID: sessionProfileID, defaultBotDisplayName: nil)
            guard generation == sessionResumeGeneration, owner == composerDraftKey, storageID == sessionStorageID
            else { return }
            let result = reconcilePendingSends(
                for: owner, restored: parsed.messages, rowIDs: parsed.rowIDs, restrictedTo: Set(outstanding.map(\.id)))
            for match in result.resolved {
                storedMessageReferences[match.messageID] = StoredMessageReference(rowID: match.rowID, uid: nil)
                transcriptMessageIDsByRowID[match.rowID] = match.messageID
            }
            if pendingSessionSends.contains(where: { $0.owner == owner && $0.phase == .uncertain }) {
                deliveryCheckNotes[owner] = "Still unconfirmed"
            }
        } catch {
            if generation == sessionResumeGeneration, owner == composerDraftKey {
                deliveryCheckNotes[owner] = "Status check unavailable"
            }
        }
    }

    func confirmPendingSend(_ id: UUID, owner: SessionComposerDraft.Key, receipt: [String: Any]) {
        guard let value = receipt["user_row_id"] as? NSNumber,
            CFGetTypeID(value) != CFBooleanGetTypeID(),
            !CFNumberIsFloatType(value as! CFNumber),
            let rowID = Int(exactly: value.int64Value), rowID > 0,
            let index = pendingSessionSends.firstIndex(where: { $0.id == id && $0.owner == owner })
        else { return }
        guard deliveryRowClaims[owner]?[rowID] == nil || deliveryRowClaims[owner]?[rowID] == id else { return }
        deliveryRowClaims[owner, default: [:]][rowID] = id
        let pending = pendingSessionSends.remove(at: index)
        let messageID = pending.visibleMessageID ?? pending.message.id
        if owner == composerDraftKey {
            storedMessageReferences[messageID] = StoredMessageReference(rowID: rowID, uid: nil)
            transcriptMessageIDsByRowID[rowID] = messageID
        }
    }

    var composerIsEmptyForRecovery: Bool {
        draft.isEmpty && pendingImages.isEmpty && pendingPDFURL == nil && attachedContexts.isEmpty && replyQuote == nil
    }

    static func interruptWasAccepted(_ response: [String: Any]) -> Bool {
        let status = response["status"] as? String
        let accepted = status == "interrupted" || (response["status"] == nil && response["accepted"] as? Bool == true)
        return accepted && response["interrupted"] as? Bool != false
    }

    func recoverPendingSend(_ id: UUID) {
        guard let index = pendingSessionSends.firstIndex(where: { $0.id == id }) else { return }
        pendingSessionSends[index].phase = .notSent
        restorePendingSendIfPossible(for: pendingSessionSends[index].owner)
    }

    func restorePendingSendIfPossible(for owner: SessionComposerDraft.Key) {
        guard let index = pendingSessionSends.firstIndex(where: { $0.owner == owner && $0.phase == .notSent }) else {
            return
        }
        if owner == composerDraftKey {
            guard composerIsEmptyForRecovery else { return }
            composerDrafts[owner] = pendingSessionSends.remove(at: index).snapshot
            restoreComposerDraft(for: owner)
        } else if composerDrafts[owner] == nil {
            composerDrafts[owner] = pendingSessionSends.remove(at: index).snapshot
        }
    }

    func reconcilePendingSends(
        for owner: SessionComposerDraft.Key, restored: [ChatMessage], rowIDs: [Int: UUID],
        restrictedTo: Set<UUID>? = nil, replacingTranscript: Bool = false, visibleHistory: Bool = false
    ) -> SessionPendingSendReconciliation {
        var claims = deliveryRowClaims[owner] ?? [:]
        var result = SessionPendingSendReconciliation()
        pendingSessionSends.removeAll { pending in
            guard pending.owner == owner, pending.phase != .notSent,
                restrictedTo?.contains(pending.id) ?? true
            else { return false }
            let parsedText =
                pending.submittedText.flatMap { text in
                    Self.parseMessages([["role": "user", "content": text]]).messages.first?.text
                } ?? pending.message.text
            let match = rowIDs.keys.sorted().first { rowID in
                guard claims[rowID] == nil, let baseline = pending.baselineRowID, rowID > baseline,
                    let messageID = rowIDs[rowID], let row = restored.first(where: { $0.id == messageID })
                else { return false }
                return row.role == .user && row.text == parsedText
            }
            if let match {
                claims[match] = pending.id
                result.resolved.append(
                    .init(sendID: pending.id, messageID: pending.visibleMessageID ?? pending.message.id, rowID: match))
                return true
            }
            let legacyMatch = restored.contains { row in
                row.role == .user && row.text == parsedText && !rowIDs.values.contains(row.id)
            }
            if !legacyMatch {
                result.unmatchedMessages.append(pending.message)
            }
            return false
        }
        for index in pendingSessionSends.indices
        where pendingSessionSends[index].owner == owner
            && (restrictedTo?.contains(pendingSessionSends[index].id) ?? true)
        {
            let pending = pendingSessionSends[index]
            let parsedText =
                pending.submittedText.flatMap {
                    Self.parseMessages([["role": "user", "content": $0]]).messages.first?.text
                } ?? pending.message.text
            let alias = restored.first {
                $0.role == .user && $0.text == parsedText && !rowIDs.values.contains($0.id)
            }?.id
            if replacingTranscript || (visibleHistory && pending.visibleMessageID == nil && alias != nil) {
                pendingSessionSends[index].visibleMessageID = alias
            }
            if pending.phase == .acknowledged && pending.acceptedStatus != "queued" {
                pendingSessionSends[index].phase = .uncertain
            }
        }
        deliveryRowClaims[owner] = claims
        return result
    }
}
