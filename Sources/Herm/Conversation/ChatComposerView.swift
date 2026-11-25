import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The chat composer, isolated from DockPopover so draft keystrokes re-render
/// only this view. The draft lives in ComposerText; DockPopover does not
/// observe it and keeps its conversation/sidebar render tree stable while
/// typing.
struct ChatComposerView: View {
    let model: DockModel
    @ObservedObject var composer: ComposerText
    let speechInput: SpeechInput
    let botMode: BotModeModel
    var onStop: () -> Void
    var requiredContext: ChatContext? = nil
    var isFullscreen = false
    var metrics: ConversationWorkspaceMetrics = .resolve(isFullscreen: false)
    /// Nil hides the quota chip (previews and snapshots).
    var controlCenter: ControlCenterModel? = nil
    var openQuota: () -> Void = {}
    /// Set on a new chat with no session yet, to choose the project it starts in.
    var projectPicker: NewChatProjectPicker? = nil
    /// The session's folder and branch, shown in the tray under the input.
    var worktreeBar: WorktreePicker? = nil
    var returnApprovalID: UUID? = nil
    var generateFollowUp: (String) async -> String? = OnDeviceAssist.suggestFollowUp

    @State private var composerHeight: CGFloat = ComposerLayout.minHeight
    @State private var presentationRevision = 0
    @State private var followUp: ComposerFollowUp?
    @State private var isComposerFirstResponder = false
    @AppStorage(ComposerTypingSettings.followUpSuggestionsKey) private var followUpSuggestionsEnabled = true
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
    @Environment(\.composerReservesFolderBar) private var reservesFolderBar

    var body: some View {
        let _ = presentationRevision
        let _ = HermPerformanceRecorder.countBody("ChatComposerView")
        let request = followUpRequest
        let suggestion = followUp?.request == request ? followUp : nil
        composerContent(suggestion: suggestion)
            .onReceive(model.composerPresentationChanges) { _ in presentationRevision &+= 1 }
            .onReceive(model.$messages) { messages in
                // @Published emits before the model stores the new transcript.
                if canSuggestFollowUp,
                    ComposerFollowUp.prompt(in: messages) != ComposerFollowUp.prompt(in: model.messages)
                {
                    presentationRevision &+= 1
                }
            }
            .task(id: request) {
                guard let request, followUp?.request != request else { return }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, followUpRequest == request,
                    let text = await generateFollowUp(request.prompt), !Task.isCancelled, followUpRequest == request
                else { return }
                followUp = ComposerFollowUp(request: request, text: text)
            }
            .onChange(of: followUpSuggestionsEnabled) { _, enabled in
                if !enabled { followUp = nil }
            }
            .onReceive(speechInput.$isRecording.removeDuplicates().dropFirst()) { _ in presentationRevision &+= 1 }
            .onReceive(speechInput.$errorMessage.removeDuplicates().dropFirst()) { _ in presentationRevision &+= 1 }
            .onReceive(botMode.$avatarImages.dropFirst()) { _ in
                if completions.isPresented { presentationRevision &+= 1 }
            }
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
            .onChange(of: model.composerIsEmptyForRecovery) { _, isEmpty in
                if isEmpty { model.restorePendingSendIfPossible(for: model.composerDraftKey) }
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
                isComposerFirstResponder = false
                if let historyMonitor {
                    NSEvent.removeMonitor(historyMonitor)
                    self.historyMonitor = nil
                }
            }
    }

    private var canSuggestFollowUp: Bool {
        followUpSuggestionsEnabled && isComposerFirstResponder && composer.text.isEmpty
            && model.composerIsEmptyForRecovery
            && model.sessionID != nil && model.sessionActionsReady && !model.isRestoringSession
            && model.status == .idle && !model.isSending && model.currentSessionQueuedPrompts.isEmpty
            && !completions.isPresented && !dictation.isRecording && !speechInput.isRecording
    }

    private var followUpRequest: ComposerFollowUp.Request? {
        guard canSuggestFollowUp, let prompt = ComposerFollowUp.prompt(in: model.messages) else { return nil }
        return .init(owner: model.composerDraftKey, prompt: prompt)
    }

