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
    var metrics: ConversationWorkspaceMetrics = .resolve(isFullscreen: false)
    /// Nil hides the quota chip (previews and snapshots).
    var controlCenter: ControlCenterModel? = nil
    var openQuota: () -> Void = {}

    @State private var composerHeight: CGFloat = 44
    @State private var isComposerPulsing = false
    @State private var sendKick = 0
    @State private var pasteMonitor: Any?
    @State private var showingAttachmentPopover = false
    @State private var showingFilePicker = false
    @State private var showingImagePicker = false
    @State private var showingFolderPicker = false
    /// Separate from voice mode's `speechInput`: dictation only fills the draft.
    @StateObject private var dictation = SpeechInput(isDictation: true)
    @StateObject private var completions = ComposerCompletionController()
    @FocusState private var isComposerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        composerContent
            .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.png, .jpeg, .gif, .heic, .webP, .pdf], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    stageAttachmentFiles(urls)
                } else if case .failure(let error) = result,
                          let message = AttachmentPopoverPresentation.importerErrorMessage(error) {
                    model.reportAttachmentError(message)
                }
            }
            .fileImporter(isPresented: $showingImagePicker, allowedContentTypes: [.png, .jpeg, .image, .pdf], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    stageAttachmentFiles(urls)
                } else if case .failure(let error) = result,
                          let message = AttachmentPopoverPresentation.importerErrorMessage(error) {
                    model.reportAttachmentError(message)
                }
            }
            .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    composer.text = AttachmentPopoverPresentation.insertingPath(url, into: composer.text)
                    isComposerFocused = true
                } else if case .failure(let error) = result,
                          let message = AttachmentPopoverPresentation.importerErrorMessage(error) {
                    model.reportAttachmentError(message)
                }
            }
            .onChange(of: model.composerFocusRequest) { _, _ in
                isComposerFocused = true
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isComposerPulsing
            )
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: composerHeight)
            .onChange(of: speechInput.isRecording) { _, isRecording in
                isComposerPulsing = isRecording
            }
            .onChange(of: dictation.isRecording) { _, isRecording in
                // Dictation ends by mic tap, final result, or error; keep what was heard.
                let spoken = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !isRecording, !spoken.isEmpty else { return }
                composer.text += (composer.text.isEmpty || composer.text.hasSuffix(" ") || composer.text.hasSuffix("\n") ? "" : " ") + spoken
                isComposerFocused = true
            }
            .onDisappear { dictation.stop() }
            .onAppear {
                DebugLog.write("composer: appeared")
                completions.configure(
                    model: model, botMode: botMode,
                    text: { composer.text },
                    apply: { text, caret in
                        composer.pendingCaret = caret
                        composer.text = text
                        isComposerFocused = true
                    },
                    onOpenChanged: { composer.isCompletionOpen = $0 }
                )
                if pasteMonitor == nil {
                    let dockModel = model
                    let composerText = composer
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
                               MainActor.assumeIsolated({ () -> Bool in
                                   guard !composerText.isCompletionOpen else { return false }
                                   // In a draft, arrows move the caret first; history only
                                   // takes over once the caret can't move further that way.
                                   if !composerText.isBrowsingHistory, !firstResponder.string.isEmpty {
                                       let before = firstResponder.selectedRange()
                                       if direction < 0 { firstResponder.moveUp(nil) } else { firstResponder.moveDown(nil) }
                                       if firstResponder.selectedRange() != before { return true }
                                   }
                                   return dockModel.navigateComposerHistory(direction: direction)
                               }) {
                                return nil
                            }
                        }

                        // isComposerEditing only flips on the first keystroke, so an
                        // untouched composer must be recognised by its first responder.
                        guard event.window?.firstResponder is ComposerInputTextView,
                              event.modifierFlags.contains(.command),
                              event.charactersIgnoringModifiers?.lowercased() == "v" else {
                            return event
                        }
                        let consumed = MainActor.assumeIsolated { dockModel.pasteImageFromPasteboard() }
                        return consumed ? nil : event
                    }
                }
            }
            .onChange(of: composer.text) { _, text in
                // Sends and session switches clear the draft programmatically.
                if text.isEmpty { completions.close() }
            }
            .onDisappear {
                completions.close()
                if let pasteMonitor {
                    NSEvent.removeMonitor(pasteMonitor)
                    self.pasteMonitor = nil
                }
            }
    }

    private var composerContent: some View {
        // Evaluate submission capabilities based on draft text, images, and steering state
        let draftIsEmpty = composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasComposerContent = !draftIsEmpty || !model.pendingImages.isEmpty || model.pendingPDFURL != nil || !model.attachedContexts.isEmpty
        let isResponding = model.status == .working || model.isSending
        // Mid-turn input redirects the turn, or queues when it can't (attachments, approvals).
        let isSteeringTurn = model.isSending && model.sessionID != nil
        let queuedPrompts = model.currentSessionQueuedPrompts
        let queuesAttachments = isSteeringTurn && (!model.pendingImages.isEmpty || model.pendingPDFURL != nil
            || !model.attachedContexts.isEmpty || model.replyQuote != nil)
        let submitLabel = hasComposerContent && model.status != .needsClarification
            && (model.hasQueuedOrRedirectingPrompt || queuesAttachments)
            ? "Queue message"
            : (isSteeringTurn ? DockSkinPresentation.current.steerLabel : DockSkinPresentation.current.submitLabel)
        // An idle composer with a queue left by a stopped turn sends the next one.
        let canSubmit = hasComposerContent || (!model.isSending && !queuedPrompts.isEmpty)
        let showStop = isResponding && !hasComposerContent && !speechInput.isRecording
        // Keep stop reachable while a steer draft is typed or Hermes waits on a
        // clarification; the submit button already shows stop when the draft is empty.
        let showsInterruptControl = (isResponding || model.status == .needsClarification)
            && !speechInput.isRecording
            && !showStop
        // Leave room for TextEditor's native top and bottom insets.
        let minimumComposerHeight = ComposerLayout.minHeight
        let effectiveComposerHeight = max(minimumComposerHeight, draftIsEmpty ? ComposerLayout.minHeight : composerHeight)
        // One visual gutter shared by the native editor and placeholder. Do
        // not counteract TextEditor's internal padding with nested offsets:
        // those offsets made the caret look detached from the input edge.
        let textContentInset: CGFloat = 16
        let textTopPadding: CGFloat = 4

        return VStack(spacing: 6) {
            if let trigger = completions.trigger, !completions.result.items.isEmpty {
                ComposerCompletionPopover(
                    trigger: trigger,
                    items: completions.result.items,
                    selectedIndex: completions.index,
                    avatarImages: botMode.avatarImages,
                    onSelect: { completions.accept($0) }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            PinnedWorkStrip(model: model)
            if let controlCenter { RunningProcessesStrip(control: controlCenter, isTurnActive: isResponding) }

            if !queuedPrompts.isEmpty {
                QueuedPromptList(model: model, prompts: queuedPrompts)
            }

            if let quote = model.replyQuote {
                ReplyQuoteChip(quote: quote, showsAuthor: false) { model.replyQuote = nil }
                    .padding(.horizontal, 12)
            }

            VStack(spacing: 6) {

            // Main multi-line text input area at top of card container.
            ZStack(alignment: .topLeading) {
                ComposerInputEditor(
                    text: $composer.text,
                    isFocused: isComposerFocused,
                    onSubmit: submitComposerInput,
                    onCompletionKey: completions.handleKey,
                    onDropFiles: stageAttachmentFiles,
                    onFocusChanged: { focused in
                        isComposerFocused = focused
                        model.isComposerEditing = focused
                    },
                    onCaretMoved: { text, caret in
                        // Moving the caret retargets or closes an open popover; only typing opens one.
                        completions.caretMoved(text: text, caret: caret)
                    },
                    takePendingCaret: {
                        defer { composer.pendingCaret = nil }
                        return composer.pendingCaret
                    },
                    onTextChanged: { text, caret in
                        completions.update(for: text, caret: caret)
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
                        .font(.system(size: 14, design: DockThemeStyle.current.fontDesign))
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
            .clipShape(DockThemeShape(cornerRadius: DockSkinPresentation.current.composerRadius, role: .pane))

            // Image Attachment Previews (if any images are pending)
            if !model.pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.pendingImages) { image in
                            HStack(spacing: 6) {
                                Image(nsImage: image.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 32, height: 32)
                                    .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous))
                                Button(action: { model.removePendingImage(image) }) {
                                    DockIcon(.x)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color.dockSecondaryText)
                                    .frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.dockHover)
                                .help("Remove image")
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).fill(Color.dockSurface))
                            .contextMenu {
                                Button("Add Text from Image to Message") { Task { await model.stageText(from: image) } }
                            }
                        }
                    }
                }
            }
            if !model.attachedContexts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.attachedContexts) { context in
                            HStack(spacing: 7) {
                                DockIcon(.chatCircleText)
                                    .foregroundStyle(Color.dockAccent)
                                Text(context.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.dockPrimaryText)
                                    .lineLimit(1)
                                    .frame(maxWidth: 240, alignment: .leading)
                                Button { model.removeAttachedContext(context) } label: {
                                    DockIcon(.x)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color.dockSecondaryText)
                                    .frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.dockHover)
                                .help("Remove context")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).fill(Color.dockSurface))
                            .help(context.body)
                        }
                    }
                }
            }
            if let pdfURL = model.pendingPDFURL {
                HStack(spacing: 7) {
                    DockIcon(.fileText)
                        .foregroundStyle(Color.dockAccent)
                    Text(pdfURL.lastPathComponent)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1)
                    Button { model.removePendingPDF() } label: {
                        DockIcon(.x)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.dockSecondaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.dockHover)
                    .help("Remove PDF")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).fill(Color.dockSurface))
            }
            ForEach([model.pendingPDFError, model.pendingAttachmentError].compactMap { $0 }, id: \.self) { error in
                HStack(spacing: 6) {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockWarning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.clearAttachmentErrors() } label: {
                        DockIcon(.x)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.dockSecondaryText)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.dockHover)
                    .help("Remove attachment")
                }
            }

            // Integrated Bottom Toolbar Row
            HStack(alignment: .center, spacing: 8) {
                // Left Toolbar Group: Paperclip attachment button & Model selector dropdown menu
                HStack(alignment: .center, spacing: 6) {
                    // Attachment popover keeps secondary actions discoverable
                    // without changing the composer's stable footprint.
                    Button { showingAttachmentPopover = true } label: {
                        DockIcon(.plus, size: 14, color: Color.dockSecondaryText)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                                    .fill(DockSkinPresentation.current.composerControlFill)
                            )
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.dockHover)
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

                    if #available(macOS 15.2, *), OnDeviceAssist.isAvailable {
                        Button {
                            NSApp.sendAction(#selector(NSResponder.showWritingTools(_:)), to: nil, from: nil)
                        } label: {
                            DockIcon(.magicWand, size: 14, color: Color.dockSecondaryText)
                                .frame(width: 28, height: 28)
                                .background(
                                    RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                                        .fill(DockSkinPresentation.current.composerControlFill)
                                )
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.dockHover)
                        .help("Rewrite or proofread with Apple Intelligence")
                        .accessibilityLabel("Writing Tools")
                    }

                    composerModelPicker
                }
                .layoutPriority(-1)

                Spacer(minLength: 4)

                // Right Toolbar Group: Thinking depth selector menu & circular submit button
                HStack(alignment: .center, spacing: 8) {
                    if let controlCenter {
                        ChatQuotaChip(control: controlCenter, openQuota: openQuota,
                                      selectedProvider: selectedModelOptionID?.components(separatedBy: "|").first)
                    }
                    SessionContextRing(model: model)

                    composerReasoningPicker

                    if !speechInput.isRecording {
                        Button { dictation.toggle() } label: {
                            DockIcon(dictation.isRecording ? .stop : .microphone, size: 14,
                                     color: dictation.isRecording ? Color.dockDestructive : Color.dockSecondaryText)
                                .frame(width: 28, height: 28)
                                .background(
                                    RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                                        .fill(dictation.isRecording ? Color.dockDestructive.opacity(0.14) : DockSkinPresentation.current.composerControlFill)
                                )
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.dockHover)
                        .disabled(model.isRestoringSession || dictation.isStarting)
                        .help(dictation.isRecording ? "Stop dictation" : "Dictate")
                        .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate")
                    }

                    if showsInterruptControl {
                        Button(action: { onStop() }) {
                            DockIcon(.stop, weight: .fill)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.dockDestructive)
                                .frame(width: isFullscreen ? 34 : 28, height: isFullscreen ? 34 : 28)
                                .background(Circle().fill(Color.dockDestructive.opacity(0.14)))
                        }
                        .buttonStyle(.dockHover)
                        .help(model.status == .needsClarification
                              ? "Dismiss the question and interrupt Hermes"
                              : "Stop Hermes response")
                        .accessibilityLabel(model.status == .needsClarification ? "Dismiss clarification" : "Stop Hermes response")
                    }

                    // Submit and stop share one action, styled by the composer role.
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
                            (DockSkinPresentation.current.composer != .floating
                                ? AnyShape(DockThemeShape(cornerRadius: DockLayout.controlRadius))
                                : AnyShape(Circle()))
                                .fill(canSubmit && !model.isRestoringSession ? Color.dockAccent : Color.dockSurface6)
                                .frame(width: isFullscreen ? 36 : 32, height: isFullscreen ? 36 : 32)

                            Group {
                                if speechInput.isRecording {
                                    DockIcon(.stop, weight: .fill)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color.dockPrimaryText)
                                } else if showStop {
                                    DockIcon(.stop, weight: .fill)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color.dockDestructive)
                                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                                } else {
                                    DockIcon(.arrowUp)
                                        .font(.system(size: 12, weight: .semibold))
                                        // Use soft dockPrimaryText instead of stark white to prevent eye strain
                                        .foregroundStyle(canSubmit ? Color.dockOnAccentText : Color.dockSecondaryText.opacity(0.5))
                                        // Send: the arrow launches up and drops back in.
                                        .keyframeAnimator(initialValue: CGFloat(0), trigger: sendKick) { view, y in
                                            view.offset(y: y).opacity(1 - Double(abs(y)) / 14)
                                        } keyframes: { _ in
                                            KeyframeTrack {
                                                CubicKeyframe(-12, duration: 0.14)
                                                MoveKeyframe(10)
                                                SpringKeyframe(0, duration: 0.3, spring: .bouncy)
                                            }
                                        }
                                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                                }
                            }
                            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.65), value: showStop)
                        }
                    }
                    .buttonStyle(.dockHover)
                    .frame(width: 32, height: 32)
                    .disabled(
                        model.isRestoringSession ||
                        model.isUpdatingSessionModel ||
                        (!speechInput.isRecording && !showStop && (!canSubmit || (!isSteeringTurn && model.isSending)))
                    )
                    .accessibilityLabel(speechInput.isRecording ? "Send voice prompt" : showStop ? "Stop Hermes response" : submitLabel)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help(
                        speechInput.isRecording
                            ? "Send voice prompt"
                            : (showStop
                                ? "Stop Hermes response"
                                : "\(submitLabel) (↩; ⇧↩ for newline)")
                    )
                }
            }
            .padding(.top, 0)

            // Voice Recording & Steering Status Messages
            if let error = speechInput.errorMessage ?? dictation.errorMessage {
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
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.top, 6)
            .padding(.bottom, 6)
            .background {
                let skin = DockSkinPresentation.current
                let shape = DockThemeShape(cornerRadius: skin.composerRadius, role: .pane)
                if skin.composer == .line {
                    // Typographic skins replace the input box with one rule.
                    Rectangle()
                        .fill(speechInput.isRecording ? Color.dockDestructive : isComposerFocused ? Color.dockAccent : Color.dockPrimaryText)
                        .frame(height: isComposerFocused ? 2 : 1)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                } else {
                    shape.dockInputFill()
                        .overlay {
                            shape.stroke(
                                speechInput.isRecording
                                    ? Color.dockDestructive.opacity(isComposerPulsing ? 0.65 : 0.28)
                                    : (isComposerFocused ? Color.dockAccent.opacity(0.42) : Color.dockBorder),
                                lineWidth: isComposerFocused || speechInput.isRecording ? max(1, DockLayout.outline) : DockLayout.outline
                            )
                            .opacity(DockLayout.outline > 0 || isComposerFocused || speechInput.isRecording ? 1 : 0)
                        }
                        .dockStickerShadow(shape)
                        .dockFoldCrease()
                        .dockEmboss(shape)
                        .dockBevel(pressed: true)
                        .dockCardMarks()
                        .shadow(color: Color.black.opacity(0.10), radius: skin.composerShadow, y: skin.composerShadow == 0 ? 0 : 2)
                }
            }
        }
        .padding(.horizontal, metrics.composerInset)
        .padding(.top, metrics.composerTopInset)
        .padding(.bottom, metrics.composerBottomInset)
        .frame(maxWidth: metrics.composerMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private var composerModelPicker: some View {
        ModelPickerView(
            options: model.runtimeModelOptions,
            selectedID: selectedModelOptionID,
            isRefreshing: model.isLoadingRuntimeModelOptions,
            refreshError: model.runtimeModelOptionsError,
            onRefresh: { model.refreshRuntimeModelOptions(sessionID: model.sessionID) },
            onSelect: { option in
                model.updateSessionModel(option)
            }
        )
        .font(DockTypography.control)
        .foregroundStyle(Color.dockSecondaryText)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .fill(DockSkinPresentation.current.composerControlFill)
        )
        .frame(height: 32)
        .disabled(model.isUpdatingSessionModel)
        .help("Select model")
    }

    private var composerReasoningPicker: some View {
        // Thinking depth variant selector menu
        DockMenu {
            DockMenuChoices(selection: reasoningVariantSelection) {
                ForEach(HermesReasoningVariant.allCases) { variant in
                    DockMenuOption(variant.displayName, value: Optional(variant))
                }
            }
        } label: {
            // A plain button-style menu renders this SwiftUI
            // label as drawn; a borderless menu keeps only native
            // text and images and drops custom icon views.
            HStack(spacing: 6) {
                DockIcon(.brain, size: 13, color: Color.dockSecondaryText)
                Text(sessionReasoningDisplayName)
                    .font(DockTypography.control)
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
                DockIcon(.caretDown, size: 10, color: Color.dockMetadataText)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .fill(DockSkinPresentation.current.composerControlFill)
            )
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .fixedSize()
        .accessibilityLabel("Thinking depth, currently \(sessionReasoningDisplayName)")
        .disabled(model.sessionID != nil && model.isUpdatingSessionReasoning)
        .help("Select thinking depth")
    }

    private func submitComposerInput() {
        if !reduceMotion { sendKick += 1 }
        // Hermes only gives message_agent to canonical Bot Chat sessions, so a
        // single leading roster mention is delivered through bot_relay.deliver
        // into that Bot's Bot Chat. Attachments and in-flight turns keep the
        // ordinary path until Hermes exposes a profile-scoped attachment API.
        // A busy foreground turn doesn't block it: relay runs in the Bot's own
        // chat, while steering would hand the mention to an agent without
        // message_agent.
        if !model.hasQueuedOrRedirectingPrompt,
           model.attachedContexts.isEmpty,
           ComposerMentionPresentation.canDirectRouteBot(
               hasImages: !model.pendingImages.isEmpty,
               hasPDF: model.pendingPDFURL != nil
           ),
           let request = ComposerMentionPresentation.directBotRequest(
                in: composer.text,
                profileIDs: botMode.visibleBots.map(\.id)
           ),
           let bot = botMode.visibleBots.first(where: { $0.id == request.profileID }) {
            completions.close()
            model.sendDirectBotRequest(profileID: bot.id, displayName: bot.name, text: request.text, chatSessionID: bot.chat?.sessionID, quote: model.replyQuote)
            return
        }
        // Other mentions are identified for the session agent, which can
        // deliver them with message_agent when it runs in a Bot Chat.
        model.submitComposerInput(mentionProfiles: botMode.visibleBots.map { $0.id })
    }

    private var pasteImageAvailable: Bool {
        DockModel.pasteboardHoldsImageOnly(.general)
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
        case .folder:
            showingFolderPicker = true
        case .url, .promptSnippets:
            break
        }
    }

    private func stageAttachmentFiles(_ urls: [URL]) {
        AttachmentPopoverFileSelection.process(
            urls,
            stageImage: model.stageImageFile,
            stagePDF: model.stagePDFFile,
            reportError: model.reportAttachmentError,
            clearErrors: model.clearAttachmentErrors
        )
        isComposerFocused = true
    }

    private func insertURL(_ rawValue: String) {
        guard let updated = AttachmentPopoverPresentation.insertingURL(rawValue, into: composer.text) else { return }
        composer.text = updated
        showingAttachmentPopover = false
        isComposerFocused = true
    }

    private func insertSnippet(_ text: String) {
        composer.text = AttachmentPopoverPresentation.insertingSnippet(text, into: composer.text)
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
        if model.isRestoringSession { return DockSkinPresentation.current.restoringPlaceholder }
        if model.status == .needsClarification { return DockSkinPresentation.current.answerPlaceholder }
        return DockSkinPresentation.current.composerPlaceholder
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
        return "Loading…"
    }

    private var sessionReasoningDisplayName: String {
        let reasoning = model.sessionID == nil
            ? model.defaultReasoningVariant
            : model.sessionReasoningVariant
        return reasoning?.displayName ?? "Loading…"
    }

    private var selectedModelOptionID: String? {
        if let id = model.sessionModelOptionID { return id }
        guard model.sessionID == nil else { return nil }
        if let id = model.defaultModelOptionID { return id }
        guard let provider = model.runtimeConfiguration?.provider,
              let modelName = model.runtimeConfiguration?.model else { return nil }
        return HermesModelOption(provider: provider, model: modelName).id
    }

    private var selectedReasoningVariant: HermesReasoningVariant? {
        model.sessionID == nil ? model.defaultReasoningVariant : model.sessionReasoningVariant
    }

    private var reasoningVariantSelection: Binding<HermesReasoningVariant?> {
        Binding(
            get: { selectedReasoningVariant },
            set: { variant in
                guard let variant else { return }
                if model.sessionID == nil {
                    model.updateDefaultReasoning(variant)
                } else {
                    model.updateSessionReasoning(variant)
                }
            }
        )
    }
}

