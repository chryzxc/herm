import AppKit
import KeyboardShortcuts
import SwiftUI
import Foundation
import UniformTypeIdentifiers
struct DockPopover: View {
    @ObservedObject var model: DockModel
    var onWorkspaceWidthChange: (CGFloat) -> CGFloat = { $0 }
    @State private var isConversationAtBottom = true
    @State private var unseenMessageCount = 0
    @State private var isWorkspaceManuallyExpanded = true
    @State private var isNarrowLayout = false
    @State private var isNarrowControlVisible = true
    @State private var isComposerPulsing = false
    @State private var composerHeight: CGFloat = 44
    @State private var pasteMonitor: Any?
    @State private var showingImagePicker = false
    @FocusState private var isComposerFocused: Bool
    @StateObject private var speechInput = SpeechInput()
    @StateObject private var voiceOutput = VoiceOutput()
    @StateObject private var workspaceStore = WorkspaceStore()
    @StateObject private var controlCenter = ControlCenterModel()
    @StateObject private var developerWorkflow = DeveloperWorkflowModel()
    @State private var inputMode: InputMode = .chat
    @State private var suppressNextVoiceResponse = false
    @State private var inspectorScope: InspectorScope = .global

    private enum InputMode {
        case chat, talk
    }

    private enum InspectorScope: String, CaseIterable, Identifiable {
        case global = "Global"
        case session = "Session"

        var id: Self { self }

        var icon: String {
            switch self {
            case .global: "square.grid.2x2"
            case .session: "bubble.left.and.bubble.right"
            }
        }
    }

    private enum QuickPrompt: CaseIterable, Identifiable {
        case reminder, notes, research, summarize, automation, review, email, message, search, kanban

        var id: Self { self }
        var label: String {
            switch self {
            case .reminder: "Reminder"
            case .notes: "Save to Notes"
            case .research: "Research"
            case .summarize: "Summarize work"
            case .automation: "Recurring automation"
            case .review: "Review work"
            case .email: "Email"
            case .message: "Message"
            case .search: "Search sources"
            case .kanban: "Kanban task"
            }
        }
        var prompt: String {
            switch self {
            case .reminder: "Create an Apple Reminder for: "
            case .notes: "Save the following to Apple Notes: "
            case .research: "Start research on: "
            case .summarize: "Summarize my active work and list the next actions."
            case .automation: "Help me create a recurring automation for: "
            case .review: "Review my completed work and identify anything that needs follow-up."
            case .email: "Using the Himalaya skill, help me draft or send this email: "
            case .message: "Using the configured messaging skill, help me draft or send this message: "
            case .search: "Search all connected Hermes sources for: "
            case .kanban: "Create or update a Hermes Kanban task for: "
            }
        }

        var requiredCapability: String? {
            switch self {
            case .reminder: "reminders"
            case .notes: "notes"
            case .automation: "rpc-scheduling"
            case .email: "email"
            case .message: "messaging"
            case .kanban: "kanban.create"
            case .research, .summarize, .review, .search: nil
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if !isNarrowLayout || !isNarrowControlVisible {
                VStack(spacing: 0) {
                    if inputMode == .talk {
                        voiceMode
                    } else {
                        header
                        conversation
                        Divider().overlay(Color.scifiBorderLight)
                        composer
                    }
                }
                .frame(width: showsDesktopContextPanel ? 480 : 500, height: 720)
            }

            if isWorkspaceVisibleForLayout {
                Rectangle().fill(Color.scifiBorderLight).frame(width: 0.5)
                contextPanel
                    .frame(width: isNarrowLayout ? 500 : 480, height: 720)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: popupWidth, height: 720)
        .background {
            ZStack {
                Color(red: 0.055, green: 0.065, blue: 0.115)
                RadialGradient(
                    colors: [Color.scifiAccent.opacity(0.09), .clear],
                    center: UnitPoint(x: 0.15, y: 0),
                    startRadius: 0,
                    endRadius: 360
                )
            }
            .background(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.scifiBorderLight, lineWidth: 0.5)
        }
        .animation(.scifiEase(duration: 0.35), value: isWorkspaceVisibleForLayout)
        .environment(\.colorScheme, .dark)
        .fileImporter(isPresented: $showingImagePicker, allowedContentTypes: [.png, .jpeg, .image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                urls.forEach { model.stageImageFile(at: $0) }
            }
        }
        .task {
            model.restoreLatestSessionIfNeeded()
            model.refreshRuntimeConfiguration()
            model.refreshRuntimeModelOptions()
            model.refreshDefaultReasoningVariant()
        }
        .onAppear {
            synchronizePanelLayout()
            synchronizeWorkspace()
            controlCenter.bind(to: model)
            controlCenter.refresh()
        }
        .onChange(of: isWorkspaceVisible) { _, visible in
            if isNarrowLayout { isNarrowControlVisible = visible }
            synchronizePanelLayout()
        }
        .onChange(of: model.composerFocusRequest) { _, _ in
            isComposerFocused = true
        }
        .onChange(of: speechInput.completedTranscript) { _, transcript in
            guard let transcript, !transcript.isEmpty, !model.isSending else { return }
            guard !voiceOutput.isSpeaking else {
                speechInput.consumeCompletedTranscript()
                return
            }
            model.draft = transcript
            speechInput.consumeCompletedTranscript()
            model.send()
        }
        .onChange(of: speechInput.isRecording) { _, isRecording in
            if !isRecording, speechInput.errorMessage != nil {
                inputMode = .chat
            }
        }
        .onChange(of: model.status) { _, status in
            synchronizeWorkspace(status: status)
            guard inputMode == .talk, status == .idle, !model.voiceState.isNativeConversationActive else { return }
            if suppressNextVoiceResponse {
                suppressNextVoiceResponse = false
                resumeVoiceConversationIfReady()
                return
            }
            if let response = model.messages.last(where: { $0.role == .hermes }),
               !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                speechInput.stopForAssistantSpeech()
                voiceOutput.speak(messageID: response.id, text: response.text)
            } else {
                resumeVoiceConversationIfReady()
            }
        }
        .onChange(of: voiceOutput.isSpeaking) { _, isSpeaking in
            if !isSpeaking, !model.voiceState.isNativeConversationActive {
                resumeVoiceConversationIfReady()
            }
        }
        .onChange(of: model.voiceState) { _, state in
            if state == .interrupted {
                // The native gateway has accepted a spoken interruption. Stop
                // any fallback playback immediately before it resumes capture.
                voiceOutput.stop()
            }
            if case .localFallback = state {
                resumeVoiceConversationIfReady()
            }
        }
        .onChange(of: model.sessionID) { _, _ in
            synchronizeWorkspace()
            controlCenter.focus(sessionID: model.sessionID)
            synchronizePanelLayout()
        }
        .onChange(of: model.sessionID) { _, _ in model.refreshSessionModelOptions() }
        .onChange(of: model.currentSessionTitle) { _, _ in synchronizeWorkspace() }
        .onChange(of: model.messages.count) { oldCount, newCount in
            if newCount > oldCount { synchronizeWorkspace() }
        }
    }

