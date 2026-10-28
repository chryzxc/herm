import SwiftUI

struct SessionDashboard<Conversation: View>: View {
    @ObservedObject var model: DockModel
    @ObservedObject var bots: BotModeModel
    let control: ControlCenterModel
    @StateObject private var sidebar: SessionNavSidebarModel
    @ObservedObject private var seen = SidebarSessionSeenStore.shared
    @State private var selection = SessionDashboardSelection()
    @State private var showsConversation = false
    let onNewConversation: () -> Void
    let onOpenWorkspace: () -> Void
    let onShowList: () -> Void
    @ViewBuilder let conversation: () -> Conversation

    init(
        model: DockModel, bots: BotModeModel, control: ControlCenterModel, store: WorkspaceStore,
        onNewConversation: @escaping () -> Void, onOpenWorkspace: @escaping () -> Void,
        onShowList: @escaping () -> Void,
        @ViewBuilder conversation: @escaping () -> Conversation
    ) {
        self.model = model
        self.bots = bots
        self.control = control
        self.onNewConversation = onNewConversation
        self.onOpenWorkspace = onOpenWorkspace
        self.onShowList = onShowList
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
        case .stale where model.isLoadingSessions: return "All projects in the selected bot · updates every 10 seconds"
        case .stale, .unavailable, .failed: return "Activity is not current · refresh to retry"
        case .ready, .empty: return "All projects in the selected bot · updates every 10 seconds"
        }
    }

    private var sessions: [HermesSession] { SessionDashboardProjection.sessions(in: snapshot) }

    var body: some View {
        DockExpandedPage(
            title: "Chats", subtitle: subtitle,
            showsClose: false, close: {}
        ) {
            SessionDashboardToolbar(
                bots: bots, fallbackName: model.agentDisplayName,
                isLoading: selection.isLoading, isRefreshing: model.isLoadingSessions,
                onRefresh: refresh, onShowList: onShowList, onNewConversation: onNewConversation)
        } content: {
            sessionList
        }
        .dockSheet(isPresented: $showsConversation) {
            DockExpandedPage(
                title: selection.session?.displayTitle ?? "Conversation",
                subtitle: "Respond to this session", close: { showsConversation = false }
            ) {
                conversationPane
            }
            .frame(minWidth: 540, idealWidth: 760, minHeight: 560, idealHeight: 780)
        }
        .task {
            baseline()
            if model.sessions.isEmpty { model.loadSessions() }
            control.refreshProjectNavigation()
        }
        .onChange(of: snapshot.inputs.sessionProjectionState) { _, _ in baseline() }
        .onChange(of: model.profileScopeID) { _, _ in
            selection = SessionDashboardSelection()
            showsConversation = false
        }
    }

    private var sessionList: some View {
        SessionDashboardList(
            sidebar: sidebar, selection: selection, isCurrent: isCurrent, onSelect: select,
            client: model.controlRPCClient, model: model
        ).equatable().id(model.profileScopeID)
    }

    private var conversationPane: some View {
        VStack(spacing: 0) {
            if let session = selection.session {
                HStack {
                    Text(session.displayTitle).dockFont(.body, weight: .semibold).lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Open workspace") {
                        showsConversation = false
                        onOpenWorkspace()
                    }
                    .buttonStyle(.dockCompact).disabled(!canRespond)
                }
                .padding(12)
                Color.dockBorderLight.frame(height: DockLayout.hairline)
                if selection.isLoading {
                    DockLoadingState(title: "Loading conversation…", minHeight: 120)
                        .frame(maxHeight: .infinity)
                } else if canRespond {
                    conversation()
                } else {
                    emptyState("Conversation unavailable", detail: "Reload this session before responding.")
                    Button("Retry") { select(session) }.buttonStyle(.dockSecondary)
                    Spacer()
                }
            } else {
                emptyState(
                    "Select a session", detail: "Read the conversation, answer requests, or send an instruction here.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var canRespond: Bool {
        selection.canRespond(
            activeSessionID: model.navigationSessionID, activeProfileID: model.sessionProfileID,
            profileID: model.profileScopeID)
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).dockFont(.body, weight: .semibold)
            Text(detail).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func select(_ session: HermesSession) {
        let generation = selection.begin(session)
        showsConversation = true
        Task {
            let loaded = await model.resumeSession(session, reportFailure: true)
            selection.finish(generation, loaded: loaded)
            if loaded, selection.generation == generation {
                seen.markSeen(
                    profileID: session.profileID ?? model.profileScopeID, sessionID: session.id,
                    at: session.lastUpdatedAt)
            }
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
