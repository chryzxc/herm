import SwiftUI

/// Forwards one message to a bot in a new session. The note field uses the
/// composer's `/`, `@` and `$` completions, scoped to the bot's own commands.
struct ForwardToBotPopover: View {
    let model: DockModel
    @ObservedObject var botMode: BotModeModel
    let bot: BotSummary
    let messageText: String
    @ObservedObject var draft: ForwardToBotDraft
    let dismiss: () -> Void
    @Environment(\.dismiss) private var environmentDismiss

    /// A class box, not @State: the editor reads and clears it during a view update.
    @State private var pendingCaret = CaretBox()
    @State private var height = ComposerLayout.minHeight

    @StateObject private var completions = ComposerCompletionController()
    @FocusState private var isFocused: Bool

    var body: some View {
        let field = DockThemeShape(cornerRadius: DockLayout.controlRadius)
        let isForwarding = draft.submission == .sending
        VStack(alignment: .leading, spacing: 10) {
            if let trigger = completions.trigger, completions.isPresented {
                ComposerCompletionPopover(
                    trigger: trigger,
                    items: completions.result.items,
                    selectedIndex: completions.index,
                    isLoading: completions.isLoading,
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
                text: $draft.note,
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
            if case .failed(let error) = draft.submission {
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
                text: { draft.note },
                apply: { text, caret in
                    pendingCaret.value = caret
                    draft.note = text
                    isFocused = true
                }
            )
        }
        .onDisappear { completions.close() }
        .onChange(of: draft.submission) { _, submission in
            guard case .sent = submission else { return }
            dismiss()
            environmentDismiss()
        }
    }

    private func forward() {
        draft.submit(messageText: messageText, to: bot.id, using: model)
    }
}

private final class CaretBox { var value: Int? }