/// Context-window occupancy ring, matching Hermes desktop's context gauge.
/// Occupancy uses the full context window, not the runtime's compaction budget.
/// Compaction replaces the last percentage until Hermes reports completion.
private struct SessionContextRing: View {
    @ObservedObject var model: DockModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingDetails = false
    @State private var details: SessionContextSummary?
    @State private var loadingDetails = false
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let context = model.sessionContextUsage, context.sessionID == model.sessionID {
                let fraction = min(1, Double(context.used) / Double(context.max))
                let percent = Int((fraction * 100).rounded())
                let compacting = model.compactingSessionID == model.sessionID
                let tint: Color = compacting ? .dockAccent : fraction >= 0.8 ? .dockWarning : .dockMetadataText
                HStack(spacing: 4) {
                    ZStack {
                        Circle().stroke(Color.dockBorderLight, lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 12, height: 12)
                    .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: fraction)
                    Text(compacting ? "Compacting" : "\(percent)%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(tint)
                        .contentTransition(.numericText(value: Double(percent)))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: percent)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(compacting ? "Compacting context" : "Context \(percent) percent full")
                .onHover { hovering in updateHover(hovering) }
                .onTapGesture { showingDetails.toggle() }
                .accessibilityAction(named: "Show context details") { showingDetails = true }
                .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                    contextDetails
                        .onHover { hovering in updateHover(hovering) }
                        .task(id: model.compactingSessionID) {
                            loadingDetails = true
                            details = await model.fetchSessionContextDetails()
                            loadingDetails = false
                        }
                }
            }
        }
        .task(id: model.sessionID) { model.refreshSessionTokenUsage() }
        .onChange(of: model.sessionID) { _, _ in
            showingDetails = false
            details = nil
            dismissTask?.cancel()
        }
        .onDisappear { dismissTask?.cancel() }
    }

    private func updateHover(_ hovering: Bool) {
        dismissTask?.cancel()
        if hovering {
            showingDetails = true
        } else {
            dismissTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                showingDetails = false
            }
        }
    }

    private var contextDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Context").font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.compactingSessionID == model.sessionID {
                    Text("Compacting").foregroundStyle(Color.dockAccent)
                }
            }
            if let details {
                if details.contextMax > 0 {
                    detailRow(details.contextEstimated ? "Estimated usage" : "Usage",
                              "\(SessionTokenFormatting.formatCompact(details.contextUsed)) / \(SessionTokenFormatting.formatCompact(details.contextMax)) tokens")
                }
                if details.compressionEnabled == false {
                    detailRow("Automatic compaction", "Disabled")
                } else if let threshold = details.compressionThresholdTokens {
                    detailRow("Compaction threshold", SessionTokenFormatting.format(threshold))
                    if details.contextMax > 0 {
                        let percent = Int((Double(threshold) / Double(details.contextMax) * 100).rounded())
                        Text("Compaction can start at \(percent)% of the full window.")
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                    if model.compactingSessionID != model.sessionID, details.contextUsed > 0 {
                        detailRow("Until token threshold", SessionTokenFormatting.format(max(0, threshold - details.contextUsed)))
                    }
                } else {
                    Text("Compaction threshold isn’t reported by this runtime.")
                        .foregroundStyle(Color.dockSecondaryText)
                }
                Divider().overlay(Color.dockBorderLight)
                if details.categories.isEmpty {
                    Text("Context breakdown is unavailable.").foregroundStyle(Color.dockMetadataText)
                } else {
                    Text("Estimated breakdown").font(.system(size: 12, weight: .semibold))
                    ForEach(details.categories) { category in
                        detailRow(category.label, SessionTokenFormatting.format(category.tokens))
                    }
                }
                Text("The ring measures the full window. Idle time or provider limits can also trigger compaction; this is a token threshold, not a countdown.")
                    .foregroundStyle(Color.dockSecondaryText)
            } else {
                Text(loadingDetails ? "Loading context details…" : "Context details are unavailable.")
                    .foregroundStyle(Color.dockMetadataText)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.dockPrimaryText)
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .background(Color.dockSurface)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Color.dockSecondaryText)
            Spacer(minLength: 12)
            Text(value).monospacedDigit()
        }
    }
}

