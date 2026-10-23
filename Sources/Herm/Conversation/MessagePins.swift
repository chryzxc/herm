import SwiftUI

struct StoredMessageReference: Equatable {
    let rowID: Int
    let uid: String?

    static func references(rows: Any?, rowIDs: [Int: UUID]) -> [UUID: Self] {
        guard let rows = rows as? [[String: Any]] else { return [:] }
        var references: [UUID: Self] = [:]
        for row in rows {
            guard let rowID = TranscriptHistoryPaging.rowID(row, key: "row_id"),
                  let messageID = rowIDs[rowID] else { continue }
            references[messageID] = Self(rowID: rowID, uid: row["message_uid"] as? String)
        }
        return references
    }
}

struct PinnedMessage: Equatable, Identifiable {
    let rowID: Int
    let uid: String
    let role: String
    let preview: String
    var id: String { uid }

    static func parse(_ response: [String: Any], sessionID: String) throws -> [Self] {
        guard response["supported"] as? Bool == true,
              response["requested_session_id"] as? String == sessionID,
              let rows = response["pins"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        return try rows.map { row in
            guard let rowID = TranscriptHistoryPaging.rowID(row, key: "row_id"), rowID > 0,
                  let uid = row["message_uid"] as? String, !uid.isEmpty,
                  let role = row["role"] as? String, role == "user" || role == "assistant",
                  let preview = row["preview"] as? String else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            return Self(rowID: rowID, uid: uid, role: role, preview: preview)
        }
    }

    func matches(_ reference: StoredMessageReference) -> Bool {
        reference.uid.map { $0 == uid } ?? (reference.rowID == rowID)
    }
}

struct MessagePinsView: View {
    @ObservedObject var model: DockModel
    @ObservedObject private var theme = DockThemeStore.shared
    let onSelect: (PinnedMessage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Pinned messages").dockFont(.body, weight: .semibold)
                Spacer()
                DockIconButton(icon: .arrowClockwise, label: "Refresh pinned messages", isBusy: model.isLoadingMessagePins, size: 24, style: DockThemePalette(theme: theme.selectedThemeID)) {
                    Task { await model.refreshMessagePins() }
                }
                .disabled(model.isLoadingMessagePins)
            }
            .padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if model.pinnedMessages.isEmpty {
                        Text(model.messagePinError != nil ? "Pinned messages unavailable" : model.isLoadingMessagePins ? "Loading pinned messages…" : "No pinned messages")
                            .dockFont(.body, weight: .semibold)
                        if !model.isLoadingMessagePins && model.messagePinError == nil {
                            Text("Pin a saved message using its pin action.")
                                .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                        }
                    }
                    ForEach(model.pinnedMessages) { pin in
                        HStack(spacing: 8) {
                            Button { onSelect(pin) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(pin.role == "user" ? "You" : "Hermes")
                                        .dockFont(.body, weight: .semibold)
                                    Text(pin.preview.isEmpty ? "Message with an attachment" : pin.preview)
                                        .dockFont(.body).foregroundStyle(Color.dockSecondaryText).lineLimit(3)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.trailing, 18)
                                .overlay(alignment: .trailing) {
                                    DockIcon(.caretRight, size: 12, color: .dockSecondaryText)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.dockHover)
                            .help("Jump to pinned message")
                            DockIconButton(icon: .pushPinSlash, label: "Unpin message", isBusy: model.updatingMessagePinRowID == pin.rowID, size: 28, style: DockThemePalette(theme: theme.selectedThemeID)) {
                                Task { await model.setMessagePinned(rowID: pin.rowID, pinned: false) }
                            }
                            .disabled(model.isUpdatingMessagePin || !model.messagePinsSupported)
                        }
                        .padding(8)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(model.messagePinError ?? "")
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 48, alignment: .topLeading)
                .padding(.horizontal, 12)
                .help(model.messagePinError ?? "")
        }
        .foregroundStyle(Color.dockPrimaryText)
        .frame(width: 320, height: 340)
        .background(Color.dockCanvas)
    }
}