    private var isWorkspaceVisible: Bool {
        isWorkspaceManuallyExpanded || !model.activeSubagents.isEmpty
    }

    private var isWorkspaceVisibleForLayout: Bool {
        isNarrowLayout ? isNarrowControlVisible : isWorkspaceVisible
    }

    private var popupWidth: CGFloat {
        guard showsDesktopContextPanel else { return 500 }
        return 480 + 0.5 + 480
    }

    private var showsDesktopContextPanel: Bool {
        !isNarrowLayout && isWorkspaceVisibleForLayout
    }

    /// The status-bar item can live on a different display from `NSScreen.main`.
    /// Ask the native panel for the width it can actually occupy before choosing
    /// the desktop layout, then render only a layout that fits that screen.
    private func synchronizePanelLayout() {
        let fittedDesktopWidth = onWorkspaceWidthChange(desktopRequiredWidth)
        let shouldUseNarrowLayout = fittedDesktopWidth < desktopRequiredWidth
        if isNarrowLayout != shouldUseNarrowLayout {
            isNarrowLayout = shouldUseNarrowLayout
            if shouldUseNarrowLayout { isNarrowControlVisible = false }
        }
        _ = onWorkspaceWidthChange(popupWidth)
    }

    private var desktopRequiredWidth: CGFloat { 960.5 }

    private var contextPanel: some View {
        VStack(spacing: 0) {
            contextPanelHeader

            Group {
                switch inspectorScope {
                case .global:
                    WorkspaceActivitySidebar(
                        model: model,
                        store: workspaceStore,
                        control: controlCenter,
                        workflow: developerWorkflow,
                        onClose: closeContextPanel,
                        showsHeader: false
                    )
                case .session:
                    SessionInspector(model: model, control: controlCenter, workflow: developerWorkflow, showsHeader: false)
                }
            }
            .transition(.opacity)
            .animation(.scifiEase(duration: 0.2), value: inspectorScope)
        }
        .background(Color.scifiCanvas)
    }

    private var contextPanelHeader: some View {
        HStack(spacing: 12) {
            if inspectorScope == .session {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.currentSessionTitle ?? "Untitled session")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.scifiFg)
                        .lineLimit(1)
                    if let contextProjectName {
                        HStack(spacing: 6) {
                            Label(contextProjectName, systemImage: "folder")
                                .lineLimit(1)
                                .layoutPriority(1)

                            Button(action: newChatForContextProject) {
                                Label("NEW SESSION", systemImage: "plus.bubble")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .tracking(0.35)
                                    .padding(.horizontal, 7)
                                    .frame(height: 22)
                                    .background(Color.scifiAccent.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.scifiPress)
                            .foregroundStyle(Color.scifiAccent)
                            .disabled(model.isRestoringSession)
                            .help("Start a new chat in \(contextProjectName)")
                            .accessibilityLabel("Start a new chat in \(contextProjectName)")
                        }
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.scifiTertiary)
                    }
                }
            }

