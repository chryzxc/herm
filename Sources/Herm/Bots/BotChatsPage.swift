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

/// The Bots page's left panel: every bot's main chat and every group room in
/// one list. The chat, toolbar and workspace beside it are the Sessions layout's.
struct BotChatsPage: View, Equatable {
    @Environment(\.dockHostVisible) private var hostVisible
    @ObservedObject var bots: BotModeModel
    @ObservedObject var groups: GroupChatStore
    let activeBotID: String?
    let style: DockThemePalette
    let usesWindowChrome: Bool
    @Binding var openRoomID: String
    @Binding var isCollapsed: Bool
    let onShowSessions: () -> Void
    let onOpen: (BotSummary) -> Void
    @ObservedObject private var sessionPanes = SessionPaneStore.shared
    @State private var query = ""
    @State private var isShowingNewGroupChat = false
    @State private var hoveredBotID: String?

    /// The host re-renders on every DockModel publication; skip those. The
    /// observed bot and group stores still drive this page's own updates.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.activeBotID == rhs.activeBotID && lhs.style.theme == rhs.style.theme
                && lhs.usesWindowChrome == rhs.usesWindowChrome && lhs.openRoomID == rhs.openRoomID
                && lhs.isCollapsed == rhs.isCollapsed
        }
    }

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
            // Same strip as the Sessions list: the sidebar toggle beside the traffic lights.
            HStack(spacing: 0) {
                if usesWindowChrome {
                    DockBuildBadgeSlot()
                        .dockPadding(.trailing, HermBuildInfo.current.badge() == nil ? 0 : 8)
                }
                DockSidebarToggle(isCollapsed: $isCollapsed)
                DockHistoryButtons()
                Spacer(minLength: 0)
                    .frame(maxHeight: .infinity)
                    .background { if usesWindowChrome { TitlebarDoubleClickArea() } }
                DockChatsScopeSwitch(showsBots: true, onShowSessions: onShowSessions, onShowBots: {})
            }
            .dockPadding(.leading, usesWindowChrome ? DockWindowChrome.sidebarToggleLeading : 6)
            .dockPadding(.trailing, 8)
            .frame(height: usesWindowChrome ? DockWindowChrome.titleRowHeight : 44)
            HStack(spacing: 6) {
                searchField
                if groups.isAvailable {
                    DockIconButton(icon: .plus, label: "New group chat", size: 28, style: style) {
                        isShowingNewGroupChat = true
                    }
                }
            }
            .dockPadding(.horizontal, 12)
            .dockPadding(.vertical, 8)
            botList
        }
        .dockShellPane()
        .dockSheet(isPresented: $isShowingNewGroupChat) {
            NewGroupChatSheet(store: groups, botMode: bots, bots: visibleBots, onCreated: openRoom)
        }
        .task(id: hostVisible) {
            // ponytail: 15s room-list poll for unread dots and previews; Hermes has no room push events.
            guard hostVisible else { return }
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
        } else {
            itemList(listedItems, selectedRoomID: openRoom?.id)
        }
    }

    @ViewBuilder
    private func itemList(_ items: [BotChatsItem], selectedRoomID: String?) -> some View {
        if items.isEmpty {
            Text("No matching chats")
                .dockFont(.body)
                .foregroundStyle(style.metadataText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(items) { item in
                        switch item {
                        case .bot(let bot):
                            // Bots shown in split columns are on screen too, so they highlight.
                            row(
                                bot,
                                isSelected: selectedRoomID == nil && bot.id == activeBotID
                                    || bot.chat.map { sessionPanes.shownSessionIDs.contains($0.sessionID) } == true)
                        case .room(let room, let date):
                            GroupChatSidebarRow(
                                room: room, store: groups, botMode: bots, style: style,
                                isSelected: room.id == selectedRoomID, date: date
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
        DockSearchField(placeholder: "Search Bots and groups", text: $query)
    }

    private func open(_ bot: BotSummary) {
        closeRoom()
        UserDefaults.standard.set(bot.id, forKey: BotChatsOrdering.lastBotKey)
        onOpen(bot)
    }

    private func openRoom(_ id: String) { openRoomID = id }

    private func closeRoom() { openRoomID = "" }

    /// A tap gesture, not a Button: a Button's mouse tracking swallows the split-view drag.
    private func row(_ bot: BotSummary, isSelected: Bool) -> some View {
        Group {
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
                    .fill(
                        isSelected
                            ? style.selectedFill : hoveredBotID == bot.id ? style.selectedFill.opacity(0.4) : .clear)
            )
            .contentShape(Rectangle())
        }
        .onHover { hoveredBotID = $0 ? bot.id : (hoveredBotID == bot.id ? nil : hoveredBotID) }
        .onTapGesture { open(bot) }
        .sessionPaneDraggable(SessionPaneDrag(bot: bot))
        .contextMenu {
            Button("Open in Split View", icon: .columnsPlusRight) {
                if let drag = SessionPaneDrag(bot: bot) { sessionPanes.open(drag) }
            }
            .disabled(isSelected || bot.chat == nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open(bot) }
        .accessibilityLabel(bot.name)
        .accessibilityHint("Open the main chat")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
