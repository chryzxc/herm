import SwiftUI

struct SessionInspectorEmptyView: View {
    let sections: [SessionInspector.Section]
    let onOpen: (SessionInspector.Section) -> Void
    /// Conversations that can open in a split column beside this one.
    var bots: [BotSummary] = []
    var botAvatars: [String: Data] = [:]
    /// Every pickable session; the menu shows the most recent until a search narrows it.
    var sessions: [HermesSession] = []
    /// Bots with recent sessions, for the Sessions grid, and those sessions by bot id.
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
                            Button {
                                SessionPaneStore.shared.open(SessionPaneDrag(room: room))
                                onDismiss()
                            } label: {
                                groupRoomRow(room)
                            }
                        }
                    }
                }
                if !sessionBots.isEmpty {
                    DockMenu("Sessions", icon: .chatCircle) { botGrid }
                } else if !sessions.isEmpty {
                    DockMenu("Sessions", icon: .chatCircle) {
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

    private var botRows: some View {
        let query = botQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? bots : bots.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return DockMenuSearchList(placeholder: "Search Bots", query: $botQuery, isEmpty: matches.isEmpty) {
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
    }

    /// A group chat's name over its members' avatars, side by side.
    private func groupRoomRow(_ room: GroupRoom) -> some View {
        let members = room.members.compactMap { router?.bots?.botsByID[$0.profile] }
        return VStack(alignment: .leading, spacing: 4) {
            Text(room.name).lineLimit(1)
            if !members.isEmpty {
                HStack(spacing: 4) {
                    ForEach(members) { bot in
                        BotAvatarView(bot: bot, imageData: botAvatars[bot.id], size: 16, animated: false)
                            .help(bot.name)
                    }
                }
            }
        }
        .dockPadding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(room.name), \(members.map(\.name).joined(separator: ", "))")
    }

    /// Bots in a three-column grid; each opens its own recent sessions. The grid scrolls on its own
    /// at three and a half rows, so a half-shown row hints at more; the menu panel's own height
    /// can exceed the room the popover gets on screen, which clips rows instead of scrolling them.
    private var botGrid: some View {
        let rows = (sessionBots.count + 2) / 3
        let visibleRows = min(CGFloat(rows), 3.5)
        return ScrollView(.vertical, showsIndicators: rows > 3) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(84), spacing: Self.tileSpacing), count: 3),
                spacing: Self.tileSpacing
            ) {
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
                        .frame(height: Self.tileHeight)
                    }
                    .accessibilityLabel("\(bot.name) recent sessions")
                }
            }
        }
        .frame(width: 3 * 84 + 2 * Self.tileSpacing)
        .frame(height: visibleRows * Self.tileHeight + max(visibleRows - 1, 0) * Self.tileSpacing)
    }

    private static let tileHeight: CGFloat = 72
    private static let tileSpacing: CGFloat = 4

    private func open(_ session: HermesSession) {
        SessionPaneStore.shared.open(SessionPaneDrag(session: session))
        onDismiss()
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
        let all = SessionSidebarSearch.sessions(matching: query, in: sessions, projects: [:])
        let shown = all.prefix(limit)
        DockMenuSearchList(placeholder: "Search sessions", query: $query, isEmpty: all.isEmpty) {
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
        .onChange(of: query) { _, _ in limit = Self.page }
    }
}
