import SwiftUI

struct SessionDashboard<Conversation: View>: View {
    @ObservedObject var model: DockModel
    @ObservedObject var bots: BotModeModel
    let control: ControlCenterModel
    @StateObject private var sidebar: SessionNavSidebarModel
    @ObservedObject private var seen = SidebarSessionSeenStore.shared
    @State private var selection = SessionDashboardSelection()
    @State private var showsConversation = false
    @State private var isNewConversation = false
    let onNewConversation: () -> Void
    let onOpenWorkspace: () -> Void
    let onShowList: () -> Void
    let onSelectProfile: (String) -> Void
    @ViewBuilder let conversation: () -> Conversation

    init(
        model: DockModel, bots: BotModeModel, control: ControlCenterModel, store: WorkspaceStore,
        onNewConversation: @escaping () -> Void, onOpenWorkspace: @escaping () -> Void,
        onShowList: @escaping () -> Void, onSelectProfile: @escaping (String) -> Void,
        @ViewBuilder conversation: @escaping () -> Conversation
    ) {
        self.model = model
        self.bots = bots
        self.control = control
        self.onNewConversation = onNewConversation
        self.onOpenWorkspace = onOpenWorkspace
        self.onShowList = onShowList
        self.onSelectProfile = onSelectProfile
        self.conversation = conversation
        _sidebar = StateObject(wrappedValue: SessionNavSidebarModel(model: model, control: control, store: store))
    }

    private var snapshot: SessionNavSidebarSnapshot { sidebar.snapshot }
    private var isCurrent: Bool {
        guard model.isHermesConnected else { return false }
        switch snapshot.inputs.sessionProjectionState {
        case .ready, .empty: return true
        // A manual refresh marks loaded rows stale; they stay current until it fails,
        // so tiles do not blank their status and reload on every refresh.
        case .stale: return model.isLoadingSessions
        default: return false
        }
    }

    private var subtitle: String {
        guard model.isHermesConnected else { return "Disconnected · activity is not current" }
        switch snapshot.inputs.sessionProjectionState {
        case .loading: return "Loading sessions…"
        case .stale where model.isLoadingSessions: return "All bots and projects · updates every 10 seconds"
        case .stale, .unavailable, .failed: return "Activity is not current · refresh to retry"
        case .ready, .empty: return "All bots and projects · updates every 10 seconds"
        }
    }

    private var sessions: [HermesSession] { SessionDashboardProjection.sessions(in: snapshot) }

    var body: some View {
        DockExpandedPage(
            title: "Chats", subtitle: subtitle,
            onShowList: onShowList,
            showsClose: false, close: {}
        ) {
            SessionDashboardToolbar(
                isLoading: selection.isLoading, isRefreshing: model.isLoadingSessions,
                onRefresh: refresh, onNewConversation: newConversation)
        } content: {
            sessionList
        }
        .dockSheet(isPresented: $showsConversation) {
            DockExpandedPage(
                title: conversationTitle,
                subtitle: isNewConversation ? "Start a conversation" : "Respond to this session",
                close: { showsConversation = false }
            ) {
                Button {
                    showsConversation = false
                    onOpenWorkspace()
                } label: {
                    DockIconLabel("Open workspace", icon: .cornersOut)
                }
                .buttonStyle(.dockSecondary)
                .disabled(!canRespond)
            } content: {
                conversationPane
            }
            .environment(\.dockTitleRow, nil)
            .frame(minWidth: 540, idealWidth: 760, maxWidth: 760, minHeight: 560, idealHeight: 680, maxHeight: 680)
        }
        .task {
            baseline()
            if model.sessions.isEmpty { model.loadSessions() }
            control.refreshProjectNavigation()
        }
        .onChange(of: snapshot.inputs.sessionProjectionState) { _, _ in baseline() }
    }

    private var sessionList: some View {
        SessionDashboardList(
            sidebar: sidebar, selection: selection, isCurrent: isCurrent, onSelect: select,
            client: model.controlRPCClient, model: model, tileBots: tileBots
        ).equatable()
    }

    /// Bots only label tiles when more than one could own them.
    private var tileBots: [String: SessionDashboardBot] {
        let visible = bots.bots.filter { !$0.isHidden }
        guard visible.count > 1 else { return [:] }
        return Dictionary(
            visible.map { ($0.id, SessionDashboardBot(summary: $0, image: bots.avatarImages[$0.id])) },
            uniquingKeysWith: { first, _ in first })
    }

    private var conversationPane: some View {
        VStack(spacing: 0) {
            if isNewConversation || selection.session != nil {
                if selection.isLoading {
                    DockLoadingState(title: "Loading conversation…", minHeight: 120)
                        .frame(maxHeight: .infinity)
                } else if canRespond {
                    conversation()
                } else {
                    emptyState("Conversation unavailable", detail: "Reload this session before responding.")
                    if let session = selection.session {
                        Button("Retry") { select(session) }.buttonStyle(.dockSecondary)
                    }
                    Spacer()
                }
            } else {
                emptyState(
                    "Select a session", detail: "Read the conversation, answer requests, or send an instruction here.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var conversationTitle: String {
        isNewConversation ? model.currentSessionTitle ?? "New chat" : selection.session?.displayTitle ?? "Conversation"
    }

    private var canRespond: Bool {
        isNewConversation
            || selection.canRespond(
                activeSessionID: model.navigationSessionID, activeProfileID: model.sessionProfileID,
                profileID: model.profileScopeID)
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).dockFont(.body, weight: .semibold)
            Text(detail).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
        }
        .dockPadding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func newConversation() {
        selection = SessionDashboardSelection()
        isNewConversation = true
        onNewConversation()
        showsConversation = true
    }

    private func select(_ session: HermesSession) {
        isNewConversation = false
        // A chat from another bot opens in that bot's scope, as in the sidebar.
        if let owner = session.profileID, owner != model.profileScopeID { onSelectProfile(owner) }
        let generation = selection.begin(session)
        showsConversation = true
        Task {
            let loaded = await model.resumeSession(session, reportFailure: true)
            selection.finish(generation, loaded: loaded)
        }
    }

    private func baseline() {
        guard isCurrent else { return }
        seen.baseline(profileID: model.profileScopeID, sessions: sessions)
    }

    private func refresh() {
        model.loadSessions()
        control.refreshProjectNavigation()
    }
}
