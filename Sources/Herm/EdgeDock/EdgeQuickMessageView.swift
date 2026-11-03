import SwiftUI
import UniformTypeIdentifiers

/// A recoverable quick draft; sending never borrows workspace attachments.
struct EdgeQuickMessageView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var control: ControlCenterModel
    @ObservedObject var state: EdgeNotchState
    var inline = false
    let close: () -> Void
    let openDock: () -> Void
    @State private var focused = false
    @State private var choosingDestination = false
    @State private var composerHeight = ComposerLayout.minHeight
    @State private var confirmingReview = false
    @State private var confirmingDiscard = false
    @StateObject private var chat = EdgeQuickConversationModel()

    private var unavailableReason: String? {
        model.quickMessageUnavailableReason(for: state.quickTarget ?? state.quickCreatedSession)
            ?? (inline ? nil : chat.unavailableReason)
    }
    private var canSend: Bool {
        !state.quickSending && state.quickPreparing == 0 && !state.quickNeedsReview && state.draftStore.error == nil
            && unavailableReason == nil
            && (!state.quickDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !state.quickFiles.isEmpty
                || !state.quickSources.isEmpty)
    }

    var body: some View {
        Group { if inline { inlineBody } else { panelBody } }
            .task(
                id:
                    "\(state.captureRecord().destination.sessionKey)/\(state.quickTranscriptRevision)/\(state.quickSending)"
            ) {
                guard !inline, !state.quickSending else { return }
                await chat.load(state.captureRecord().destination, runtime: model)
            }
            .onDisappear { chat.shutdown() }
            .onAppear { focused = true }
            .onChange(of: state.quickDraft) { _, text in
                if !text.isEmpty { state.quickResult = nil }
            }
            .confirmationDialog("Have you checked the interrupted submission?", isPresented: $confirmingReview) {
                Button("I checked; allow deliberate retry") { state.confirmQuickDraftReview() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Inspect the destination conversation first. If the message arrived, discard this draft. Clear any unconfirmed queued attachments in Hermes before retrying. A new session may be created if its earlier creation was uncertain. Nothing is resent automatically."
                )
            }
            .onDrop(
                of: [UTType.fileURL.identifier, UTType.url.identifier, UTType.text.identifier], isTargeted: nil,
                perform: receiveDrop
            )
            .confirmationDialog("Discard this quick draft?", isPresented: $confirmingDiscard) {
                Button("Discard draft", role: .destructive) { discard() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This removes local text and draft-owned images. It does not cancel work already received by Hermes. Review an interrupted submission in its session first."
                )
            }
    }

    private var inlineBody: some View {
        VStack(alignment: .leading, spacing: DockSpacing.control) {
            messageComposer
            messageFeedback
        }
        .foregroundStyle(Color.dockPrimaryText)
    }

    private var panelBody: some View {
        VStack(alignment: .leading, spacing: DockSpacing.group) {
            HStack(spacing: DockSpacing.control) {
                destinationMenu()
                Spacer(minLength: DockSpacing.control)
                DockIconButton(
                    icon: .x, label: "Close quick message",
                    style: DockThemePalette(theme: DockThemeRuntime.current), action: close)
            }
            Divider().overlay(Color.dockBorderLight)
            Group {
                if let conversation = chat.conversation {
                    EdgeQuickConversationTranscript(
                        model: conversation, control: control,
                        onReply: { quote in
                            guard !state.quickSending, !state.quickNeedsReview else { return }
                            state.quickDraft = quote.composing(state.quickDraft)
                            focused = true
                        },
                        onSessionChanged: { session in
                            guard session.id != state.captureRecord().destination.sessionID else { return }
                            state.selectQuickTarget(session)
                        }
                    )
                    .id(ObjectIdentifier(conversation))
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { if startsNewSession && chat.conversation?.messages.isEmpty != false { emptyState } }
            if chat.loadFailed {
                Button("Reload conversation") {
                    Task { await chat.load(state.captureRecord().destination, runtime: model) }
                }
                .buttonStyle(.dockCompact)
                .disabled(chat.isLoading)
            }
            messageFeedback
            messageComposer.layoutPriority(1)
        }
        .dockPadding(DockSpacing.group)
        .foregroundStyle(Color.dockPrimaryText)
        .accessibilityLabel("Quick message")
    }

    private var messageComposer: some View {
        let hasAttachments = !state.quickFiles.isEmpty || !state.quickSources.isEmpty
        let inputHeight = hasAttachments ? min(composerHeight, 80) : composerHeight
        return VStack(spacing: ComposerLayout.rowSpacing) {
            ZStack(alignment: .topLeading) {
                ComposerInputEditor(
                    text: $state.quickDraft, isFocused: focused, onSubmit: submit,
                    onCompletionKey: { _ in false }, onDropFiles: { state.stageQuickFiles($0) },
                    onPaste: {
                        paste()
                        return true
                    },
                    onFocusChanged: { focused = $0 }, onCaretMoved: { _, _ in },
                    takePendingCaret: { nil }, onTextChanged: { _, _ in },
                    onContentHeightChanged: { composerHeight = ComposerLayout.height(for: $0) }
                )
                .frame(height: inputHeight)
                .disabled(state.quickSending || state.quickNeedsReview)
                .accessibilityLabel(inline ? "Reply" : "Quick message")
                if state.quickDraft.isEmpty {
                    Text(inline ? "Reply…" : "Message \(destinationName)…")
                        .dockFont(.conversation, weight: .regular, design: DockThemeStyle.current.fontDesign)
                        .foregroundStyle(Color.dockSecondaryText)
                        .dockPadding(.leading, 16)
                        .allowsHitTesting(false)
                }
            }
            .dockPadding(.top, 4)
            .clipShape(DockThemeShape(cornerRadius: DockSkinPresentation.current.composerRadius, role: .pane))
            if hasAttachments {
                ScrollView {
                    attachments.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 48)
                .dockPadding(.horizontal, DockSpacing.control)
            }
            captureActions
        }
        .dockPadding(.leading, 6)
        .dockPadding(.trailing, 8)
        .dockPadding(.vertical, 6)
        .modifier(ComposerInputSurface(isFocused: focused))
    }

    private var messageFeedback: some View {
        VStack(alignment: .leading, spacing: DockSpacing.tight) {
            if let status = state.quickPreparing > 0
                ? "Preparing captured files…"
                : state.quickResult ?? state.draftStore.error ?? unavailableReason
            {
                Text(status)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func submit() {
        guard canSend else { return }
        var record = state.captureRecord()
        record.delivery = .submitting
        state.quickSending = true
        state.quickResult = nil
        Task {
            do {
                try state.updateQuickSubmission(record)
                let submitted = try await model.submitQuickDraft(record, progress: state.updateQuickSubmission)
                state.finishQuickSubmission(submitted, failure: nil)
            } catch {
                let failure =
                    error as? QuickSubmissionFailure
                    ?? QuickSubmissionFailure(
                        message: DockModel.safeUserDiagnostic(error.localizedDescription), uncertain: false)
                state.finishQuickSubmission(record, failure: failure)
            }
        }
    }

    private var startsNewSession: Bool { state.quickTarget == nil && state.quickCreatedSession == nil }

    private var destinationBot: BotSummary? {
        let profile = state.captureRecord().destination.profileID
        return state.bots.first { $0.id == profile }
    }
    private var destinationName: String { destinationBot?.name ?? model.agentDisplayName }

    @ViewBuilder private func destinationArt(size: CGFloat) -> some View {
        if let bot = destinationBot {
            BotAvatarView(bot: bot, imageData: state.avatarImages[bot.id], size: size, animated: false)
        } else {
            DockIcon(.chatCenteredText, size: size * 0.6, color: Color.dockSecondaryText).frame(width: size, height: size)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DockSpacing.control) {
            destinationArt(size: 56)
            Text("Message \(destinationName)").dockFont(.body, weight: .semibold)
            Text("Your first message starts a new session.").dockFont(.body).foregroundStyle(Color.dockSecondaryText)
        }
        .allowsHitTesting(false)
    }

    private var destination: some View {
        let record = state.captureRecord()
        let project = record.destination.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        return HStack(spacing: DockSpacing.control) {
            destinationArt(size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(startsNewSession ? destinationName : record.destination.title)
                    .dockFont(.body, weight: .semibold).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(Color.dockPrimaryText)
                Text(([startsNewSession ? "New session" : destinationName] + [project].compactMap { $0 })
                    .joined(separator: " · "))
                    .dockFont(.metadata).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(Color.dockSecondaryText)
            }
        }
    }

    private func destinationMenu() -> some View {
        Button { choosingDestination.toggle() } label: {
            HStack(spacing: DockSpacing.tight) {
                destination
                DockIcon(.caretDown, size: 10, color: Color.dockSecondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .dockPopover(isPresented: $choosingDestination, arrowEdge: .bottom) { destinationPicker }
        .disabled(state.quickSending || state.quickPreparing > 0)
        .help("Choose message destination")
        .accessibilityLabel("Choose message destination")
    }

    private var destinationPicker: some View {
        func pick(_ action: @escaping () -> Void) -> () -> Void {
            { choosingDestination = false; action() }
        }
        return VStack(alignment: .leading, spacing: DockSpacing.control) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 4), count: 4), spacing: 4) {
                ForEach(state.bots) { bot in
                    destinationTile(bot.name, action: pick {
                        state.switchQuickProfile(bot.id)
                        state.composing = true
                    }) { BotAvatarView(bot: bot, imageData: state.avatarImages[bot.id], size: 32, animated: false) }
                }
            }
        }
        .dockPadding(DockSpacing.control)
        .frame(width: 76 * 4 + 12 + DockSpacing.control * 2)
    }

    private func destinationTile<Art: View>(
        _ title: String, action: @escaping () -> Void, @ViewBuilder art: () -> Art
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                art()
                Text(title).dockFont(.metadata).lineLimit(1).truncationMode(.tail)
            }
            .frame(width: 76, height: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
    }

    private var captureActions: some View {
        HStack(spacing: DockSpacing.control) {
            DockMenu {
                Button("Attach files…", icon: .paperclip) {
                    let picker = NSOpenPanel()
                    picker.canChooseDirectories = false
                    picker.allowsMultipleSelection = true
                    if picker.runModal() == .OK { state.stageQuickFiles(picker.urls) }
                }
                .disabled(state.quickNeedsReview)
                Button("Paste", icon: .clipboard, action: paste).disabled(state.quickNeedsReview)
                Divider()
                if !state.recoverableDrafts.isEmpty || !state.savedPrompts.isEmpty {
                    DockMenu("Drafts") {
                        ForEach(state.recoverableDrafts) { record in
                            Button(
                                "\(record.destination.title) · \(record.text.isEmpty ? "Attachments" : String(record.text.prefix(32)))"
                            ) { state.restoreQuickDraft(record) }
                        }
                        if !state.savedPrompts.isEmpty {
                            DockMenu("Saved prompts") {
                                ForEach(state.savedPrompts) { record in
                                    Button(record.savedName ?? "Prompt") { state.restoreQuickDraft(record) }
                                }
                            }
                        }
                    }
                }
                Button("Capture window") { state.captureWindow() }
                if state.quickTarget == nil && state.quickCreatedSession == nil {
                    Button("Choose project…") {
                        let picker = NSOpenPanel()
                        picker.canChooseFiles = false
                        picker.canChooseDirectories = true
                        if picker.runModal() == .OK { state.setQuickProject(picker.url?.path) }
                    }
                    if state.captureRecord().destination.projectPath != nil {
                        Button("Use profile directory") { state.setQuickProject(nil) }
                    }
                }
                if state.quickNeedsReview {
                    Button("Review destination in Herm", action: review)
                    Button("I checked the session; allow retry…") { confirmingReview = true }
                }
                Button("Discard draft…", role: .destructive) { confirmingDiscard = true }
            } label: {
                ComposerControlLabel(icon: .plus)
            }
            .buttonStyle(.dockHover)
            .disabled(state.quickSending || state.quickPreparing > 0)
            .help("Attach or insert content").accessibilityLabel("Message actions")
            Spacer(minLength: 0)
            Button(action: submit) {
                ComposerSubmitLabel(isEnabled: canSend) {
                    if state.quickSending {
                        ProgressView().controlSize(.mini)
                    } else {
                        DockIcon(.arrowUp)
                            .dockFont(.body, weight: .semibold)
                            .foregroundStyle(canSend ? Color.dockOnAccentText : Color.dockSecondaryText.opacity(0.5))
                    }
                }
            }
            .buttonStyle(.dockHover)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend)
            .help("Send message (↩; ⇧↩ for newline)")
            .accessibilityLabel(state.quickSending ? "Sending message" : "Send message")
        }
        .dockFont(.control)
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.quickFiles) { file in
                QuickDraftFileRow(file: file, disabled: state.quickSending || state.quickNeedsReview) {
                    state.removeQuickFile(file)
                }
            }
            ForEach(state.quickSources, id: \.self) { source in
                Text(source).lineLimit(1).truncationMode(.middle).foregroundStyle(Color.dockSecondaryText)
            }
        }.dockFont(.metadata)
    }

    private func review() {
        if let session = state.captureRecord().destination.session { model.resumeSession(session) }
        openDock()
    }

    private func discard() {
        let record = state.captureRecord()
        if record.files.contains(where: \.uploaded), !state.quickNeedsReview {
            state.quickSending = true
            Task {
                do {
                    try await model.cleanupQuickDraftUploads(record)
                    state.quickSending = false
                    state.discardQuickDraft()
                } catch {
                    state.finishQuickSubmission(
                        record,
                        failure: QuickSubmissionFailure(
                            message: DockModel.safeUserDiagnostic(error.localizedDescription), uncertain: true))
                }
            }
        } else {
            state.discardQuickDraft()
        }
    }

    private func paste() {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            state.stageQuickFiles(urls.filter(\.isFileURL))
            for url in urls where !url.isFileURL { state.addQuickSource(url.absoluteString) }
        } else if let png = board.data(forType: NSPasteboard.PasteboardType(UTType.png.identifier)) {
            state.stageQuickImage(png)
        } else if let tiff = board.data(forType: .tiff) {
            let owner = state.captureRecord().id
            state.quickPreparing += 1
            Task {
                defer { state.quickPreparing -= 1 }
                let png = await Task.detached(priority: .userInitiated) {
                    guard tiff.count <= 50 * 1024 * 1024 else { return Data?.none }
                    return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                }.value
                guard state.captureRecord().id == owner else { return }
                if let png {
                    state.stageQuickImage(png)
                } else {
                    state.quickResult = "The pasted image could not be prepared. Choose an image file instead."
                }
            }
        } else if let text = board.string(forType: .string) {
            if let url = URL(string: text), ["http", "https"].contains(url.scheme ?? "") {
                state.addQuickSource(text)
            } else {
                state.quickDraft += (state.quickDraft.isEmpty ? "" : "\n") + text
            }
        }
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !state.quickSending, !state.quickNeedsReview else { return false }
        let owner = state.captureRecord().id
        for provider in providers {
            state.quickPreparing += 1
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                    let url = value as? URL ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    Task { @MainActor in
                        defer { state.quickPreparing -= 1 }
                        guard state.captureRecord().id == owner else { return }
                        if let url { state.stageQuickFiles([url]) }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { value, _ in
                    let url = value as? URL ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    Task { @MainActor in
                        defer { state.quickPreparing -= 1 }
                        guard state.captureRecord().id == owner else { return }
                        if let url { state.addQuickSource(url.absoluteString) }
                    }
                }
            } else {
                provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { value, _ in
                    let text = value as? String ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
                    Task { @MainActor in
                        defer { state.quickPreparing -= 1 }
                        guard state.captureRecord().id == owner else { return }
                        if let text { state.quickDraft += text }
                    }
                }
            }
        }
        return true
    }
}
