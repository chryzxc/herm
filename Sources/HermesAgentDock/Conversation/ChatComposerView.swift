import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The chat composer, isolated from DockPopover so draft keystrokes re-render
/// only this view. The draft lives in ComposerText; DockPopover does not
/// observe it and keeps its conversation/sidebar render tree stable while
/// typing.
struct ChatComposerView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var composer: ComposerText
    @ObservedObject var speechInput: SpeechInput
    var onStop: () -> Void
    var isFullscreen = false

    @State private var composerHeight: CGFloat = 44
    @State private var isComposerPulsing = false
    @State private var pasteMonitor: Any?
    @State private var showingImagePicker = false
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        composerContent
            .fileImporter(isPresented: $showingImagePicker, allowedContentTypes: [.png, .jpeg, .image], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    urls.forEach { model.stageImageFile(at: $0) }
                }
            }
            .onChange(of: model.composerFocusRequest) { _, _ in
                isComposerFocused = true
            }
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isComposerPulsing)
            .onChange(of: speechInput.isRecording) { _, isRecording in
                isComposerPulsing = isRecording
            }
            .onAppear {
                DebugLog.write("composer: appeared")
                if pasteMonitor == nil {
                    let dockModel = model
                    pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                        let editingModifiers: NSEvent.ModifierFlags = [.shift, .command, .option, .control]
                        // History navigation must not swallow Up/Down in other text fields.
                        if event.modifierFlags.intersection(editingModifiers).isEmpty,
                           dockModel.isComposerEditing,
                           let firstResponder = event.window?.firstResponder as? NSTextView {
                            let direction: Int?
                            switch event.keyCode {
                            case 126: direction = -1 // Up arrow
                            case 125: direction = 1 // Down arrow
                            default: direction = nil
                            }
                            if let direction,
                               firstResponder.isEditable,
                               MainActor.assumeIsolated({ dockModel.navigateComposerHistory(direction: direction) }) {
                                return nil
                            }
                        }

                        guard dockModel.isComposerEditing,
                              event.modifierFlags.contains(.command),
                              event.charactersIgnoringModifiers?.lowercased() == "v" else {
                            return event
                        }
                        let consumed = MainActor.assumeIsolated { dockModel.pasteImageFromPasteboard() }
                        return consumed ? nil : event
                    }
                }
            }
            .onDisappear {
                if let pasteMonitor {
                    NSEvent.removeMonitor(pasteMonitor)
                    self.pasteMonitor = nil
                }
            }
    }

    private var composerContent: some View {
        // Evaluate submission capabilities based on draft text, images, and steering state
        let draftIsEmpty = composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasComposerContent = !draftIsEmpty || !model.pendingImages.isEmpty
        let isResponding = model.status == .working || model.isSending
        let isSteeringTurn = model.status == .working && model.isSending && model.sessionID != nil
        let canSubmit = isSteeringTurn ? !draftIsEmpty : (!draftIsEmpty || !model.pendingImages.isEmpty)
        let showStop = isResponding && !hasComposerContent && !speechInput.isRecording
        // Keep stop reachable while a steer draft is typed or Hermes waits on a
        // clarification; the submit button already shows stop when the draft is empty.
        let showsInterruptControl = (isResponding || model.status == .needsClarification)
            && !speechInput.isRecording
            && !showStop
        // Leave room for TextEditor's native top and bottom insets.
        let minimumComposerHeight = isFullscreen ? 64 : max(ComposerLayout.minHeight, 52)
        let effectiveComposerHeight = max(minimumComposerHeight, draftIsEmpty ? ComposerLayout.minHeight : composerHeight)
        // TextEditor adds a small native leading inset on macOS. Keep that
        // correction in one place so the editor, placeholder, and measurement
        // text all share the same content origin.
        let textInset: CGFloat = 5

        return VStack(spacing: 8) {
            // Main multi-line text input area at top of card container.
            // TextEditor on macOS has a built-in ~5px leading inset; we apply a
            // negative horizontal padding of -5 so the cursor lands exactly where
            // the placeholder text starts, then re-apply an equal positive padding
            // on the surrounding ZStack to restore the visual offset.
            ZStack(alignment: .topLeading) {
                TextEditor(text: $composer.text)
                    .font(.system(size: 14))
                    .focused($isComposerFocused)
                    .onChange(of: isComposerFocused) { _, focused in
                        model.isComposerEditing = focused
                    }
                    .onChange(of: composer.text) { _, _ in
                        // A large paste can change NSTextView's content size
                        // without updating its internal scroll origin. Defer
                        // until AppKit lays out the new text, then keep the
                        // insertion point visible inside the fixed editor.
                        DispatchQueue.main.async {
                            keepEditorCaretVisible()
                        }
                    }
                    .onKeyPress(phases: .down) { press in
                        let hasModifier = !press.modifiers.intersection([.shift, .command, .option, .control]).isEmpty
                        if !hasModifier {
                            switch press.key {
                            case .upArrow where model.navigateComposerHistory(direction: -1): return .handled
                            case .downArrow where model.navigateComposerHistory(direction: 1): return .handled
                            case .return:
                                model.submitComposerInput()
                                return .handled
                            default: break
                            }
                        }
                        return .ignored
                    }
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.automatic)
                    // Negate the TextEditor's internal 5pt inset so text starts
                    // at the same x position as the placeholder overlay.
                    .padding(.horizontal, -textInset)
                    .padding(.vertical, 0)
                    // NSTextView can draw outside its SwiftUI proposal when
                    // its content grows. Keep the native editor inside the
                    // composer; it will scroll internally once this height is
                    // reached instead of covering the toolbar below.
                    .frame(height: effectiveComposerHeight)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .foregroundStyle(Color.dockPrimaryText)
                    .disabled(model.isRestoringSession)

                // Placeholder text displayed when input draft is empty.
                // Padding must match the TextEditor's effective content origin.
                if composer.text.isEmpty {
                    Text(placeholderText)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.dockSecondaryText)
                        // TextEditor already supplies the leading content inset
                        // used by the caret. Do not add another inset here.
                        // TextEditor is already shifted by `-textInset` above,
                        // so the placeholder must not add another horizontal
                        // inset. Its native macOS top inset is approximately
                        // 5pt, which keeps the baseline aligned with the caret.
                        .padding(.leading, 0)
                        .padding(.top, textInset)
                        // macOS TextEditor places its insertion caret above the
                        // SwiftUI text overlay; lift the placeholder to share
                        // the caret's vertical text origin.
                        .allowsHitTesting(false)
                }

                // Invisible measurement overlay — same font/padding as real text —
                // so the ZStack grows to the correct height for dynamic sizing.
                    Text(composer.text.isEmpty ? "" : composer.text)
                        .font(.system(size: 14))
                        .padding(.horizontal, textInset)
                        .padding(.vertical, 7)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(0)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: ComposerContentHeightKey.self, value: proxy.size.height)
                        }
                    }
            }
            // Add back the horizontal inset we removed from TextEditor so the
            // whole block still respects the composer's visual gutter.
            .padding(.horizontal, textInset)
            .frame(height: effectiveComposerHeight)
            .frame(maxWidth: .infinity)
            // NSTextView is AppKit-backed and may ignore a SwiftUI clipping
            // proposal while its intrinsic text height changes. Mask the
            // complete input surface as a final paint boundary.
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .fill(Color.dockCanvas.opacity(0.72))
                    .overlay {
                        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                            .stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline)
                    }
            )
            .onPreferenceChange(ComposerContentHeightKey.self) { contentHeight in
                // Cap composer height between 40px and 140px
                composerHeight = ComposerLayout.height(for: contentHeight)
            }

            // Image Attachment Previews (if any images are pending)
            if !model.pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.pendingImages) { image in
                            HStack(spacing: 6) {
                                Image(nsImage: image.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 40, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                Button(action: { model.removePendingImage(image) }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color.dockSecondaryText)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove image")
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.dockSurface))
                        }
                    }
                }
            }

            // Integrated Bottom Toolbar Row
            HStack(alignment: .center, spacing: 8) {
                // Left Toolbar Group: Paperclip attachment button & Model selector dropdown menu
                HStack(alignment: .center, spacing: 6) {
                    // Attachment Paperclip Button
                    Button(action: { showingImagePicker = true }) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.dockSecondaryText)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Attach image or file")

                    // Model Selector Dropdown Menu
                    Menu {
                        if model.runtimeModelOptions.isEmpty {
                            Text("Loading model catalog…")
                        } else {
                            ForEach(model.runtimeModelOptions) { option in
                                Button {
                                    if model.sessionID == nil {
                                        model.updateRuntimeModel(option)
                                    } else {
                                        model.updateSessionModel(option)
                                    }
                                } label: {
                                    HStack {
                                        Text(option.displayName)
                                        if option.id == selectedModelOptionID {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(sessionModelDisplayName)
                                .font(.system(size: 12, weight: .regular))
                                .lineLimit(1)
                                .foregroundStyle(Color.dockSecondaryText)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.borderless)
                    .frame(minHeight: isFullscreen ? 34 : 28, alignment: .center)
                    .disabled(model.sessionID == nil ? model.isLoadingRuntimeConfiguration : model.isUpdatingSessionModel)
                    .help("Select model")
                }

                Spacer(minLength: 4)

                // Right Toolbar Group: Thinking depth selector menu & circular submit button
                HStack(alignment: .center, spacing: 8) {
                    // Thinking depth variant selector menu
                    Menu {
                        ForEach(HermesReasoningVariant.allCases) { variant in
                            Button {
                                if model.sessionID == nil {
                                    model.updateDefaultReasoning(variant)
                                } else {
                                    model.updateSessionReasoning(variant)
                                }
                            } label: {
                                HStack {
                                    Text(variant.displayName)
                                    if variant == selectedReasoningVariant {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "brain")
                                .font(.system(size: 12, weight: .medium))
                            Text(sessionReasoningDisplayName)
                                .font(.system(size: 12, weight: .regular))
                        }
                        .foregroundStyle(Color.dockSecondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.borderless)
                    .frame(minHeight: isFullscreen ? 34 : 28, alignment: .center)
                    .disabled(model.sessionID == nil ? model.isUpdatingDefaultReasoning : model.isUpdatingSessionReasoning)
                    .help("Select thinking depth")

                    if showsInterruptControl {
                        Button(action: { onStop() }) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.dockDestructive)
                                .frame(width: isFullscreen ? 34 : 28, height: isFullscreen ? 34 : 28)
                                .background(Circle().fill(Color.dockDestructive.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                        .help(model.status == .needsClarification
                              ? "Dismiss the question and interrupt Hermes"
                              : "Stop Hermes response")
                        .accessibilityLabel(model.status == .needsClarification ? "Dismiss clarification" : "Stop Hermes response")
                    }

                    // Circular Submit / Action Button with Upward Arrow
                    Button(action: {
                        if speechInput.isRecording {
                            speechInput.stop()
                            model.send()
                        } else if showStop {
                            onStop()
                        } else {
                            model.submitComposerInput()
                        }
                    }) {
                        ZStack {
                            Circle()
                                // Soft translucent fill for submit circle
                                .fill(canSubmit && !model.isSteering && !model.isRestoringSession ? Color.dockPrimaryText.opacity(0.20) : Color.dockSurface6)
                                .frame(width: isFullscreen ? 34 : 28, height: isFullscreen ? 34 : 28)

                            if speechInput.isRecording {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.dockPrimaryText)
                            } else if showStop {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.dockDestructive)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 12, weight: .semibold))
                                    // Use soft dockPrimaryText instead of stark white to prevent eye strain
                                    .foregroundStyle(canSubmit && !model.isSteering ? Color.dockPrimaryText : Color.dockSecondaryText.opacity(0.5))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isRestoringSession || (!speechInput.isRecording && !showStop && (!canSubmit || (isSteeringTurn ? model.isSteering : model.isSending))))
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help(
                        speechInput.isRecording
                            ? "Send voice prompt"
                            : (showStop
                                ? "Stop Hermes response"
                                : (isSteeringTurn ? "Steer active turn (↩; ⇧↩ for newline)" : "Send message (↩; ⇧↩ for newline)"))
                    )
                }
            }
            .padding(.top, 4)

            // Voice Recording & Steering Status Messages
            if let error = speechInput.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            if let steeringError = model.steeringError {
                Text(steeringError)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                    .padding(.top, 2)
            }
            if model.status == .needsClarification {
                Text("Hermes is waiting for your answer — the next message you send replies to the question above.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockAccent)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            if let clarificationResponseError = model.clarificationResponseError {
                Text(clarificationResponseError)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, isFullscreen ? 20 : DockLayout.compactInset)
        // Keep a clear visual buffer below the transcript divider. A composer
        // should feel anchored to the bottom of the workspace, not pressed
        // directly against the last message.
        .padding(.top, isFullscreen ? 22 : 16)
        .padding(.bottom, isFullscreen ? 14 : 10)
        // Native material keeps the composer attached to the popover while
        // allowing the desktop behind it to softly show through.
        .background(
            Rectangle()
                .fill(Color.dockSurface2)
                .overlay {
                    if speechInput.isRecording {
                        Color.dockDestructive.opacity(isComposerPulsing ? 0.12 : 0.05)
                    }
                }
        )
        // The composer joins the conversation with one top separator only.
        // A full outline here doubled the chat boundary and made its side
        // gutters look misaligned with the scrolling transcript.
        .overlay(alignment: .top) {
            (speechInput.isRecording
                ? Color.dockDestructive.opacity(isComposerPulsing ? 0.65 : 0.28)
                : Color.dockBorderLight)
                .frame(height: DockLayout.hairline)
        }
    }

    private func keepEditorCaretVisible() {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
              textView.isEditable else { return }

        let caret = textView.selectedRange().location
        textView.scrollRangeToVisible(NSRange(location: caret, length: 0))
    }

    private var placeholderText: String {
        if model.isRestoringSession { return "Restoring conversation…" }
        if model.status == .needsClarification { return "Answer Hermes' question…" }
        return "Do anything"
    }

    private var sessionModelDisplayName: String {
        if let id = model.sessionModelOptionID,
           let option = model.runtimeModelOptions.first(where: { $0.id == id }) {
            return option.displayName
        }
        if let value = model.sessionModelValue, !value.isEmpty {
            return value
        }
        let runtime = model.runtimeConfiguration
        if let provider = runtime?.provider, let modelName = runtime?.model {
            return "\(provider)  /  \(modelName)"
        }
        return "LOADING…"
    }

    private var sessionReasoningDisplayName: String {
        let reasoning = model.sessionID == nil
            ? model.defaultReasoningVariant
            : model.sessionReasoningVariant
        return reasoning?.displayName ?? "LOADING…"
    }

    private var selectedModelOptionID: String? {
        if model.sessionID != nil { return model.sessionModelOptionID }
        guard let provider = model.runtimeConfiguration?.provider,
              let modelName = model.runtimeConfiguration?.model else { return nil }
        return HermesModelOption(provider: provider, model: modelName).id
    }

    private var selectedReasoningVariant: HermesReasoningVariant? {
        model.sessionID == nil ? model.defaultReasoningVariant : model.sessionReasoningVariant
    }
}

private struct ComposerContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 44

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