enum SessionTokenFormatting {
    static func format(_ tokens: Int) -> String {
        tokens < 1_000 ? "\(tokens) tokens" : "\(formatCompact(tokens)) tokens"
    }

    static func formatCompact(_ tokens: Int) -> String {
        switch tokens {
        case ..<1_000: "\(tokens)"
        case ..<1_000_000: String(format: "%.1fk", Double(tokens) / 1_000)
        default: String(format: "%.2fM", Double(tokens) / 1_000_000)
        }
    }
}

/// Stacked response choices for an active Hermes clarification. The composer
/// remains available for a custom response.
/// Prompts parked until the active turn settles; not yet submitted, so removable.
private struct QueuedPromptList: View {
    @ObservedObject var model: DockModel
    let prompts: [QueuedPrompt]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("QUEUED · SENDS WHEN HERMES FINISHES")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Color.dockMetadataText)

            ForEach(prompts) { prompt in
                let isEditing = model.editingQueuedPromptID == prompt.id
                HStack(spacing: 8) {
                    ForEach(prompt.images) { image in
                        Image(nsImage: image.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .help(image.fileName)
                    }
                    if isEditing {
                        DockTextField("Queued message", text: Binding(
                            get: { prompt.text },
                            set: { model.updateQueuedPrompt(prompt.id, text: $0) }
                        ), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.dockPrimaryText)
                            .lineLimit(1...4)
                            .onSubmit { model.editingQueuedPromptID = nil }
                    } else {
                        Text(label(for: prompt))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.dockPrimaryText)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    rowButton(isEditing ? .check : .pencilSimple, label: isEditing ? "Done editing" : "Edit queued message") {
                        if isEditing { model.editingQueuedPromptID = nil } else { model.editQueuedPrompt(prompt.id) }
                    }
                    if model.canSteerQueuedPrompt(prompt) {
                        rowButton(.arrowBendDownRight, label: "Steer into the running turn") {
                            model.steerQueuedPrompt(prompt.id)
                        }
                    } else if model.canSendQueuedPromptNow(prompt) {
                        rowButton(.arrowUp, label: "Stop the running turn and send this now") {
                            model.sendQueuedPromptNow(prompt.id)
                        }
                    }
                    rowButton(.x, label: "Remove queued message") {
                        model.removeQueuedPrompt(prompt.id)
                    }
                }
                .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .top).combined(with: .opacity)))
                .padding(.leading, prompt.images.isEmpty ? 10 : 5)
                .padding(.trailing, 4)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                        .fill(Color.dockAccent.opacity(isEditing ? 0.1 : 0.06))
                        .overlay {
                            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                                .stroke(Color.dockAccent.opacity(isEditing ? 0.5 : 0.24), lineWidth: DockLayout.hairline)
                        }
                )
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: prompts.map(\.id))
    }

    private func rowButton(_ icon: Ph, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DockIcon(icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.dockSecondaryText)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .help(label)
        .accessibilityLabel(label)
    }

    private func label(for prompt: QueuedPrompt) -> String {
        var parts: [String] = []
        if let pdf = prompt.pdfURL { parts.append("[PDF: \(pdf.lastPathComponent)]") }
        parts.append(contentsOf: prompt.contexts.map { "[\($0.title)]" })
        if !prompt.text.isEmpty { parts.append(prompt.text) }
        return parts.joined(separator: " ")
    }
}

