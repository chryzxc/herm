import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers
struct DockPopover: View {
    @ObservedObject var model: DockModel
    var onWorkspaceWidthChange: (CGFloat) -> CGFloat = { $0 }
    var onClose: () -> Void = {}
    var onFullscreenToggle: () -> Void = {}
    @State private var isConversationAtBottom = true
    @State private var unseenMessageCount = 0
    @State private var scrollSettleTask: Task<Void, Never>?
    @State private var isWorkspaceManuallyExpanded = true
    @State private var isNarrowLayout = false
    @State private var isNarrowControlVisible = true
    @State private var selectedChatImage: ChatImagePreview?
    @StateObject private var speechInput = SpeechInput()
    @StateObject private var voiceOutput = VoiceOutput()
    @StateObject private var workspaceStore = WorkspaceStore()
    @StateObject private var controlCenter = ControlCenterModel()
    @StateObject private var developerWorkflow = DeveloperWorkflowModel()
    @StateObject private var repositoryPreferences = CommandCenterPreferencesStore()
    @State private var inputMode: InputMode = .chat
    @State private var suppressNextVoiceResponse = false
    @State private var sessionPendingDeletion: HermesSession?
    // A restored/active conversation is the primary workspace at launch, so
    // the right pane should open on its session context rather than Today.
    @State private var inspectorScope: InspectorScope = .session
    /// Cached project/repo folder name for the active session.
    /// Only updated when a non-nil value is resolved — never cleared on transient
    /// refresh-cycle gaps where projectIDBySessionID is momentarily empty.
    @State private var cachedProjectName: String? = nil
    @State private var cachedSessionRepositoryPath: String? = nil
    @State private var lastSessionTitleAtIdentityChange: String?
    @State private var isFullscreen = false
    @State private var isMissionInspectorVisible = true

    private enum FullscreenSurface {
        case conversation
        case global
        case artifacts
    }
    @State private var fullscreenSurface: FullscreenSurface = .conversation
    @State private var fullscreenGlobalTab: ControlTab = .today

    private enum InputMode {
        case chat, talk
    }

    private enum InspectorScope: String, CaseIterable, Identifiable {
        case global = "Global"
        case session = "Session"
        case artifacts = "Artifacts"

        var id: Self { self }

