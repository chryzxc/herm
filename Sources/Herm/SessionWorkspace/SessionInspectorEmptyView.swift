import SwiftUI

struct SessionInspectorEmptyView<ConversationCard: View>: View {
    let entries: [SessionInspectorNewTab]
    let onOpen: (SessionInspector.Section) -> Void
    @ViewBuilder let conversationCard: (SessionInspectorNewTab) -> ConversationCard

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
                    ForEach(entries) { entry in
                        switch entry {
                        case .conversation: conversationCard(entry)
                        case .section(let section):
                            Button {
                                onOpen(section)
                            } label: {
                                SessionInspectorTabCard(entry: entry)
                            }
                            .buttonStyle(.dockHover)
                            .accessibilityLabel("Open \(entry.title) tab")
                        case .reopenClosed: EmptyView()
                        }
                    }
                }
            }
            .frame(maxWidth: 480)
            .dockPadding(DockSpacing.inspectorInset)
            .dockPadding(.top, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Color.dockCanvas)
    }
}

struct SessionInspectorTabCard: View {
    let entry: SessionInspectorNewTab

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DockIcon(entry.icon, size: 16, color: .dockSecondaryText)
                Text(entry.title)
                    .dockFont(.body, weight: .semibold)
                Spacer(minLength: 0)
                DockIcon(.plus, size: 12, color: .dockSecondaryText)
            }
            if let detail = entry.cardDetail {
                Text(detail)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
                    // Two lines reserved on every card so the grid's rows share one height.
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .foregroundStyle(Color.dockPrimaryText)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .dockCard(padding: 12)
        .contentShape(Rectangle())
    }
}

struct SessionInspectorConversationMenu<MenuLabel: View>: View {
    let bots: [BotSummary]
    let botAvatars: [String: Data]
    let sessions: [HermesSession]
    let sessionBots: [BotSummary]
    let sessionsByBot: [String: [HermesSession]]
    let onOpen: () -> Void
    @ViewBuilder let label: () -> MenuLabel
    @Environment(\.chatContextRouter) private var router
    @State private var botQuery = ""

    var body: some View {
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
                                onOpen()
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
                label()
            }
            .accessibilityLabel("Open a conversation in split view")
        }
    }

    private var botRows: some View {
        let query = botQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? bots : bots.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return DockMenuSearchList(placeholder: "Search Bots", query: $botQuery, isEmpty: matches.isEmpty) {
            ForEach(matches) { bot in
                if let item = SessionPaneDrag(bot: bot) {
                    Button {
                        SessionPaneStore.shared.open(item)
                        onOpen()
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
        let tileHeight: CGFloat = 72
        let tileSpacing: CGFloat = 4
        let rows = (sessionBots.count + 2) / 3
        let visibleRows = min(CGFloat(rows), 3.5)
        return ScrollView(.vertical, showsIndicators: rows > 3) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(84), spacing: tileSpacing), count: 3),
                spacing: tileSpacing
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
                        .frame(height: tileHeight)
                    }
                    .accessibilityLabel("\(bot.name) recent sessions")
                }
            }
        }
        .frame(width: 3 * 84 + 2 * tileSpacing)
        .frame(height: visibleRows * tileHeight + max(visibleRows - 1, 0) * tileSpacing)
    }

    private func open(_ session: HermesSession) {
        SessionPaneStore.shared.open(SessionPaneDrag(session: session))
        onOpen()
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
