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
/// one list, grouped into local folders. The chat, toolbar and workspace beside
/// it are the Sessions layout's.
struct BotChatsPage: View, Equatable {
    @Environment(\.dockHostVisible) private var hostVisible
    @ObservedObject var bots: BotModeModel
    @ObservedObject var groups: GroupChatStore
    let activeBotID: String?
    let style: DockThemePalette
    let usesWindowChrome: Bool
    @Binding var openRoomID: String
    @Binding var isCreatingBot: Bool
    @Binding var isCollapsed: Bool
    let onShowSessions: () -> Void
    let onOpen: (BotSummary) -> Void
    @ObservedObject private var sessionPanes = SessionPaneStore.shared
    @ObservedObject private var folders = BotFolderStore.shared
    @State private var query = ""
    @State private var isShowingNewGroupChat = false
    @State private var hoveredBotID: String?
    @State private var hoveredFolderID: UUID?
    /// The folder header (by id) or "loose" area a drag is over.
    @State private var dropTarget: String?
    /// The folder a dragged folder is hovering; it opens a gap so the dragged one lands there.
    @State private var folderGapID: UUID?
    /// A dragged folder is over the area below the folders, so it would land last.
    @State private var endGap = false
    /// The row that just landed in a folder, flashed once so the eye follows it.
    @State private var landedItemID: String?
    /// Per-folder drop count: each drop replays the folder's squash-and-bounce.
    @State private var folderDrops: [UUID: Int] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renamingFolderID: UUID?
    @State private var folderName = ""
    @FocusState private var isRenameFocused: Bool
    @State private var renameClickMonitor: Any?

