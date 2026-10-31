import SwiftUI

struct SessionRailPinnedItem: View {
    let pin: PinnedMessage
    let onView: (PinnedMessage) async -> Bool
    @State private var opening = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                opening = true
                failed = false
                Task {
                    failed = !(await onView(pin))
                    opening = false
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    DockIcon(.chatCircle, size: 14, color: .dockSecondaryText).frame(width: 14, height: 14)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(opening ? "Opening…" : pin.preview.isEmpty ? "Message with an attachment" : pin.preview)
                            .multilineTextAlignment(.leading)
                        Text(pin.role == "user" ? "You" : "Herm")
                            .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                    }
                    Spacer(minLength: 0)
                    DockIcon(.arrowUpRight, size: 12, color: .dockMetadataText)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.dockHover).disabled(opening).help(pin.preview.isEmpty ? "Show in chat" : pin.preview)
            if failed {
                Text("Message unavailable. Refresh and retry.")
                    .foregroundStyle(Color.dockWarning).dockPadding(.leading, 22)
            }
        }
        .dockFont(.body)
    }
}
