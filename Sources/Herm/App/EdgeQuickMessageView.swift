import SwiftUI

/// A separate, in-memory draft; sending never consumes workspace attachments.
struct EdgeQuickMessageView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var state: EdgeNotchState
    var inline = false
    let close: () -> Void
    let openDock: () -> Void
    @FocusState private var focused: Bool

    private var unavailableReason: String? {
        model.quickMessageUnavailableReason(for: state.quickTarget ?? state.quickCreatedSession)
    }
    private var canSend: Bool {
        !state.quickSending && unavailableReason == nil
            && !state.quickDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if inline { inlineBody } else { panelBody }
    }

    /// Chat-style field that sits inside the task card; the card's reply toggle closes it.
    private var inlineBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Reply…", text: $state.quickDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(1...4)
                    .focused($focused)
                    .disabled(state.quickSending)
                    .padding(.vertical, 6)
                    .accessibilityLabel("Reply")
                Button(action: submit) {
                    Group {
                        if state.quickSending {
                            ProgressView().controlSize(.mini)
                        } else {
                            DockIcon(.arrowUp, size: 12, color: canSend ? .white : .dockMetadataText)
                        }
                    }
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(canSend ? Color.dockAccent : Color.dockSurface4))
                }
                .buttonStyle(.dockPress)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .padding(.bottom, 3)
                .help("Send reply (⌘↩)")
                .accessibilityLabel("Send reply")
            }
            .padding(.leading, 10)
            .padding(.trailing, 3)
            .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).fill(Color.dockCanvas.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .stroke(focused ? Color.dockAccent.opacity(0.5) : Color.dockBorderLight, lineWidth: 0.5))
            Text(state.quickResult ?? unavailableReason ?? "⌘↩ to send")
                .font(.system(size: 11))
                .foregroundStyle(unavailableReason != nil && state.quickResult == nil ? Color.dockSecondaryText : Color.dockMetadataText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)
        }
        .foregroundStyle(Color.dockPrimaryText)
        .onAppear { focused = true }
        .onChange(of: state.quickDraft) { _, text in
            if !text.isEmpty { state.quickResult = nil }
        }
    }

    private var panelBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(state.quickTarget == nil ? "Quick message" : "Reply").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Back", action: close).buttonStyle(.dockPress)
            }
            Text(state.quickTarget.map { "To: \($0.displayTitle)" } ?? "To: New session")
                .font(.system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
                .lineLimit(1)
                .help(state.quickTarget?.displayTitle ?? "New session")
            TextField("Message Hermes…", text: $state.quickDraft, axis: .vertical)
                .textFieldStyle(.dockGlass)
                .font(.system(size: 12))
                .lineLimit(3...4)
                .focused($focused)
                .disabled(state.quickSending)
                .accessibilityLabel("Quick message")
            Text(state.quickResult ?? unavailableReason ?? "⌘ Return to send")
                .font(.system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            Spacer(minLength: 0)
            Divider().overlay(Color.dockBorderLight)
            HStack {
                EdgePreviewFooterButton(title: "Open Herm", icon: .sidebarSimple, action: openDock)
                Spacer()
                Button(action: submit) {
                    DockActionLabel(title: state.quickTarget == nil ? "Start session" : "Send reply", pendingTitle: "Sending…", isPending: state.quickSending)
                }
                .buttonStyle(.dockPrimary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
            }
        }
        .padding(12)
        .foregroundStyle(Color.dockPrimaryText)
        .onAppear { focused = true }
        .onChange(of: state.quickDraft) { _, text in
            if !text.isEmpty { state.quickResult = nil }
        }
    }

    private func submit() {
        guard !state.quickSending else { return }
        state.quickSending = true
        state.quickResult = nil
        model.sendQuickMessage(state.quickDraft, to: state.quickTarget ?? state.quickCreatedSession,
                               onCreated: { state.quickCreatedSession = $0 }) { error in
            state.quickSending = false
            if let error {
                state.quickResult = error
            } else {
                state.quickDraft = ""
                if state.quickTarget == nil { state.quickCreatedSession = nil }
                state.quickResult = "Sent. Follow the response in Activity."
            }
        }
    }
}