    /// The host re-renders on every DockModel publication; skip those. The
    /// observed bot, group and folder stores still drive this page's own updates.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.activeBotID == rhs.activeBotID && lhs.style.theme == rhs.style.theme
                && lhs.usesWindowChrome == rhs.usesWindowChrome && lhs.openRoomID == rhs.openRoomID
                && lhs.isCollapsed == rhs.isCollapsed && lhs.isCreatingBot == rhs.isCreatingBot
        }
    }

    private var visibleBots: [BotSummary] { bots.bots.filter { !$0.isHidden } }

    /// Only a room Hermes still lists; a stale id falls back to the bot chat.
    private var openRoom: GroupRoom? { groups.rooms.first { $0.id == openRoomID } }

    private func activity(_ room: GroupRoom) -> Date { groups.lastMessages[room.id]?.date ?? room.updatedAt }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

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
            }
            .dockPadding(.leading, usesWindowChrome ? DockWindowChrome.sidebarToggleLeading : 6)
            .dockPadding(.trailing, 8)
            .frame(height: usesWindowChrome ? DockWindowChrome.titleRowHeight : 44)
            DockChatsScopeSwitch(showsBots: true, onShowSessions: onShowSessions, onShowBots: {})
                .dockPadding(.horizontal, 12)
                .dockPadding(.top, 8)
            HStack(spacing: 6) {
                searchField
                addMenu
            }
            .dockPadding(.horizontal, 12)
            .dockPadding(.top, 14)
            .dockPadding(.bottom, 8)
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
            if !isCreatingBot,
                let bot = BotChatsOrdering.initialBot(
                    visibleBots, activeID: activeBotID,
                    lastID: UserDefaults.standard.string(forKey: BotChatsOrdering.lastBotKey))
            {
                open(bot)
            }
        }
    }

    /// New Bot opens in the chat area; a group chat keeps its modal.
    private var addMenu: some View {
        DockMenu {
            if bots.canCreateBots {
                Button("New Bot", icon: .robot) {
                    closeRoom()
                    isCreatingBot = true
                }
            }
            if groups.isAvailable {
                Button("New Group Chat", icon: .usersThree) { isShowingNewGroupChat = true }
            }
            Button("New Folder", icon: .folderSimplePlus) { newFolder() }
        } label: {
            DockIconButtonLabel(icon: .plus, size: 28, style: style)
        }
        .fixedSize()
        .help("New bot, group chat or folder")
        .accessibilityLabel("New bot, group chat or folder")
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
                    Text(bots.canCreateBots ? "Create one with the + button." : "Create one in Settings › Bots.")
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
            let sections = BotChatsOrdering.sections(items, folders: folders.folders, isSearching: isSearching)
            ScrollView {
                // ponytail: eager VStack so folder moves animate; a LazyVStack cross-fades them. Fine for a roster.
                // Sections sit apart so a folder's last row never reads as part of the next group.
                VStack(spacing: 12) {
                    ForEach(sections.folders) { section in
                        folderSection(section, selectedRoomID: selectedRoomID)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    VStack(spacing: DockSidebarListMetrics.rowSpacing) {
                        if endGap {
                            RoundedRectangle(cornerRadius: DockControlMetrics.cornerRadius, style: .continuous)
                                .fill(style.selectedFill)
                                .overlay { Ph.folderSimple.image(size: 14, color: NSColor(Color.dockMetadataText)) }
                                .frame(height: 28)
                                .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .top)))
                        }
                        // Unfiled rows get their own header once folders exist.
                        if !sections.folders.isEmpty, !sections.loose.isEmpty {
                            sectionHeader("Other")
                        }
                        ForEach(sections.loose) { item in
                            itemCell(item, selectedRoomID: selectedRoomID)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        // Room to drop below the last row: back to the top level, or a folder to the end.
                        Color.clear.frame(height: folders.folders.isEmpty ? 0 : 44)
                    }
                    .background {
                        RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                            .fill(dropTarget == "loose" && !endGap ? style.selectedFill.opacity(0.4) : .clear)
                    }
                    .onDrop(
                        of: [SessionPaneDrag.pasteboardType.rawValue, BotFolderDrag.pasteboardType.rawValue],
                        delegate: BotListDropDelegate(
                            isTargeted: dropBinding("loose"),
                            onItem: { moveItem($0, to: nil) },
                            onFolder: { folders.moveFolder($0.folderID, before: nil) },
                            onFolderHover: { endGap = $0 }))
                }
                .animation(BotFolderMotion.spring, value: folders.folders)
                .dockPadding(.horizontal, DockSidebarListMetrics.listInset)
                .dockPadding(.vertical, 8)
            }
            .task(id: dropTarget) { await springLoadTargetFolder() }
            .onChange(of: renamingFolderID) { _, id in
                // A click on a non-focusable area never blurs the field, so end the edit ourselves.
                if let monitor = renameClickMonitor { NSEvent.removeMonitor(monitor) }
                renameClickMonitor = nil
                guard id != nil else { return }
                renameClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                    let hit = event.window?.contentView?.hitTest(event.locationInWindow)
                    if !(hit is NSTextView || hit is NSTextField) { Task { @MainActor in commitRename() } }
                    return event
                }
            }
        }
    }

    private func itemCell(_ item: BotChatsItem, selectedRoomID: String?) -> some View {
        itemRow(item, selectedRoomID: selectedRoomID)
            .background {
                if landedItemID == item.id {
                    RoundedRectangle(cornerRadius: DockControlMetrics.cornerRadius, style: .continuous)
                        .fill(style.selectedFill)
                        .transition(.opacity)
                }
            }
    }

    @ViewBuilder
    private func itemRow(_ item: BotChatsItem, selectedRoomID: String?) -> some View {
        switch item {
        case .bot(let bot):
            // Bots shown in split columns are on screen too, so they highlight.
            row(
                bot,
                isSelected: !isCreatingBot && selectedRoomID == nil && bot.id == activeBotID
                    || bot.chat.map { sessionPanes.shownSessionIDs.contains($0.sessionID) } == true)
        case .room(let room, let date):
            GroupChatSidebarRow(
                room: room, store: groups, botMode: bots, style: style,
                isSelected: room.id == selectedRoomID, date: date,
                onOpen: { openRoom(room.id) }, onOpenRoom: openRoom
            )
            .sessionPaneDraggable(SessionPaneDrag(room: room))
        }
    }

    /// Flat like a Finder sidebar group: a header row aligned with the bot rows and
    /// indented children. Only a drag over it paints a fill.
    private func folderSection(_ section: BotFolderSection, selectedRoomID: String?) -> some View {
        let folder = section.folder
        let hasGap = folderGapID == folder.id
        let isTarget = dropTarget == folder.id.uuidString && !hasGap
        return VStack(spacing: DockSidebarListMetrics.rowSpacing) {
            folderHeader(folder, count: section.items.count)
            if !folder.isCollapsed {
                ForEach(section.items) { item in
                    itemCell(item, selectedRoomID: selectedRoomID)
                        // Lands by growing out of the header rather than sliding in.
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.9, anchor: .topLeading))))
                }
                if section.items.isEmpty, isTarget {
                    Text("Drop to add")
                        .dockFont(.metadata)
                        .foregroundStyle(style.metadataText)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                .fill(isTarget ? style.selectedFill.opacity(0.45) : .clear)
        }
        .scaleEffect(isTarget && !reduceMotion ? 1.02 : 1)
        .animation(BotFolderMotion.hover, value: isTarget)
        // A dragged folder pushes this one down and leaves a slot marked by an accent bar.
        .dockPadding(.top, hasGap ? 34 : 0)
        .overlay(alignment: .top) {
            if hasGap {
                RoundedRectangle(cornerRadius: DockControlMetrics.cornerRadius, style: .continuous)
                    .fill(style.selectedFill)
                    .overlay { Ph.folderSimple.image(size: 14, color: NSColor(Color.dockMetadataText)) }
                    .frame(height: 28)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottom)))
            }
        }
        .animation(reduceMotion ? nil : BotFolderMotion.spring, value: hasGap)
        // A drop squashes the folder and lets it bounce back, as if it swallowed the row.
        .keyframeAnimator(initialValue: CGFloat(1), trigger: folderDrops[folder.id] ?? 0) { content, scale in
            content.scaleEffect(x: 1 + (1 - scale) * 0.4, y: scale, anchor: .top)
        } keyframes: { _ in
            SpringKeyframe(0.94, duration: 0.1, spring: .snappy)
            SpringKeyframe(1.03, duration: 0.16, spring: .bouncy)
            SpringKeyframe(1, duration: 0.3, spring: .smooth)
        }
        .onDrop(
            of: [SessionPaneDrag.pasteboardType.rawValue, BotFolderDrag.pasteboardType.rawValue],
            delegate: BotListDropDelegate(
                isTargeted: dropBinding(folder.id.uuidString),
                onItem: { moveItem($0, to: folder.id) },
                onFolder: { folders.moveFolder($0.folderID, before: folder.id) },
                onFolderHover: { folderGapID = $0 ? folder.id : (folderGapID == folder.id ? nil : folderGapID) }))
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .dockFont(.metadata, weight: .semibold)
                .foregroundStyle(style.secondaryText)
            Spacer(minLength: 0)
        }
        .frame(height: 24)
        .dockPadding(.horizontal, 8)
        .dockPadding(.top, 4)
        .accessibilityAddTraits(.isHeader)
    }

    /// A section header like a sidebar group: the name on the left, a folder mark
    /// on the right (open while expanded) that the more menu replaces on hover.
    private func folderHeader(_ folder: BotFolder, count: Int) -> some View {
        HStack(spacing: 6) {
            if renamingFolderID == folder.id {
                TextField("Folder name", text: $folderName)
                    .textFieldStyle(.plain)
                    .dockFont(.metadata, weight: .semibold)
                    .focused($isRenameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { renamingFolderID = nil }
                    .onChange(of: isRenameFocused) { _, focused in if !focused { commitRename() } }
            } else {
                Text(folder.name)
                    .dockFont(.metadata, weight: .semibold)
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(1)
                if folder.isCollapsed, count > 0 {
                    Text("\(count)")
                        .dockFont(.metadata).monospacedDigit()
                        .foregroundStyle(style.metadataText)
                        .contentTransition(.numericText(value: Double(count)))
                        .animation(BotFolderMotion.spring, value: count)
                }
            }
            Spacer(minLength: 4)
            // The menu stays mounted (just hidden) so its popover survives the pointer leaving the header.
            let showsMenu = hoveredFolderID == folder.id && renamingFolderID != folder.id
            ZStack {
                // Under a drag the folder opens and hops up to take the row.
                let isTarget = dropTarget == folder.id.uuidString && !reduceMotion
                (isTarget || !folder.isCollapsed ? Ph.folderOpen : Ph.folderSimple)
                    .image(size: 14, color: NSColor(isTarget ? Color.dockPrimaryText : Color.dockMetadataText))
                    .scaleEffect(isTarget ? 1.25 : 1)
                    .rotationEffect(.degrees(isTarget ? -10 : 0))
                    .offset(y: isTarget ? -2 : 0)
                    .animation(BotFolderMotion.hover, value: isTarget)
                    .frame(width: 20, height: 20)
                    .opacity(showsMenu ? 0 : 1)
                DockMenu {
                    folderActions(folder)
                } label: {
                    Ph.dotsThree.image(size: 13, color: NSColor(Color.dockSecondaryText))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .fixedSize()
                .help("More folder actions")
                .accessibilityLabel("More actions for \(folder.name)")
                .opacity(showsMenu ? 1 : 0)
                .allowsHitTesting(showsMenu)
            }
        }
        .frame(height: 24)
        .dockPadding(.horizontal, 8)
        .dockPadding(.top, 4)
        .contentShape(Rectangle())
        .onHover { hoveredFolderID = $0 ? folder.id : (hoveredFolderID == folder.id ? nil : hoveredFolderID) }
        .onTapGesture {
            guard renamingFolderID != folder.id else { return }
            withAnimation(BotFolderMotion.spring) { folders.toggleCollapsed(folder.id) }
        }
        .draggable(BotFolderDrag(folderID: folder.id)) {
            Label(folder.name, icon: .folderSimple).dockPill().dockPadding(6)
        }
        .modifier(DockDragCursor(isEnabled: renamingFolderID != folder.id, isDragging: false))
        .dockContextMenu { folderActions(folder) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(folder.name), \(count) chats")
        .accessibilityValue(folder.isCollapsed ? "Collapsed" : "Expanded")
    }

    @ViewBuilder
    private func folderActions(_ folder: BotFolder) -> some View {
        Button("Rename…", icon: .pencilSimple) { startRename(folder) }
        Button("New Folder", icon: .folderSimplePlus) { newFolder() }
        Divider()
        Button("Delete Folder", icon: .trash, role: .destructive) {
            withAnimation(BotFolderMotion.spring) { folders.delete(folder.id) }
        }
    }

    private func dropBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { dropTarget == key },
            set: { dropTarget = $0 ? key : (dropTarget == key ? nil : dropTarget) })
    }

    private func moveItem(_ drag: SessionPaneDrag, to folderID: UUID?) {
        guard let id = BotChatsOrdering.itemID(for: drag, bots: visibleBots),
            folders.folderID(containing: id) != folderID
        else { return }
        folders.move(id, to: folderID)
        guard !reduceMotion else { return }
        if let folderID { folderDrops[folderID, default: 0] += 1 }
        landedItemID = id
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.easeOut(duration: 0.6)) { if landedItemID == id { landedItemID = nil } }
        }
    }

    /// Hovering a drag over a collapsed folder opens it after a beat, like Finder.
    private func springLoadTargetFolder() async {
        guard let key = dropTarget,
            let folder = folders.folders.first(where: { $0.id.uuidString == key }), folder.isCollapsed
        else { return }
        try? await Task.sleep(for: BotFolderMotion.springLoadDelay)
        guard !Task.isCancelled, dropTarget == key else { return }
        withAnimation(BotFolderMotion.spring) { folders.toggleCollapsed(folder.id) }
    }

    private func newFolder(containing itemID: String? = nil) {
        var id = UUID()
        withAnimation(BotFolderMotion.spring) { id = folders.create(containing: itemID) }
        startRename(id: id, name: "New Folder")
    }

    private func startRename(_ folder: BotFolder) { startRename(id: folder.id, name: folder.name) }

    private func startRename(id: UUID, name: String) {
        folderName = name
        renamingFolderID = id
        isRenameFocused = true
    }

    private func commitRename() {
        guard let id = renamingFolderID else { return }
        folders.rename(id, to: folderName)
        renamingFolderID = nil
    }

    private var searchField: some View {
        DockSearchField(placeholder: "Search Bots and groups", text: $query)
    }

    private func open(_ bot: BotSummary) {
        closeRoom()
        isCreatingBot = false
        UserDefaults.standard.set(bot.id, forKey: BotChatsOrdering.lastBotKey)
        onOpen(bot)
    }

    private func openRoom(_ id: String) {
        isCreatingBot = false
        openRoomID = id
    }

    private func closeRoom() { openRoomID = "" }

    /// A tap gesture, not a Button: a Button's mouse tracking swallows the split-view drag.
    private func row(_ bot: BotSummary, isSelected: Bool) -> some View {
        Group {
            HStack(spacing: 8) {
                // The face animates while the bot works; the row draws no spinner.
                BotAvatarView(
                    bot: bot, imageData: bots.avatarImages[bot.id], size: 34, orbits: bot.isMainChatWorking
                )
                .overlay(alignment: .bottomTrailing) {
                    if !isSelected, let session = bot.chat?.unreadSession(title: bot.name) {
                        SessionUnreadReplyBadge(session: session, showUnavailable: false)
                            .offset(x: 5, y: 4)
                    }
                }
                VStack(alignment: .leading, spacing: DockSidebarListMetrics.titleToPreview) {
                    HStack(spacing: 6) {
                        Text(bot.name)
                            .dockFont(.navigation)
                            .foregroundStyle(style.primaryText)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if let role = bot.title?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty {
                            Text(role)
                                .dockFont(size: 10, weight: .medium)
                                .foregroundStyle(style.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .dockPill(compact: true)
                        }
                        Spacer(minLength: 4)
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
            .dockPadding(.leading, DockSidebarListMetrics.rowLeadingWithAvatar)
            .dockPadding(.trailing, DockSidebarListMetrics.rowTrailing)
            .dockPadding(.vertical, DockSidebarListMetrics.rowVertical)
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
        .dockContextMenu {
            Button("Open in Split View", icon: .columnsPlusRight) {
                if let drag = SessionPaneDrag(bot: bot) { sessionPanes.open(drag) }
            }
            .disabled(isSelected || bot.chat == nil)
            BotFolderMoveMenu(itemID: BotChatsItem.bot(bot).id) { startRename(id: $0, name: "New Folder") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open(bot) }
        .accessibilityLabel(bot.name)
        .accessibilityHint("Open the main chat")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension BotChatReference {
    /// The main chat as a session, so the Sessions list's unread-reply count applies.
    func unreadSession(title: String) -> HermesSession {
        HermesSession(
            id: sessionID, profileID: profileID, title: title, preview: preview ?? "", startedAt: lastActive,
            updatedAt: lastActive, messageCount: 0, source: "hermes-bot")
    }
}
