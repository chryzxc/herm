import SwiftUI

struct SessionInspectorEmptyView: View {
    let sections: [SessionInspector.Section]
    let onOpen: (SessionInspector.Section) -> Void
    /// Conversations that can open in a split column beside this one.
    var bots: [BotSummary] = []
    var botAvatars: [String: Data] = [:]
    /// Every pickable session; the menu shows the most recent until a search narrows it.
    var sessions: [HermesSession] = []
    /// Bots with recent sessions, for the Recent session grid, and those sessions by bot id.
    /// Empty when the bot roster is unavailable; the menu then lists `sessions` directly.
    var sessionBots: [BotSummary] = []
    var sessionsByBot: [String: [HermesSession]] = [:]
    /// Collapses the inspector once a card opens something outside it (a split column),
    /// so the grid doesn't linger; + or the inspector toggle brings it back.
    var onDismiss: () -> Void = {}
    @Environment(\.chatContextRouter) private var router
    @State private var botQuery = ""

    /// Most-used first: talking to the session, then working in its project, then reviewing it.
    private static let priority: [SessionInspector.Section] = [
        .talk, .terminal, .browser, .files, .changes, .pullRequests, .issues, .diff, .github, .artifacts,
        .timeline, .iosSimulator, .androidEmulator,
    ]

    private var ordered: [SessionInspector.Section] {
        sections.sorted { (Self.priority.firstIndex(of: $0) ?? .max) < (Self.priority.firstIndex(of: $1) ?? .max) }
    }

    private func detail(_ section: SessionInspector.Section) -> String {
        switch section {
        case .browser: "Open a page or search the web"
        case .terminal: "Run commands in your workspace"
        case .files: "Browse project files"
        case .artifacts: "Explore this session’s outputs"
        case .changes: "Review repository changes"
        case .timeline: "Inspect session activity"
        case .diff: "Review the attached diff"
        case .github: "Follow the linked pull request or issue"
        case .iosSimulator: "Run the app in an iOS Simulator"
        case .androidEmulator: "Run the app in an Android Emulator"
        case .talk: "Talk with this session by voice"
        case .pullRequests: "Browse this repository’s pull requests"
        case .issues: "Browse this repository’s issues"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open a new tab")
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                    Text("Choose a tool to use alongside your conversation.")
                        .dockFont(.body)
                        .foregroundStyle(Color.dockSecondaryText)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
                    // Talk, then splitting in another conversation, then the tools.
                    ForEach(ordered.filter { $0 == .talk }) { section in sectionCard(section) }
                    conversationCard
                    ForEach(ordered.filter { $0 != .talk }) { section in sectionCard(section) }
                }
            }
            .frame(maxWidth: 480)
            .dockPadding(DockSpacing.inspectorInset)
            .dockPadding(.top, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Color.dockCanvas)
    }

    private func sectionCard(_ section: SessionInspector.Section) -> some View {
        Button {
            onOpen(section)
        } label: {
            card(title: section.navigationTitle, detail: detail(section), icon: section.icon)
        }
        .buttonStyle(.dockHover)
        .accessibilityLabel("Open \(section.navigationTitle) tab")
    }

    @ViewBuilder
    private var conversationCard: some View {
        let rooms = router?.bots?.groupChats.rooms ?? []
        if !bots.isEmpty || !sessions.isEmpty || !sessionBots.isEmpty || !rooms.isEmpty {
            DockMenu {
                if !bots.isEmpty {
                    DockMenu("Bot chat", icon: .robot) { botRows }
                }
                if !rooms.isEmpty {
                    DockMenu("Group chat", icon: .usersThree) {
                        ForEach(rooms) { room in
                            Button(room.name) {
                                SessionPaneStore.shared.open(SessionPaneDrag(room: room))
                                onDismiss()
                            }
                        }
                    }
                }
                if !sessionBots.isEmpty {
                    DockMenu("Recent session", icon: .chatCircle) { botGrid }
                } else if !sessions.isEmpty {
                    DockMenu("Recent session", icon: .chatCircle) {
                        SessionPickerRows(sessions: sessions, onPick: open)
                    }
                }
            } label: {
                card(
                    title: "Conversation", detail: "Open a session, Bot chat or group chat in split view",
                    icon: .columnsPlusRight)
            }
            .accessibilityLabel("Open a conversation in split view")
        }
    }

    private func card(title: String, detail: String, icon: Ph) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DockIcon(icon, size: 16, color: .dockSecondaryText)
                Text(title)
                    .dockFont(.body, weight: .semibold)
                Spacer(minLength: 0)
                DockIcon(.plus, size: 12, color: .dockSecondaryText)
            }
            Text(detail)
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
                // Two lines reserved on every card so the grid's rows share one height.
                .lineLimit(2, reservesSpace: true)
        }
        .foregroundStyle(Color.dockPrimaryText)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .dockCard(padding: 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var botRows: some View {
        DockSearchField(placeholder: "Search Bots", text: $botQuery).frame(maxWidth: .infinity).dockPadding(.bottom, 4)
        let query = botQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? bots : bots.filter { $0.name.localizedCaseInsensitiveContains(query) }
        if matches.isEmpty { noMatches }
        ForEach(matches) { bot in
            if let item = SessionPaneDrag(bot: bot) {
                Button {
                    SessionPaneStore.shared.open(item)
                    onDismiss()
                } label: {
                    HStack(spacing: 8) {
                        BotAvatarView(bot: bot, imageData: botAvatars[bot.id], size: 18, animated: false)
                        Text(bot.name)
                    }
                }
            }
        }
    }

    /// Bots in a three-column grid; each opens its own recent sessions.
    private var botGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 4), count: 3), spacing: 4) {
            ForEach(sessionBots) { bot in
                DockMenu(tile: true) {
                    SessionPickerRows(sessions: sessionsByBot[bot.id] ?? [], onPick: open)
                } label: {
                    VStack(spacing: 6) {
                        BotAvatarView(bot: bot, imageData: botAvatars[bot.id], size: 32, animated: false)
                        Text(bot.name)
                            .dockFont(.metadata, weight: .medium)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity)
                    .dockPadding(.vertical, 8)
                }
                .accessibilityLabel("\(bot.name) recent sessions")
            }
        }
    }

    private func open(_ session: HermesSession) {
        SessionPaneStore.shared.open(SessionPaneDrag(session: session))
        onDismiss()
    }

    private var noMatches: some View { DockMenuNoMatches() }
}

