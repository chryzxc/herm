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
    @State private var composerHeight = ComposerLayout.minHeight
    @State private var confirmingReview = false
    @State private var confirmingDiscard = false

    private var unavailableReason: String? {
        model.quickMessageUnavailableReason(for: state.quickTarget ?? state.quickCreatedSession)
    }
    private var canSend: Bool {
        !state.quickSending && state.quickPreparing == 0 && !state.quickNeedsReview && state.draftStore.error == nil
            && unavailableReason == nil
            && (!state.quickDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !state.quickFiles.isEmpty
                || !state.quickSources.isEmpty)
    }

    var body: some View {
        Group { if inline { inlineBody } else { panelBody } }
            .task(id: state.captureRecord().destination.sessionKey) {
                let destination = state.captureRecord().destination
                guard let session = destination.session else { return }
                do {
                    let snapshot = try await HermesWorkflowRPC(
                        client: model.controlRPCClient, profileID: destination.profileID
                    ).sessionCapacity(session)
                    guard !Task.isCancelled, state.captureRecord().destination.sessionKey == destination.sessionKey
                    else { return }
                    state.capacitySnapshots[destination.sessionKey] = snapshot
                    if state.capacitySnapshots.count > 8,
                        let oldest = state.capacitySnapshots.min(by: { $0.value.readAt < $1.value.readAt })?.key
                    {
                        state.capacitySnapshots.removeValue(forKey: oldest)
                    }
                } catch {
                    // Submission stays available when session model metadata cannot be read.
                }
            }
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
            ScrollView {
                messageFeedback.frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .defaultScrollAnchor(.bottom)
            messageComposer.layoutPriority(1)
        }
        .padding(DockSpacing.group)
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
                    Text(inline ? "Reply…" : "Message Herm…")
                        .dockFont(.conversation, weight: .regular, design: DockThemeStyle.current.fontDesign)
                        .foregroundStyle(Color.dockSecondaryText)
                        .padding(.leading, 16)
                        .allowsHitTesting(false)
                }
            }
            .padding(.top, 4)
            .clipShape(DockThemeShape(cornerRadius: DockSkinPresentation.current.composerRadius, role: .pane))
            if hasAttachments {
                ScrollView {
                    attachments.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 48)
                .padding(.horizontal, DockSpacing.control)
            }
            captureActions
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .modifier(ComposerInputSurface(isFocused: focused))
    }

    private var messageFeedback: some View {
        VStack(alignment: .leading, spacing: DockSpacing.tight) {
            capacityAdvisory
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

    private var destination: some View {
        let record = state.captureRecord()
        return VStack(alignment: .leading, spacing: 2) {
            let profile = record.destination.profileID ?? "Launch profile"
            Text(
                state.quickTarget == nil
                    ? "New session · \(profile)" : "Replying in \(record.destination.title) · \(profile)"
            )
            .dockFont(.body).lineLimit(1).truncationMode(.middle).foregroundStyle(Color.dockSecondaryText)
            if let path = record.destination.projectPath {
                Text("Project: \(URL(fileURLWithPath: path).lastPathComponent)").dockFont(.metadata).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var capacityAdvisory: some View {
        let destination = state.captureRecord().destination
        let provider = state.capacitySnapshots[destination.sessionKey]?.modelID?.components(separatedBy: "|").first
        if let reading = control.quotaReading(for: provider), reading.remaining <= 20 {
            HStack(alignment: .top, spacing: DockSpacing.tight) {
                DockIcon(.warning, size: 14, color: QuotaWorkspaceView.color(for: reading.window.threshold))
                    .padding(.top, 1)
                Text("\(reading.snapshot.displayName) · \(Int(reading.remaining.rounded()))% allowance left")
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockSecondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .help(
                "Sending is available · Updated \(reading.snapshot.updatedAt.formatted(date: .omitted, time: .shortened))"
            )
            .accessibilityHint(
                "Sending is available. Updated \(reading.snapshot.updatedAt.formatted(date: .omitted, time: .shortened))"
            )
        }
    }

    private func destinationMenu() -> some View {
        DockMenu {
            Button("New session in \(model.agentDisplayName)") {
                state.switchQuickProfile(model.profileScopeID)
                state.composing = true
            }
            ForEach(state.bots) { bot in
                Button("New session · \(bot.name)") {
                    state.switchQuickProfile(bot.id)
                    state.composing = true
                }
            }
            ForEach(model.sessions) { session in
                Button("\(session.profileID ?? model.agentDisplayName) · \(session.displayTitle)") {
                    state.selectQuickTarget(session)
                }
            }
        } label: {
            HStack(spacing: DockSpacing.tight) {
                destination
                DockIcon(.caretDown, size: 10, color: Color.dockSecondaryText)
            }
            .contentShape(Rectangle())
        }
        .disabled(state.quickSending || state.quickPreparing > 0)
        .help("Choose message destination")
        .accessibilityLabel("Choose message destination")
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
                    Menu("Drafts") {
                        ForEach(state.recoverableDrafts) { record in
                            Button(
                                "\(record.destination.title) · \(record.text.isEmpty ? "Attachments" : String(record.text.prefix(32)))"
                            ) { state.restoreQuickDraft(record) }
                        }
                        if !state.savedPrompts.isEmpty {
                            Menu("Saved prompts") {
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
