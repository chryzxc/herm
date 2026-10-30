import SwiftUI

/// Matches browser annotation: select, describe the change, Cancel or Send to the draft.
struct SessionSimulatorAnnotation: View {
    let label: String
    let cancel: () -> Void
    let submit: (String) -> Bool
    @State private var comment = ""
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label).dockFont(.body, weight: .semibold).lineLimit(2)
            TextField("Describe the change…", text: $comment, axis: .vertical)
                .textFieldStyle(.dockGlass).lineLimit(2...5)
                .focused($focused).onSubmit(send)
            if failed {
                Text("Could not attach to this session. Check the chat and retry.")
                    .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
            }
            HStack {
                Text("⇧↵ newline · esc cancel").dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(.dockSecondary).keyboardShortcut(.cancelAction)
                Button("Send", action: send).buttonStyle(.dockPrimary)
            }
        }
        .dockButtonSize(.compact)
        .dockPadding(16).frame(width: 340)
        .foregroundStyle(Color.dockPrimaryText).background(Color.dockCanvas)
        .onAppear { focused = true }
    }

    private func send() { failed = !submit(String(comment.prefix(8000))) }
}
