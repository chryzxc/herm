import SwiftUI

struct StoredMessageReference: Equatable {
    let rowID: Int
    let uid: String?

    static func references(rows: Any?, rowIDs: [Int: UUID]) -> [UUID: Self] {
        guard let rows = rows as? [[String: Any]] else { return [:] }
        var references: [UUID: Self] = [:]
        for row in rows {
            guard let rowID = TranscriptHistoryPaging.rowID(row, key: "row_id"),
                let messageID = rowIDs[rowID]
            else { continue }
            references[messageID] = Self(rowID: rowID, uid: row["message_uid"] as? String)
        }
        return references
    }
}

/// The persisted part of a pin: a reference to a stored Hermes message, never its text.
struct MessagePinRecord: Codable, Equatable {
    let rowID: Int
    let uid: String?
    let role: String
}

struct PinnedMessage: Equatable, Identifiable {
    let record: MessagePinRecord
    /// Excerpt of the message when it is loaded; empty until then.
    let preview: String
    var rowID: Int { record.rowID }
    var uid: String { record.uid ?? "row:\(record.rowID)" }
    var role: String { record.role }
    var id: String { uid }

    init(rowID: Int, uid: String?, role: String, preview: String) {
        self.init(record: MessagePinRecord(rowID: rowID, uid: uid, role: role), preview: preview)
    }

    init(record: MessagePinRecord, preview: String) {
        self.record = record
        self.preview = preview
    }

    func matches(_ reference: StoredMessageReference) -> Bool {
        reference.uid.map { $0 == uid } ?? (reference.rowID == rowID)
    }
}

struct MessagePinLabel: View {
    let pin: PinnedMessage
    var opening = false
    var showsJump = true

    var body: some View {
        let isUser = pin.role == "user"
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                DockIcon(isUser ? .user : .chatCircleText, size: 12)
                Text(isUser ? "You" : "Herm")
                if showsJump {
                    Spacer(minLength: 0)
                    DockIcon(.arrowUpRight, size: 12)
                }
            }
            .dockFont(.metadata, weight: .semibold)
            .foregroundStyle(Color.dockSecondaryText)
            Text(opening ? "Opening…" : pin.preview.isEmpty ? "Open to view this message" : pin.preview)
                .dockFont(.body)
                .foregroundStyle(Color.dockPrimaryText)
                .multilineTextAlignment(.leading)
                .lineLimit(showsJump ? 3 : 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    func messagePinHoverPreview(_ pin: PinnedMessage) -> some View {
        dockHoverTip(
            "Jump to pinned message", edge: .leading,
            preview: DockHoverTipPreview(
                contentID: AnyHashable([pin.id, pin.role, pin.preview]),
                content: AnyView(MessagePinLabel(pin: pin, showsJump: false)))
        )
        .accessibilityHint("Jumps to this message in chat")
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
            }
            .dockPadding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if model.pinnedMessages.isEmpty {
                        Text("No pinned messages").dockFont(.body, weight: .semibold)
                        Text("Pin a saved message using its pin action.")
                            .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    }
                    ForEach(model.pinnedMessages) { pin in
                        HStack(spacing: 8) {
                            Button {
                                onSelect(pin)
                            } label: {
                                MessagePinLabel(pin: pin).contentShape(Rectangle())
                            }
                            .buttonStyle(.dockHover)
                            .messagePinHoverPreview(pin)
                            DockIconButton(
                                icon: .pushPinSlash, label: "Unpin message",
                                size: 28,
                                style: DockThemePalette(theme: theme.selectedThemeID)
                            ) {
                                model.setMessagePinned(pin.record, pinned: false)
                            }
                        }
                        .dockPadding(8)
                    }
                }
                .dockPadding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(model.messagePinError ?? "")
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 48, alignment: .topLeading)
                .dockPadding(.horizontal, 12)
                .help(model.messagePinError ?? "")
        }
        .foregroundStyle(Color.dockPrimaryText)
        .frame(width: 320, height: 340)
        .background(Color.dockOpaqueCanvas)
    }
}