        var icon: String {
            switch self {
            case .global: "square.grid.2x2"
            case .session: "bubble.left.and.bubble.right"
            case .artifacts: "doc.text.magnifyingglass"
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
        layoutContent
        .frame(width: isFullscreen ? nil : popupWidth, height: isFullscreen ? nil : 720)
        .background(Color.dockCanvas)
        .clipShape(RoundedRectangle(cornerRadius: isFullscreen ? 0 : 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isFullscreen ? 0 : 22, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 0.5)
        }
        .animation(.dockEase(duration: 0.35), value: isWorkspaceVisibleForLayout)
        .sheet(item: $selectedChatImage) { preview in
            ChatImagePreviewModal(image: preview.image)
        }
        .task {
            loadInitialModelConfiguration()
        }
        .onAppear {
            configureWorkspaceOnAppear()
        }
        .onChange(of: isWorkspaceVisible) { _, visible in
            if isNarrowLayout { isNarrowControlVisible = visible }
            synchronizePanelLayout()
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
        .onChange(of: inputMode) { _, mode in
            guard mode == .chat else { return }
            // Returning to chat must always release both fallback and native
            // voice capture, including a microphone that is still starting.
            speechInput.stop()
            voiceOutput.stop()
            model.stopVoiceConversation()
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
        .onChange(of: model.sessionID) { oldValue, newValue in
            DebugLog.writeDiagnostic("session.switch old=\(oldValue ?? "nil") new=\(newValue ?? "nil") title=\(model.currentSessionTitle ?? "nil") cachedProject=\(cachedProjectName ?? "nil") cachedRepo=\(cachedSessionRepositoryPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "nil")")
            synchronizeWorkspace()
            controlCenter.focus(sessionID: newValue)
            // Session membership and title projections are loaded separately
            // from the conversation stream. Refresh them whenever identity
            // changes so an already-wired session does not require visiting
            // Projects first to reveal its repository and title.
            controlCenter.refresh()
            synchronizePanelLayout()
            // Only clear the cached project name when the session ID genuinely changes to a different
            // session. DockModel publishes sessionID twice during resume (an optimistic set then a confirmed
            // set), so we must compare old vs new to avoid wiping the cache on same-value re-publications.
            if oldValue != newValue {
                let title = model.currentSessionTitle
                let isLogicalSessionSwitch = lastSessionTitleAtIdentityChange != nil
                    && title != lastSessionTitleAtIdentityChange
                lastSessionTitleAtIdentityChange = title
                if newValue == nil || isLogicalSessionSwitch {
                    cachedProjectName = nil
                    cachedSessionRepositoryPath = nil
                    refreshCachedProjectName()
                    cacheSessionRepositoryPath()
                }
            }
        }
        .onChange(of: model.sessionID) { _, _ in
            model.refreshSessionModelOptions()
            synchronizeSessionMetadataFromControlCenter()
        }
        .onChange(of: model.currentSessionTitle) { _, _ in synchronizeWorkspace() }
        .onChange(of: controlCenter.projectSessions) { _, _ in
            synchronizeSessionMetadataFromControlCenter()
        }
        .onChange(of: controlCenter.activeSessions) { _, _ in
            synchronizeSessionMetadataFromControlCenter()
        }
        // Refresh the cached project name whenever the membership map updates.
        // This fires after the async resolveProjectMembership completes and
        // ensures the label reappears even after a refresh cycle wiped it.
        .onChange(of: controlCenter.projectIDBySessionID) { _, _ in
            DebugLog.writeDiagnostic("session.membership_changed session=\(model.sessionID ?? "nil") project=\(contextProjectName ?? "nil") cachedProject=\(cachedProjectName ?? "nil")")
            refreshCachedProjectName()
            cacheSessionRepositoryPath()
            synchronizeSessionMetadataFromControlCenter()
        }
        .onChange(of: model.messages.count) { oldCount, newCount in
            if newCount > oldCount {
                synchronizeWorkspace()
                // The first user turn can cause Hermes to assign the real
                // session title and project membership asynchronously.
                controlCenter.refresh()
            }
        }
    }

    private var layoutContent: AnyView {
        if isFullscreen && !isNarrowLayout {
            if fullscreenSurface == .global || fullscreenSurface == .artifacts {
                return AnyView(
                    FullscreenPanelSplitView(
                        leading: missionControlQueue,
                        trailing: fullscreenGlobalSurface,
                        leadingFraction: 0.30
                    )
                )
            }
            if isMissionInspectorVisible {
                return AnyView(
                    MissionControlSplitView(
                        queue: missionControlQueue,
                        workspace: conversationColumn,
                        inspector: contextPanel
                    )
                )
            }
            return AnyView(
                FullscreenPanelSplitView(
                    leading: missionControlQueue,
                    trailing: conversationColumn,
                    leadingFraction: 0.30
                )
            )
        }

        return AnyView(compactLayoutContent)
    }

    private var compactLayoutContent: some View {
        if !isNarrowLayout {
            if fullscreenSurface == .global || fullscreenSurface == .artifacts {
                // Global destinations occupy the focused center workspace in
                // the dock exactly as they do in fullscreen. The inspector
                // is intentionally hidden until the user returns to a chat.
                return AnyView(
                    FullscreenPanelSplitView(
                        leading: missionControlQueue,
                        trailing: fullscreenGlobalSurface,
                        leadingFraction: 0.30
                    )
                )
            }
            if isWorkspaceVisibleForLayout {
                // The dock is the compact form of the fullscreen workspace:
                // the same queue → conversation → inspector order, with
                // narrower resizable columns.
                return AnyView(
                    MissionControlSplitView(
                        queue: missionControlQueue,
                        workspace: conversationColumn,
                        inspector: contextPanel
                    )
                )
            }

            // Collapsing the inspector must leave the queue visible, because
            // its top control is also how the inspector is restored.
            return AnyView(
                FullscreenPanelSplitView(
                    leading: missionControlQueue,
                    trailing: conversationColumn,
                    leadingFraction: 0.30
                )
            )
        }

        return AnyView(HStack(spacing: 2) {
            if !isNarrowLayout || !isNarrowControlVisible {
                conversationColumn
                    .frame(
                        width: isFullscreen ? .infinity : (showsDesktopContextPanel ? 480 : 500),
                        height: isFullscreen ? .infinity : 720
                    )
            }

            if isWorkspaceVisibleForLayout {
                Rectangle().fill(Color.dockBorderLight).frame(width: 0.5)
                contextPanel
                    .frame(
                        width: isFullscreen ? .infinity : (isNarrowLayout ? 500 : 480),
                        height: isFullscreen ? .infinity : 720
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        })
    }

    private var isWorkspaceVisible: Bool {
        isWorkspaceManuallyExpanded || !model.activeSubagents.isEmpty
    }

    private var isWorkspaceVisibleForLayout: Bool {
        isNarrowLayout ? isNarrowControlVisible : isWorkspaceVisible
    }

    /// Both fullscreen and the desktop dock use the queue → workspace →
    /// inspector shell. Keep the inspector chrome identical in those two
    /// presentations; only the genuinely narrow two-pane dock needs its own
    /// visible inspector scope picker.
    private var usesMissionControlLayout: Bool {
        isFullscreen || (!isNarrowLayout && isWorkspaceVisibleForLayout)
    }

    private var popupWidth: CGFloat {
        if !isNarrowLayout { return showsDesktopContextPanel ? 1_200 : 720 }
        return 500
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

    private var desktopRequiredWidth: CGFloat { 1_040 }

    private var conversationColumn: some View {
        VStack(spacing: 0) {
            if inputMode == .talk {
                voiceMode
            } else {
                header
                conversation
                Divider().overlay(Color.dockBorderLight)
                ChatComposerView(
                    model: model,
                    composer: model.composer,
                    speechInput: speechInput,
                    onStop: stopCurrentRequest,
                    isFullscreen: isFullscreen
                )
            }
        }
    }

    private func loadInitialModelConfiguration() {
        model.restoreLatestSessionIfNeeded()
        model.refreshRuntimeConfiguration()
        model.refreshRuntimeModelOptions()
        model.refreshDefaultReasoningVariant()
    }

    private func configureWorkspaceOnAppear() {
        synchronizePanelLayout()
        synchronizeWorkspace()
        controlCenter.bind(to: model)
        controlCenter.refresh()
        // Seed the project name cache immediately after bind so the label is
        // visible from the first render if membership data is already loaded.
        refreshCachedProjectName()
    }

    /// Fullscreen has a dedicated navigation rail. Unlike the compact session
    /// picker popover, it keeps the active queue visible while the user works
    /// through a conversation or task.
    private var missionControlQueue: some View {
        MissionControlQueue(
            model: model,
            workspaceStore: workspaceStore,
            controlCenter: controlCenter,
            activeSessionID: model.sessionID,
            activeGlobalTab: fullscreenSurface == .global ? fullscreenGlobalTab : nil,
            isArtifactsActive: fullscreenSurface == .artifacts,
            onNewConversation: {
                fullscreenSurface = .conversation
                inspectorScope = .session
                model.newChat()
                model.requestComposerFocus()
            },
            onSelectSession: { session in
                fullscreenSurface = .conversation
                inspectorScope = .session
                model.resumeSession(session)
            },
            onSelectTask: { task in
                if let sessionID = task.sessionID,
                   let session = model.sessions.first(where: { $0.id == sessionID }) {
                    fullscreenSurface = .conversation
                    inspectorScope = .session
                    model.resumeSession(session)
                } else {
                    // Workspace tasks without a conversation still have a
                    // useful destination: the global Kanban surface.
                    fullscreenGlobalTab = .kanban
                    fullscreenSurface = .global
                }
            },
            onOpenGlobal: { tab in
                fullscreenGlobalTab = tab
                fullscreenSurface = .global
            },
            onOpenArtifacts: {
                fullscreenSurface = .artifacts
            },
            showsFullscreenToggle: true,
            isFullscreen: isFullscreen,
            onFullscreenToggle: toggleFullscreen
        )
    }

    private var fullscreenGlobalControlSurface: some View {
        WorkspaceActivitySidebar(
            model: model,
            store: workspaceStore,
            control: controlCenter,
            workflow: developerWorkflow,
            onClose: onClose,
            onOpenArtifacts: { },
            onSessionOpened: { _ in
                // Global surfaces (such as Projects) own discovery; after a
                // session is chosen, return the user to the shared chat
                // workspace where that session is visible.
                fullscreenSurface = .conversation
                isMissionInspectorVisible = true
            },
            showsHeader: false,
            showsModePicker: false,
            initialMode: fullscreenGlobalTab
        )
        .id("fullscreen-global-\(fullscreenGlobalTab.id)")
    }

    private var fullscreenGlobalSurface: some View {
        Group {
            if fullscreenSurface == .artifacts {
                PlanArtifactsInspectorView(plansRoot: PlanArtifactService.defaultPlansRoot)
                    .id("fullscreen-artifacts")
            } else {
                fullscreenGlobalControlSurface
            }
        }
    }

    private var contextPanel: some View {
        VStack(spacing: 0) {
            if !usesMissionControlLayout {
                contextPanelHeader
            }

            Group {
                switch inspectorScope {
                case .global:
                    WorkspaceActivitySidebar(
                        model: model,
                        store: workspaceStore,
                        control: controlCenter,
                        workflow: developerWorkflow,
                        onClose: onClose,
                        onOpenArtifacts: { inspectorScope = .artifacts },
                        showsHeader: false,
                        initialMode: fullscreenGlobalTab
                    )
                    .id("context-global-\(fullscreenGlobalTab.id)")
                 case .session:
                     SessionInspector(
                         model: model,
                         control: controlCenter,
                         workflow: developerWorkflow,
                         sessionRepositoryPath: activeSessionRepositoryPath,
                         sessionProjectIsBound: activeSessionRepositoryPath != nil,
                         showsHeader: false
                     )
                case .artifacts:
                    PlanArtifactsInspectorView(plansRoot: PlanArtifactService.defaultPlansRoot)
                }
            }
            .transition(.opacity)
            .animation(.dockEase(duration: 0.2), value: inspectorScope)
        }
        .background(Color.clear)
        // This task belongs to the shared context panel, not the Global
        // sidebar. The sidebar is removed in Session scope, but the session
        // inspector still needs the same repository projection loaded.
        .task(id: activeSessionRepositoryIdentity) {
            // Capture the resolved path at the start of the task. Project
            // membership can transiently disappear during a refresh after
            // this task has been scheduled; that must not turn a valid
            // session repository into nil.
            let repositoryPath = liveSessionRepositoryPath ?? cachedSessionRepositoryPath
            guard let repositoryPath else { return }
            if let liveSessionRepositoryPath { cachedSessionRepositoryPath = liveSessionRepositoryPath }
            await developerWorkflow.setActiveRepository(
                path: repositoryPath,
                preferences: repositoryPreferences,
                control: controlCenter
            )
        }
        .onAppear {
            refreshCachedProjectName()
            cacheSessionRepositoryPath()
            synchronizeSessionMetadataFromControlCenter()
        }
    }

    private var contextPanelHeader: some View {
        HStack(spacing: 12) {
            Text("INSPECTOR")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.05)
                .foregroundStyle(Color.dockMetadataText)

            Spacer(minLength: 8)

            scopePicker
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(Color.dockSurface2)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
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

    private var activeSessionRepositoryPath: String? {
        liveSessionRepositoryPath ?? cachedSessionRepositoryPath
    }

    private var liveSessionRepositoryPath: String? {
        workspaceStore.resolvedProjectPath(
            forSessionID: model.sessionID,
            hermesProjectPath: model.sessionID.flatMap { controlCenter.project(forSessionID: $0)?.name }
        )
    }

    private var activeSessionRepositoryIdentity: String? {
        guard let sessionID = model.sessionID,
              let path = activeSessionRepositoryPath else { return nil }
        return "\(sessionID):\(path)"
    }

    /// Updates the cached project name from the live computed value.
    /// Called whenever the session or project membership changes.
    private func refreshCachedProjectName() {
        if let contextProjectName {
            cachedProjectName = contextProjectName
        }
    }

    private func cacheSessionRepositoryPath() {
        if let liveSessionRepositoryPath {
            cachedSessionRepositoryPath = liveSessionRepositoryPath
        }
    }

    private func synchronizeSessionMetadataFromControlCenter() {
        guard let sessionID = model.sessionID,
              let summary = controlCenter.sessionSummary(for: sessionID) else { return }
        model.updateCurrentSessionTitle(summary.title)
    }

    private var scopePicker: some View {
        HStack(spacing: 0) {
            // The fullscreen right region is an inspector for the active
            // center surface, never a competing global workspace.
            let scopes: [InspectorScope] = usesMissionControlLayout
                ? [.session, .artifacts]
                : InspectorScope.allCases
            ForEach(scopes) { scope in
                Button {
                    withAnimation(.dockEase(duration: 0.18)) {
                        inspectorScope = scope
                    }
                } label: {
                    Text(scope.rawValue)
                        .font(.system(size: 13, weight: inspectorScope == scope ? .semibold : .regular))
                        .foregroundStyle(inspectorScope == scope ? Color.dockPrimaryText : Color.dockSecondaryText)
                        .frame(width: 82, height: 34)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(inspectorScope == scope ? Color.dockAccent.opacity(0.10) : Color.clear)
                        }
                        .overlay(alignment: .bottom) {
                            if inspectorScope == scope {
                                Color.dockAccent.frame(height: 2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Show \(scope.rawValue) inspector")
            }
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector scope")
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
        case .needsClarification:
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
                        Text(model.currentSessionTitle ?? "Untitled chat")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.dockPrimaryText)
                            .lineLimit(1)
                        Image(systemName: model.isShowingSessions ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                }
                .buttonStyle(.borderless)
                .help("Session status: \(model.status.title)")
                .accessibilityLabel("\(model.currentSessionTitle ?? "Untitled chat"), \(model.status.title)")
                .popover(isPresented: $model.isShowingSessions, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                    sessionPicker
                        .frame(width: 390, height: 310)
                        .padding(.vertical, 4)
                        .background(Color.dockCanvas)
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
                            .foregroundStyle(Color.dockSecondaryText)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .help("Talk mode")

                    // This control belongs to the active conversation: it
                    // toggles the inspector (the third workspace panel).
                    Button(action: toggleInspectorPanel) {
                        Image(systemName: inspectorPanelIsVisible ? "rectangle.compress.vertical" : "rectangle.split.2x1")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(inspectorPanelIsVisible ? Color.dockAccent : Color.dockSecondaryText)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.dockSurface4))
                    }
                    .buttonStyle(.borderless)
                    .help(inspectorPanelIsVisible ? "Hide inspector" : "Show inspector")
                    .padding(.leading, 6)

                }
            }
            // Reduced vertical padding for a more compact header bar
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .background(Color.dockSurface2)
        .overlay(alignment: .bottom) {
            Color.dockBorderLight.frame(height: 0.5)
        }
        .animation(.dockEase(duration: 0.2), value: model.status)
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: .dockSuccess
        case .working: .dockAccent
        case .needsApproval: .dockWarning
        case .needsClarification: .dockWarning
        case .offline: .dockDestructive
        }
    }

    private var inspectorPanelIsVisible: Bool {
        isFullscreen ? isMissionInspectorVisible : isWorkspaceVisibleForLayout
    }

    private func toggleInspectorPanel() {
        if isFullscreen {
            isMissionInspectorVisible.toggle()
        } else if isNarrowLayout {
            isNarrowControlVisible.toggle()
        } else {
            isWorkspaceManuallyExpanded.toggle()
        }
    }

    private func toggleFullscreen() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isFullscreen.toggle()
            if isFullscreen {
                isNarrowLayout = false
                isMissionInspectorVisible = true
                inspectorScope = .session
                fullscreenSurface = .conversation
            } else {
                synchronizePanelLayout()
            }
        }
        onFullscreenToggle()
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
            .buttonStyle(.borderless)
            .disabled(model.sessionID == nil ? model.isLoadingRuntimeConfiguration : model.isUpdatingSessionModel)
            .help("Change the model for \(configurationScopeLabel)")
            .accessibilityLabel("Model for \(configurationScopeLabel): \(sessionModelDisplayName)")

            Color.dockBorderLight
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
            .buttonStyle(.borderless)
            .disabled(model.sessionID == nil ? model.isUpdatingDefaultReasoning : model.isUpdatingSessionReasoning)
            .help("Change thinking depth for \(configurationScopeLabel)")
            .accessibilityLabel("Thinking depth for \(configurationScopeLabel): \(sessionReasoningDisplayName)")
        }
        .foregroundStyle(Color.dockPrimaryText)
        .background(Color.dockSurface4)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.dockBorder, lineWidth: 0.5)
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
                .foregroundStyle(Color.dockAccent)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.dockSecondaryText)

            Text(value)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(truncatesValue ? .middle : .tail)
                .layoutPriority(1)

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.dockSecondaryText)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var sessionPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CONVERSATIONS")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(Color.dockAccent.opacity(0.8))
                Spacer()
                if model.isLoadingSessions {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Button(action: { model.loadSessions() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.dockSurface2)

            if model.sessions.isEmpty && !model.isLoadingSessions {
                Text("No saved conversations")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                List {
                    ForEach(model.sessions) { session in
                        HStack(spacing: 6) {
                            Button(action: { model.resumeSession(session) }) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(session.displayTitle)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .foregroundStyle(Color.dockPrimaryText)
                                    if let preview = session.displayPreview {
                                        Text(preview)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.dockSecondaryText)
                                            .lineLimit(1)
                                    }
                                    if let projectName = conversationProjectName(for: session) {
                                        Label(projectName, systemImage: "folder")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(Color.dockMetadataText)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    if let date = session.startedAt {
                                        Text(date, style: .relative)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.dockMetadataText)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)

                            Button {
                                sessionPendingDeletion = session
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.dockWarning)
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.borderless)
                            .disabled(session.id == model.sessionID || model.deletingSessionID != nil)
                            .help(session.id == model.sessionID ? "The active session cannot be deleted" : "Delete session")
                            .accessibilityLabel("Delete \(session.displayTitle)")
                        }
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
        .background(Color.dockCanvas)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .confirmationDialog(
            "Delete Session?",
            isPresented: Binding(
                get: { sessionPendingDeletion != nil },
                set: { if !$0 { sessionPendingDeletion = nil } }
            ),
            presenting: sessionPendingDeletion
        ) { session in
            Button("Delete \(session.displayTitle)", role: .destructive) {
                model.deleteSession(session)
                sessionPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                sessionPendingDeletion = nil
            }
        } message: { session in
            Text("This permanently deletes the saved conversation and its transcript.")
        }
        .alert(
            "Could Not Delete Session",
            isPresented: Binding(
                get: { model.sessionDeletionError != nil },
                set: { if !$0 { model.clearSessionDeletionError() } }
            )
        ) {
            Button("OK", role: .cancel) {
                model.clearSessionDeletionError()
            }
        } message: {
            Text(model.sessionDeletionError ?? "The session could not be deleted.")
        }
    }

    private func conversationProjectName(for session: HermesSession) -> String? {
        guard let project = controlCenter.project(forSessionID: session.id),
              !project.name.isEmpty,
              project.name != "__no_project__" else {
            return nil
        }

        let name = URL(fileURLWithPath: project.name).lastPathComponent
        return name.isEmpty ? project.name : name
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
            .buttonStyle(.borderless)
            .help(model.voiceState.isNativeConversationActive || speechInput.isRecording ? "End voice conversation" : "Resume listening")
            .overlay(alignment: .bottom) {
                if let detail = model.voiceState.fallbackDetail {
                    Text("LOCAL FALLBACK · \(detail)")
                        .font(.system(size: 12, weight: .medium))
                        .tracking(0.35)
                        .foregroundStyle(Color.dockWarning)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 270)
                        .offset(y: 42)
                } else if model.voiceState.isNativeConversationActive {
                    VStack(spacing: 5) {
                        Text(model.voiceState.label)
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(0.75)
                            .foregroundStyle(model.voiceState == .listening ? Color.dockSuccess : Color.dockAccent)
                        if let timing = model.voiceTelemetry.summary {
                            Text(timing)
                                .font(.system(size: 12, weight: .medium))
                                .tracking(0.45)
                                .foregroundStyle(Color.dockMetadataText)
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
        .animation(.dockEase(duration: 0.25), value: model.status)
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
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.6)
                .lineLimit(1)
        }
        .foregroundStyle(Color.dockAccent)
        .padding(.horizontal, 13)
        .frame(height: 32)
        .background(Capsule().fill(Color.dockSurface6).stroke(Color.dockAccent.opacity(0.25), lineWidth: 0.5))
        .shadow(color: Color.dockAccent.opacity(0.12), radius: 10)
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
                        // Conversation rows can change height while Hermes is
                        // streaming and while Markdown is being laid out.
                        // A lazy stack may temporarily evict rows at the
                        // viewport boundary, causing the bottom sentinel and
                        // scrollbar range to move when those rows rematerialize.
                        // Keep the conversation's geometry stable instead.
                        VStack(spacing: 0) {
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
                        let isAtBottom = ConversationScrollMetrics.isAtBottom(
                            bottomMaxY: bottomY,
                            viewportHeight: viewport.size.height
                        )
                        isConversationAtBottom = isAtBottom
                        if isAtBottom { unseenMessageCount = 0 }
                    }
                    .animation(Animation.dockEase(duration: 0.4), value: model.messages.count)
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
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(Color.dockOnAccentText)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Capsule().fill(Color.dockAccent))
                            .shadow(color: Color.dockAccent.opacity(0.3), radius: 10, y: 3)
                        }
                        .buttonStyle(.borderless)
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
        scrollSettleTask?.cancel()
        scrollSettleTask = Task { @MainActor in
            // A single scrollTo can race content that was inserted in the same
            // tick (activity row, streaming growth, Markdown layout): it targets
            // the bottom sentinel's pre-growth frame and lands mid-conversation.
            // Re-assert after layout settles; a newer request cancels this one.
            for delayNanos: UInt64 in [0, 80_000_000, 180_000_000] {
                if delayNanos > 0 {
                    try? await Task.sleep(nanoseconds: delayNanos)
                    guard !Task.isCancelled else { return }
                }
                if animated {
                    withAnimation(.dockEase(duration: duration)) {
                        proxy.scrollTo("conversationBottom", anchor: .bottom)
                    }
                } else {
                    proxy.scrollTo("conversationBottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        if message.id == model.streamingMessageIDForPresentation {
            StreamingAssistantMessageRow(
                streaming: model.streamingText,
                timestamp: message.timestamp,
                modelName: message.modelName,
                responseDuration: message.responseDuration
            )
        } else if message.role == .hermes && message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.images.isEmpty {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 0) {
                if message.role == .user {
                    Spacer(minLength: 40)
                    VStack(alignment: .trailing, spacing: 4) {
                        // Attachments sit above the text surface instead of inside
                        // the bubble, keeping media visually distinct from copy.
                        if !message.images.isEmpty {
                            VStack(alignment: .trailing, spacing: 6) {
                                ForEach(Array(message.images.enumerated()), id: \.offset) { _, image in
                                    Button {
                                        selectedChatImage = ChatImagePreview(image: image)
                                    } label: {
                                        Image(nsImage: image)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(maxWidth: 220, maxHeight: 220)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .help("Open image preview")
                                }
                            }
                        }
                        if message.isSteering || !message.text.isEmpty {
                            VStack(alignment: .trailing, spacing: 6) {
                                if message.isSteering {
                                    Text("STEERING · \(message.steeringStatus ?? "QUEUED")")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Color.dockAccent)
                                }
                                if !message.text.isEmpty {
                                    Text(message.text)
                                        .font(.system(size: 14))
                                        .textSelection(.enabled)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(Color.dockPrimaryText)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            // Use opaque slate-navy user message bubble background to eliminate eye strain
                            .background(Color.dockUserMessageBubble)
                            .clipShape(MessageBubbleShape(isUser: true))
                            .overlay(
                                MessageBubbleShape(isUser: true)
                                    .stroke(Color.dockBorderStrong, lineWidth: 0.5)
                            )
                            .shadow(color: Color.black.opacity(0.12), radius: 4)
                        }

                        Text(HumanDateFormatting.timeOnly(message.timestamp))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockMetadataText)
                            .padding(.horizontal, 4)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        if !message.text.isEmpty || message.id == model.streamingMessageIDForPresentation {
                            Group {
                                if message.id == model.streamingMessageIDForPresentation {
                                    StreamingMessageText(streaming: model.streamingText)
                                } else {
                                    MarkdownMessageView(markdown: message.text)
                                }
                            }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .foregroundStyle(Color.dockPrimaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // Use opaque charcoal-indigo AI message bubble (DESIGN.md) to eliminate high-contrast glare
                                .background(Color.dockMessageBubble)
                                .clipShape(MessageBubbleShape(isUser: false))
                                .overlay(
                                    MessageBubbleShape(isUser: false)
                                        .stroke(Color.dockBorder, lineWidth: 0.5)
                                )
                        }

                        HStack(spacing: 6) {
                            Text(HumanDateFormatting.timeOnly(message.timestamp))
                            if let responseDuration = message.responseDuration {
                                ResponseDurationLabel(startedAt: message.timestamp, finishedDuration: responseDuration)
                            }
                            if let modelName = message.modelName {
                                Text("· \(modelName)")
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockMetadataText)
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
                .font(.system(size: 12))
                .textSelection(.enabled)
                .foregroundStyle(Color.dockSecondaryText)
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
            .foregroundStyle(Color.dockSecondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.dockSurface)
                .stroke(Color.dockBorderLight, lineWidth: 0.5)
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
                            .fill(Color.dockWarning)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Approval required")
                        .font(.system(size: 14, weight: .semibold))
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockWarning)
                        .lineLimit(2)
                }
                .foregroundStyle(Color.dockPrimaryText)
                Spacer()
                Text("ACTION NEEDED")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.dockWarning)
            }

            ScrollView(.vertical) {
                Text(detail)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .foregroundStyle(Color.dockPrimaryText)
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
                        .stroke(Color.dockBorderLight, lineWidth: 0.5)
                )

            HStack(spacing: 6) {
                Button { model.respondToApproval("deny") } label: {
                    DockActionLabel(
                        title: "Deny",
                        pendingTitle: "Working…",
                        isPending: model.isRespondingToApproval,
                        tint: Color.dockWarning
                    )
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockWarning)
                .frame(minWidth: 88, minHeight: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.dockWarning.opacity(0.08))
                        .stroke(Color.dockWarning.opacity(0.34), lineWidth: 0.5)
                )
                .disabled(model.isRespondingToApproval)
                Button { model.respondToApproval("once") } label: {
                    DockActionLabel(
                        title: "Allow once",
                        pendingTitle: "Allowing…",
                        isPending: model.isRespondingToApproval,
                        tint: Color.dockOnAccentText
                    )
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockOnAccentText)
                .frame(minWidth: 112, minHeight: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.dockAccent)
                )
                .disabled(model.isRespondingToApproval)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.dockSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.dockWarning.opacity(0.035))
                }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.dockWarning.opacity(0.22), lineWidth: 0.6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func quickPromptChip(_ quickPrompt: QuickPrompt) -> some View {
        let requiredCapability = quickPrompt.requiredCapability
        let isAvailable = requiredCapability.map(controlCenter.capabilityAvailable) ?? true
        return Button(quickPrompt.label) {
            selectQuickPrompt(quickPrompt)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isAvailable ? Color.dockSecondaryText : Color.dockMetadataText)
        .padding(.horizontal, 9)
        .frame(minHeight: 26)
        .fixedSize(horizontal: true, vertical: false)
        .background(Capsule().fill(Color.dockSurface4).stroke(Color.dockBorderLight, lineWidth: 0.5))
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
                .foregroundStyle(Color.dockSecondaryText)
                .padding(.horizontal, 9)
                .frame(minHeight: 26)
                .background(Capsule().fill(Color.dockSurface4).stroke(Color.dockBorderLight, lineWidth: 0.5))
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

private struct ChatImagePreview: Identifiable {
    let id = UUID()
    let image: NSImage
}

private struct ChatImagePreviewModal: View {
    @Environment(\.dismiss) private var dismiss
    let image: NSImage

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.96)

            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 900, maxHeight: 700)
                .padding(28)

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help("Close image preview")
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

/// Fullscreen navigation stays visible as a quiet operational queue. It is
/// intentionally list-led rather than another dashboard: selecting an item
/// always changes the central work surface.
private struct MissionControlQueue: View {
    private struct QueueTaskGroup: Identifiable {
        let key: String
        let task: WorkspaceTask
        let count: Int
        var id: String { key }
    }

    @ObservedObject var model: DockModel
    @ObservedObject var workspaceStore: WorkspaceStore
    @ObservedObject var controlCenter: ControlCenterModel
    let activeSessionID: String?
    let activeGlobalTab: ControlTab?
    let isArtifactsActive: Bool
    let onNewConversation: () -> Void
    let onSelectSession: (HermesSession) -> Void
    let onSelectTask: (WorkspaceTask) -> Void
    let onOpenGlobal: (ControlTab) -> Void
    let onOpenArtifacts: () -> Void
    let showsFullscreenToggle: Bool
    let isFullscreen: Bool
    let onFullscreenToggle: () -> Void
    @State private var showsAllConversations = false
    @State private var selectedTaskID: UUID?
    @State private var selectedSessionID: String?
    @State private var collapsedProjectIDs: Set<String> = []
    @State private var areProjectsExpanded = true
    @State private var areConversationsExpanded = true

    private var readyTasks: [WorkspaceTask] {
        workspaceStore.tasks.filter { $0.status == .readyForReview || $0.status == .todo }
    }

    private var blockedTasks: [WorkspaceTask] {
        workspaceStore.tasks.filter { $0.status == .awaitingApproval }
    }

    private var recentSessions: [HermesSession] {
        model.sessions.sorted { sessionDate($0) > sessionDate($1) }
    }

    private struct ConversationGroup: Identifiable {
        let id: String
        let title: String
        let sessions: [HermesSession]
        let declaredSessionCount: Int
        let projectID: String?
        let isLinked: Bool
    }

    private var conversationGroups: [ConversationGroup] {
        var groups: [ConversationGroup] = []
        var assigned = Set<String>()

        for project in controlCenter.projects where project.name != "__no_project__" {
            var sessionsByID = Dictionary(uniqueKeysWithValues: recentSessions.compactMap { session -> (String, HermesSession)? in
                let isMember = project.sessionIDs.contains(session.id)
                    || controlCenter.projectIDBySessionID[session.id] == project.id
                guard isMember else { return nil }
                assigned.insert(session.id)
                return (session.id, session)
            })
            for summary in controlCenter.projectSessionsByProjectID[project.id] ?? [] {
                let savedSession = sessionsByID[summary.id]
                sessionsByID[summary.id] = HermesSession(
                    id: summary.id,
                    title: summary.title,
                    preview: summary.preview ?? savedSession?.preview ?? "",
                    startedAt: savedSession?.startedAt,
                    messageCount: savedSession?.messageCount ?? 0,
                    source: savedSession?.source ?? "project"
                )
                assigned.insert(summary.id)
            }
            let sessions = sessionsByID.values.sorted { sessionDate($0) > sessionDate($1) }
            groups.append(
                ConversationGroup(
                    id: "project:\(project.id)",
                    title: projectDisplayName(project.name),
                    sessions: sessions,
                    declaredSessionCount: project.sessionCount,
                    projectID: project.id,
                    isLinked: true
                )
            )
        }

        let unlinked = recentSessions.filter { !assigned.contains($0.id) }
        if !unlinked.isEmpty {
            groups.append(
                ConversationGroup(
                    id: "unlinked",
                    title: "Unlinked conversations",
                    sessions: unlinked,
                    declaredSessionCount: unlinked.count,
                    projectID: nil,
                    isLinked: false
                )
            )
        }
        return groups.sorted { lhs, rhs in
            sessionDate(lhs.sessions.first) > sessionDate(rhs.sessions.first)
        }
    }

    private func sessionDate(_ session: HermesSession) -> Date {
        session.startedAt ?? .distantPast
    }

    private func sessionDate(_ session: HermesSession?) -> Date {
        session.map(sessionDate) ?? .distantPast
    }

    private var readyTaskGroups: [QueueTaskGroup] {
        groupedTasks(readyTasks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Spacer(minLength: 0)
                Button(action: onNewConversation) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.dockSurface4))
                }
                .buttonStyle(.borderless)
                .help("New conversation")
                if showsFullscreenToggle {
                    Button(action: onFullscreenToggle) {
                        Image(systemName: isFullscreen
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.dockSecondaryText)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.dockSurface4))
                    }
                    .buttonStyle(.borderless)
                    .help(isFullscreen ? "Exit fullscreen" : "Enter fullscreen")
                    .padding(.leading, 6)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            ScrollView {
                globalRailBar
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
            }
        }
        .background(Color.dockSurface2)
        .task { model.loadSessions() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hermes control queue")
    }

    private func conversationGroup(_ group: ConversationGroup) -> some View {
        let sessionCount = max(group.declaredSessionCount, group.sessions.count)
        let isCollapsed = sessionCount == 0 || collapsedProjectIDs.contains(group.id)

        return VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.dockEase(duration: 0.18)) {
                    if collapsedProjectIDs.contains(group.id) {
                        collapsedProjectIDs.remove(group.id)
                    } else {
                        collapsedProjectIDs.insert(group.id)
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Text(group.title.uppercased())
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .tracking(0.9)
                        .foregroundStyle(Color.dockAccent)
                    Spacer(minLength: 0)
                    Text(compactCount(sessionCount))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.dockMetadataText)
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.dockMetadataText)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.dockAccent.opacity(0.07))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            if !isCollapsed {
                let visibleSessions = showsAllConversations
                    ? group.sessions
                    : Array(group.sessions.prefix(10))
                VStack(alignment: .leading, spacing: 0) {
                    if visibleSessions.isEmpty && sessionCount > 0 {
                        Text("Loading linked sessions…")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dockMetadataText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                    } else {
                        ForEach(visibleSessions) { session in
                            sessionRow(session)
                        }
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Color.dockBorderLight.frame(width: DockLayout.hairline)
                }
            }
        }
        .task(id: "\(group.projectID ?? "unlinked"):\(isCollapsed)") {
            guard !isCollapsed,
                  let projectID = group.projectID,
                  let project = controlCenter.projects.first(where: { $0.id == projectID }) else { return }
            controlCenter.refreshProjectSessions(for: project)
        }
    }

    private func projectDisplayName(_ rawName: String) -> String {
        let name = URL(fileURLWithPath: rawName).lastPathComponent
        return name.isEmpty ? rawName : name
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: .dockSuccess
        case .working: .dockAccent
        case .needsApproval, .needsClarification: .dockWarning
        case .offline: .dockDestructive
        }
    }

