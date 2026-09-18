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
    @ObservedObject var botMode: BotModeModel
    var onStop: () -> Void
    var isFullscreen = false

    @State private var composerHeight: CGFloat = 44
    @State private var isComposerPulsing = false
    @State private var pasteMonitor: Any?
    @State private var showingAttachmentPopover = false
    @State private var showingFilePicker = false
    @State private var showingImagePicker = false
    @State private var showingBotMentionPicker = false
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        composerContent
            .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    stageAttachmentFiles(urls)
                }
            }
            .fileImporter(isPresented: $showingImagePicker, allowedContentTypes: [.png, .jpeg, .image, .pdf], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    let pdfURLs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
                    urls.filter { $0.pathExtension.lowercased() != "pdf" }.forEach { url in
                        model.stageImageFile(at: url)
                    }
                    if pdfURLs.count == 1, let pdfURL = pdfURLs.first {
                        model.stagePDFFile(at: pdfURL)
                    } else if pdfURLs.count > 1 {
                        model.reportPDFError("Select one PDF at a time. Multiple images can still be selected together.")
                    }
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
        let hasComposerContent = !draftIsEmpty || !model.pendingImages.isEmpty || model.pendingPDFURL != nil
        let isResponding = model.status == .working || model.isSending
        let isSteeringTurn = model.status == .working && model.isSending && model.sessionID != nil
        let canSubmit = isSteeringTurn ? !draftIsEmpty : (!draftIsEmpty || !model.pendingImages.isEmpty || model.pendingPDFURL != nil)
        let showStop = isResponding && !hasComposerContent && !speechInput.isRecording
        // Keep stop reachable while a steer draft is typed or Hermes waits on a
        // clarification; the submit button already shows stop when the draft is empty.
        let showsInterruptControl = (isResponding || model.status == .needsClarification)
            && !speechInput.isRecording
            && !showStop
        // Leave room for TextEditor's native top and bottom insets.
        let minimumComposerHeight = isFullscreen ? 64 : max(ComposerLayout.minHeight, 52)
        let effectiveComposerHeight = max(minimumComposerHeight, draftIsEmpty ? ComposerLayout.minHeight : composerHeight)
        // One visual gutter shared by the native editor and placeholder. Do
        // not counteract TextEditor's internal padding with nested offsets:
        // those offsets made the caret look detached from the input edge.
        let textContentInset: CGFloat = 16
        let textTopPadding: CGFloat = 8

        return VStack(spacing: 8) {
            if showingBotMentionPicker {
                BotMentionPicker(
                    bots: mentionCandidates,
                    isLoading: botMode.isRefreshing || botMode.inventory.availability == .unavailable,
                    onSelect: { profileID in
                        composer.text = ComposerMentionPresentation.replacingActiveToken(in: composer.text, with: profileID)
                        showingBotMentionPicker = false
                        isComposerFocused = true
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if model.status == .needsClarification, !model.clarificationChoices.isEmpty {
                ClarificationChoiceChips(
                    choices: model.clarificationChoices,
                    isDisabled: model.isRespondingToClarification || model.isRestoringSession,
                    onSelect: { choice in
                        // A suggested response is a complete answer, so send it
                        // directly instead of making the user copy it into the
                        // editor and submit a second time.
                        model.respondToClarification(choice)
                    }
                )
            }

            // Main multi-line text input area at top of card container.
            ZStack(alignment: .topLeading) {
                ComposerInputEditor(
                    text: $composer.text,
                    isFocused: isComposerFocused,
                    onSubmit: submitComposerInput,
                    onFocusChanged: { focused in
                        isComposerFocused = focused
                        model.isComposerEditing = focused
                    },
                    onTextChanged: { text in
                        updateMentionPicker(for: text)
                        // A large paste can change NSTextView's content size
                        // without updating its internal scroll origin. Defer
                        // until AppKit lays out the new text, then keep the
                        // insertion point visible inside the fixed editor.
                        DispatchQueue.main.async {
                            keepEditorCaretVisible()
                        }
                    },
                    onContentHeightChanged: { contentHeight in
                        composerHeight = ComposerLayout.height(for: contentHeight)
                    }
                )
                    // The native scroll view remains bounded while its document
                    // grows, so wheel and trackpad scrolling stay inside the
                    // editor after the composer reaches its maximum height.
                    .frame(height: max(1, effectiveComposerHeight - textTopPadding))
                    .frame(maxWidth: .infinity)
                    .disabled(model.isRestoringSession)

                // Placeholder text shares the editor's single visual gutter.
                if composer.text.isEmpty {
                    Text(placeholderText)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.dockSecondaryText)
                        .padding(.leading, textContentInset)
                        .allowsHitTesting(false)
                }
            }
            // Move the native editor and the placeholder together; applying
            // padding to only the placeholder would reintroduce caret drift.
            .padding(.top, textTopPadding)
            .frame(height: effectiveComposerHeight)
            .frame(maxWidth: .infinity)
            // NSTextView is AppKit-backed and may ignore a SwiftUI clipping
            // proposal while its intrinsic text height changes. Mask the
            // complete input surface as a final paint boundary.
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .fill(Color.dockCanvas.opacity(0.72))
                    .overlay {
                        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                            .stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline)
                    }
            )

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
                                    LucideImage(systemName: "xmark")
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
            if let pdfURL = model.pendingPDFURL {
                HStack(spacing: 7) {
                    LucideImage(systemName: "doc.text")
                        .foregroundStyle(Color.dockAccent)
                    Text(pdfURL.lastPathComponent)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1)
                    Button { model.removePendingPDF() } label: {
                        LucideImage(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove PDF")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.dockSurface))
            }
            if let pdfError = model.pendingPDFError {
                Text(pdfError)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Integrated Bottom Toolbar Row
            HStack(alignment: .center, spacing: 8) {
                // Left Toolbar Group: Paperclip attachment button & Model selector dropdown menu
                HStack(alignment: .center, spacing: 6) {
                    // Attachment popover keeps secondary actions discoverable
                    // without changing the composer’s stable footprint.
                    Button { showingAttachmentPopover = true } label: {
                        HStack(spacing: 4) {
                            LucideImage(systemName: "plus")
                                .font(.system(size: 14, weight: .medium))
                            Text("Attach")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Color.dockSecondaryText)
                        .frame(minWidth: 44, minHeight: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Attach or insert content")
                    .accessibilityLabel("Attach")
                    .popover(isPresented: $showingAttachmentPopover, arrowEdge: .bottom) {
                        AttachmentPopover(
                            pasteImageAvailable: pasteImageAvailable,
                            onSelect: handleAttachmentAction,
                            onInsertURL: insertURL,
                            onSelectSnippet: insertSnippet
                        )
                    }

                    ModelPickerView(
                        options: model.runtimeModelOptions,
                        selectedID: selectedModelOptionID,
                        isRefreshing: model.isLoadingRuntimeModelOptions,
                        refreshError: model.runtimeModelOptionsError,
                        onRefresh: { model.refreshRuntimeModelOptions(sessionID: model.sessionID) },
                        onSelect: { option in
                            if model.sessionID == nil {
                                model.updateRuntimeModel(option)
                            } else {
                                model.updateSessionModel(option)
                            }
                        }
                    )
                    .font(.system(size: 12, weight: .regular))
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
                                        LucideImage(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            LucideImage(systemName: "brain")
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
                            LucideImage(systemName: "stop.fill")
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
                            submitComposerInput()
                        }
                    }) {
                        ZStack {
                            Circle()
                                // Soft translucent fill for submit circle
                                .fill(canSubmit && !model.isSteering && !model.isRestoringSession ? Color.dockPrimaryText.opacity(0.20) : Color.dockSurface6)
                                .frame(width: isFullscreen ? 34 : 28, height: isFullscreen ? 34 : 28)

                            if speechInput.isRecording {
                                LucideImage(systemName: "stop.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.dockPrimaryText)
                            } else if showStop {
                                LucideImage(systemName: "stop.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.dockDestructive)
                            } else {
                                LucideImage(systemName: "arrow.up")
                                    .font(.system(size: 12, weight: .semibold))
                                    // Use soft dockPrimaryText instead of stark white to prevent eye strain
                                    .foregroundStyle(canSubmit && !model.isSteering ? Color.dockPrimaryText : Color.dockSecondaryText.opacity(0.5))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        model.isRestoringSession ||
                        model.isUpdatingSessionModel ||
                        (!speechInput.isRecording && !showStop && (!canSubmit || (isSteeringTurn ? model.isSteering : model.isSending)))
                    )
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

    private var mentionCandidates: [BotSummary] {
        let query = ComposerMentionPresentation.activeToken(in: composer.text)?
            .dropFirst().lowercased() ?? ""
        return botMode.visibleBots.filter { bot in
            query.isEmpty
                || bot.id.localizedCaseInsensitiveContains(query)
                || bot.name.localizedCaseInsensitiveContains(query)
                || (bot.title?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    private func submitComposerInput() {
        // A single explicit roster mention is a request to that Bot, not a hint
        // for the current ordinary-chat agent to create an unprofiled delegate.
        // Attachments and in-flight turns retain their existing, conservative
        // submission paths until Hermes exposes a profile-scoped attachment API.
        if model.status != .working,
           !model.isSending,
           ComposerMentionPresentation.canDirectRouteBot(
               hasImages: !model.pendingImages.isEmpty,
               hasPDF: model.pendingPDFURL != nil
           ),
           let request = ComposerMentionPresentation.directBotRequest(
                in: composer.text,
                profileIDs: botMode.visibleBots.map(\.id)
           ),
           let bot = botMode.visibleBots.first(where: { $0.id == request.profileID }) {
            showingBotMentionPicker = false
            model.sendDirectBotRequest(profileID: bot.id, displayName: bot.name, text: request.text, chatSessionID: bot.chat?.sessionID)
            return
        }
        model.submitComposerInput()
    }

    private func updateMentionPicker(for text: String) {
        let wasPickerVisible = showingBotMentionPicker
        showingBotMentionPicker = ComposerMentionPresentation.activeToken(in: text) != nil
        guard ComposerMentionRefreshPolicy.shouldRefresh(
            wasPickerVisible: wasPickerVisible,
            isPickerVisible: showingBotMentionPicker
        ) else { return }
        Task { @MainActor in
            await botMode.refreshNow(force: true)
        }
    }

    private var pasteImageAvailable: Bool {
        let pasteboard = NSPasteboard.general
        guard pasteboard.string(forType: .string) == nil else { return false }
        return pasteboard.types?.contains(where: { $0 == .png || $0 == .tiff }) == true
    }

    private func handleAttachmentAction(_ action: AttachmentPopoverAction) {
        showingAttachmentPopover = false
        switch action {
        case .files:
            showingFilePicker = true
        case .images:
            showingImagePicker = true
        case .pasteImage:
            _ = model.pasteImageFromPasteboard()
            isComposerFocused = true
        case .folder, .url, .promptSnippets:
            break
        }
    }

    private func stageAttachmentFiles(_ urls: [URL]) {
        let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "heic", "webp"])
        let imageURLs = urls.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        let pdfURLs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        imageURLs.forEach { model.stageImageFile(at: $0) }
        if pdfURLs.count == 1, let pdfURL = pdfURLs.first {
            model.stagePDFFile(at: pdfURL)
        } else if pdfURLs.count > 1 {
            model.reportPDFError("Select one PDF at a time. Multiple images can still be selected together.")
        }
        isComposerFocused = true
    }

    private func insertURL(_ rawValue: String) {
        guard let updated = AttachmentPopoverPresentation.insertingURL(rawValue, into: composer.text) else { return }
        composer.text = updated
        showingAttachmentPopover = false
        isComposerFocused = true
    }

    private func insertSnippet(_ text: String) {
        let existing = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        composer.text = existing.isEmpty ? text : "\(existing)\n\(text)"
        showingAttachmentPopover = false
        isComposerFocused = true
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

/// Stacked response choices for an active Hermes clarification. The composer
/// remains available for a custom response.
private struct ClarificationChoiceChips: View {
    let choices: [String]
    let isDisabled: Bool
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SUGGESTED RESPONSES")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Color.dockMetadataText)

            ForEach(Array(choices.enumerated()), id: \.offset) { item in
                let choice = item.element
                Button {
                    onSelect(choice)
                } label: {
                    HStack(spacing: 8) {
                        LucideImage(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text(choice)
                            .font(.system(size: 12, weight: .medium))
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isDisabled ? Color.dockMetadataText : Color.dockAccent)
                .background(
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                        .fill(Color.dockAccent.opacity(isDisabled ? 0.04 : 0.10))
                        .overlay {
                            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                                .stroke(Color.dockAccent.opacity(isDisabled ? 0.16 : 0.42), lineWidth: DockLayout.hairline)
                        }
                )
                .disabled(isDisabled)
                .help("Send suggested response: \(choice)")
                .accessibilityLabel("Send suggested response: \(choice)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggested clarification responses")
    }
}

private struct BotMentionPicker: View {
    let bots: [BotSummary]
    let isLoading: Bool
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("CALL A BOT")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Color.dockAccent)
                Spacer()
                Text("@")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.dockSurface6.opacity(0.5))

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading Bots…")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    } else if bots.isEmpty {
                        HStack(spacing: 8) {
                            LucideImage(systemName: "person.2.slash")
                                .foregroundStyle(Color.dockMetadataText)
                            Text("No matching Bots")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    } else {
                        ForEach(bots) { bot in
                            Button {
                                onSelect(bot.id)
                            } label: {
                                HStack(spacing: 9) {
                                    BotAvatarView(bot: bot, imageData: nil, size: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(bot.name)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Color.dockPrimaryText)
                                            .lineLimit(1)
                                        if let description = bot.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                                           !description.isEmpty {
                                            Text(description)
                                                .font(.system(size: 11))
                                                .foregroundStyle(Color.dockMetadataText)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Text("@\(bot.id)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Color.dockMetadataText)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .background(Color.dockCanvas.opacity(0.28))
                            .overlay(alignment: .bottom) {
                                Color.dockBorderLight.opacity(0.45)
                                    .frame(height: DockLayout.hairline)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(maxWidth: .infinity)
        .background(Color.dockSurface2)
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
    }
}

private struct ComposerInputEditor: NSViewRepresentable {
    @Binding var text: String
    let isFocused: Bool
    let onSubmit: () -> Void
    let onFocusChanged: (Bool) -> Void
    let onTextChanged: (String) -> Void
    let onContentHeightChanged: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .automatic
        scrollView.horizontalScrollElasticity = .none

        let textView = ComposerInputTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.string = text
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = NSColor(Color.dockPrimaryText)
        textView.insertionPointColor = NSColor(Color.dockAccent)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 16, height: 0)
        // NSTextContainer adds a 5pt line-fragment inset by default. The
        // placeholder already uses the shared 16pt gutter, so remove that
        // hidden extra inset to align the caret with its first character.
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        context.coordinator.reportContentHeight(for: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerInputTextView else { return }
        context.coordinator.parent = self
        textView.onSubmit = onSubmit
        if textView.string != text {
            context.coordinator.isSynchronizingText = true
            textView.string = text
            context.coordinator.isSynchronizingText = false
        }
        context.coordinator.reportContentHeight(for: textView)

        guard isFocused, scrollView.window?.firstResponder !== textView else { return }
        DispatchQueue.main.async {
            scrollView.window?.makeFirstResponder(textView)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerInputEditor
        var isSynchronizingText = false

        init(_ parent: ComposerInputEditor) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChanged(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onFocusChanged(false)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if !isSynchronizingText, parent.text != textView.string {
                parent.text = textView.string
                parent.onTextChanged(textView.string)
            }
            reportContentHeight(for: textView)
        }

        func reportContentHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let height = layoutManager.usedRect(for: textContainer).height
                + (textView.textContainerInset.height * 2)
            parent.onContentHeightChanged(max(ComposerLayout.minHeight, height))
        }
    }
}

private final class ComposerInputTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let editingModifiers: NSEvent.ModifierFlags = [.shift, .command, .option, .control]
        if (event.keyCode == 36 || event.keyCode == 76),
           event.modifierFlags.intersection(editingModifiers).isEmpty {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }
}
