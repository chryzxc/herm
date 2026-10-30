import SwiftUI

/// One row on the Bots page: a bot's main chat or a group room.
enum BotChatsItem: Identifiable {
    case bot(BotSummary)
    case room(GroupRoom, Date)

    var id: String {
        switch self {
        case .bot(let bot): "bot:\(bot.id)"
        case .room(let room, _): "room:\(room.id)"
        }
    }

    var date: Date? {
        switch self {
        case .bot(let bot): bot.chat?.lastActive
        case .room(_, let date): date
        }
    }
}

/// Pure choices behind the Bots page, kept out of the view for tests.
enum BotChatsOrdering {
    static let lastBotKey = "herm.bots.lastMainChatBot"
    /// Set while a group room is the open chat; opening a bot clears it.
    static let lastRoomKey = "herm.bots.lastGroupRoom"

    /// Bots and rooms in one inbox, newest activity first. Undated rows keep
    /// their given order after the dated ones.
    static func items(_ bots: [BotSummary], rooms: [(GroupRoom, Date)]) -> [BotChatsItem] {
        (bots.map(BotChatsItem.bot) + rooms.map(BotChatsItem.room))
            .enumerated()
            .sorted { lhs, rhs in
                let lhsDate = lhs.element.date ?? .distantPast
                let rhsDate = rhs.element.date ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// The bot whose main chat the page opens on: the open one, else the one
    /// last opened here, else the default bot. nil keeps the open chat.
    static func initialBot(_ bots: [BotSummary], activeID: String?, lastID: String?) -> BotSummary? {
        guard !bots.contains(where: { $0.id == activeID }) else { return nil }
        return bots.first { $0.id == lastID } ?? bots.first(where: \.isDefault) ?? bots.first
    }
}

/// Messenger-style Bots destination: every bot's main chat and every group
/// room in one list beside the open conversation. No session sections and no
/// inspector.
struct BotChatsPage<Conversation: View>: View {
    @ObservedObject var bots: BotModeModel
    @ObservedObject var groups: GroupChatStore
    let activeBotID: String?
    let style: DockThemePalette
    let onOpen: (BotSummary) -> Void
    @ViewBuilder let conversation: () -> Conversation
    @State private var query = ""
    @State private var openRoomID = UserDefaults.standard.string(forKey: BotChatsOrdering.lastRoomKey)
    @State private var isShowingNewGroupChat = false

    private var visibleBots: [BotSummary] { bots.bots.filter { !$0.isHidden } }

    /// Only a room Hermes still lists; a stale id falls back to the bot chat.
    private var openRoom: GroupRoom? { groups.rooms.first { $0.id == openRoomID } }

    private func activity(_ room: GroupRoom) -> Date { groups.lastMessages[room.id]?.date ?? room.updatedAt }

    /// Search only narrows the list; the open chat stays put.
    private var listedItems: [BotChatsItem] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let matches = { (name: String) in needle.isEmpty || name.localizedCaseInsensitiveContains(needle) }
        return BotChatsOrdering.items(
            visibleBots.filter { matches($0.name) },
            rooms: groups.rooms.filter { matches($0.name) }.map { ($0, activity($0)) })
    }

    var body: some View {
        VStack(spacing: 0) {
            DockPageHeader(title: "Bots", subtitle: "")
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        searchField
                        if groups.isAvailable {
                            DockIconButton(icon: .plus, label: "New group chat", size: 28, style: style) {
                                isShowingNewGroupChat = true
                            }
                        }
                    }
                    .dockPadding(.horizontal, 12)
                    .dockPadding(.top, 8)
                    botList
                }
                .frame(width: 360)
                .background(style.sidebarBackground)
                Divider().overlay(Color.dockBorderLight)
                Group {
                    if let openRoom {
                        GroupChatView(store: groups, botMode: bots, roomID: openRoom.id) { closeRoom() }
                            .id(openRoom.id)
                    } else {
                        conversation()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .dockSheet(isPresented: $isShowingNewGroupChat) {
            NewGroupChatSheet(store: groups, bots: visibleBots, onCreated: openRoom)
        }
        .task {
            // ponytail: 15s room-list poll for unread dots and previews; Hermes has no room push events.
            while !Task.isCancelled {
                await groups.refreshRooms()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .task(id: visibleBots.map(\.id)) {
            // Waits for the roster: an empty list opens nothing.
            if let bot = BotChatsOrdering.initialBot(
                visibleBots, activeID: activeBotID,
                lastID: UserDefaults.standard.string(forKey: BotChatsOrdering.lastBotKey))
            {
                open(bot)
            }
        }
    }

    @ViewBuilder
    private var botList: some View {
        if visibleBots.isEmpty && groups.rooms.isEmpty {
            if bots.isRefreshing {
                DockLoadingState(title: "Loading Bots…")
            } else {
                VStack(spacing: 4) {
                    Text("No Bots")
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(style.primaryText)
                    Text("Create one in Settings › Bots.")
                        .dockFont(.body)
                        .foregroundStyle(style.metadataText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if listedItems.isEmpty {
            Text("No matching chats")
                .dockFont(.body)
                .foregroundStyle(style.metadataText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(listedItems) { item in
                        switch item {
                        case .bot(let bot):
                            row(bot)
                        case .room(let room, let date):
                            GroupChatSidebarRow(
                                room: room, store: groups, botMode: bots, style: style,
                                isSelected: room.id == openRoom?.id, date: date
                            ) { openRoom(room.id) }
                        }
                    }
                }
                .dockPadding(.horizontal, 6)
                .dockPadding(.vertical, 8)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            DockIcon(.magnifyingGlass, size: 13, color: .dockMetadataText)
            DockTextField("Search Bots and groups", text: $query)
                .textFieldStyle(.plain)
                .dockFont(.body)
                .accessibilityLabel("Search Bots and groups")
                .onExitCommand { query = "" }
            if !query.isEmpty {
                DockIconButton(icon: .x, label: "Clear search", size: 24, style: style) { query = "" }
            }
        }
        .dockPadding(.horizontal, 8)
        .frame(minHeight: 32)
        .background(DockThemeShape(cornerRadius: DockLayout.controlRadius).fill(Color.dockControlSurface))
        .overlay {
            DockThemeShape(cornerRadius: DockLayout.controlRadius)
                .stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline)
        }
    }

    private func open(_ bot: BotSummary) {
        closeRoom()
        UserDefaults.standard.set(bot.id, forKey: BotChatsOrdering.lastBotKey)
        onOpen(bot)
    }

    private func openRoom(_ id: String) {
        openRoomID = id
        UserDefaults.standard.set(id, forKey: BotChatsOrdering.lastRoomKey)
    }

    private func closeRoom() {
        openRoomID = nil
        UserDefaults.standard.removeObject(forKey: BotChatsOrdering.lastRoomKey)
    }

    private func row(_ bot: BotSummary) -> some View {
        let isSelected = openRoom == nil && bot.id == activeBotID
        return Button {
            open(bot)
        } label: {
            HStack(spacing: 10) {
                BotAvatarView(
                    bot: bot, imageData: bots.avatarImages[bot.id], size: 42, orbits: bot.isMainChatWorking)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(bot.name)
                            .dockFont(.navigation)
                            .foregroundStyle(style.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        SessionActivityGlyph(isWorking: bot.isMainChatWorking, hasUnreadUpdate: false)
                        if let date = bot.chat?.lastActive {
                            Text(SidebarSessionTime.short(date))
                                .dockFont(.metadata).monospacedDigit()
                                .foregroundStyle(style.metadataText)
                                .fixedSize()
                        }
                    }
                    Text(bot.chat?.preview ?? "No messages yet")
                        .dockFont(.body)
                        .foregroundStyle(style.metadataText)
                        .lineLimit(1)
                }
            }
            .dockPadding(.horizontal, 6)
            .dockPadding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DockControlMetrics.cornerRadius, style: .continuous)
                    .fill(isSelected ? style.selectedFill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityLabel(bot.name)
        .accessibilityHint("Open the main chat")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
