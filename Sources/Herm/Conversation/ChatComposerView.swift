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
    @State private var pasteMonitor: Any?
    @State private var showingAttachmentPopover = false
    @State private var showingFilePicker = false
    @State private var showingImagePicker = false
    @State private var completionTrigger: ComposerCompletionTrigger?
    @State private var completion = ComposerCompletion.Result()
    @State private var completionIndex = 0
    /// UTF-16 caret the active trigger was detected at.
    @State private var completionCaret = 0
    @State private var completionTask: Task<Void, Never>?
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
            .onAppear {
                DebugLog.write("composer: appeared")
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
                if text.isEmpty { closeCompletions() }
            }
            .onDisappear {
                completionTask?.cancel()
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
            if let completionTrigger, !completion.items.isEmpty {
                ComposerCompletionPopover(
                    trigger: completionTrigger,
                    items: completion.items,
                    selectedIndex: completionIndex,
                    avatarImages: botMode.avatarImages,
                    onSelect: { acceptCompletion($0) }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if !queuedPrompts.isEmpty {
                QueuedPromptList(model: model, prompts: queuedPrompts)
            }

            VStack(spacing: 6) {

            // Main multi-line text input area at top of card container.
            ZStack(alignment: .topLeading) {
                ComposerInputEditor(
                    text: $composer.text,
                    isFocused: isComposerFocused,
                    onSubmit: submitComposerInput,
                    onCompletionKey: handleCompletionKey,
                    onFocusChanged: { focused in
                        isComposerFocused = focused
                        model.isComposerEditing = focused
                    },
                    onCaretMoved: { text, caret in
                        // Moving the caret retargets or closes an open popover; only typing opens one.
                        guard completionTrigger != nil else { return }
                        updateCompletions(for: text, caret: caret)
                    },
                    takePendingCaret: {
                        defer { composer.pendingCaret = nil }
                        return composer.pendingCaret
                    },
                    onTextChanged: { text, caret in
                        updateCompletions(for: text, caret: caret)
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
                                }
                                .buttonStyle(.borderless)
                                .help("Remove image")
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).fill(Color.dockSurface))
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
                                }
                                .buttonStyle(.borderless)
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
                    }
                    .buttonStyle(.borderless)
                    .help("Remove PDF")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).fill(Color.dockSurface))
            }
            if let pdfError = model.pendingPDFError {
                Text(pdfError)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let attachmentError = model.pendingAttachmentError {
                Text(attachmentError)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                            .frame(width: 44, height: 44)
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

                    if showsInterruptControl {
                        Button(action: { onStop() }) {
                            DockIcon(.stop, weight: .fill)
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

                            if speechInput.isRecording {
                                DockIcon(.stop, weight: .fill)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.dockPrimaryText)
                            } else if showStop {
                                DockIcon(.stop, weight: .fill)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.dockDestructive)
                            } else {
                                DockIcon(.arrowUp)
                                    .font(.system(size: 12, weight: .semibold))
                                    // Use soft dockPrimaryText instead of stark white to prevent eye strain
                                    .foregroundStyle(canSubmit ? Color.dockOnAccentText : Color.dockSecondaryText.opacity(0.5))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                    .disabled(
                        model.isRestoringSession ||
                        model.isUpdatingSessionModel ||
                        (!speechInput.isRecording && !showStop && (!canSubmit || (!isSteeringTurn && model.isSending)))
                    )
                    .accessibilityLabel(speechInput.isRecording ? "Send voice prompt" : showStop ? "Stop Hermes response" : isSteeringTurn ? DockSkinPresentation.current.steerLabel : DockSkinPresentation.current.submitLabel)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help(
                        speechInput.isRecording
                            ? "Send voice prompt"
                            : (showStop
                                ? "Stop Hermes response"
                                : (isSteeringTurn ? "\(DockSkinPresentation.current.steerLabel) (↩; ⇧↩ for newline)" : "\(DockSkinPresentation.current.submitLabel) (↩; ⇧↩ for newline)"))
                    )
                }
            }
            .padding(.top, 0)

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
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.top, 6)
            .padding(.bottom, 0)
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
                    shape
                        .fill(DockThemeStyle.current.material == .glass ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.dockSurface2))
                        .overlay {
                            shape.stroke(
                                speechInput.isRecording
                                    ? Color.dockDestructive.opacity(isComposerPulsing ? 0.65 : 0.28)
                                    : (isComposerFocused ? Color.dockAccent.opacity(0.42) : Color.dockBorder),
                                lineWidth: DockLayout.hairline
                            )
                        }
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
        .frame(minHeight: 44, alignment: .center)
        .disabled(model.isUpdatingSessionModel)
        .help("Select model")
    }

    private var composerReasoningPicker: some View {
        // Thinking depth variant selector menu
        Menu {
            Picker("", selection: reasoningVariantSelection) {
                ForEach(HermesReasoningVariant.allCases) { variant in
                    Text(variant.displayName).tag(Optional(variant))
                }
            }
            .pickerStyle(.inline)
        } label: {
            // A plain button-style menu renders this SwiftUI
            // label as drawn; a borderless menu keeps only native
            // text and images and drops custom icon views.
            HStack(spacing: 6) {
                DockIcon(.brain, size: 13, color: Color.dockSecondaryText)
                if ComposerToolbarPresentation.showsReasoningLabel(for: metrics) {
                    Text(sessionReasoningDisplayName)
                        .font(DockTypography.control)
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                }
                DockIcon(.caretDown, size: 10, color: Color.dockMetadataText)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .fill(DockSkinPresentation.current.composerControlFill)
            )
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Thinking depth, currently \(sessionReasoningDisplayName)")
        .disabled(model.sessionID != nil && model.isUpdatingSessionReasoning)
        .help("Select thinking depth")
    }

    /// Roster Bots offered ahead of Hermes' `@` rows (desktop's Bot Mode
    /// `composer.atCompletions` contribution). Typed refs like `@file:` skip them.
    private func botCompletionItems(for trigger: ComposerCompletionTrigger) -> [ComposerCompletionItem] {
        guard case .mention(let token) = trigger else { return [] }
        let query = token.dropFirst().lowercased()
        guard !query.contains(":"), !query.contains("/") else { return [] }
        return botMode.visibleBots
            .filter { bot in
                query.isEmpty
                    || bot.id.localizedCaseInsensitiveContains(query)
                    || bot.name.localizedCaseInsensitiveContains(query)
                    || (bot.title?.localizedCaseInsensitiveContains(query) == true)
            }
            .map { ComposerCompletionItem(text: "@\($0.id)", display: "@\($0.id)", meta: $0.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", group: "", bot: $0) }
    }

    private func updateCompletions(for text: String, caret: Int) {
        let wasMention: Bool = { if case .mention = completionTrigger { return true }; return false }()
        let caret = min(caret, (text as NSString).length)
        let trigger = ComposerCompletionTrigger.detect(in: (text as NSString).substring(to: caret))
        if trigger != nil, trigger == completionTrigger, caret == completionCaret { return }
        completionCaret = caret
        completionTask?.cancel()
        completionTrigger = trigger
        guard let trigger else {
            closeCompletions()
            return
        }
        if case .mention = trigger,
           ComposerMentionRefreshPolicy.shouldRefresh(wasPickerVisible: wasMention, isPickerVisible: true) {
            Task { @MainActor in await botMode.refreshNow(force: true) }
        }
        completionTask = Task { @MainActor in
            // Same debounce as desktop's live completion adapter.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            let result = await model.composerCompletions(for: trigger, bots: botCompletionItems(for: trigger))
            guard !Task.isCancelled, completionTrigger == trigger else { return }
            completion = result
            completionIndex = 0
            composer.isCompletionOpen = !result.items.isEmpty
        }
    }

    private func closeCompletions() {
        completionTask?.cancel()
        completionTrigger = nil
        completion = ComposerCompletion.Result()
        completionIndex = 0
        composer.isCompletionOpen = false
    }

    /// The draft split at the trigger's caret; completions rewrite only `before`.
    private var completionSplit: (before: String, after: String) {
        let text = composer.text as NSString
        let caret = min(completionCaret, text.length)
        return (text.substring(to: caret), text.substring(from: caret))
    }

    private func acceptCompletion(_ item: ComposerCompletionItem) {
        guard let trigger = completionTrigger else { return }
        let (before, after) = completionSplit
        let result = ComposerCompletion.accepting(item, trigger: trigger, in: before, replaceFrom: completion.replaceFrom)
        let tail = result.text.hasSuffix(" ") && after.hasPrefix(" ") ? String(after.dropFirst()) : after
        let caret = (result.text as NSString).length
        composer.pendingCaret = caret
        composer.text = result.text + tail
        isComposerFocused = true
        closeCompletions()
        if result.keepOpen { updateCompletions(for: composer.text, caret: caret) }
    }

    private func handleCompletionKey(_ key: ComposerCompletionKey) -> Bool {
        guard completionTrigger != nil, completion.items.indices.contains(completionIndex) else { return false }
        let count = completion.items.count
        switch key {
        case .up, .down:
            completionIndex = (completionIndex + (key == .down ? 1 : -1) + count) % count
        case .escape:
            closeCompletions()
        case .tab, .enter:
            let item = completion.items[completionIndex]
            // Enter on a command that is already fully typed runs it instead of re-inserting it.
            if key == .enter,
               let trigger = completionTrigger,
               case let before = completionSplit.before,
               ComposerCompletion.accepting(item, trigger: trigger, in: before, replaceFrom: completion.replaceFrom)
                .text.trimmingCharacters(in: .whitespaces) == before.trimmingCharacters(in: .whitespaces) {
                closeCompletions()
                return false
            }
            acceptCompletion(item)
        }
        return true
    }

    private func submitComposerInput() {
        // Hermes' composer identifies mentions; the session agent owns delivery
        // through message_agent, including its Bot Chat and permission rules.
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
        case .folder, .url, .promptSnippets:
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
        guard model.sessionID == nil, let provider = model.runtimeConfiguration?.provider,
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
                        TextField("Queued message", text: Binding(
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
                        model.editingQueuedPromptID = isEditing ? nil : prompt.id
                    }
                    rowButton(.x, label: "Remove queued message") {
                        model.removeQueuedPrompt(prompt.id)
                    }
                }
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
    }

    private func rowButton(_ icon: Ph, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DockIcon(icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.dockSecondaryText)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private func label(for prompt: QueuedPrompt) -> String {
        var parts: [String] = []
        if let pdf = prompt.pdfURL { parts.append("[PDF: \(pdf.lastPathComponent)]") }
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

private struct ComposerInputEditor: NSViewRepresentable {
    @Binding var text: String
    let isFocused: Bool
    let onSubmit: () -> Void
    let onCompletionKey: (ComposerCompletionKey) -> Bool
    let onFocusChanged: (Bool) -> Void
    let onCaretMoved: (String, Int) -> Void
    let takePendingCaret: () -> Int?
    let onTextChanged: (String, Int) -> Void
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
        textView.onCompletionKey = onCompletionKey
        textView.string = text.displayBullets
        textView.font = DockSkinPresentation.nativeFont(size: 14)
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
        textView.onCompletionKey = onCompletionKey
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
            reportContentHeight(for: textView)
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
