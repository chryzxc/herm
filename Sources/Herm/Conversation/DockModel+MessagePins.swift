import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    func canPinMessage(_ message: ChatMessage) -> Bool {
        messagePinsSupported && !isUpdatingMessagePin && message.id != streamingMessageID
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
        storedMessageReferences = [:]
        submittedMessageIDForPin = nil
    }

    func refreshMessagePins() async {
        guard let owner = navigationSessionID, !isLoadingMessagePins else { return }
        let generation = sessionResumeGeneration
        let profile = sessionProfileID
        isLoadingMessagePins = true
        defer { if generation == sessionResumeGeneration { isLoadingMessagePins = false } }
        do {
            var pins: [PinnedMessage] = []
            var hasMore = true
            for _ in 0..<20 {
                guard let path = TranscriptHistoryPaging.sessionPath(sessionID: owner, endpoint: "message-pins", profileID: profile,
                    query: [URLQueryItem(name: "offset", value: String(pins.count))]) else {
                    throw HermesGateway.GatewayError.malformedResponse
                }
                let result = try await sessionRPCClient.fetchHTTP(path)
                let page = try PinnedMessage.parse(result, sessionID: owner)
                pins += page
                hasMore = (result["pagination"] as? [String: Any])?["has_more"] as? Bool == true
                if !hasMore { break }
                if page.isEmpty { throw HermesGateway.GatewayError.malformedResponse }
            }
            guard !hasMore, Set(pins.map(\.id)).count == pins.count else { throw HermesGateway.GatewayError.malformedResponse }
            guard generation == sessionResumeGeneration, navigationSessionID == owner, sessionProfileID == profile else { return }
            pinnedMessages = pins
            messagePinsSupported = true
            messagePinError = nil
        } catch {
            guard generation == sessionResumeGeneration, navigationSessionID == owner, sessionProfileID == profile else { return }
            messagePinsSupported = false
            switch error {
            case HermesGateway.GatewayError.httpError(404), HermesGateway.GatewayError.httpRefused(404, _):
                messagePinError = "This Hermes runtime does not support message pins. Install the backend patch and restart Hermes."
            default:
                messagePinError = "Pinned messages unavailable. \(Self.safeUserDiagnostic(error.localizedDescription))"
            }
        }
    }

    func toggleMessagePinned(_ message: ChatMessage) async {
        guard canPinMessage(message), let reference = storedMessageReferences[message.id] else { return }
        await setMessagePinned(rowID: reference.rowID, pinned: !isMessagePinned(message))
    }

    func setMessagePinned(rowID: Int, pinned: Bool) async {
        guard messagePinsSupported, !isUpdatingMessagePin, let owner = navigationSessionID,
              let path = TranscriptHistoryPaging.sessionPath(sessionID: owner, endpoint: "message-pins/\(rowID)", profileID: sessionProfileID, query: []) else { return }
        let generation = sessionResumeGeneration
        let profile = sessionProfileID
        updatingMessagePinRowID = rowID
        defer { if generation == sessionResumeGeneration { updatingMessagePinRowID = nil } }
        do {
            let result = try await sessionRPCClient.sendHTTP("PUT", path: path, body: ["pinned": pinned])
            guard result["requested_session_id"] as? String == owner, result["row_id"] as? Int == rowID,
                  result["pinned"] as? Bool == pinned,
                  let uid = result["message_uid"] as? String, !uid.isEmpty else { throw HermesGateway.GatewayError.malformedResponse }
            guard generation == sessionResumeGeneration, navigationSessionID == owner, sessionProfileID == profile else { return }
            for (id, reference) in storedMessageReferences where reference.rowID == rowID {
                storedMessageReferences[id] = StoredMessageReference(rowID: rowID, uid: uid)
            }
            while isLoadingMessagePins {
                try await Task.sleep(for: .milliseconds(20))
                guard generation == sessionResumeGeneration else { return }
            }
            await refreshMessagePins()
        } catch {
            guard generation == sessionResumeGeneration, navigationSessionID == owner, sessionProfileID == profile else { return }
            messagePinError = "Could not \(pinned ? "pin" : "unpin") message. \(Self.safeUserDiagnostic(error.localizedDescription))"
        }
    }

    func messageID(forPin pin: PinnedMessage) async -> UUID? {
        let generation = sessionResumeGeneration
        if let id = storedMessageReferences.first(where: { pin.matches($0.value) })?.key,
           messages.contains(where: { $0.id == id }) { return id }
        _ = await loadTranscriptHistory(through: pin.rowID)
        guard generation == sessionResumeGeneration else { return nil }
        guard let id = storedMessageReferences.first(where: { pin.matches($0.value) })?.key,
              messages.contains(where: { $0.id == id }) else {
            messagePinError = "The pinned message is no longer in the loaded history. Refresh the conversation and try again."
            return nil
        }
        return id
    }

    func applyMessagePinReceipt(_ receipt: [String: Any]?, assistantMessageID: UUID?) {
        defer { submittedMessageIDForPin = nil }
        guard let receipt, receipt["complete"] as? Bool == true else { return }
        if let id = submittedMessageIDForPin, let rowID = TranscriptHistoryPaging.rowID(receipt, key: "user_row_id"), rowID > 0 {
            storedMessageReferences[id] = StoredMessageReference(rowID: rowID, uid: nil)
            transcriptMessageIDsByRowID[rowID] = id
        }
        if let id = assistantMessageID, let rowID = TranscriptHistoryPaging.rowID(receipt, key: "final_assistant_row_id"), rowID > 0 {
            storedMessageReferences[id] = StoredMessageReference(rowID: rowID, uid: nil)
            transcriptMessageIDsByRowID[rowID] = id
        }
    }

    /// The message for a stored row, or the next loaded message after it when
    /// that row itself has no visible message.
    func loadedMessageID(forRowID rowID: Int) -> UUID? {
        if let exact = transcriptMessageIDsByRowID[rowID] { return exact }
        guard let next = transcriptMessageIDsByRowID.keys.filter({ $0 > rowID }).min(),
              transcriptHistoryCursor?.seenRowIDs.contains(rowID) == true else { return nil }
        return transcriptMessageIDsByRowID[next]
    }
}
