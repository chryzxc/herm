import AppKit
import Combine
import SwiftUI
import Foundation
import UniformTypeIdentifiers

extension DockPopover {
    func sessionIdentity(style: DockThemePalette) -> some View {
        Button(action: { model.toggleSessions() }) {
            HStack(spacing: 8) {
                Text(model.currentSessionTitle ?? "Untitled chat")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(style.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                DockIcon(.caretUpDown, size: 12, color: style.metadataText)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: DockControlMetrics.cornerRadius, style: .continuous)
                    .fill(model.isShowingSessions ? style.selectedFill : isSessionIdentityHovering ? style.surface4.opacity(0.6) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .onHover { isSessionIdentityHovering = $0 }
        .animation(reduceMotion ? nil : .dockEase(duration: 0.16), value: isSessionIdentityHovering)
        .help("\(model.currentSessionTitle ?? "Untitled chat") — \(model.status.title)")
        .accessibilityLabel("Choose session: \(model.currentSessionTitle ?? "Untitled chat"), \(model.status.title)")
        .popover(isPresented: $model.isShowingSessions, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            sessionPicker
                .frame(width: 390, height: 310)
                .padding(.vertical, 4)
                .background(Color.dockCanvas)
        }
    }

    func sessionModeSwitcher(style: DockThemePalette) -> some View {
        SessionModeTabStrip(
            modes: activeSessionRepositoryScope == nil ? [.chat, .voice] : [.chat, .voice, .pullRequests],
            selectedMode: sessionWorkspaceMode,
            style: style,
            onSelect: selectSessionMode
        )
    }

    func sessionViewMenu(includesInspector: Bool, style: DockThemePalette) -> some View {
        DockMenu {
            if let session = currentSession {
                let pinned = model.isSessionPinned(session.id)
                Button(pinned ? "Unpin conversation" : "Pin conversation", icon: pinned ? .pushPinSlash : .pushPin) {
                    Task { await model.toggleSessionPinned(session) }
                }
                Button("Rename…", icon: .pencilSimple) {
                    renameDraft = session.displayTitle
                    isRenamingSession = true
                }
                Button(session.isHidden ? "Show in list" : "Hide from list", icon: session.isHidden ? .eye : .eyeSlash) {
                    Task { @MainActor in
                        if await model.setSessionHidden(session, hidden: !session.isHidden) {
                            controlCenter.refreshProjectNavigation()
                        }
                    }
                }
                // No trailing rule when nothing follows (voice mode, inspector shown).
                if sessionWorkspaceMode == .chat || includesInspector { Divider() }
            }
            if sessionWorkspaceMode == .chat {
                Button(isShowingMessageSearch ? "Close message search" : "Find in conversation", icon: .magnifyingGlass) {
                    isShowingMessageSearch.toggle()
                }
                if !model.messageNavigatorItems.isEmpty {
                    Button("Pinned messages", icon: .pushPin) { isShowingMessagePins.toggle() }
                }
            }
            if includesInspector {
                if sessionWorkspaceMode == .chat { Divider() }
                Button(inspectorPanelIsVisible ? "Hide inspector" : "Show inspector", action: toggleInspectorPanel)
            }
        } label: {
            DockIcon(.dotsThree, size: DockLayout.toolbarIconSize, color: isSessionMenuHovering ? style.primaryText : style.secondaryText)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous)
                        .fill(isSessionMenuHovering ? style.surface4.opacity(0.7) : .clear)
                )
                .contentShape(Rectangle())
        }
        .onHover { isSessionMenuHovering = $0 }
        .help("Conversation actions")
        .accessibilityLabel("Conversation actions")
        .alert("Rename conversation", isPresented: $isRenamingSession) {
            TextField("Title", text: $renameDraft)
            Button("Rename") {
                let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, let session = currentSession, title != session.title else { return }
                Task { @MainActor in
                    if await model.renameSession(session, title: title) { controlCenter.refreshProjectNavigation() }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The open conversation as a session row, so list actions can target it.
    var currentSession: HermesSession? {
        guard let id = model.navigationSessionID else { return nil }
        return model.sessions.first { $0.id == id } ?? HermesSession(
            id: id, profileID: model.sessionProfileID, title: model.currentSessionTitle ?? "",
            preview: "", startedAt: nil, messageCount: 0, source: "herm")
    }

    func showFilePreview() {
        guard filePreview.url != nil else { return }
        filePreview.sessionID = model.sessionID
        if isNarrowLayout, sessionWorkspaceMode == .explorer { sessionWorkspaceMode = .chat }
        ensureInspectorPanelVisible()
    }

    func selectSessionMode(_ mode: SessionWorkspaceMode) {
        guard mode != sessionWorkspaceMode else { return }
        withAnimation(.dockEase(duration: 0.2)) {
            sessionWorkspaceMode = mode
        }
        if mode.usesContextPreview {
            ensureInspectorPanelVisible()
        }
    }

    func ensureInspectorPanelVisible() {
        if isFullscreen {
            isMissionInspectorVisible = true
        } else if isNarrowLayout {
            if sessionWorkspaceMode == .explorer { return }
            isNarrowControlVisible = true
        } else {
            isWorkspaceManuallyExpanded = true
        }
    }

    func refreshSessionWorkflow() async {
        await developerWorkflow.refresh(preferences: repositoryPreferences, control: controlCenter)
    }

    func selectChangeFile(_ file: RepositoryFileChange) {
        guard let scope = activeSessionRepositoryScope else { return }
        let requestID = UUID()
        sourceControlRequestID = requestID
        selectedChange = ScopedRepositoryChange(scope: scope, file: file)
        selectedChangeDiff = nil
        isLoadingChangeDiff = true
        Task {
            let diff = await RepositoryService.diff(path: scope.repositoryPath, file: file)
            guard sourceControlRequestID == requestID,
                  activeSessionRepositoryScope == scope,
                  selectedChange?.file.id == file.id else { return }
            selectedChangeDiff = diff
            isLoadingChangeDiff = false
        }
    }

    /// The session inspector's tab strip carries its own collapse toggle.
    var inspectorHasOwnToggle: Bool {
        inspectorPanelIsVisible && !isNarrowLayout && filePreview.url == nil
            && !sessionWorkspaceMode.usesContextPreview && inspectorScope == .session
    }

    var inspectorPanelIsVisible: Bool {
        isFullscreen ? isMissionInspectorVisible : isWorkspaceVisibleForLayout
    }

    func toggleInspectorPanel() {
        if isFullscreen {
            isMissionInspectorVisible.toggle()
        } else if isNarrowLayout {
            isNarrowControlVisible.toggle()
        } else {
            isWorkspaceManuallyExpanded.toggle()
        }
    }

    func toggleFullscreen() {
        onFullscreenToggle()
    }

    func applyFullscreen(_ fullscreen: Bool) {
        guard fullscreen != isFullscreen else { return }
        // Fullscreen changes only the host window and available layout space.
        // It must not select a different workspace, inspector scope, or
        // session surface: those are user-owned presentation state.
        let preservedInspectorVisibility = inspectorPanelIsVisible
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isFullscreen = fullscreen
            if isFullscreen {
                isNarrowLayout = false
                isMissionInspectorVisible = preservedInspectorVisibility
            } else {
                synchronizePanelLayout()
                if isNarrowLayout {
                    isNarrowControlVisible = preservedInspectorVisibility
                } else {
                    isWorkspaceManuallyExpanded = preservedInspectorVisibility
                }
            }
        }
    }

    var sessionModelDisplayName: String {
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

    var sessionReasoningDisplayName: String {
        let reasoning = model.sessionID == nil
            ? model.defaultReasoningVariant
            : model.sessionReasoningVariant
        return reasoning?.displayName ?? "LOADING…"
    }

    var selectedModelOptionID: String? {
        if let id = model.sessionModelOptionID { return id }
        guard model.sessionID == nil, let provider = model.runtimeConfiguration?.provider,
              let modelName = model.runtimeConfiguration?.model else { return nil }
        return HermesModelOption(provider: provider, model: modelName).id
    }

    var selectedReasoningVariant: HermesReasoningVariant? {
        model.sessionID == nil ? model.defaultReasoningVariant : model.sessionReasoningVariant
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

    var configurationScopeLabel: String {
        model.sessionID == nil ? "new chats" : "this session"
    }

    /// A single, divider-led rail keeps the two session settings scannable as
    /// one piece of context instead of presenting competing controls.
    @ViewBuilder
    var sessionConfigurationRow: some View {
        HStack(spacing: 0) {
            DockMenu {
                if model.runtimeModelOptions.isEmpty {
                    Text("Loading model catalog…")
                } else {
                    ForEach(model.runtimeModelOptions) { option in
                        Button {
                            model.updateSessionModel(option)
                        } label: {
                            HStack {
                                Text(option.displayName)
                                if option.id == selectedModelOptionID {
                                    Ph.check.image()
                                }
                            }
                        }
                    }
                }
            } label: {
                sessionConfigurationLabel(
                    icon: .cpu,
                    title: "MODEL",
                    value: sessionModelDisplayName,
                    truncatesValue: true
                )
            }
            .buttonStyle(.dockHover)
            .disabled(model.isUpdatingSessionModel)
            .help("Change the model for \(configurationScopeLabel)")
            .accessibilityLabel("Model for \(configurationScopeLabel): \(sessionModelDisplayName)")

            Color.dockBorderLight
                .frame(width: 0.5, height: 24)

            DockMenu {
                DockMenuChoices(selection: reasoningVariantSelection) {
                    ForEach(HermesReasoningVariant.allCases) { variant in
                        DockMenuOption(variant.displayName, value: Optional(variant))
                    }
                }
            } label: {
                sessionConfigurationLabel(
                    icon: .brain,
                    title: "THINKING",
                    value: sessionReasoningDisplayName
                )
            }
            .buttonStyle(.dockHover)
            .disabled(model.sessionID != nil && model.isUpdatingSessionReasoning)
            .help("Change thinking depth for \(configurationScopeLabel)")
            .accessibilityLabel("Thinking depth for \(configurationScopeLabel): \(sessionReasoningDisplayName)")
        }
        .foregroundStyle(Color.dockPrimaryText)
        .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).dockSurfaceFill(Color.dockSurface4))
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .stroke(Color.dockBorder, lineWidth: 0.5)
        }
    }

    func sessionConfigurationLabel(
        icon: Ph,
        title: String,
        value: String,
        truncatesValue: Bool = false
    ) -> some View {
        HStack(spacing: 7) {
            DockIcon(icon)
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

            DockIcon(.caretDown)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.dockSecondaryText)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    var sessionPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            sessionList
        }
        .background(Color.dockCanvas)
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.paneRadius + 2, style: .continuous))
    }

