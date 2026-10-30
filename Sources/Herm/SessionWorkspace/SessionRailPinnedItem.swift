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
                    DockIcon(.chatCircle, size: 14, color: .dockSecondaryText)
                    Text(opening ? "Opening…" : pin.preview.isEmpty ? "Message with an attachment" : pin.preview)
                        .multilineTextAlignment(.leading).lineLimit(2)
                    Spacer(minLength: 0)
                    DockIcon(.arrowUpRight, size: 14, color: .dockSecondaryText)
                }
            }
            .buttonStyle(.dockHover).disabled(opening).help("Show in chat")
            if !pin.preview.isEmpty {
                Text(pin.preview)
                    .textSelection(.enabled)
                    .dockPadding(.leading, 22)
            }
            Text(pin.role == "user" ? "You" : "Herm")
                .foregroundStyle(Color.dockMetadataText).dockPadding(.leading, 22)
            if failed {
                Text("Message unavailable. Refresh and retry.")
                    .foregroundStyle(Color.dockWarning).dockPadding(.leading, 22)
            }
        }
        .dockFont(.body)
    }
}