enum ComposerCompletionKey {
    case up, down, tab, enter, escape

    init?(keyCode: UInt16) {
        switch keyCode {
        case 126: self = .up
        case 125: self = .down
        case 48: self = .tab
        case 36, 76: self = .enter
        case 53: self = .escape
        default: return nil
        }
    }
}

struct ComposerInputEditor: NSViewRepresentable {
    @Binding var text: String
    let isFocused: Bool
    let onSubmit: () -> Void
    let onCompletionKey: (ComposerCompletionKey) -> Bool
    var onDropFiles: (([URL]) -> Void)? = nil
    let onFocusChanged: (Bool) -> Void
    let onCaretMoved: (String, Int) -> Void
    let takePendingCaret: () -> Int?
    let onTextChanged: (String, Int) -> Void
    let onContentHeightChanged: (CGFloat) -> Void
    var inset = NSSize(width: 16, height: 0)

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
        textView.onCompletionKey = onCompletionKey
        textView.onDropFiles = onDropFiles
        textView.string = text.displayBullets
        textView.font = DockSkinPresentation.nativeFont(size: 14)
        textView.textColor = NSColor(Color.dockPrimaryText)
        textView.insertionPointColor = NSColor(Color.dockAccent)
        textView.drawsBackground = false
        textView.isRichText = false
        if #available(macOS 15.0, *) {
            // Plain text only: Writing Tools must not insert formatting into a message.
            textView.writingToolsBehavior = .complete
            textView.allowedWritingToolsResultOptions = [.plainText]
        }
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = inset
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
        textView.onCompletionKey = onCompletionKey
        textView.onDropFiles = onDropFiles
        textView.font = DockSkinPresentation.nativeFont(size: 14)
        textView.textColor = NSColor(Color.dockPrimaryText)
        textView.insertionPointColor = NSColor(Color.dockAccent)
        if textView.string.markdownBullets != text {
            context.coordinator.isSynchronizingText = true
            textView.string = text.displayBullets
            context.coordinator.isSynchronizingText = false
        }
        if let caret = takePendingCaret() {
            textView.setSelectedRange(NSRange(location: min(caret, (textView.string as NSString).length), length: 0))
        }
        context.coordinator.highlightCommands(in: textView)
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
            if !isSynchronizingText { bulletizeCurrentLine(textView) }
            let markdown = textView.string.markdownBullets
            if !isSynchronizingText, parent.text != markdown {
                parent.text = markdown
                parent.onTextChanged(markdown, textView.selectedRange().location)
            }
            highlightCommands(in: textView)
            reportContentHeight(for: textView)
        }

        /// Tints `/command` tokens without making the plain-text editor rich.
        func highlightCommands(in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager else { return }
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            let accent = NSColor(Color.dockAccent)
            for range in SlashCommandTokens.ranges(in: textView.string) {
                layoutManager.addTemporaryAttributes(
                    [.foregroundColor: accent, .backgroundColor: accent.withAlphaComponent(0.16)],
                    forCharacterRange: range
                )
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isSynchronizingText, let textView = notification.object as? NSTextView else { return }
            parent.onCaretMoved(textView.string.markdownBullets, textView.selectedRange().location)
        }

        /// Typing "- " at a line start shows a "•" bullet; the binding keeps markdown "- ".
        private func bulletizeCurrentLine(_ textView: NSTextView) {
            let ns = textView.string as NSString
            let caret = textView.selectedRange().location
            let line = ns.lineRange(for: NSRange(location: caret, length: 0))
            guard caret >= line.location + 2, ns.substring(with: line).hasPrefix("- ") else { return }
            let range = NSRange(location: line.location, length: 2)
            if textView.shouldChangeText(in: range, replacementString: "• ") {
                textView.replaceCharacters(in: range, with: "• ")
                textView.didChangeText()
            }
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
    var onCompletionKey: ((ComposerCompletionKey) -> Bool)?
    var onDropFiles: (([URL]) -> Void)?

    /// Dropped files become attachments; NSTextView would otherwise insert their paths as text.
    private func droppedFileURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFileURLs(sender)
        guard !urls.isEmpty, let onDropFiles else { return super.performDragOperation(sender) }
        onDropFiles(urls)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let editingModifiers: NSEvent.ModifierFlags = [.shift, .command, .option, .control]
        if event.modifierFlags.intersection(editingModifiers).isEmpty,
           let key = ComposerCompletionKey(keyCode: event.keyCode),
           onCompletionKey?(key) == true {
            return
        }
        if (event.keyCode == 36 || event.keyCode == 76),
           event.modifierFlags.intersection(editingModifiers).isEmpty {
            onSubmit?()
            return
        }
        if event.keyCode == 36, event.modifierFlags.contains(.shift), continueBullet() { return }
        super.keyDown(with: event)
    }

    /// Shift+Return on a "• " line continues the list; on an empty bullet it ends it.
    private func continueBullet() -> Bool {
        let ns = string as NSString
        let line = ns.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let content = ns.substring(with: line).trimmingCharacters(in: .newlines)
        guard content.hasPrefix("• ") else { return false }
        if content == "• " {
            let range = NSRange(location: line.location, length: 2)
            if shouldChangeText(in: range, replacementString: "") {
                replaceCharacters(in: range, with: "")
                didChangeText()
            }
        } else {
            insertText("\n• ", replacementRange: selectedRange())
        }
        return true
    }
}

