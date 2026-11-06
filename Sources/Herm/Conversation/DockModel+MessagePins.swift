import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    func canPinMessage(_ message: ChatMessage) -> Bool {
        sessionActionsReady && messagePinsSupported && !isUpdatingMessagePin && message.id != streamingMessageID
            && storedMessageReferences[message.id] != nil
            && message.systemEvent == nil && message.kanbanNotice == nil && !message.isError
    }

    func isMessagePinned(_ message: ChatMessage) -> Bool {
        guard let reference = storedMessageReferences[message.id] else { return false }
        return reference.uid.map { pinnedMessageUIDs.contains($0) } ?? pinnedMessageRowIDs.contains(reference.rowID)
    }

    func clearMessagePins() {
        pinnedMessages = []
        messagePinsSupported = false
        isLoadingMessagePins = false
        updatingMessagePinRowID = nil
        messagePinError = nil
        messagePinMutationFeedback = nil
        storedMessageReferences = [:]
        submittedMessageIDForPin = nil
    }

    /// Pins live in Herm's own store as references; Hermes has no pin feature to ask.
    func refreshMessagePins() async { reloadMessagePins() }

    func reloadMessagePins() {
        guard let owner = navigationSessionID else { return }
        pinnedMessages = messagePinStore.pins(profile: sessionProfileID, sessionID: owner).map { record in
            let reference = storedMessageReferences.first { pin(record, matches: $0.value) }
            let text = reference.flatMap { entry in messages.first { $0.id == entry.key }?.text } ?? ""
            return PinnedMessage(
                record: record, preview: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)))
        }
        messagePinsSupported = true
        messagePinError = messagePinMutationFeedback?.error
    }

    private func pin(_ record: MessagePinRecord, matches reference: StoredMessageReference) -> Bool {
        PinnedMessage(record: record, preview: "").matches(reference)
    }

    func toggleMessagePinned(_ message: ChatMessage) async {
        guard canPinMessage(message), let reference = storedMessageReferences[message.id] else { return }
        setMessagePinned(
            MessagePinRecord(
                rowID: reference.rowID, uid: reference.uid, role: message.role == .user ? "user" : "assistant"),
            pinned: !isMessagePinned(message))
    }

    func setMessagePinned(_ record: MessagePinRecord, pinned: Bool) {
        guard sessionActionsReady, messagePinsSupported, let owner = navigationSessionID else { return }
        var records = messagePinStore.pins(profile: sessionProfileID, sessionID: owner)
        records.removeAll { $0.rowID == record.rowID }
        if pinned { records.append(record) }
        messagePinStore.save(records, profile: sessionProfileID, sessionID: owner)
        recordMessagePinFeedback(error: nil)
        reloadMessagePins()
    }

    private func recordMessagePinFeedback(error: String?) {
        messagePinError = error
        messagePinMutationFeedback = MessagePinMutationFeedback(error: error)
    }

    func messageID(forPin pin: PinnedMessage) async -> UUID? {
        let generation = sessionResumeGeneration
        if let id = storedMessageReferences.first(where: { pin.matches($0.value) })?.key,
            messages.contains(where: { $0.id == id })
        {
            return id
        }
        _ = await loadTranscriptHistory(through: pin.rowID)
        guard generation == sessionResumeGeneration else { return nil }
        reloadMessagePins()
        guard let id = storedMessageReferences.first(where: { pin.matches($0.value) })?.key,
            messages.contains(where: { $0.id == id })
        else {
            messagePinError =
                "The pinned message is no longer in the loaded history. Refresh the conversation and try again."
            return nil
        }
        return id
    }

    func applyMessagePinReceipt(_ receipt: [String: Any]?, assistantMessageID: UUID?) {
        defer { submittedMessageIDForPin = nil }
        guard let receipt, receipt["complete"] as? Bool == true else { return }
        if let id = submittedMessageIDForPin, let rowID = TranscriptHistoryPaging.rowID(receipt, key: "user_row_id"),
            rowID > 0
        {
            storedMessageReferences[id] = StoredMessageReference(rowID: rowID, uid: nil)
            transcriptMessageIDsByRowID[rowID] = id
        }
        if let id = assistantMessageID,
            let rowID = TranscriptHistoryPaging.rowID(receipt, key: "final_assistant_row_id"), rowID > 0
        {
            storedMessageReferences[id] = StoredMessageReference(rowID: rowID, uid: nil)
            transcriptMessageIDsByRowID[rowID] = id
        }
    }

    /// The message for a stored row, or the next loaded message after it when
    /// that row itself has no visible message.
    func loadedMessageID(forRowID rowID: Int) -> UUID? {
        if let exact = transcriptMessageIDsByRowID[rowID] { return exact }
        guard let next = transcriptMessageIDsByRowID.keys.filter({ $0 > rowID }).min(),
            transcriptHistoryCursor?.seenRowIDs.contains(rowID) == true
        else { return nil }
        return transcriptMessageIDsByRowID[next]
    }
}
