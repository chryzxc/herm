import Foundation

extension DockModel {
    /// Paints a `message.reaction` event. Hermes keys this event by the stored
    /// session id rather than the runtime one, so either names the open chat.
    func applyMessageReaction(payload: [String: Any], owner: String?) {
        guard let owner, !owner.isEmpty, let current = sessionID,
            owner == current || owner == sessionStorageID || rowSessionID(owner) == rowSessionID(current),
            let rowID = TranscriptHistoryPaging.rowID(payload, key: "row_id"),
            let index = MessageReaction.targetIndex(
                rowID: rowID, role: payload["role"] as? String, messages: messages,
                knownRows: transcriptMessageIDsByRowID)
        else { return }
        transcriptMessageIDsByRowID[rowID] = messages[index].id
        messages[index].reactions = MessageReaction.parse(payload["reactions"])
    }
}
