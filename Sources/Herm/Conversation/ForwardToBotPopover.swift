import SwiftUI

/// Forwards one message to a bot in a new session. The note field uses the
/// composer's `/`, `@` and `$` completions, scoped to the bot's own commands.
struct ForwardToBotPopover: View {
    let model: DockModel
    @ObservedObject var botMode: BotModeModel
    let bot: BotSummary
    let messageText: String
    let dismiss: () -> Void
    @Environment(\.dismiss) private var environmentDismiss

    @State private var note = ""
    /// A class box, not @State: the editor reads and clears it during a view update.
    @State private var pendingCaret = CaretBox()
    @State private var height = ComposerLayout.minHeight
    @State private var error: String?
    @State private var isForwarding = false

    @StateObject private var completions = ComposerCompletionController()
    @FocusState private var isFocused: Bool

    var body: some View {
        let field = DockThemeShape(cornerRadius: DockLayout.controlRadius)
        VStack(alignment: .leading, spacing: 10) {
            if let trigger = completions.trigger, !completions.result.items.isEmpty {
                ComposerCompletionPopover(
                    trigger: trigger,
                    items: completions.result.items,
                    selectedIndex: completions.index,
                    avatarImages: botMode.avatarImages,
                    onSelect: { completions.accept($0) }
                )
            }
            Text("Forward to \(bot.name) in a new session")
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockSecondaryText)
            Text(messageText)
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
                .lineLimit(5)
                .dockPadding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(field.dockSurfaceFill(.dockControlSurface, stroke: .dockBorderLight))
            ComposerInputEditor(
                text: $note,
                isFocused: isFocused,
                onSubmit: forward,
                onCompletionKey: completions.handleKey,
                onFocusChanged: { isFocused = $0 },
                onCaretMoved: { completions.caretMoved(text: $0, caret: $1) },
                takePendingCaret: {
                    defer { pendingCaret.value = nil }
                    return pendingCaret.value
                },
                onTextChanged: { completions.update(for: $0, caret: $1) },
                onContentHeightChanged: { height = ComposerLayout.height(for: $0) },
                inset: NSSize(width: 10, height: 8)
            )
            .frame(height: height)
            .background(
                field.dockSurfaceFill(
                    .dockControlSurface, stroke: .dockBorderStrong, lineWidth: 1, strokeOnGlass: true))
            if let error {
                Text(error).dockFont(.metadata).foregroundStyle(Color.dockDestructive)
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss)
                Button(isForwarding ? "Sending…" : "Forward", action: forward)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isForwarding)
            }
        }
        .dockPadding(12)
        .frame(width: 340)
        .onAppear {
            isFocused = true
            completions.configure(
                model: model, botMode: botMode, profileID: bot.id,
                text: { note },
                apply: { text, caret in
                    pendingCaret.value = caret
                    note = text
                    isFocused = true
                }
            )
        }
        .onDisappear { completions.close() }
    }

    private func forward() {
        guard !isForwarding else { return }
        let typed = ComposerCompletion.pathifyingBareRefs(note.trimmingCharacters(in: .whitespacesAndNewlines))
        let body = "Forwarded message:\n\(messageText)"
        isForwarding = true
        error = nil
        // A leading slash command runs on the bot's new session with the
        // forwarded message as the tail of its argument.
        let text = typed.isEmpty ? body : "\(typed)\n\n\(body)"
        model.forwardMessage(text, toProfile: bot.id) { failure, _ in
            isForwarding = false
            if let failure {
                error = failure
            } else {
                dismiss()
                environmentDismiss()
            }
        }
    }
}

private final class CaretBox { var value: Int? }
