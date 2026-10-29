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
}

extension DockModel {
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
        for owner: SessionComposerDraft.Key, restored: [ChatMessage], rowIDs: [Int: UUID]
    ) -> [ChatMessage] {
        var consumed: Set<Int> = []
        var visible: [ChatMessage] = []
        pendingSessionSends.removeAll { pending in
            guard pending.owner == owner, pending.phase != .notSent else { return false }
            let parsedText =
                pending.submittedText.flatMap { text in
                    Self.parseMessages([["role": "user", "content": text]]).messages.first?.text
                } ?? pending.message.text
            let match = rowIDs.keys.sorted().first { rowID in
                guard !consumed.contains(rowID), let baseline = pending.baselineRowID, rowID > baseline,
                    let messageID = rowIDs[rowID], let row = restored.first(where: { $0.id == messageID })
                else { return false }
                return row.role == .user && row.text == parsedText
            }
            if let match {
                consumed.insert(match)
                return true
            }
            let legacyMatch = restored.contains { row in
                row.role == .user && row.text == parsedText && !rowIDs.values.contains(row.id)
            }
            if !legacyMatch {
                visible.append(pending.message)
            }
            return false
        }
        if pendingSessionSends.contains(where: { $0.owner == owner && $0.phase != .notSent }) {
            visible.append(
                ChatMessage(
                    role: .hermes,
                    text: "Herm could not confirm that this message was saved. Check the conversation before retrying.")
            )
        }
        return visible
    }
}
