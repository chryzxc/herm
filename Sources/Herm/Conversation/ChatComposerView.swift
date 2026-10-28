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
    var requiredContext: ChatContext? = nil
    var isFullscreen = false
    var metrics: ConversationWorkspaceMetrics = .resolve(isFullscreen: false)
    /// Nil hides the quota chip (previews and snapshots).
    var controlCenter: ControlCenterModel? = nil
    var openQuota: () -> Void = {}
    /// The session's folder and branch, shown in the tray under the input.
    var worktreeBar: WorktreePicker? = nil

    @State private var composerHeight: CGFloat = 44
    @State private var isComposerPulsing = false
    @State private var sendKick = 0
    @State private var contextCaret = 0
    @State private var inspectingContext: ChatContext?
    @State private var contextPreviewOwner: String?
    @State private var showingSavedPrompts = false
    @State private var showingConversationContext = false
    @State private var historyMonitor: Any?
    @State private var showingAttachmentPopover = false
    @State private var showingFilePicker = false
    @State private var attachmentPicker: AttachmentPopoverFilePicker = .files
    /// Separate from voice mode's `speechInput`: dictation only fills the draft.
    @StateObject private var dictation = SpeechInput(isDictation: true)
    @State private var liveDictation = ComposerDictation()
    @StateObject private var completions = ComposerCompletionController()
    @FocusState private var isComposerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        composerContent
            // A single importer owns presentation; stacked importers can shadow one another.
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: attachmentPicker.allowedContentTypes,
                allowsMultipleSelection: attachmentPicker.allowsMultipleSelection
            ) { result in
                if case .success(let urls) = result {
                    if attachmentPicker == .folder {
                        if let url = urls.first {
                            composer.text = AttachmentPopoverPresentation.insertingPath(url, into: composer.text)
                            isComposerFocused = true
                        }
                    } else {
                        stageAttachmentFiles(urls)
                    }
                } else if case .failure(let error) = result,
                    let message = AttachmentPopoverPresentation.importerErrorMessage(error)
                {
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
                if !isRecording {
                    updateDictation()
                    liveDictation = ComposerDictation()
                }
            }
            .onChange(of: dictation.transcript) { _, _ in
                updateDictation()
            }
            .onChange(of: model.sessionID) { _, _ in
                liveDictation = ComposerDictation()
                dictation.reset()
            }
            .onDisappear {
                liveDictation = ComposerDictation()
                dictation.reset()
            }
            .onChange(of: model.attachedContexts) { previous, _ in
                model.moveContextsToTray(previous: previous)
            }
            .dockSheet(item: $inspectingContext) { context in
                ComposerContextPreview(context: context) { text in
                    guard contextPreviewOwner == WorkspaceIdentity.session(model),
                        model.attachedContexts.contains(where: { $0.id == context.id })
                    else { return }
                    if let token = context.inlineToken, model.draft.contains(token) {
                        model.draft = model.draft.replacingOccurrences(of: token, with: text)
                    } else {
                        model.stageDraft(text)
                    }
                    model.attachedContexts.removeAll { $0.id == context.id }
                }
            }
            .dockSheet(isPresented: $showingSavedPrompts) { SavedPromptLibrary(model: model) }
            .dockSheet(isPresented: $showingConversationContext) { ConversationContextPicker(model: model) }
            .onAppear {
                DebugLog.write("composer: appeared")
                model.moveContextsToTray()
                completions.configure(
                    model: model, botMode: botMode,
                    text: { composer.text },
                    apply: { text, caret in
                        composer.pendingCaret = caret
                        composer.text = text
                        isComposerFocused = true
                    },
                    onOpenChanged: { composer.isCompletionOpen = $0 },
                    onBotSelected: { composer.selectBot($0, range: $1) }
                )
                if historyMonitor == nil {
                    let dockModel = model
                    let composerText = composer
                    historyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                        let editingModifiers: NSEvent.ModifierFlags = [.shift, .command, .option, .control]
                        // History navigation must not swallow Up/Down in other text fields.
                        if event.modifierFlags.intersection(editingModifiers).isEmpty,
                            dockModel.isComposerEditing,
                            let firstResponder = event.window?.firstResponder as? NSTextView
                        {
                            let direction: Int?
                            switch event.keyCode {
                            case 126: direction = -1  // Up arrow
                            case 125: direction = 1  // Down arrow
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
                                        if direction < 0 {
                                            firstResponder.moveUp(nil)
                                        } else {
                                            firstResponder.moveDown(nil)
                                        }
                                        if firstResponder.selectedRange() != before { return true }
                                    }
                                    return dockModel.navigateComposerHistory(direction: direction)
                                })
                            {
                                return nil
                            }
                        }

                        return event
                    }
                }
            }
            .onChange(of: composer.text) { _, text in
                // Sends and session switches clear the draft programmatically.
                if text.isEmpty { completions.close() }
                if liveDictation.owner != nil, !liveDictation.owns(text) {
                    liveDictation = ComposerDictation()
                    dictation.stop()
                }
            }
            .onDisappear {
                completions.close()
                if let historyMonitor {
                    NSEvent.removeMonitor(historyMonitor)
                    self.historyMonitor = nil
                }
            }
    }

    private var composerContent: some View {
        // Evaluate submission capabilities based on draft text, images, and steering state
        let draftIsEmpty = composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasComposerContent =
            !draftIsEmpty || !model.pendingImages.isEmpty || model.pendingPDFURL != nil
            || !model.attachedContexts.isEmpty
        let isResponding = model.status == .working || model.isSending
        // Mid-turn input redirects the turn, or queues when it can't (attachments, approvals).
        let isSteeringTurn = model.isSending && model.sessionID != nil
        let queuedPrompts = model.currentSessionQueuedPrompts
        let queuesAttachments =
            isSteeringTurn
            && (!model.pendingImages.isEmpty || model.pendingPDFURL != nil
                || !model.attachedContexts.isEmpty || model.replyQuote != nil)
        let submitLabel =
            hasComposerContent && model.status != .needsClarification
                && (model.hasQueuedOrRedirectingPrompt || queuesAttachments)
            ? "Queue message"
            : (isSteeringTurn ? DockSkinPresentation.current.steerLabel : DockSkinPresentation.current.submitLabel)
        // An idle composer with a queue left by a stopped turn sends the next one.
        let canSubmit = hasComposerContent || (!model.isSending && !queuedPrompts.isEmpty)
        let showStop = isResponding && !hasComposerContent && !speechInput.isRecording
        // Keep stop reachable while a steer draft is typed or Hermes waits on a
        // clarification; the submit button already shows stop when the draft is empty.
        let showsInterruptControl =
            (isResponding || model.status == .needsClarification)
            && !speechInput.isRecording
            && !showStop
        // Leave room for TextEditor's native top and bottom insets.
        let minimumComposerHeight = ComposerLayout.minHeight
        let effectiveComposerHeight = max(
            minimumComposerHeight, draftIsEmpty ? ComposerLayout.minHeight : composerHeight)
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
                    notice: mentionRelayNotice(trigger),
                    onSelect: { completions.accept($0) }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // One tray joins the plan, queue and folder bar to the input. With
            // none of them showing, the input covers it completely.
            VStack(spacing: 0) {
                PinnedWorkStrip(model: model)
                if let controlCenter { RunningProcessesStrip(control: controlCenter, isTurnActive: isResponding) }

                if !queuedPrompts.isEmpty {
                    QueuedPromptList(model: model, prompts: queuedPrompts)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }

                if let quote = model.replyQuote {
                    ReplyQuoteChip(quote: quote, showsAuthor: false) { model.replyQuote = nil }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
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
                            onPaste: {
                                if !NSEvent.modifierFlags.contains(.shift), model.stageLargePaste() { return true }
                                return model.pasteImageFromPasteboard()
                            },
                            onFocusChanged: { focused in
                                isComposerFocused = focused
                                model.isComposerEditing = focused
                            },
                            onCaretMoved: { text, caret in
                                contextCaret = caret
                                // Moving the caret retargets or closes an open popover; only typing opens one.
                                completions.caretMoved(text: text, caret: caret)
                            },
                            takePendingCaret: {
                                defer { composer.pendingCaret = nil }
                                return composer.pendingCaret
                            },
                            onTextChanged: { text, caret in
                                contextCaret = caret
                                model.removeDeletedInlineContexts()
                                completions.update(for: text, caret: caret)
                            },
                            onTextReplaced: { composer.noteEdit(range: $0, replacement: $1) },
                            onContentHeightChanged: { contentHeight in
                                composerHeight = ComposerLayout.height(for: contentHeight)
                            },
                            contexts: model.attachedContexts,
                            onInspectContext: {
                                contextPreviewOwner = WorkspaceIdentity.session(model)
                                inspectingContext = $0
                            }
                        )
                        // The native scroll view remains bounded while its document
                        // grows, so wheel and trackpad scrolling stay inside the
                        // editor after the composer reaches its maximum height.
                        .frame(height: effectiveComposerHeight)
                        .frame(maxWidth: .infinity)
                        .disabled(model.isRestoringSession)

                        // Placeholder text shares the editor's single visual gutter.
                        if composer.text.isEmpty {
                            Text(placeholderText)
                                .dockFont(.conversation, weight: .regular, design: DockThemeStyle.current.fontDesign)
                                .foregroundStyle(Color.dockSecondaryText)
                                .padding(.leading, textContentInset)
                                .allowsHitTesting(false)
                        }
                    }
                    // Move the native editor and the placeholder together; applying
                    // padding to only the placeholder would reintroduce caret drift.
                    .padding(.top, textTopPadding)
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
                                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                            .overlay {
                                                if model.extractingImageTextIDs.contains(image.id) {
                                                    ProgressView().controlSize(.mini).accessibilityLabel(
                                                        "Reading image text")
                                                }
                                            }
                                        Button(action: { model.removePendingImage(image) }) {
                                            DockIcon(.x)
                                                .dockFont(.compactStatus, weight: .bold)
                                                .foregroundStyle(Color.dockSecondaryText)
                                                .frame(width: 22, height: 22)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.dockHover)
                                        .help("Remove image")
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous).dockSurfaceFill(
                                            Color.dockSurface)
                                    )
                                    .contextMenu {
                                        Button("Add Text from Image to Message") {
                                            Task { await model.stageText(from: image) }
                                        }
                                        .disabled(model.extractingImageTextIDs.contains(image.id))
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
                                        Button {
                                            contextPreviewOwner = WorkspaceIdentity.session(model)
                                            inspectingContext = context
                                        } label: {
                                            HStack(spacing: 7) {
                                                DockIcon(.chatCircleText).foregroundStyle(Color.dockAccent)
                                                Text(context.title).dockFont(.body)
                                                    .lineLimit(1).frame(maxWidth: 240, alignment: .leading)
                                            }
                                        }
                                        .buttonStyle(.dockCompact)
                                        .accessibilityLabel("Inspect context: " + context.title)
                                        Button {
                                            model.removeAttachedContext(context)
                                        } label: {
                                            DockIcon(.x)
                                                .dockFont(.compactStatus, weight: .bold)
                                                .foregroundStyle(Color.dockSecondaryText)
                                                .frame(width: 22, height: 22)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.dockHover)
                                        .help("Remove context").accessibilityLabel("Remove context: " + context.title)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                                            .dockSurfaceFill(Color.dockSurface)
                                    )
                                    .help("Inspect context")
                                }
                            }
                        }
                    }
                    if let pdfURL = model.pendingPDFURL {
                        HStack(spacing: 7) {
                            DockIcon(.fileText)
                                .foregroundStyle(Color.dockAccent)
                            Text(pdfURL.lastPathComponent)
                                .dockFont(.metadata, weight: .medium)
                                .foregroundStyle(Color.dockPrimaryText)
                                .lineLimit(1)
                            Button {
                                model.removePendingPDF()
                            } label: {
                                DockIcon(.x)
                                    .dockFont(.compactStatus, weight: .bold)
                                    .foregroundStyle(Color.dockSecondaryText)
                                    .frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.dockHover)
                            .help("Remove PDF")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                                .dockSurfaceFill(Color.dockSurface))
                    }
                    ForEach([model.pendingPDFError, model.pendingAttachmentError].compactMap { $0 }, id: \.self) {
                        error in
                        HStack(spacing: 6) {
                            Text(error)
                                .dockFont(.metadata)
                                .foregroundStyle(Color.dockWarning)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                model.clearAttachmentErrors()
                            } label: {
                                DockIcon(.x)
                                    .dockFont(.compactStatus, weight: .bold)
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
                            Button {
                                showingAttachmentPopover = true
                            } label: {
                                ComposerControlLabel(icon: .plus)
                            }
                            .buttonStyle(.dockHover)
                            .help("Attach or insert content")
                            .accessibilityLabel("Attach")
                            .dockPopover(isPresented: $showingAttachmentPopover, arrowEdge: .bottom) {
                                AttachmentPopover(
                                    pasteImageAvailable: pasteImageAvailable,
                                    onSelect: handleAttachmentAction,
                                    onSelectSnippet: insertSnippet
                                )
                            }

                            composerModelPicker
                        }
                        .layoutPriority(-1)

                        Spacer(minLength: 4)

                        // Right Toolbar Group: Thinking depth selector menu & circular submit button
                        HStack(alignment: .center, spacing: 8) {
                            if let controlCenter {
                                ChatQuotaChip(
                                    control: controlCenter, openQuota: openQuota,
                                    selectedProvider: selectedModelOptionID?.components(separatedBy: "|").first)
                            }
                            SessionContextRing(model: model)

                            composerReasoningPicker

                            if !speechInput.isRecording {
                                Button {
                                    if dictation.isRecording { dictation.stop() } else { beginDictation() }
                                } label: {
                                    DockIcon(
                                        dictation.isRecording ? .stop : .microphone, size: 14,
                                        color: dictation.isRecording ? Color.dockDestructive : Color.dockSecondaryText
                                    )
                                    .frame(width: 28, height: 28)
                                    .background(
                                        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                                            .fill(
                                                dictation.isRecording
                                                    ? Color.dockDestructiveFill.opacity(0.14)
                                                    : DockSkinPresentation.current.composerControlFill)
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
                                        .dockFont(.compactStatus, weight: .bold)
                                        .foregroundStyle(Color.dockDestructive)
                                        .frame(width: isFullscreen ? 34 : 28, height: isFullscreen ? 34 : 28)
                                        .background(Circle().fill(Color.dockDestructiveFill.opacity(0.14)))
                                }
                                .buttonStyle(.dockHover)
                                .help(
                                    model.status == .needsClarification
                                        ? "Dismiss the question and interrupt Hermes"
                                        : "Stop Herm response"
                                )
                                .accessibilityLabel(
                                    model.status == .needsClarification
                                        ? "Dismiss clarification" : "Stop Herm response")
                            }

                            // Submit and stop share one action, styled by the composer role.
                            Button(action: {
                                if speechInput.isRecording {
                                    speechInput.stop()
                                    prepareRequiredContext()
                                    submitComposerInput()
                                } else if showStop {
                                    onStop()
                                } else {
                                    submitComposerInput()
                                }
                            }) {
                                ComposerSubmitLabel(
                                    isEnabled: canSubmit && !model.isRestoringSession, isFullscreen: isFullscreen
                                ) {
                                    Group {
                                        if speechInput.isRecording {
                                            DockIcon(.stop, weight: .fill)
                                                .dockFont(.compactStatus, weight: .bold)
                                                .foregroundStyle(Color.dockPrimaryText)
                                        } else if showStop {
                                            DockIcon(.stop, weight: .fill)
                                                .dockFont(.compactStatus, weight: .bold)
                                                .foregroundStyle(Color.dockDestructive)
                                                .transition(.scale(scale: 0.3).combined(with: .opacity))
                                        } else {
                                            DockIcon(.arrowUp)
                                                .dockFont(.body, weight: .semibold)
                                                // Use soft dockPrimaryText instead of stark white to prevent eye strain
                                                .foregroundStyle(
                                                    canSubmit
                                                        ? Color.dockOnAccentText : Color.dockSecondaryText.opacity(0.5)
                                                )
                                                // Send: the arrow launches up and drops back in.
                                                .keyframeAnimator(initialValue: CGFloat(0), trigger: sendKick) {
                                                    view, y in
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
                                    .animation(
                                        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.65),
                                        value: showStop)
                                }
                            }
                            .buttonStyle(.dockHover)
                            .frame(width: 32, height: 32)
                            .disabled(
                                model.isRestoringSession || model.isUpdatingSessionModel
                                    || (!speechInput.isRecording && !showStop
                                        && (!canSubmit || (!isSteeringTurn && model.isSending)))
                            )
                            .accessibilityLabel(
                                speechInput.isRecording
                                    ? "Send voice prompt" : showStop ? "Stop Herm response" : submitLabel
                            )
                            .keyboardShortcut(.return, modifiers: [.command])
                            .help(
                                speechInput.isRecording
                                    ? "Send voice prompt"
                                    : (showStop
                                        ? "Stop Herm response"
                                        : "\(submitLabel) (↩; ⇧↩ for newline)")
                            )
                        }
                    }
                    .padding(.top, 0)

                    // Voice Recording & Steering Status Messages
                    if let error = speechInput.errorMessage ?? dictation.errorMessage {
                        HStack(spacing: 8) {
                            Text(error)
                                .dockFont(.metadata)
                                .foregroundStyle(Color.dockWarning)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Retry", action: beginDictation)
                                .buttonStyle(.dockCompact)
                                .disabled(model.isRestoringSession || dictation.isStarting)
                            Button {
                                speechInput.dismissError()
                                dictation.dismissError()
                            } label: {
                                DockIcon(.x, size: 12)
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.dockHover)
                            .accessibilityLabel("Dismiss speech recognition warning")
                        }
                        .padding(.top, 2)
                    }
                    if let steeringError = model.steeringError {
                        Text(steeringError)
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockWarning)
                            .padding(.top, 2)
                    }
                    if let clarificationResponseError = model.clarificationResponseError {
                        Text(clarificationResponseError)
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockWarning)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                .padding(.leading, 6)
                .padding(.trailing, 8)
                .padding(.top, 6)
                .padding(.bottom, 6)
                .modifier(
                    ComposerInputSurface(
                        isFocused: isComposerFocused, isRecording: speechInput.isRecording, isPulsing: isComposerPulsing
                    ))

                if let worktreeBar { worktreeBar.padding(.vertical, 2) }
            }
            .background {
                let skin = DockSkinPresentation.current
                if skin.composer != .line {
                    DockThemeShape(cornerRadius: skin.composerRadius, role: .pane)
                        .dockSurfaceFill(Color.dockSurface4, stroke: Color.dockBorderLight)
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
        .dockFont(.control)
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
                    .dockFont(.control)
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

    private func beginDictation() {
        speechInput.dismissError()
        liveDictation.begin(owner: WorkspaceIdentity.session(model), text: composer.text)
        dictation.startListening()
    }

    private func updateDictation() {
        guard liveDictation.owner != nil else { return }
        guard
            let text = liveDictation.update(
                dictation.transcript, text: composer.text,
                owner: WorkspaceIdentity.session(model))
        else {
            liveDictation = ComposerDictation()
            dictation.stop()
            return
        }
        composer.text = text
        isComposerFocused = true
    }

    private func submitComposerInput() {
        liveDictation = ComposerDictation()
        dictation.stop()
        if !reduceMotion { sendKick += 1 }
        completions.close()
        prepareRequiredContext()
        model.submitComposerInput(bots: botMode.bots.filter { !$0.isHidden })
    }

    private func prepareRequiredContext() {
        guard let requiredContext, !model.attachedContexts.contains(where: { $0.id == requiredContext.id }) else {
            return
        }
        model.attachedContexts.append(requiredContext)
    }

    private func mentionRelayNotice(_ trigger: ComposerCompletionTrigger) -> String? {
        guard case .mention = trigger, completions.result.items.contains(where: { $0.bot != nil }) else { return nil }
        return ComposerMentionPresentation.relayNotice(
            draft: composer.text,
            profileIDs: botMode.bots.filter { !$0.isHidden }.map(\.id),
            hasAttachments: !model.attachedContexts.isEmpty || !model.pendingImages.isEmpty
                || model.pendingPDFURL != nil,
            isQueued: model.hasQueuedOrRedirectingPrompt
        )
    }

    private var pasteImageAvailable: Bool {
        DockModel.pasteboardHoldsImageOnly(.general)
    }

    private func handleAttachmentAction(_ action: AttachmentPopoverAction) {
        showingAttachmentPopover = false
        switch action {
        case .savedPrompts:
            showingSavedPrompts = true
        case .conversation:
            showingConversationContext = true
        case .captureWindow:
            model.captureDesktopWindow()
        case .files:
            attachmentPicker = .files
            showingFilePicker = true
        case .images:
            attachmentPicker = .images
            showingFilePicker = true
        case .pasteImage:
            _ = model.pasteImageFromPasteboard()
            isComposerFocused = true
        case .folder:
            attachmentPicker = .folder
            showingFilePicker = true
        case .promptSnippets:
            break
        }
    }

    private func stageAttachmentFiles(_ urls: [URL]) {
        AttachmentPopoverFileSelection.process(
            urls,
            stageImage: model.stageImageFile,
            stagePDF: model.stagePDFFile,
            stageFile: model.stageFile,
            reportError: model.reportAttachmentError,
            clearErrors: model.clearAttachmentErrors
        )
        isComposerFocused = true
    }

    private func insertSnippet(_ text: String) {
        composer.text = AttachmentPopoverPresentation.insertingSnippet(text, into: composer.text)
        showingAttachmentPopover = false
        isComposerFocused = true
    }

    private var placeholderText: String {
        if model.isRestoringSession { return DockSkinPresentation.current.restoringPlaceholder }
        if model.status == .needsClarification { return DockSkinPresentation.current.answerPlaceholder }
        return DockSkinPresentation.current.composerPlaceholder
    }

    private var sessionModelDisplayName: String {
        if let id = model.sessionModelOptionID,
            let option = model.runtimeModelOptions.first(where: { $0.id == id })
        {
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
        let reasoning =
            model.sessionID == nil
            ? model.defaultReasoningVariant
            : model.sessionReasoningVariant
        return reasoning?.displayName ?? "Loading…"
    }

    private var selectedModelOptionID: String? {
        if let id = model.sessionModelOptionID { return id }
        guard model.sessionID == nil else { return nil }
        if let id = model.defaultModelOptionID { return id }
        guard let provider = model.runtimeConfiguration?.provider,
            let modelName = model.runtimeConfiguration?.model
        else { return nil }
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
    @State private var usage: SessionUsageSummary?
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
                        .dockFont(.metadata, weight: .medium, design: .monospaced)
                        .foregroundStyle(tint)
                        .contentTransition(.numericText(value: Double(percent)))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: percent)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(compacting ? "Compacting context" : "Context \(percent) percent full")
                .onHover { hovering in updateHover(hovering) }
                .onTapGesture { showingDetails.toggle() }
                .accessibilityAction(named: "Show context details") { showingDetails = true }
                .dockPopover(isPresented: $showingDetails, arrowEdge: .bottom) {
                    contextDetails
                        .onHover { hovering in updateHover(hovering) }
                        .task(id: model.compactingSessionID) {
                            loadingDetails = true
                            async let fetchedUsage = model.fetchSessionUsageDetails()
                            details = await model.fetchSessionContextDetails()
                            usage = await fetchedUsage
                            loadingDetails = false
                        }
                }
            }
        }
        .task(id: model.sessionID) { model.refreshSessionTokenUsage() }
        .onChange(of: model.sessionID) { _, _ in
            showingDetails = false
            details = nil
            usage = nil
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
        VStack(alignment: .leading, spacing: 14) {
            contextHeader
            if let details {
                if details.contextMax > 0 { windowBar(details) }
                if details.categories.contains(where: { $0.tokens > 0 }) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(details.categories.enumerated()), id: \.element.id) { index, category in
                            if category.tokens > 0 {
                                legendRow(category.label, tokens: category.tokens, color: segmentColor(index))
                            }
                        }
                    }
                } else {
                    Text("Context breakdown is unavailable.").foregroundStyle(Color.dockMetadataText)
                }
                compactionRow(details)
            } else {
                Text(loadingDetails ? "Loading context details…" : "Context details are unavailable.")
                    .foregroundStyle(Color.dockMetadataText)
            }
            if let usage, usage.calls > 0 || usage.totalTokens > 0 {
                Divider().overlay(Color.dockBorderLight)
                sessionUsage(usage)
            }
        }
        .dockFont(.body)
        .foregroundStyle(Color.dockPrimaryText)
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .dockPaneTint(Color.dockSurface)
    }

    private var contextHeader: some View {
        let compacting = model.compactingSessionID == model.sessionID
        let modelName = [usage?.model, details?.model].compactMap { $0 }.first { !$0.isEmpty }
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Context").dockFont(.body, weight: .semibold)
                if let modelName {
                    Text(modelName).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            if compacting {
                Text("Compacting").foregroundStyle(Color.dockAccent)
            } else if let details, details.contextMax > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(
                        "\(SessionTokenFormatting.formatCompact(details.contextUsed)) / \(SessionTokenFormatting.formatCompact(details.contextMax))"
                    )
                    .monospacedDigit()
                    Text(details.contextEstimated ? "Estimated" : "Reported by provider")
                        .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                }
            }
        }
    }

    /// Segments are drawn against the full window so the remaining headroom stays visible.
    private func windowBar(_ details: SessionContextSummary) -> some View {
        GeometryReader { geometry in
            let window = Double(details.contextMax)
            HStack(spacing: 1) {
                ForEach(Array(details.categories.enumerated()), id: \.element.id) { index, category in
                    if category.tokens > 0 {
                        segmentColor(index)
                            .frame(width: max(2, geometry.size.width * min(1, Double(category.tokens) / window)))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dockBorderLight)
            .clipShape(Capsule())
            .overlay(alignment: .leading) {
                if let threshold = details.compressionThresholdTokens, details.compressionEnabled != false {
                    Color.dockSecondaryText.frame(width: 1.5)
                        .offset(x: geometry.size.width * min(1, Double(threshold) / window))
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private func segmentColor(_ index: Int) -> Color {
        DockAccentColor.allCases[index % DockAccentColor.allCases.count].fill
    }

    private func legendRow(_ label: String, tokens: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(Color.dockSecondaryText)
            Spacer(minLength: 12)
            Text(SessionTokenFormatting.formatCompact(tokens)).monospacedDigit()
        }
    }

    @ViewBuilder private func compactionRow(_ details: SessionContextSummary) -> some View {
        if details.compressionEnabled == false {
            detailRow("Auto-compaction", "Off")
        } else if let threshold = details.compressionThresholdTokens {
            let percent =
                details.contextMax > 0 ? Int((Double(threshold) / Double(details.contextMax) * 100).rounded()) : nil
            detailRow(
                "Compacts near",
                SessionTokenFormatting.formatCompact(threshold) + (percent.map { " (\($0)%)" } ?? ""))
        } else {
            Text("Compaction threshold isn’t reported by this runtime.")
                .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
        }
    }

    private func sessionUsage(_ usage: SessionUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Session usage").dockFont(.body, weight: .semibold).padding(.bottom, 2)
            detailRow("Input", SessionTokenFormatting.formatCompact(usage.inputTokens))
            detailRow("Output", SessionTokenFormatting.formatCompact(usage.outputTokens))
            if usage.reasoningTokens > 0 {
                detailRow("Reasoning", SessionTokenFormatting.formatCompact(usage.reasoningTokens))
            }
            detailRow("API calls", usage.calls.formatted())
            if let hit = usage.cacheHitPercent { detailRow("Cache hit", "\(hit)%") }
            if usage.compactions > 0 { detailRow("Compactions", usage.compactions.formatted()) }
            if let speed = SessionTokenFormatting.speed(
                tokensPerSecond: usage.tokensPerSecond, latency: usage.averageLatencySeconds)
            {
                detailRow("Speed", speed)
            }
            Text("Main conversation totals; background tasks like titles and compaction aren’t included.")
                .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
        }
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

    /// Hermes' rolling average over recent API calls; nil when it reported neither.
    static func speed(tokensPerSecond: Double?, latency: Double?) -> String? {
        let parts = [
            tokensPerSecond.map { String(format: "%.0f tok/s", $0) },
            latency.map { String(format: "%.1fs avg", $0) },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: DockModel
    let prompts: [QueuedPrompt]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Queued (\(prompts.count)) · Sends when Herm finishes")
                .dockFont(.body, weight: .medium)
                .foregroundStyle(Color.dockMetadataText)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(prompts) { prompt in
                        HStack(spacing: 8) {
                            ForEach(prompt.images) { image in
                                Image(nsImage: image.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 28, height: 28)
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    .help(image.fileName)
                            }
                            Text(label(for: prompt))
                                .dockFont(.body, weight: .medium)
                                .foregroundStyle(Color.dockPrimaryText)
                                .lineLimit(2)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            rowButton(.pencilSimple, label: "Edit in composer") {
                                model.editQueuedPrompt(prompt.id)
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
                        .draggable(prompt.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            guard let value = items.first, let id = UUID(uuidString: value) else { return false }
                            model.reorderQueuedPrompt(id, before: prompt.id)
                            return true
                        }
                        .contextMenu {
                            Button("Move up") { model.moveQueuedPrompt(prompt.id, offset: -1) }
                            Button("Move down") { model.moveQueuedPrompt(prompt.id, offset: 1) }
                        }
                        .transition(
                            .asymmetric(insertion: .opacity, removal: .move(edge: .top).combined(with: .opacity))
                        )
                        .padding(.leading, prompt.images.isEmpty ? 10 : 5)
                        .padding(.trailing, 4)
                        .padding(.vertical, 5)
                        .background(
                            DockThemeShape(cornerRadius: DockLayout.controlRadius)
                                .fill(Color.dockControlSurface)
                                .overlay {
                                    DockThemeShape(cornerRadius: DockLayout.controlRadius)
                                        .stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline)
                                }
                        )
                    }
                }
            }
            .frame(maxHeight: 144)
            .fixedSize(horizontal: false, vertical: true)
        }
        .animation(reduceMotion ? nil : .dockEase(duration: 0.16), value: prompts.map(\.id))
    }

    private func rowButton(_ icon: Ph, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DockIcon(icon)
                .dockFont(.compactStatus, weight: .semibold)
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
        if !prompt.text.isEmpty {
            parts.append(
                prompt.contexts.reduce(prompt.text) { value, context in
                    context.inlineToken.map { value.replacingOccurrences(of: $0, with: "[" + context.title + "]") }
                        ?? value
                })
        }
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

extension String {
    var markdownBullets: String { replacingOccurrences(of: "(?m)^• ", with: "- ", options: .regularExpression) }
    var displayBullets: String { replacingOccurrences(of: "(?m)^- ", with: "• ", options: .regularExpression) }
}

/// The AI's todo plan and running background tasks, pinned above the input.
private struct PinnedWorkStrip: View {
    @ObservedObject var model: DockModel

    var body: some View {
        let plan = model.todoPlan.flatMap { $0.sessionID == model.sessionID ? $0 : nil }
            .flatMap { model.status == .working && $0.done < $0.items.count ? $0 : nil }
        let tasks = model.currentSessionBackgroundTasks.filter { $0.status == .running }
        if plan != nil || !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let plan {
                    ComposerTodoPlanView(plan: plan, isWorking: model.status == .working)
                        .id(plan.sessionID)
                }
                if !tasks.isEmpty {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(tasks) { task in
                                HStack(spacing: 6) {
                                    DockActivityIndicator(state: .running, size: 12)
                                    Text(task.prompt).lineLimit(1).truncationMode(.tail)
                                        .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                                    Text("background").dockFont(.compactStatus, weight: .regular, design: .monospaced)
                                        .foregroundStyle(Color.dockMetadataText)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .frame(minHeight: 28)
                            }
                        }
                    }
                    .frame(maxHeight: 96)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(4)
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
                Button {
                    withAnimation(.dockEase(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        DockIcon(.terminal, size: 12, color: Color.dockSecondaryText)
                        Text(
                            "\(control.processes.count) background process\(control.processes.count == 1 ? "" : "es") running"
                        )
                        .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
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
                                .dockFont(.metadata, weight: .regular, design: .monospaced).foregroundStyle(
                                    Color.dockPrimaryText
                                )
                                .help(process.detail ?? process.name)
                            Spacer(minLength: 0)
                            Button("Stop") { pending = process }
                                .buttonStyle(.dockCompact).dockFont(.metadata).foregroundStyle(Color.dockWarning)
                        }
                        .padding(.leading, 18)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .confirmationDialog(
                "Stop Hermes Process?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
            ) {
                if let process = pending {
                    Button("Stop \(process.name)", role: .destructive) {
                        Task {
                            _ = await control.killProcess(process)
                            pending = nil
                        }
                    }
                }
                Button("Cancel", role: .cancel) { pending = nil }
            }
        }
    }
}
