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
                MessagePinLabel(pin: pin, opening: opening).contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .disabled(opening)
            .messagePinHoverPreview(pin)
            if failed {
                Text("Message unavailable. Refresh and retry.")
                    .foregroundStyle(Color.dockWarning)
            }
        }
        .dockFont(.body)
    }
}