    /// A one-line horizontal rail keeps global navigation compact and makes
    /// selection independent from every neighbouring destination.
    private var globalRailBar: some View {
        let unlinked = conversationGroups.first(where: { !$0.isLinked })
        let projects = conversationGroups.filter(\.isLinked)

        return VStack(alignment: .leading, spacing: 2) {
            globalRailDestination(.today)
            globalRailDestination(.inbox)
            globalRailDestination(.kanban)
            globalRailDestination(.quota)
            globalRailDestination(.automations)
            queueRailDestination("Artifacts", icon: "doc.text.magnifyingglass", isSelected: isArtifactsActive) {
                selectedTaskID = nil
                selectedSessionID = nil
                onOpenArtifacts()
            }
            navigationDisclosureRow(
                title: "Conversations",
                icon: "bubble.left.and.bubble.right",
                count: unlinked?.sessions.count ?? 0,
                isExpanded: areConversationsExpanded
            ) {
                withAnimation(.dockEase(duration: 0.18)) { areConversationsExpanded.toggle() }
            }
            if areConversationsExpanded {
                if recentSessions.isEmpty && conversationGroups.isEmpty {
                    queueEmpty("No saved conversations")
                        .padding(.leading, 14)
                } else if let unlinked {
                    let visibleSessions = showsAllConversations
                        ? unlinked.sessions
                        : Array(unlinked.sessions.prefix(10))
                    ForEach(visibleSessions) { session in
                        sessionRow(session)
                            .padding(.leading, 24)
                    }
                }
                if conversationGroups.contains(where: { $0.sessions.count > 10 }) {
                    conversationExpansionButton
                        .padding(.leading, 24)
                }
            }

            if !projects.isEmpty {
                navigationDisclosureRow(
                    title: "Projects",
                    icon: "folder",
                    count: projects.count,
                    isExpanded: areProjectsExpanded
                ) {
                    withAnimation(.dockEase(duration: 0.18)) { areProjectsExpanded.toggle() }
                }
                if areProjectsExpanded {
                    ForEach(projects) { group in
                        conversationGroup(group)
                            .padding(.leading, 14)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func globalRailDestination(_ tab: ControlTab) -> some View {
        queueRailDestination(tab.globalRailLabel, icon: tab.icon, isSelected: activeGlobalTab == tab) {
            selectedTaskID = nil
            selectedSessionID = nil
            onOpenGlobal(tab)
        }
    }

    private func navigationDisclosureRow(
        title: String,
        icon: String,
        count: Int,
        isExpanded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, alignment: .center)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockSecondaryText)
                Spacer(minLength: 0)
                Text(compactCount(count))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.dockMetadataText)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    private func queueSection<Content: View>(
        _ title: String,
        count: Int?,
        action: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let action {
                    Button(action: action) { queueSectionHeader(title, count: count, isInteractive: true) }
                        .buttonStyle(.borderless)
                        .help("Open \(title.lowercased())")
                } else {
                    queueSectionHeader(title, count: count, isInteractive: false)
                }
            }
            content()
        }
    }

    private func queueSectionHeader(_ title: String, count: Int?, isInteractive: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: title == "CONVERSATIONS" ? "bubble.left.and.bubble.right" : "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isInteractive ? Color.dockAccent : Color.dockSecondaryText)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(isInteractive ? Color.dockSecondaryText : Color.dockMetadataText)
            Spacer(minLength: 0)
            if let count {
                Text(compactCount(count))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(count == 0 ? Color.dockMetadataText : Color.dockAccent)
            }
            if isInteractive {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.dockMetadataText)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background(Color.clear)
        .contentShape(Rectangle())
    }

    private func queueEmpty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Color.dockMetadataText)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
    }