    var sessionList: some View {
        let style = DockThemePalette(theme: dockThemeStore.selectedThemeID)
        return VStack(alignment: .leading, spacing: 4) {
            DockSectionHeader(
                title: "Recents",
                count: model.sessions.isEmpty ? nil : model.sessions.count,
                style: style
            ) {
                DockIconButton(
                    icon: .arrowsClockwise,
                    label: "Refresh conversations",
                    isBusy: model.isLoadingSessions,
                    size: 24,
                    style: style
                ) { model.loadSessions() }
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)

            if model.sessions.isEmpty && model.isLoadingSessions {
                DockLoadingState(title: "Loading conversations…", minHeight: 80)
            } else if model.sessions.isEmpty {
                Text("No saved conversations")
                    .font(.system(size: 12))
                    .foregroundStyle(style.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            } else {
                List {
                    ForEach(model.sessions) { session in
                        SessionPickerRow(
                            session: session,
                            projectName: conversationProjectName(for: session),
                            isCurrent: session.id == model.navigationSessionID,
                            canDelete: session.id != model.sessionID && model.deletingSessionID == nil,
                            isUpdatingVisibility: model.updatingSessionVisibilityID == session.id,
                            style: style,
                            onOpen: { model.resumeSession(session) },
                            onToggleHidden: {
                                Task { @MainActor in
                                    if await model.setSessionHidden(session, hidden: !session.isHidden) {
                                        controlCenter.refreshProjectNavigation()
                                    }
                                }
                            },
                            onDelete: { sessionPendingDeletion = session }
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 280)
                .scrollContentBackground(.hidden)
                .padding(.bottom, 6)
            }
        }
    }

    func conversationProjectName(for session: HermesSession) -> String? {
        guard let project = controlCenter.project(forSessionID: session.id),
              !project.name.isEmpty,
              project.name != "__no_project__" else {
            return nil
        }

        let name = URL(fileURLWithPath: project.name).lastPathComponent
        return name.isEmpty ? project.name : name
    }

    @ViewBuilder
    var conversation: some View {
        if speechInput.isRecording {
            voiceMode
        } else {
            chatScroll
        }
    }
}