            Spacer(minLength: 8)

            scopePicker
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(Color.scifiSurface2)
        .overlay(alignment: .bottom) { Color.scifiBorderLight.frame(height: 0.5) }
    }

    private var contextProjectPath: String? {
        guard let sessionID = model.sessionID,
              let project = controlCenter.project(forSessionID: sessionID),
              project.name != "__no_project__",
              !project.name.isEmpty else { return nil }
        return project.name
    }

    private var contextProjectName: String? {
        let path = contextProjectPath
        guard let path, !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private func newChatForContextProject() {
        model.newChat()
        model.requestComposerFocus()
    }

    private var scopePicker: some View {
        HStack(spacing: 2) {
            ForEach(InspectorScope.allCases) { scope in
                Button {
                    withAnimation(.scifiEase(duration: 0.18)) {
                        inspectorScope = scope
                    }
                } label: {
                    Text(scope.rawValue.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(inspectorScope == scope ? Color.scifiFg : Color.scifiTertiary)
                        .frame(width: 70, height: 28)
                        .background(inspectorScope == scope ? Color.scifiAccent.opacity(0.16) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.scifiPress)
                .accessibilityLabel("Show \(scope.rawValue) inspector")
            }
        }
        .padding(3)
        .background(Color.scifiSurface4)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector scope")
    }

    private func closeContextPanel() {
        if isNarrowLayout {
            isNarrowControlVisible = false
        } else {
            isWorkspaceManuallyExpanded = false
        }
    }

    private func synchronizeWorkspace(status: HermesStatus? = nil) {
        guard let sessionID = model.sessionID else { return }
        let title = model.currentSessionTitle
            ?? model.messages.first(where: { $0.role == .user })?.text
            ?? "Current Hermes task"
        let task = workspaceStore.ensureTask(title: title, sessionID: sessionID)

        switch status ?? model.status {
        case .working:
            workspaceStore.updateStatus(.inProgress, for: task.id)
        case .needsApproval:
            workspaceStore.updateStatus(.awaitingApproval, for: task.id)
        case .idle where task.status == .inProgress || task.status == .awaitingApproval:
            workspaceStore.updateStatus(.readyForReview, for: task.id)
        case .idle, .offline:
            break
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Session title button with status indicator dot
                Button(action: { model.toggleSessions() }) {
                    HStack(spacing: 8) {
                        // Compact status dot — smaller than before
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                            .shadow(color: statusColor.opacity(0.7), radius: 3)
                        Text(model.currentSessionTitle ?? "Untitled chat")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.scifiFg)
                            .lineLimit(1)
                        Image(systemName: model.isShowingSessions ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.scifiMuted)
                    }
                }
                .buttonStyle(.scifiPress)
                .help("Session status: \(model.status.title)")
                .accessibilityLabel("\(model.currentSessionTitle ?? "Untitled chat"), \(model.status.title)")
                .popover(isPresented: $model.isShowingSessions, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                    sessionPicker
                        .frame(width: 390, height: 310)
                        .padding(.vertical, 4)
                        .background(Color.scifiCanvas)
                        .environment(\.colorScheme, .dark)
                }

                Spacer(minLength: 8)

                // Header action buttons — compact 28pt circles with 6pt gap matching voice component toolbar
                HStack(spacing: 6) {
                    Button(action: {
                        inputMode = .talk
                        beginVoiceConversation()
                    }) {
                        Image(systemName: "waveform")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.scifiMuted)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.scifiSurface4))
                    }
                    .buttonStyle(.scifiPress)
                    .help("Talk mode")

                    Button(action: {
                        if isNarrowLayout {
                            isNarrowControlVisible.toggle()
                        } else {
                            isWorkspaceManuallyExpanded.toggle()
                        }
                    }) {
                        Image(systemName: isWorkspaceVisibleForLayout ? "rectangle.compress.vertical" : "rectangle.split.2x1")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isWorkspaceVisibleForLayout ? Color.scifiAccent : Color.scifiMuted)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(isWorkspaceVisibleForLayout ? Color.scifiAccent.opacity(0.1) : Color.scifiSurface4))
                    }
                    .buttonStyle(.scifiPress)
                    .help(isWorkspaceVisibleForLayout ? "Hide Control" : "Show Control")

                    if model.status == .working || model.isSending {
                        Button(action: stopCurrentRequest) {
                            Image(systemName: "square.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.scifiMuted)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color.scifiSurface4))
                        }
                        .buttonStyle(.scifiPress)
                        .help("Stop")
                    }

                    Button(action: { model.newChat() }) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.scifiMuted)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.scifiSurface4))
                    }
                    .buttonStyle(.scifiPress)
                    .disabled(model.isRestoringSession)
                    .help("New chat")
                }
            }
            // Reduced vertical padding for a more compact header bar
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .background(Color.scifiSurface2)
        .overlay(alignment: .bottom) {
            Color.scifiBorderLight.frame(height: 0.5)
        }
        .animation(.scifiEase(duration: 0.2), value: model.status)
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: .scifiSuccess
        case .working: .scifiAccent
        case .needsApproval: .scifiWarning
        case .offline: .scifiDestructive
        }
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

    private var configurationScopeLabel: String {
        model.sessionID == nil ? "new chats" : "this session"
    }

    /// A single, divider-led rail keeps the two session settings scannable as
    /// one piece of context instead of presenting competing controls.
    @ViewBuilder
    private var sessionConfigurationRow: some View {
        HStack(spacing: 0) {
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
                sessionConfigurationLabel(
                    icon: "cpu",
                    title: "MODEL",
                    value: sessionModelDisplayName,
                    truncatesValue: true
                )
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.scifiPress)
            .disabled(model.sessionID == nil ? model.isLoadingRuntimeConfiguration : model.isUpdatingSessionModel)
            .help("Change the model for \(configurationScopeLabel)")
            .accessibilityLabel("Model for \(configurationScopeLabel): \(sessionModelDisplayName)")

            Color.scifiBorderLight
                .frame(width: 0.5, height: 24)

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
                sessionConfigurationLabel(
                    icon: "brain",
                    title: "THINKING",
                    value: sessionReasoningDisplayName
                )
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.scifiPress)
            .disabled(model.sessionID == nil ? model.isUpdatingDefaultReasoning : model.isUpdatingSessionReasoning)
            .help("Change thinking depth for \(configurationScopeLabel)")
            .accessibilityLabel("Thinking depth for \(configurationScopeLabel): \(sessionReasoningDisplayName)")
        }
        .foregroundStyle(Color.scifiFg)
        .background(Color.scifiSurface4)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.scifiBorder, lineWidth: 0.5)
        }
    }

    private func sessionConfigurationLabel(
        icon: String,
        title: String,
        value: String,
        truncatesValue: Bool = false
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.scifiAccent)

            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Color.scifiMuted)

            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(truncatesValue ? .middle : .tail)
                .layoutPriority(1)

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.scifiMuted)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var sessionPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CONVERSATIONS")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(Color.scifiAccent.opacity(0.8))
                Spacer()
                if model.isLoadingSessions {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Button(action: { model.loadSessions() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.scifiMuted)
                    }
                    .buttonStyle(.scifiPress)
                    .help("Refresh")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.scifiSurface2)

            if model.sessions.isEmpty && !model.isLoadingSessions {
                Text("No saved conversations")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scifiMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                List {
                    ForEach(model.sessions) { session in
                        Button(action: { model.resumeSession(session) }) {
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(session.displayTitle)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .foregroundStyle(Color.scifiFg)
                                    if let preview = session.displayPreview {
                                        Text(preview)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(Color.scifiMuted)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if let date = session.startedAt {
                                    Text(date, style: .relative)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Color.scifiTertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.scifiPress)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 250)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.scifiCanvas)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var conversation: some View {
        if speechInput.isRecording {
            voiceMode
        } else {
            chatScroll
        }
    }

    private var voiceMode: some View {
        VStack(spacing: 0) {
            VoiceModeToolbar(
                onReturnToChat: exitVoiceMode,
                onToggleWorkspace: {
                    if isNarrowLayout {
                        isNarrowControlVisible.toggle()
                    } else {
                        isWorkspaceManuallyExpanded.toggle()
                    }
                },
                isWorkspaceVisible: isWorkspaceVisibleForLayout,
                canStopRequest: model.status == .working || model.isSending,
                onStopRequest: stopCurrentRequest
            )
            .padding(14)
            Spacer()
            Button {
                if model.voiceState.isNativeConversationActive || speechInput.isRecording {
                    exitVoiceMode()
                } else if !model.isSending && !voiceOutput.isSpeaking {
                    voiceOutput.stop()
                    beginVoiceConversation()
                }
            } label: {
                VoiceOrbView(
                    isListening: model.voiceState == .listening || speechInput.isRecording,
                    isResponding: model.voiceState == .preparing || model.voiceState == .interrupted || model.voiceState == .thinking || model.voiceState == .speaking || (model.status == .working && !speechInput.isRecording) || voiceOutput.isSpeaking,
                    audioLevel: speechInput.audioLevel
                )
                    .frame(width: 320, height: 320)
            }
            .buttonStyle(.scifiPress)
            .help(model.voiceState.isNativeConversationActive || speechInput.isRecording ? "End voice conversation" : "Resume listening")
            .overlay(alignment: .bottom) {
                if let detail = model.voiceState.fallbackDetail {
                    Text("LOCAL FALLBACK · \(detail)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .tracking(0.35)
                        .foregroundStyle(Color.scifiWarning)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 270)
                        .offset(y: 42)
                } else if model.voiceState.isNativeConversationActive {
                    VStack(spacing: 5) {
                        Text(model.voiceState.label)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .tracking(0.75)
                            .foregroundStyle(model.voiceState == .listening ? Color.scifiSuccess : Color.scifiAccent)
                        if let timing = model.voiceTelemetry.summary {
                            Text(timing)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .tracking(0.45)
                                .foregroundStyle(Color.scifiTertiary)
                        }
                    }
                    .offset(y: 42)
                } else if model.status == .working && !speechInput.isRecording {
                    voiceActivityIndicator
                        .offset(y: 34)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .animation(.scifiEase(duration: 0.25), value: model.status)
        .onAppear { beginVoiceConversation() }
    }

    private func beginVoiceConversation() {
        if case .localFallback = model.voiceState {
            resumeVoiceConversationIfReady()
        } else {
            model.startVoiceConversation()
        }
    }

    private func resumeVoiceConversationIfReady() {
        guard inputMode == .talk,
              !model.voiceState.isNativeConversationActive,
              model.status == .idle,
              !model.isSending,
              !speechInput.isRecording,
              !speechInput.isStarting,
              !speechInput.isUnavailable,
              speechInput.errorMessage == nil,
              !voiceOutput.isSpeaking else { return }
        speechInput.startListening()
    }

    private func exitVoiceMode() {
        speechInput.stop()
        voiceOutput.stop()
        model.stopVoiceConversation()
        inputMode = .chat
    }

    private func stopCurrentRequest() {
        if inputMode == .talk {
            suppressNextVoiceResponse = true
            voiceOutput.stop()
        }
        model.stop()
    }

    private var voiceActivityIndicator: some View {
        HStack(spacing: 8) {
            ThinkingDots()
            Text(voiceActivityText)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .lineLimit(1)
        }
        .foregroundStyle(Color.scifiAccent)
        .padding(.horizontal, 13)
        .frame(height: 32)
        .background(Capsule().fill(Color.scifiSurface6).stroke(Color.scifiAccent.opacity(0.25), lineWidth: 0.5))
        .shadow(color: Color.scifiAccent.opacity(0.12), radius: 10)
    }

    private var voiceActivityText: String {
        if let reasoning = model.reasoningState, !reasoning.text.isEmpty {
            return "HERMES IS REASONING"
        }
        if let tool = model.activeToolCalls.first(where: { !$0.isComplete }) {
            return "RUNNING \(tool.name.uppercased())"
        }
        return "HERMES IS THINKING"
    }

    private var chatScroll: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if model.messages.isEmpty && model.status != .working {
                                StartupAssistantView()
                                    .frame(maxWidth: .infinity)
                                    .frame(minHeight: max(300, viewport.size.height - 16))
                            }
                            let msgList = model.messages
                            ForEach(msgList) { message in
                                messageRow(message)
                                    .id(message.id)
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.97)),
                                        removal: .opacity
                                    ))
                            }
                            if let approval = model.approvalText {
                                approvalRow(title: model.approvalTitle ?? "Review requested action", detail: approval)
                            }
                            if isConversationActivityVisible {
                                activityView
                                    .id("activity")
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("conversationBottom")
                                .background(
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: ConversationBottomPreferenceKey.self,
                                            value: geometry.frame(in: .named("conversationScroll")).maxY
                                        )
                                    }
                                )
                        }
                        .padding(.vertical, 8)
                    }
                    .coordinateSpace(name: "conversationScroll")
                    .onPreferenceChange(ConversationBottomPreferenceKey.self) { bottomY in
                        let isAtBottom = bottomY <= viewport.size.height + 32
                        isConversationAtBottom = isAtBottom
                        if isAtBottom { unseenMessageCount = 0 }
                    }
                    .animation(Animation.scifiEase(duration: 0.4), value: model.messages.count)
                    .onChange(of: model.scrollToLatestMessageRequest) { _, _ in
                        unseenMessageCount = 0
                        isConversationAtBottom = true
                        scrollConversationToBottom(proxy, animated: false)
                    }
                    .onChange(of: model.messages.count) { oldCount, newCount in
                        guard newCount > oldCount else {
                            if newCount < oldCount { unseenMessageCount = 0 }
                            return
                        }
                        if isConversationAtBottom {
                            scrollConversationToBottom(proxy)
                        } else {
                            unseenMessageCount += newCount - oldCount
                        }
                    }
                    .onChange(of: model.activeToolCalls) { _, _ in
                        if isConversationActivityVisible && isConversationAtBottom {
                            scrollConversationToBottom(proxy)
                        }
                    }
                    .onChange(of: model.reasoningState) { _, _ in
                        if isConversationActivityVisible && isConversationAtBottom {
                            scrollConversationToBottom(proxy)
                        }
                    }
                    .onChange(of: model.recentEvents.last) { _, _ in
                        if isConversationActivityVisible,
                           let event = model.recentEvents.last,
                           isAutoScrollEvent(event.type),
                           isConversationAtBottom {
                            scrollConversationToBottom(proxy)
                        }
                    }

                    if unseenMessageCount > 0 {
                        Button {
                            unseenMessageCount = 0
                            isConversationAtBottom = true
                            scrollConversationToBottom(proxy, duration: 0.25)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 11, weight: .bold))
                                Text("\(unseenMessageCount) new \(unseenMessageCount == 1 ? "message" : "messages")")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            }
                            .foregroundStyle(Color.scifiBg)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Capsule().fill(Color.scifiAccent))
                            .shadow(color: Color.scifiAccent.opacity(0.3), radius: 10, y: 3)
                        }
                        .buttonStyle(.scifiPress)
                        .padding(.bottom, 12)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            }
        }
    }

    private var activityView: some View {
        ConversationActivityRow(model: model)
    }

    /// The activity row deliberately represents one current state. Showing a
    /// history of streaming events here pushes the conversation out of view.
    private var conversationPipelineActivities: [AgentActivityPresentation.PipelineActivity] {
        model.agentPresentationSnapshot.pipeline
    }

    private var isConversationActivityVisible: Bool {
        model.status == .working || AgentActivityPresentation.hasActiveWork(
            toolCalls: model.activeToolCalls,
            subagents: model.activeSubagents
        )
    }

    private func activityLabel(for rawValue: String) -> String {
        let normalized = rawValue
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.capitalized }
            .joined(separator: " ")
        return normalized.isEmpty ? "Task" : normalized
    }

    private func isAutoScrollEvent(_ type: String) -> Bool {
        let type = type.lowercased()
        return type.contains("tool") ||
            type.contains("reason") ||
            type.contains("think") ||
            type == "message.start"
    }

    private func scrollConversationToBottom(
        _ proxy: ScrollViewProxy,
        animated: Bool = true,
        duration: TimeInterval = 0.2
    ) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.scifiEase(duration: duration)) {
                    proxy.scrollTo("conversationBottom", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("conversationBottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        if message.role == .hermes && message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.images.isEmpty {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 0) {
                if message.role == .user {
                    Spacer(minLength: 40)
                    VStack(alignment: .trailing, spacing: 4) {
                        VStack(alignment: .trailing, spacing: 6) {
                            if message.isSteering {
                                Text("STEERING · \(message.steeringStatus ?? "QUEUED")")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.scifiAccent)
                            }
                            ForEach(Array(message.images.enumerated()), id: \.offset) { _, image in
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 220, maxHeight: 220)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            if !message.text.isEmpty {
                                Text(message.text)
                                    .font(.system(size: 14))
                                    .textSelection(.enabled)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(Color.scifiFg)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        // Use opaque slate-navy user message bubble background to eliminate eye strain
                        .background(Color.scifiUserMessageBubble)
                        .clipShape(MessageBubbleShape(isUser: true))
                        .overlay(
                            MessageBubbleShape(isUser: true)
                                .stroke(Color.scifiBorderStrong, lineWidth: 0.5)
                        )
                        .shadow(color: Color.black.opacity(0.12), radius: 4)

                        Text(HumanDateFormatting.timeOnly(message.timestamp))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.scifiTertiary)
                            .padding(.horizontal, 4)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        if !message.text.isEmpty {
                            Group {
                                if message.id == model.streamingMessageIDForPresentation {
                                    Text(message.text)
                                        .font(.system(size: 14))
                                        .lineSpacing(3)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    MarkdownMessageView(markdown: message.text)
                                }
                            }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .foregroundStyle(Color.scifiFg)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // Use opaque charcoal-indigo AI message bubble (DESIGN.md) to eliminate high-contrast glare
                                .background(Color.scifiMessageBubble)
                                .clipShape(MessageBubbleShape(isUser: false))
                                .overlay(
                                    MessageBubbleShape(isUser: false)
                                        .stroke(Color.scifiBorder, lineWidth: 0.5)
                                )
                        }

                        HStack(spacing: 6) {
                            Text(HumanDateFormatting.timeOnly(message.timestamp))
                            if let modelName = message.modelName {
                                Text("· \(modelName)")
                            }
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.scifiTertiary)
                        .padding(.horizontal, 4)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func reasoningBlock(_ reasoning: ReasoningState) -> some View {
        DisclosureGroup(isExpanded: $model.isShowingReasoning) {
            Text(reasoning.text.isEmpty ? "…" : reasoning.text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(Color.scifiMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 12))
                Text("Reasoning")
                    .font(.system(size: 12, weight: .medium))
                if !reasoning.isComplete {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                }
            }
            .foregroundStyle(Color.scifiMuted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.scifiSurface)
                .stroke(Color.scifiBorderLight, lineWidth: 0.5)
        )
    }

    private func approvalRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.scifiWarning)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Approval required")
                        .font(.system(size: 14, weight: .semibold))
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.scifiWarning)
                        .lineLimit(2)
                }
                .foregroundStyle(Color.scifiFg)
                Spacer()
                Text("ACTION NEEDED")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Color.scifiWarning)
            }

            ScrollView(.vertical) {
                Text(detail)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(Color.scifiFg)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
                .frame(maxHeight: 160)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.16))
                        .stroke(Color.scifiBorderLight, lineWidth: 0.5)
                )

            HStack(spacing: 6) {
                Button { model.respondToApproval("deny") } label: {
                    ScifiActionLabel(
                        title: "Deny",
                        pendingTitle: "Working…",
                        isPending: model.isRespondingToApproval,
                        tint: Color.scifiWarning
                    )
                }
                .buttonStyle(.scifiPress)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.scifiWarning)
                .frame(minWidth: 88, minHeight: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.scifiWarning.opacity(0.08))
                        .stroke(Color.scifiWarning.opacity(0.34), lineWidth: 0.5)
                )
                .disabled(model.isRespondingToApproval)
                Button { model.respondToApproval("once") } label: {
                    ScifiActionLabel(
                        title: "Allow once",
                        pendingTitle: "Allowing…",
                        isPending: model.isRespondingToApproval,
                        tint: Color.scifiBg
                    )
                }
                .buttonStyle(.scifiPress)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.scifiBg)
                .frame(minWidth: 112, minHeight: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.scifiAccent)
                )
                .disabled(model.isRespondingToApproval)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.scifiSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.scifiWarning.opacity(0.035))
                }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.scifiWarning.opacity(0.22), lineWidth: 0.6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Modern unified chat composer matching reference screenshot design.
    private var composer: some View {
        // Evaluate submission capabilities based on draft text, images, and steering state
        let draftIsEmpty = model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isSteeringTurn = model.status == .working && model.isSending && model.sessionID != nil
        let canSubmit = isSteeringTurn ? !draftIsEmpty : (!draftIsEmpty || !model.pendingImages.isEmpty)

        return VStack(spacing: 8) {
            // Main multi-line text input area at top of card container.
            // TextEditor on macOS has a built-in ~5px leading inset; we apply a
            // negative horizontal padding of -5 so the cursor lands exactly where
            // the placeholder text starts, then re-apply an equal positive padding
            // on the surrounding ZStack to restore the visual offset.
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.draft)
                    .font(.system(size: 14))
                    .focused($isComposerFocused)
                    .onKeyPress(phases: .down) { press in
                        guard press.key == .return,
                              !press.modifiers.contains(.shift) else {
                            return .ignored
                        }
                        // Submit on Return without Shift
                        model.submitComposerInput()
                        return .handled
                    }
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.automatic)
                    // Negate the TextEditor's internal 5pt inset so text starts
                    // at the same x position as the placeholder overlay.
                    .padding(.horizontal, -5)
                    .padding(.vertical, 0)
                    .foregroundStyle(Color.scifiFg)
                    .environment(\.colorScheme, .dark)
                    .disabled(model.isRestoringSession)

                // Placeholder text displayed when input draft is empty.
                // Padding must match the TextEditor's effective content origin.
                if model.draft.isEmpty {
                    Text(model.isRestoringSession ? "Restoring conversation…" : "Do anything")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.scifiMuted.opacity(0.6))
                        .padding(.horizontal, 0)
                        .padding(.vertical, 7)
                        .allowsHitTesting(false)
                }

                // Invisible measurement overlay — same font/padding as real text —
                // so the ZStack grows to the correct height for dynamic sizing.
                Text(model.draft.isEmpty ? " " : model.draft)
                    .font(.system(size: 14))
                    .padding(.horizontal, 0)
                    .padding(.vertical, 7)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(0)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: ComposerContentHeightKey.self, value: proxy.size.height)
                        }
                    }
            }
            // Add back the horizontal inset we removed from TextEditor so the
            // whole block still respects the composer's visual gutter.
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, minHeight: composerHeight, maxHeight: composerHeight)
            .onPreferenceChange(ComposerContentHeightKey.self) { contentHeight in
                // Cap composer height between 40px and 140px
                composerHeight = min(max(contentHeight, 40), 140)
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
                                    .frame(width: 32, height: 32)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                Text(image.fileName)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.scifiFg)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Button(action: { model.removePendingImage(image) }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color.scifiMuted)
                                }
                                .buttonStyle(.scifiPress)
                                .help("Remove image")
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.scifiSurface))
                        }
                    }
                }
            }

            // Integrated Bottom Toolbar Row
            HStack(alignment: .center, spacing: 8) {
                // Left Toolbar Group: Paperclip attachment button & Model selector dropdown menu
                HStack(spacing: 6) {
                    // Attachment Paperclip Button
                    Button(action: { showingImagePicker = true }) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.scifiMuted)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.scifiPress)
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
                                .foregroundStyle(Color.scifiMuted)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.scifiPress)
                    .disabled(model.sessionID == nil ? model.isLoadingRuntimeConfiguration : model.isUpdatingSessionModel)
                    .help("Select model")
                }

                Spacer(minLength: 4)

                // Right Toolbar Group: Thinking depth selector menu & circular submit button
                HStack(spacing: 8) {
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
                        .foregroundStyle(Color.scifiMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.scifiPress)
                    .disabled(model.sessionID == nil ? model.isUpdatingDefaultReasoning : model.isUpdatingSessionReasoning)
                    .help("Select thinking depth")

                    // Circular Submit / Action Button with Upward Arrow
                    Button(action: {
                        if speechInput.isRecording {
                            speechInput.stop()
                            model.send()
                        } else {
                            model.submitComposerInput()
                        }
                    }) {
                        ZStack {
                            Circle()
                                // Soft translucent fill for submit circle
                                .fill(canSubmit && !model.isSteering && !model.isRestoringSession ? Color.scifiFg.opacity(0.20) : Color.scifiSurface6)
                                .frame(width: 28, height: 28)

                            if speechInput.isRecording {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.scifiFg)
                            } else if model.isSending && !isSteeringTurn {
                                ProgressView().controlSize(.small).tint(Color.scifiFg)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 12, weight: .semibold))
                                    // Use soft scifiFg instead of stark white to prevent eye strain
                                    .foregroundStyle(canSubmit && !model.isSteering ? Color.scifiFg : Color.scifiMuted.opacity(0.5))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isRestoringSession || (!speechInput.isRecording && (!canSubmit || (isSteeringTurn ? model.isSteering : model.isSending))))
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help(speechInput.isRecording ? "Send voice prompt" : (isSteeringTurn ? "Steer active turn (↩; ⇧↩ for newline)" : "Send message (↩; ⇧↩ for newline)"))
                }
            }
            .padding(.top, 4)

            // Voice Recording & Steering Status Messages
            if let error = speechInput.errorMessage {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.scifiWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            if let steeringError = model.steeringError {
                Text(steeringError)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.scifiWarning)
                    .padding(.top, 2)
            } else if let steeringNotice = model.steeringNotice {
                Text(steeringNotice)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.scifiSuccess)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Outer composer background styled with square rectangular edges
        .background(
            Rectangle()
                .fill(speechInput.isRecording ? Color.scifiDestructive.opacity(isComposerPulsing ? 0.12 : 0.05) : Color(nsColor: NSColor(red: 0.09, green: 0.10, blue: 0.14, alpha: 1.0)))
        )
        // Outer composer border styled with square rectangular stroke
        .overlay(
            Rectangle()
                .stroke(
                    speechInput.isRecording
                    ? Color.scifiDestructive.opacity(isComposerPulsing ? 0.65 : 0.28)
                    : Color.scifiBorderLight.opacity(0.3),
                    lineWidth: 0.8
                )
        )
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isComposerPulsing)
        .onChange(of: speechInput.isRecording) { _, isRecording in
            isComposerPulsing = isRecording
        }
        .onAppear {
            DebugLog.write("composer: appeared")
            if pasteMonitor == nil {
                let dockModel = model
                pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.modifierFlags.contains(.command),
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

    private func quickPromptChip(_ quickPrompt: QuickPrompt) -> some View {
        let requiredCapability = quickPrompt.requiredCapability
        let isAvailable = requiredCapability.map(controlCenter.capabilityAvailable) ?? true
        return Button(quickPrompt.label) {
            selectQuickPrompt(quickPrompt)
        }
        .buttonStyle(.scifiPress)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isAvailable ? Color.scifiMuted : Color.scifiTertiary)
        .padding(.horizontal, 9)
        .frame(minHeight: 26)
        .fixedSize(horizontal: true, vertical: false)
        .background(Capsule().fill(Color.scifiSurface4).stroke(Color.scifiBorderLight, lineWidth: 0.5))
        .disabled(!isAvailable)
        .help(isAvailable ? quickPrompt.label : unavailableCapabilityDetail(requiredCapability))
    }

    private var quickPromptOverflowMenu: some View {
        Menu {
            ForEach(QuickPrompt.allCases.dropFirst(2)) { quickPrompt in
                Button(quickPrompt.label) {
                    selectQuickPrompt(quickPrompt)
                }
                .disabled(quickPrompt.requiredCapability.map(controlCenter.capabilityAvailable) == false)
            }
        } label: {
            Label("More", systemImage: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.scifiMuted)
                .padding(.horizontal, 9)
                .frame(minHeight: 26)
                .background(Capsule().fill(Color.scifiSurface4).stroke(Color.scifiBorderLight, lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func selectQuickPrompt(_ quickPrompt: QuickPrompt) {
        model.draft = quickPrompt.prompt
        model.requestComposerFocus()
    }

    private func unavailableCapabilityDetail(_ id: String?) -> String {
        guard let id, let capability = controlCenter.capabilities.first(where: { $0.id == id }) else {
            return "This Hermes capability is unavailable. Open Core and refresh capabilities."
        }
        return capability.recovery ?? capability.detail
    }
}

private struct ComposerContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 44

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