    private func composerContent(suggestion: ComposerFollowUp?) -> some View {
        // Evaluate submission capabilities based on draft text, images, and steering state
        let draftIsEmpty = composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasComposerContent =
            !draftIsEmpty || !model.pendingImages.isEmpty || !model.pendingPDFURLs.isEmpty
            || !model.attachedContexts.isEmpty
        let isStopping = model.interruptState == .requesting
        let isResponding = model.status == .working || model.isSending || isStopping
        // Mid-turn input redirects the turn, or queues when it can't (attachments, approvals).
        let isSteeringTurn = model.isSending && model.sessionID != nil
        let queuedPrompts = model.currentSessionQueuedPrompts
        let queuesAttachments =
            isSteeringTurn
            && (!model.pendingImages.isEmpty || !model.pendingPDFURLs.isEmpty
                || !model.attachedContexts.isEmpty || model.replyQuote != nil)
        let submitLabel =
            hasComposerContent && model.status != .needsClarification
                && (model.hasQueuedOrRedirectingPrompt || queuesAttachments)
            ? "Queue message"
            : (isSteeringTurn ? DockSkinPresentation.current.steerLabel : DockSkinPresentation.current.submitLabel)
        // An idle composer with a queue left by a stopped turn sends the next one.
        let canSubmit = hasComposerContent || (!model.isSending && !queuedPrompts.isEmpty)
        let showStop = isResponding && !hasComposerContent && !speechInput.isRecording
        let stopLabel = isStopping ? "Stopping Herm response…" : "Stop Herm response"
        let submitDisabled =
            isStopping || model.isRestoringSession || !model.sessionActionsReady || model.isUpdatingSessionModel
            || (!speechInput.isRecording
                && (!canSubmit || model.isUpdatingSessionFast || (!isSteeringTurn && model.isSending)))
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
            Group {
                if let trigger = completions.trigger, completions.isPresented {
                    ComposerCompletionPopover(
                        trigger: trigger,
                        items: completions.result.items,
                        selectedIndex: completions.index,
                        isLoading: completions.isLoading,
                        avatarImages: botMode.avatarImages,
                        notice: mentionRelayNotice(trigger),
                        onSelect: { completions.accept($0) }
                    )
                    .transition(DockMotion.reveal(from: .bottom, reduceMotion: reduceMotion))
                }
            }
            .animation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.16), value: completions.isPresented)

            // One tray joins the plan, queue and folder bar to the input. With
            // none of them showing, the input covers it completely.
            VStack(spacing: 0) {
                if let projectPicker { projectPicker }
                ComposerSessionControlView(model: model)
                PinnedWorkStrip(model: model)
                if let controlCenter {
                    RunningProcessesStrip(control: controlCenter, model: model, isTurnActive: isResponding)
                }

                if !queuedPrompts.isEmpty {
                    QueuedPromptList(model: model, prompts: queuedPrompts)
                        .dockPadding(.horizontal, 12)
                        .dockPadding(.vertical, 8)
                        .transition(DockMotion.composerTray(reduceMotion: reduceMotion))
                }

                if let quote = model.replyQuote {
                    ReplyQuoteChip(quote: quote, showsAuthor: false) { model.replyQuote = nil }
                        .dockPadding(.horizontal, 12)
                        .dockPadding(.vertical, 6)
                        .transition(DockMotion.composerTray(reduceMotion: reduceMotion))
                }

                VStack(spacing: 6) {

                    if dictation.isRecording {
                        ComposerDictationRecordingBar(
                            reading: dictation.reading,
                            canSend: canSubmit && !model.isRestoringSession && model.sessionActionsReady
                                && !model.isUpdatingSessionModel && !model.isUpdatingSessionFast
                                && (isSteeringTurn || !model.isSending),
                            cancel: cancelDictation,
                            stop: stopDictation,
                            send: {
                                updateDictation()
                                submitComposerInput()
                            }
                        )
                    } else {
                        // Main multi-line text input area at top of card container.
                        ZStack(alignment: .topLeading) {
                            ComposerInputEditor(
                                text: $composer.text,
                                isFocused: isComposerFocused,
                                onSubmit: submitComposerInput,
                                onCompletionKey: completions.handleKey,
                                onEmptyReturn: {
                                    guard requiredContext == nil, let returnApprovalID else { return false }
                                    return model.allowOnceFromEmptyComposer(requestID: returnApprovalID)
                                },
                                onFollowUpSuggestion: {
                                    guard let suggestion, suggestion.request == followUpRequest else { return nil }
                                    return suggestion.text
                                },
                                onFirstResponderChanged: { isComposerFirstResponder = $0 },
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
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: effectiveComposerHeight)
                            .frame(maxWidth: .infinity)
                            .disabled(model.isRestoringSession)

                            // Placeholder text shares the editor's single visual gutter.
                            if composer.text.isEmpty {
                                composerPlaceholder(suggestion: suggestion?.text)
                                    .dockPadding(.leading, textContentInset)
                                    .allowsHitTesting(false)
                            }
                        }
                        // Move the native editor and the placeholder together; applying
                        // padding to only the placeholder would reintroduce caret drift.
                        .dockPadding(.top, textTopPadding)
                        .frame(maxWidth: .infinity)
                        // Keep native text in its rectangular viewport; the outer card owns the decorative shape.
                        .clipped()
                    }

                    if !model.pendingImages.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(model.pendingImages) { image in
                                    HStack(spacing: 6) {
                                        AttachmentThumbnailView(
                                            url: image.fileURL, maximumPixelSize: 96, contentMode: .fill,
                                            placeholderIcon: .image
                                        )
                                        .frame(width: 32, height: 32)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        .overlay {
                                            if model.extractingImageTextIDs.contains(image.id) {
                                                DockLoadingIndicator().controlSize(.mini).accessibilityLabel(
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
                                    .dockPadding(.horizontal, 6)
                                    .dockPadding(.vertical, 4)
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
                                    .dockPadding(.horizontal, 8)
                                    .dockPadding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                                            .dockSurfaceFill(Color.dockSurface)
                                    )
                                    .help("Inspect context")
                                }
                            }
                        }
                    }
                    if !model.pendingPDFURLs.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(model.pendingPDFURLs, id: \.self) { pdfURL in
                                    HStack(spacing: 7) {
                                        DockIcon(.fileText)
                                            .foregroundStyle(Color.dockAccent)
                                        Text(pdfURL.lastPathComponent)
                                            .dockFont(.metadata, weight: .medium)
                                            .foregroundStyle(Color.dockPrimaryText)
                                            .lineLimit(1).frame(maxWidth: 240, alignment: .leading)
                                        Button {
                                            model.removePendingPDF(pdfURL)
                                        } label: {
                                            DockIcon(.x)
                                                .dockFont(.compactStatus, weight: .bold)
                                                .foregroundStyle(Color.dockSecondaryText)
                                                .frame(width: 22, height: 22)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.dockHover)
                                        .help("Remove PDF")
                                        .accessibilityLabel("Remove PDF: " + pdfURL.lastPathComponent)
                                    }
                                    .dockPadding(.horizontal, 8)
                                    .dockPadding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                                            .dockSurfaceFill(Color.dockSurface)
                                    )
                                }
                            }
                        }
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

                    if !dictation.isRecording {
                        ComposerToolbarLayout {
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

                            HStack(alignment: .center, spacing: 8) {
                                if let controlCenter {
                                    ChatQuotaChip(
                                        control: controlCenter, openQuota: openQuota, selectedProvider: quotaProvider)
                                }
                                if !model.isRestoringSession && model.sessionActionsReady {
                                    SessionContextRing(model: model)
                                }
                            }

                            HStack(alignment: .center, spacing: 8) {
                                if !speechInput.isRecording {
                                    Button {
                                        if dictation.isRecording { dictation.stop() } else { beginDictation() }
                                    } label: {
                                        DockIcon(
                                            dictation.isRecording ? .stop : .microphone, size: 14,
                                            color: dictation.isRecording
                                                ? Color.dockDestructive : Color.dockSecondaryText
                                        )
                                        .frame(width: 28, height: 28)
                                        .background(
                                            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                                                .dockControlFace(
                                                    dictation.isRecording
                                                        ? Color.dockDestructiveFill.opacity(0.14)
                                                        : DockSkinPresentation.current.composerControlFill,
                                                    outlined: !dictation.isRecording)
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
                                        Group {
                                            if isStopping {
                                                DockLoadingIndicator(size: 12)
                                            } else {
                                                DockIcon(.stop, weight: .fill)
                                                    .dockFont(.compactStatus, weight: .bold)
                                                    .foregroundStyle(Color.dockDestructive)
                                            }
                                        }
                                        .frame(width: isFullscreen ? 34 : 28, height: isFullscreen ? 34 : 28)
                                        .background(Circle().fill(Color.dockDestructiveFill.opacity(0.14)))
                                    }
                                    .buttonStyle(.dockHover)
                                    .disabled(!model.canRequestStop)
                                    .help(
                                        !isStopping && model.status == .needsClarification
                                            ? "Dismiss the question and interrupt Hermes"
                                            : stopLabel
                                    )
                                    .accessibilityLabel(
                                        !isStopping && model.status == .needsClarification
                                            ? "Dismiss clarification" : stopLabel)
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
                                        isEnabled: !isStopping && canSubmit && !model.isRestoringSession,
                                        isFullscreen: isFullscreen
                                    ) {
                                        if showStop && isStopping {
                                            DockLoadingIndicator(size: 12)
                                        } else {
                                            ComposerSubmitMark(stop: speechInput.isRecording || showStop ? 1 : 0)
                                                .fill(
                                                    speechInput.isRecording
                                                        ? Color.dockPrimaryText
                                                        : showStop
                                                            ? Color.dockDestructive
                                                            : canSubmit
                                                                ? Color.dockOnAccentText
                                                                : Color.dockSecondaryText.opacity(0.5)
                                                )
                                                .frame(width: 14, height: 14)
                                                .animation(
                                                    DockMotion.animation(reduceMotion: reduceMotion, duration: 0.18),
                                                    value: speechInput.isRecording || showStop)
                                        }
                                    }
                                }
                                .buttonStyle(.dockHover)
                                .frame(width: 32, height: 32)
                                .disabled(showStop ? !model.canRequestStop : submitDisabled)
                                .accessibilityLabel(
                                    speechInput.isRecording
                                        ? "Send voice prompt" : showStop ? stopLabel : submitLabel
                                )
                                .keyboardShortcut(.return, modifiers: [.command])
                                .help(
                                    speechInput.isRecording
                                        ? "Send voice prompt"
                                        : (showStop
                                            ? stopLabel
                                            : "\(submitLabel) (↩; ⇧↩ for newline)")
                                )
                            }
                        }
                    }

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
                        .dockPadding(.top, 2)
                    }
                    if let requestError = model.interruptState.failureMessage ?? model.steeringError {
                        Text(requestError)
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockWarning)
                            .dockPadding(.top, 2)
                    }
                    if let clarificationResponseError = model.clarificationResponseError {
                        Text(clarificationResponseError)
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockWarning)
                            .fixedSize(horizontal: false, vertical: true)
                            .dockPadding(.top, 2)
                    }
                }
                .composerCard(isFocused: isComposerFocused, isRecording: speechInput.isRecording)

                if let worktreeBar { worktreeBar.dockPadding(.vertical, 2) }
            }
            .composerTray()
            if worktreeBar == nil, reservesFolderBar { ComposerFolderBarSlot() }
        }
        .composerColumn(metrics)
    }

    private var composerModelPicker: some View {
        ModelPickerView(
            options: model.runtimeModelOptions,
            selectedID: selectedModelOptionID,
            isRefreshing: model.isLoadingRuntimeModelOptions,
            refreshError: model.runtimeModelOptionsError,
            onRefresh: { model.refreshRuntimeModelOptions(sessionID: model.sessionID, keepingCatalog: true) },
            onSelect: { option in
                model.updateSessionModel(option)
            },
            effortModel: model,
            effortSelection: reasoningVariantSelection
        )
        .disabled(!model.sessionActionsReady)
        .dockFont(.control)
        .foregroundStyle(Color.dockSecondaryText)
        .dockPadding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .dockControlFace(DockSkinPresentation.current.composerControlFill)
        )
        .frame(height: 32)
        .help("Select model")
    }

    private func beginDictation() {
        speechInput.dismissError()
        liveDictation.begin(owner: WorkspaceIdentity.session(model), text: composer.text)
        dictation.startListening()
    }

    private func stopDictation() {
        updateDictation()
        dictation.stop()
    }

    private func cancelDictation() {
        let original = liveDictation.cancel(text: composer.text, owner: WorkspaceIdentity.session(model))
        liveDictation = ComposerDictation()
        dictation.stop()
        if let original { composer.text = original }
        isComposerFocused = true
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
        guard model.interruptState != .requesting else { return }
        liveDictation = ComposerDictation()
        dictation.stop()
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
                || !model.pendingPDFURLs.isEmpty,
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

    private func composerPlaceholder(suggestion: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(suggestion ?? placeholderText)
                .dockFont(.conversation, weight: .regular, design: DockThemeStyle.current.fontDesign)
                .lineLimit(suggestion == nil ? nil : 1)
            if suggestion != nil {
                Text("Tab to insert")
                    .dockFont(.control)
                    .fixedSize()
            }
        }
        .foregroundStyle(Color.dockSecondaryText)
        .dockPadding(.trailing, suggestion == nil ? 0 : 16)
        .accessibilityHidden(suggestion != nil)
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
            ? (model.draftReasoningVariant ?? model.defaultReasoningVariant)
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

    private var quotaProvider: String? {
        guard !model.isRestoringSession, model.sessionActionsReady, !model.isUpdatingSessionModel,
            let id = selectedModelOptionID, let separator = id.firstIndex(of: "|"), separator != id.startIndex
        else { return nil }
        return String(id[..<separator])
    }

    var selectedReasoningVariant: HermesReasoningVariant? {
        model.sessionID == nil
            ? (model.draftReasoningVariant ?? model.defaultReasoningVariant) : model.sessionReasoningVariant
    }

    var reasoningVariantSelection: Binding<HermesReasoningVariant?> {
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
    let model: DockModel
    @State private var presentationRevision = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingDetails = false
    @State private var details: SessionContextSummary?
    @State private var usage: SessionUsageSummary?
    @State private var loadingDetails = false
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        let _ = presentationRevision
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
                        .fixedSize()
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
        .onReceive(
            Publishers.MergeMany(
                DockModel.change(model.$sessionID), DockModel.change(model.$sessionContextUsage),
                DockModel.change(model.$compactingSessionID))
        ) { _ in presentationRevision &+= 1 }
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
        .dockPadding(16)
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
            Text("Session usage").dockFont(.body, weight: .semibold).dockPadding(.bottom, 2)
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
    let model: DockModel
    let prompts: [QueuedPrompt]
    @State private var dropTargetID: UUID?
    @State private var presentationRevision = 0

    var body: some View {
        let _ = presentationRevision
        VStack(alignment: .leading, spacing: 6) {
            Text("Queued (\(prompts.count)) · Sends when Herm finishes")
                .dockFont(.body, weight: .medium)
                .foregroundStyle(Color.dockMetadataText)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(prompts) { prompt in
                        HStack(spacing: 8) {
                            ForEach(prompt.images) { image in
                                AttachmentThumbnailView(url: image.fileURL, maximumPixelSize: 84, contentMode: .fill)
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
                            dropTargetID = nil
                            guard let value = items.first, let id = UUID(uuidString: value),
                                id != prompt.id, prompts.contains(where: { $0.id == id })
                            else { return false }
                            model.reorderQueuedPrompt(id, before: prompt.id)
                            return true
                        } isTargeted: { targeted in
                            if targeted {
                                dropTargetID = prompt.id
                            } else if dropTargetID == prompt.id {
                                dropTargetID = nil
                            }
                        }
                        .contextMenu {
                            Button("Move up") { model.moveQueuedPrompt(prompt.id, offset: -1) }
                            Button("Move down") { model.moveQueuedPrompt(prompt.id, offset: 1) }
                        }
                        .transition(
                            .asymmetric(insertion: .opacity, removal: .move(edge: .top).combined(with: .opacity))
                        )
                        .dockPadding(.leading, prompt.images.isEmpty ? 10 : 5)
                        .dockPadding(.trailing, 4)
                        .dockPadding(.vertical, 5)
                        .background(
                            DockThemeShape(cornerRadius: DockLayout.controlRadius)
                                .fill(Color.dockControlSurface)
                                .overlay {
                                    DockThemeShape(cornerRadius: DockLayout.controlRadius)
                                        .stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline)
                                }
                        )
                        .overlay(alignment: .topLeading) {
                            Capsule()
                                .fill(Color.dockAccent)
                                .frame(height: 2)
                                .scaleEffect(x: dropTargetID == prompt.id ? 1 : 0, y: 1, anchor: .leading)
                                .animation(
                                    DockMotion.animation(reduceMotion: reduceMotion, duration: 0.14),
                                    value: dropTargetID == prompt.id
                                )
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .frame(maxHeight: 144)
            .fixedSize(horizontal: false, vertical: true)
        }
        .animation(DockMotion.disclosure(reduceMotion: reduceMotion), value: prompts.map(\.id))
        .onReceive(
            Publishers.MergeMany(
                DockModel.change(model.$sessionID), DockModel.change(model.$sessionStorageID),
                DockModel.change(model.$sessionTranscriptLoadState), DockModel.change(model.$status),
                DockModel.change(model.$interruptState), DockModel.change(model.$redirectingPrompts))
        ) { _ in presentationRevision &+= 1 }
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
        parts.append(contentsOf: prompt.pdfURLs.map { "[PDF: \($0.lastPathComponent)]" })
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
    let model: DockModel
    @State private var presentationRevision = 0

    var body: some View {
        let _ = presentationRevision
        content.onReceive(
            Publishers.MergeMany(
                DockModel.change(model.$sessionID), DockModel.change(model.$sessionStorageID),
                DockModel.change(model.$status), DockModel.change(model.$todoPlan),
                DockModel.change(model.$backgroundTasks), model.latestPlanPromptChanges)
        ) { _ in presentationRevision &+= 1 }
    }

    @ViewBuilder private var content: some View {
        let plan = model.currentTodoPlan
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
                                    DockActivityIndicator(state: .running)
                                    Text(task.prompt).lineLimit(1).truncationMode(.tail)
                                        .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                                    Text("background").dockFont(.compactStatus, weight: .regular, design: .monospaced)
                                        .foregroundStyle(Color.dockMetadataText)
                                    Spacer(minLength: 0)
                                }
                                .dockPadding(.horizontal, 8)
                                .frame(minHeight: 28)
                            }
                        }
                    }
                    .frame(maxHeight: 96)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .dockPadding(4)
        }
    }
}