private extension String {
    var markdownBullets: String { replacingOccurrences(of: "(?m)^• ", with: "- ", options: .regularExpression) }
    var displayBullets: String { replacingOccurrences(of: "(?m)^- ", with: "• ", options: .regularExpression) }
}

/// The AI's todo plan and running background tasks, pinned above the input.
private struct PinnedWorkStrip: View {
    @ObservedObject var model: DockModel

    var body: some View {
        let plan = model.todoPlan.flatMap { $0.sessionID == model.sessionID ? $0 : nil }
            .flatMap { $0.done < $0.items.count ? $0 : nil }
        let tasks = model.currentSessionBackgroundTasks.filter { $0.status == .running }
        if plan != nil || !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let plan {
                    ComposerTodoPlanView(plan: plan, isWorking: model.status == .working)
                        .id(plan.sessionID)
                }
                ForEach(tasks) { task in
                    HStack(spacing: 6) {
                        DockActivityIndicator(state: .running, size: 12)
                        Text(task.prompt).lineLimit(1).truncationMode(.tail)
                            .font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
                        Text("background").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.dockMetadataText)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

/// Hermes background terminal processes for the current session, with a stop button each.
private struct RunningProcessesStrip: View {
    @ObservedObject var control: ControlCenterModel
    var isTurnActive = false
    @State private var isExpanded = false
    @State private var pending: ProcessSummary?

    var body: some View {
        content
            // Processes outlive the turn that started them, so poll while a turn runs or any are listed.
            .task(id: isTurnActive || !control.processes.isEmpty) {
                guard isTurnActive || !control.processes.isEmpty else { return }
                while !Task.isCancelled {
                    await control.pollProcesses()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
    }

    @ViewBuilder private var content: some View {
        if !control.processes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Button { withAnimation(.dockEase(duration: 0.18)) { isExpanded.toggle() } } label: {
                    HStack(spacing: 6) {
                        DockIcon(.terminal, size: 12, color: Color.dockSecondaryText)
                        Text("\(control.processes.count) background process\(control.processes.count == 1 ? "" : "es") running")
                            .font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
                        DockIcon(isExpanded ? .caretDown : .caretRight, size: 9, color: Color.dockMetadataText)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                if isExpanded {
                    ForEach(control.processes) { process in
                        HStack(spacing: 8) {
                            Text(process.name).lineLimit(1).truncationMode(.middle)
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.dockPrimaryText)
                                .help(process.detail ?? process.name)
                            Spacer(minLength: 0)
                            Button("Stop") { pending = process }
                                .buttonStyle(.dockCompact).font(.system(size: 11)).foregroundStyle(Color.dockWarning)
                        }
                        .padding(.leading, 18)
                    }
                }
            }
            .padding(.horizontal, 4)
            .confirmationDialog("Stop Hermes Process?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                if let process = pending {
                    Button("Stop \(process.name)", role: .destructive) {
                        Task { _ = await control.killProcess(process); pending = nil }
                    }
                }
                Button("Cancel", role: .cancel) { pending = nil }
            }
        }
    }
}