    private func queueRailDestination(
        _ title: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, alignment: .center)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.dockPrimaryText : Color.dockSecondaryText)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 34)
                .contentShape(Rectangle())
                .background(isSelected ? Color.dockAccent.opacity(0.14) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func queueOverflowButton(total: Int, visible: Int, title: String, action: @escaping () -> Void) -> some View {
        if total > visible {
            Button(action: action) {
                HStack(spacing: 6) {
                    Text("Showing \(visible) of \(compactCount(total))")
                    Text(title)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.dockAccent)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
    }

    private var conversationExpansionButton: some View {
        Button { showsAllConversations.toggle() } label: {
            HStack(spacing: 6) {
                Text(showsAllConversations ? "Show recent conversations" : "Show more conversations")
                Image(systemName: showsAllConversations ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.dockAccent)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    private func taskRow(_ task: WorkspaceTask, duplicateCount: Int = 1) -> some View {
        Button {
            selectedTaskID = task.id
            selectedSessionID = nil
            onSelectTask(task)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(taskColor(task.status))
                        .frame(width: 6, height: 6)
                    Text(taskDisplayTitle(task))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    if duplicateCount > 1 {
                        Text("×\(duplicateCount)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.dockMetadataText)
                    }
                }
                if let detail = taskDisplayDetail(task) {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isTaskSelected(task) ? Color.dockAccent.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.borderless)
        .help(task.sessionID == nil ? "Open this task in Kanban" : "Open task conversation")
    }

    private func sessionRow(_ session: HermesSession) -> some View {
        Button {
            selectedSessionID = session.id
            selectedTaskID = nil
            onSelectSession(session)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                if let preview = session.displayPreview {
                    Text(preview)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                }
                if let timestamp = session.startedAt {
                    HStack(spacing: 4) {
                        Text("Updated")
                        Text(timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                    }
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSessionSelected(session) ? Color.dockAccent.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.borderless)
    }

    private func taskColor(_ status: WorkspaceTaskStatus) -> Color {
        switch status {
        case .todo: .dockSecondaryText
        case .inProgress: .dockAccent
        case .awaitingApproval: .dockWarning
        case .readyForReview: .dockSuccess
        case .done: .dockMetadataText
        }
    }

    private func isTaskSelected(_ task: WorkspaceTask) -> Bool {
        guard activeGlobalTab == nil, !isArtifactsActive else { return false }
        return selectedTaskID == task.id || (task.sessionID != nil && task.sessionID == activeSessionID)
    }

    private func isSessionSelected(_ session: HermesSession) -> Bool {
        guard activeGlobalTab == nil, !isArtifactsActive else { return false }
        return selectedSessionID == session.id || session.id == activeSessionID
    }

    private func taskDisplayTitle(_ task: WorkspaceTask) -> String {
        guard task.title == "Untitled chat",
              let sessionID = task.sessionID,
              let session = model.sessions.first(where: { $0.id == sessionID }) else { return task.title }
        return session.displayTitle
    }

    private func taskDisplayDetail(_ task: WorkspaceTask) -> String? {
        if !task.summary.isEmpty { return task.summary }
        guard let sessionID = task.sessionID,
              let session = model.sessions.first(where: { $0.id == sessionID }) else { return nil }
        return session.displayPreview
    }

    private func compactCount(_ count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }

    private func groupedTasks(_ tasks: [WorkspaceTask]) -> [QueueTaskGroup] {
        var groups: [QueueTaskGroup] = []
        var indexes: [String: Int] = [:]
        for task in tasks {
            let normalizedTitle = task.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Session-linked tasks represent distinct conversations. Unlinked
            // tasks with the same title are grouped to prevent a stale or
            // repeated projection from filling the entire navigation rail.
            let key = task.sessionID.map { "session:\($0)" } ?? "title:\(normalizedTitle)"
            if let index = indexes[key] {
                let existing = groups[index]
                groups[index] = QueueTaskGroup(key: existing.key, task: existing.task, count: existing.count + 1)
            } else {
                indexes[key] = groups.count
                groups.append(QueueTaskGroup(key: key, task: task, count: 1))
            }
        }
        return groups
    }
}

/// A three-region fullscreen shell: queue, focused workspace, and contextual
/// inspector. The queue and inspector keep sensible minimums while the center
/// owns all remaining space.
private struct MissionControlSplitView<Queue: View, Workspace: View, Inspector: View>: NSViewRepresentable {
    let queue: Queue
    let workspace: Workspace
    let inspector: Inspector

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator
        splitView.addArrangedSubview(context.coordinator.queueHost)
        splitView.addArrangedSubview(context.coordinator.workspaceHost)
        splitView.addArrangedSubview(context.coordinator.inspectorHost)
        context.coordinator.splitView = splitView
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.queueHost.rootView = AnyView(queue)
        context.coordinator.workspaceHost.rootView = AnyView(workspace)
        context.coordinator.inspectorHost.rootView = AnyView(inspector)

        guard !context.coordinator.hasSetInitialPositions else { return }
        DispatchQueue.main.async {
            guard !context.coordinator.hasSetInitialPositions,
                  splitView.bounds.width > 0 else { return }
            // Mission Control deliberately gives the queue, work surface, and
            // inspector equal outer weight at launch. Users may still resize
            // either divider for a chat- or operations-heavy session.
            splitView.setPosition(splitView.bounds.width * 0.30, ofDividerAt: 0)
            splitView.setPosition(splitView.bounds.width * 0.70, ofDividerAt: 1)
            context.coordinator.hasSetInitialPositions = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        let queueHost = NSHostingView(rootView: AnyView(EmptyView()))
        let workspaceHost = NSHostingView(rootView: AnyView(EmptyView()))
        let inspectorHost = NSHostingView(rootView: AnyView(EmptyView()))
        weak var splitView: NSSplitView?
        var hasSetInitialPositions = false

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            dividerIndex == 0 ? 220 : 540
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            if dividerIndex == 0 {
                return min(360, splitView.bounds.width - 680)
            }
            return splitView.bounds.width - 280
        }
    }
}

/// AppKit owns the fullscreen divider so panel resizing stays responsive even
/// while the conversation and inspector contain complex, frequently-updating
/// SwiftUI content.
private struct FullscreenPanelSplitView<Leading: View, Trailing: View>: NSViewRepresentable {
    let leading: Leading
    let trailing: Trailing
    let leadingFraction: CGFloat

    init(leading: Leading, trailing: Trailing, leadingFraction: CGFloat = 0.30) {
        self.leading = leading
        self.trailing = trailing
        self.leadingFraction = leadingFraction
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator
        splitView.addArrangedSubview(context.coordinator.leadingHost)
        splitView.addArrangedSubview(context.coordinator.trailingHost)
        context.coordinator.splitView = splitView
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.leadingHost.rootView = AnyView(leading)
        context.coordinator.trailingHost.rootView = AnyView(trailing)

        guard !context.coordinator.hasSetInitialPosition else { return }
        DispatchQueue.main.async {
            guard !context.coordinator.hasSetInitialPosition,
                  splitView.bounds.width > 0 else { return }
            splitView.setPosition(splitView.bounds.width * leadingFraction, ofDividerAt: 0)
            context.coordinator.hasSetInitialPosition = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        let leadingHost = NSHostingView(rootView: AnyView(EmptyView()))
        let trailingHost = NSHostingView(rootView: AnyView(EmptyView()))
        weak var splitView: NSSplitView?
        var hasSetInitialPosition = false

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            min(320, splitView.bounds.width * 0.35)
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            let minimumLeadingWidth = min(320, splitView.bounds.width * 0.35)
            let minimumTrailingWidth = min(360, splitView.bounds.width * 0.35)
            return max(minimumLeadingWidth, splitView.bounds.width - splitView.dividerThickness - minimumTrailingWidth)
        }
    }
}

enum ConversationScrollMetrics {
    // Streaming rows grow while the viewport is parked at the bottom; the
    // sticky-bottom check must tolerate that transient growth so auto-scroll
    // is not suppressed before the settle re-assertion runs.
    static let atBottomTolerance: CGFloat = 96

    static func isAtBottom(bottomMaxY: CGFloat, viewportHeight: CGFloat) -> Bool {
        bottomMaxY <= viewportHeight + atBottomTolerance
    }
}
