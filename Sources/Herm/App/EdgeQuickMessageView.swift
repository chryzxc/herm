import SwiftUI
import UniformTypeIdentifiers

/// A recoverable quick draft; sending never borrows workspace attachments.
struct EdgeQuickMessageView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var state: EdgeNotchState
    var inline = false
    let close: () -> Void
    let openDock: () -> Void
    @FocusState private var focused: Bool
    @State private var confirmingReview = false
    @State private var confirmingDiscard = false

    private var unavailableReason: String? {
        model.quickMessageUnavailableReason(for: state.quickTarget ?? state.quickCreatedSession)
    }
    private var canSend: Bool {
        !state.quickSending && state.quickPreparing == 0 && !state.quickNeedsReview && state.draftStore.error == nil && unavailableReason == nil
            && (!state.quickDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !state.quickFiles.isEmpty || !state.quickSources.isEmpty)
    }

    var body: some View {
        Group { if inline { inlineBody } else { panelBody } }
            .task(id: state.captureRecord().destination.sessionKey) {
                let destination = state.captureRecord().destination
                guard let session = destination.session else { return }
                do {
                    let snapshot = try await HermesWorkflowRPC(client: model.controlRPCClient, profileID: destination.profileID).sessionCapacity(session)
                    guard !Task.isCancelled, state.captureRecord().destination.sessionKey == destination.sessionKey else { return }
                    state.capacitySnapshots[destination.sessionKey] = snapshot
                    if state.capacitySnapshots.count > 8, let oldest = state.capacitySnapshots.min(by: { $0.value.readAt < $1.value.readAt })?.key { state.capacitySnapshots.removeValue(forKey: oldest) }
                } catch { /* Submission stays available when quota cannot be read. */ }
            }
            .confirmationDialog("Have you checked the interrupted submission?", isPresented: $confirmingReview) {
                Button("I checked; allow deliberate retry") { state.confirmQuickDraftReview() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Inspect the destination conversation first. If the message arrived, discard this draft. Clear any unconfirmed queued attachments in Hermes before retrying. A new session may be created if its earlier creation was uncertain. Nothing is resent automatically.")
            }
            .onDrop(of: [UTType.fileURL.identifier, UTType.url.identifier, UTType.text.identifier], isTargeted: nil, perform: receiveDrop)
            .confirmationDialog("Discard this quick draft?", isPresented: $confirmingDiscard) {
                Button("Discard draft", role: .destructive) { discard() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes local text and draft-owned images. It does not cancel work already received by Hermes. Review an interrupted submission in its session first.")
            }
    }

    /// Chat-style field that sits inside the task card; the card's reply toggle closes it.
    private var inlineBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            destination
            attachments
            capacityAdvisory
            HStack(alignment: .bottom, spacing: 6) {
                DockTextField("Reply…", text: $state.quickDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(1...4)
                    .focused($focused)
                    .disabled(state.quickSending || state.quickNeedsReview)
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
            captureActions
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
            destination
            captureActions
            DockTextField("Message Hermes…", text: $state.quickDraft, axis: .vertical)
                .textFieldStyle(.dockGlass)
                .font(.system(size: 12))
                .lineLimit(3...4)
                .focused($focused)
                .disabled(state.quickSending || state.quickNeedsReview)
                .accessibilityLabel("Quick message")
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    attachments
                    capacityAdvisory
                    Text(state.quickPreparing > 0 ? "Preparing captured files…" : state.quickResult ?? state.draftStore.error ?? unavailableReason ?? "⌘ Return to send")
                        .font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText).lineLimit(3)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
                let failure = error as? QuickSubmissionFailure ?? QuickSubmissionFailure(message: DockModel.safeUserDiagnostic(error.localizedDescription), uncertain: false)
                state.finishQuickSubmission(record, failure: failure)
            }
        }
    }

    private var destination: some View {
        let record = state.captureRecord()
        return VStack(alignment: .leading, spacing: 2) {
            Text("To: \(record.destination.profileID ?? "Launch profile") · \(record.destination.title)")
                .font(.system(size: 12)).lineLimit(1).foregroundStyle(Color.dockSecondaryText)
            if let path = record.destination.projectPath {
                Text("Project: \(URL(fileURLWithPath: path).lastPathComponent)").font(.system(size: 11)).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var capacityAdvisory: some View {
        let destination = state.captureRecord().destination
        if let snapshot = state.capacitySnapshots[destination.sessionKey], snapshot.low, let remaining = snapshot.allowance {
            Text("\(Int(remaining))% reported allowance remains · read \(snapshot.readAt.formatted(date: .omitted, time: .shortened)). Cached usage; Send remains available.")
                .font(.system(size: 11)).foregroundStyle(Color.dockWarning).accessibilityLabel("Low quota advisory")
        }
    }
    private var captureActions: some View {
        HStack(spacing: 8) {
            Menu("To") {
                ForEach(state.preferences.workingSets) { set in
                    Menu(set.name) {
                        ForEach(Array(set.destinations.enumerated()), id: \.offset) { _, destination in
                            let unavailable = state.destinationUnavailable(destination, sessions: model.sessions, profileID: model.profileScopeID)
                            Button("\(destination.profileID ?? "Launch profile") · \(destination.title)\(unavailable ? " · unavailable" : "")") { state.useSavedDestination(destination) }.disabled(unavailable)
                        }
                    }
                }
                Button("New session in \(model.agentDisplayName)") { state.switchQuickProfile(model.profileScopeID); state.composing = true }
                ForEach(state.bots) { bot in
                    Button("New session · \(bot.name)") { state.switchQuickProfile(bot.id); state.composing = true }
                }
                ForEach(model.sessions) { session in
                    Button("\(session.profileID ?? model.agentDisplayName) · \(session.displayTitle)") { state.selectQuickTarget(session) }
                }
            }
            .disabled(state.quickSending || state.quickPreparing > 0)
            .accessibilityLabel("Choose quick-message destination")
            Button("Add") {
                let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.allowsMultipleSelection = true
                if picker.runModal() == .OK { state.stageQuickFiles(picker.urls) }
            }.disabled(state.quickSending || state.quickNeedsReview)
            Button("Paste", action: paste).disabled(state.quickSending || state.quickNeedsReview)
            Menu("Drafts") {
                ForEach(state.recoverableDrafts) { record in
                    Button("\(record.destination.title) · \(record.text.isEmpty ? "Attachments" : String(record.text.prefix(32)))") { state.restoreQuickDraft(record) }
                }
            }.disabled(state.quickSending || state.quickPreparing > 0 || state.recoverableDrafts.isEmpty)
            Menu("More") {
                if let session = state.captureRecord().destination.session {
                    Button("Capacity & session actions…") { state.capacityTarget = session }
                }
                Button("Saved working sets…") { state.showingWorkingSets = true }
                Button("Search conversations…") { state.recallProfileID = state.quickProfileID; state.showingRecall = true }
                Button("Choose project for new session…") {
                    let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true
                    if picker.runModal() == .OK { state.setQuickProject(picker.url?.path) }
                }.disabled(state.quickTarget != nil || state.quickCreatedSession != nil)
                Button("Use profile directory") { state.setQuickProject(nil) }.disabled(state.quickTarget != nil)
                Button("Review destination in Herm", action: review)
                if state.quickNeedsReview { Button("I checked the session; allow retry…") { confirmingReview = true } }
                Button("Discard draft…", role: .destructive) { confirmingDiscard = true }
            }.disabled(state.quickSending || state.quickPreparing > 0)
        }
        .font(.system(size: 11)).buttonStyle(.dockHover)
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.quickFiles) { file in
                QuickDraftFileRow(file: file, disabled: state.quickSending || state.quickNeedsReview) { state.removeQuickFile(file) }
            }
            ForEach(state.quickSources, id: \.self) { source in
                Text(source).lineLimit(1).truncationMode(.middle).foregroundStyle(Color.dockSecondaryText)
            }
        }.font(.system(size: 11))
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
                do { try await model.cleanupQuickDraftUploads(record); state.quickSending = false; state.discardQuickDraft() }
                catch { state.finishQuickSubmission(record, failure: QuickSubmissionFailure(message: DockModel.safeUserDiagnostic(error.localizedDescription), uncertain: true)) }
            }
        } else { state.discardQuickDraft() }
    }

    private func paste() {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            state.stageQuickFiles(urls.filter(\.isFileURL))
            urls.filter { !$0.isFileURL }.forEach { state.addQuickSource($0.absoluteString) }
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
                if let png { state.stageQuickImage(png) }
                else { state.quickResult = "The pasted image could not be prepared. Choose an image file instead." }
            }
        } else if let text = board.string(forType: .string) {
            if let url = URL(string: text), ["http", "https"].contains(url.scheme ?? "") { state.addQuickSource(text) }
            else { state.quickDraft += (state.quickDraft.isEmpty ? "" : "\n") + text }
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