struct RunningProcessesPresentation {
    let count: String
    let preview: String?

    init(_ processes: [ProcessSummary]) {
        let running = processes.filter { $0.state == "running" }
        count = running.isEmpty ? "Finished" : "\(running.count) running"
        let output = running.last?.latestOutput
        preview = output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? output : nil
    }
}

/// Hermes background terminal processes for the current session, with a stop button each.
struct RunningProcessesStrip: View {
    @Environment(\.dockHostVisible) private var hostVisible
    let model: DockModel
    @StateObject private var projection: SessionProcessProjection
    var isTurnActive = false
    @State private var isExpanded = false
    @State private var pending: ProcessStopConfirmation?
    @State private var presentationRevision = 0

    init(control: ControlCenterModel, model: DockModel, isTurnActive: Bool) {
        self.model = model
        self.isTurnActive = isTurnActive
        _projection = StateObject(wrappedValue: SessionProcessProjection(control: control, model: model))
    }

    var body: some View {
        let _ = presentationRevision
        content
            .onReceive(
                Publishers.Merge(
                    DockModel.change(model.$sessionID), DockModel.change(model.$isHermesConnected))
            ) { _ in presentationRevision &+= 1 }
            .onAppear { if hostVisible { projection.startObserving() } }
            .onChange(of: hostVisible) { _, visible in
                if visible { projection.startObserving() } else { projection.stopObserving() }
            }
            .onDisappear { projection.stopObserving() }
            // Processes outlive the turn that started them, so poll while a turn runs or any are listed.
            .task(
                id: "\(model.sessionID ?? ""):\(model.isHermesConnected):\(hostVisible):"
                    + "\(isTurnActive || !projection.processes.isEmpty)"
            ) {
                projection.reset(for: model.sessionID)
                guard hostVisible else { return }
                await projection.poll()
                while !Task.isCancelled {
                    guard isTurnActive || !projection.processes.isEmpty else { return }
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    await projection.poll()
                }
            }
    }