private struct DockMenuNoMatches: View {
    var body: some View {
        Text("No matches")
            .dockFont(.body)
            .foregroundStyle(Color.dockMetadataText)
            .dockPadding(.horizontal, 8)
            .dockPadding(.vertical, 6)
    }
}

/// Searchable, paged session rows inside a `DockMenu`; each menu keeps its own query.
private struct SessionPickerRows: View {
    let sessions: [HermesSession]
    let onPick: (HermesSession) -> Void
    @State private var query = ""
    @State private var limit = Self.page
    private static let page = 20

    var body: some View {
        DockSearchField(placeholder: "Search sessions", text: $query).frame(maxWidth: .infinity)
            .dockPadding(.bottom, 4)
            .onChange(of: query) { _, _ in limit = Self.page }
        let all = SessionSidebarSearch.sessions(matching: query, in: sessions, projects: [:])
        let shown = all.prefix(limit)
        if all.isEmpty { DockMenuNoMatches() }
        // Lazy, so a row's onAppear means it actually scrolled into view.
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(Array(shown)) { session in
                Button {
                    onPick(session)
                } label: {
                    HStack(spacing: 8) {
                        Text(session.displayTitle).lineLimit(1).frame(maxWidth: 280, alignment: .leading)
                        if let date = session.lastUpdatedAt {
                            Spacer(minLength: 12)
                            Text(SidebarSessionTime.short(date))
                                .foregroundStyle(Color.dockMetadataText).monospacedDigit()
                        }
                    }
                }
                // Reaching the last shown row reveals the next page.
                .onAppear {
                    if session.id == shown.last?.id, limit < all.count { limit += Self.page }
                }
            }
        }
    }
}