    @ViewBuilder private var content: some View {
        if !projection.processes.isEmpty && model.sessionID == projection.sessionID {
            let presentation = RunningProcessesPresentation(projection.processes)
            DisclosureGroup(isExpanded: $isExpanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        processRows
                    }
                }
                .frame(maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    DockIcon(.terminal, size: 14, color: .dockSecondaryText)
                        .frame(width: 14, height: 14).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Background processes").dockFont(.body, weight: .semibold)
                            .foregroundStyle(Color.dockPrimaryText)
                        if !isExpanded, let preview = presentation.preview {
                            Text(preview).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                                .lineLimit(1).truncationMode(.tail).help(preview)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(presentation.count).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                        .fixedSize()
                }
            }
            .disclosureGroupStyle(DockDisclosureGroupStyle(alignment: .top))
            .dockPadding(.horizontal, 12)
            .dockPadding(.vertical, 8)
            .confirmationDialog(
                "Stop Hermes Process?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
            ) {
                if let confirmation = pending {
                    Button("Stop \(confirmation.process.name)", role: .destructive) {
                        Task {
                            _ = await projection.stop(confirmation)
                            pending = nil
                        }
                    }
                }
                Button("Cancel", role: .cancel) { pending = nil }
            }
        }
    }

    @ViewBuilder private var processRows: some View {
        ForEach(projection.processes) { process in
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if process.state == "running" {
                        DockStatusDot(tone: .working, size: 7, pulses: true)
                    } else {
                        DockIcon(
                            process.state == "killed" ? .minusCircle : .checkCircle, size: 14,
                            color: .dockMetadataText)
                    }
                }.frame(width: 14, height: 14).accessibilityHidden(true)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        processText(process).frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                        stopButton(process)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        processText(process)
                        stopButton(process)
                    }
                }
            }
        }
    }

    private func processText(_ process: ProcessSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(process.name).lineLimit(1).truncationMode(.middle)
                .dockFont(.metadata, weight: .regular, design: .monospaced).foregroundStyle(Color.dockPrimaryText)
                .help(process.detail ?? process.name)
            Text(process.state.capitalized).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
            if let latest = process.latestOutput {
                Text(latest).lineLimit(1).truncationMode(.tail)
                    .dockFont(.metadata).foregroundStyle(Color.dockMetadataText).help(latest)
            }
        }
    }

    @ViewBuilder private func stopButton(_ process: ProcessSummary) -> some View {
        if process.state == "running" {
            Button("Stop") { pending = projection.confirmation(for: process) }
                .buttonStyle(.dockCompact).dockFont(.metadata).foregroundStyle(Color.dockWarning)
                .accessibilityLabel("Stop \(process.name)")
        }
    }
}

/// The shoulders of the send arrow fold into the stop square. The button
/// and its hit target remain stationary when the action changes.
private struct ComposerSubmitMark: Shape {
    var stop: CGFloat

    var animatableData: CGFloat {
        get { stop }
        set { stop = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(1, max(0, stop))
        func point(_ x: CGFloat, _ y: CGFloat, _ endX: CGFloat, _ endY: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * (x + (endX - x) * t),
                y: rect.minY + rect.height * (y + (endY - y) * t))
        }
        var path = Path()
        path.move(to: point(0.5, 0.03, 0.5, 0.12))
        path.addLine(to: point(0.96, 0.48, 0.88, 0.12))
        path.addLine(to: point(0.81, 0.63, 0.88, 0.5))
        path.addLine(to: point(0.59, 0.40, 0.88, 0.7))
        path.addLine(to: point(0.59, 0.97, 0.88, 0.88))
        path.addLine(to: point(0.41, 0.97, 0.12, 0.88))
        path.addLine(to: point(0.41, 0.40, 0.12, 0.7))
        path.addLine(to: point(0.19, 0.63, 0.12, 0.5))
        path.addLine(to: point(0.04, 0.48, 0.12, 0.12))
        path.closeSubpath()
        return path
    }
}
