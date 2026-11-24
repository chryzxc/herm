import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// A sidebar session dragged toward the chat area to open beside the primary conversation.
struct SessionPaneDrag: Codable, Equatable, Transferable {
    let sessionID: String
    let profileID: String?
    let title: String
    static let pasteboardType = NSPasteboard.PasteboardType("io.github.chryzxc.Herm.session-pane")

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: pasteboardType.rawValue, conformingTo: .data))
    }

    var destination: QuickDestination { QuickDestination(profileID: profileID, sessionID: sessionID, title: title) }
}

extension SessionPaneDrag {
    init(session: HermesSession) {
        self.init(sessionID: session.id, profileID: session.profileID, title: session.displayTitle)
    }

    /// A group chat room. Rooms are not Hermes sessions; the tab id carries the room id.
    init(room: GroupRoom) {
        self.init(sessionID: QuickDestination.groupRoomTabID(room.id), profileID: nil, title: room.name)
    }

    /// A Bot's canonical chat; nil until Hermes has created it (the roster then only knows its title).
    init?(bot: BotSummary) {
        guard let chat = bot.chat else { return nil }
        self.init(sessionID: chat.sessionID, profileID: chat.profileID, title: bot.name)
    }
}

extension QuickDestination {
    // ponytail: rooms ride the session-keyed tab model behind an id prefix; give tabs a
    // real kind if more non-session tab types appear.
    static let groupRoomPrefix = "group-room:"
    /// The tab (and detached-window) id that stands for a group room.
    static func groupRoomTabID(_ roomID: String) -> String { groupRoomPrefix + roomID }
    var groupRoomID: String? {
        guard let id = sessionID, id.hasPrefix(Self.groupRoomPrefix) else { return nil }
        return String(id.dropFirst(Self.groupRoomPrefix.count))
    }
}

extension View {
    /// Lets a sidebar row be dragged into the chat area to open in split view.
    @ViewBuilder
    func sessionPaneDraggable(
        _ drag: SessionPaneDrag?, isEnabled: Bool = true, pinnedDrag: PinnedSessionDrag? = nil
    ) -> some View {
        if let pinnedDrag, isEnabled {
            draggable(pinnedDrag) {
                SidebarReorderDragPreview(title: pinnedDrag.session.title, icon: .pushPin)
            }
            .modifier(DockDragCursor(isEnabled: true, isDragging: false))
        } else if let drag, pinnedDrag == nil {
            draggable(drag) {
                HStack(spacing: 8) {
                    // A bot always shows its avatar beside its name; a group chat its group mark.
                    if let (bot, avatar) = BotMentions.mainChatBot(drag.sessionID) {
                        BotAvatarView(bot: bot, imageData: avatar, size: 22, animated: false, mood: .happy)
                    } else {
                        DockIcon(
                            drag.destination.groupRoomID == nil ? .chatCircle : .usersThree, size: 14,
                            weight: .fill, color: .dockPrimaryText)
                    }
                    Text(drag.title)
                        .dockFont(.navigation, weight: .semibold)
                        .lineLimit(1)
                        .frame(maxWidth: 260, alignment: .leading)
                }
                .dockCard(padding: 10, isActive: true)
                // Upright, with room around it: the preview is rasterized to its own bounds, so a
                // tilt or a flush border clips the card's corners and stroke.
                .dockPadding(6)
            }
            .modifier(DockDragCursor(isEnabled: isEnabled, isDragging: false))
        } else {
            self
        }
    }
}

/// Where a dropped session lands: a new column at a slot, or a tab in an existing column.
enum SessionPaneTarget: Hashable {
    case newPanel(Int)
    case tab(Int)
}

/// What opening a session does once duplicates are accounted for.
enum SessionPaneResolution: Equatable {
    case newPanel(Int)
    case addTab(Int)
    case select(panel: Int, tab: Int)
}

/// The workspace column uses the shared model. Other columns keep a live
/// projection of their selected tab. Focus selects the header and inspector.
@MainActor
final class SessionPaneStore: ObservableObject {
    static let shared = SessionPaneStore()
    nonisolated static let maxColumns = 3
    /// The unsplit primary column keeps this id once split, so it never re-animates in.
    nonisolated static let baseColumnID = "session-pane-base"
    /// Set by `performDrop` and cleared on the next `dropEntered`, so the late update AppKit
    /// can deliver after a drop cannot re-arm the tab/column hints.
    var dropPerformed = false

    @MainActor struct Panel: Identifiable {
        var id = UUID().uuidString
        var tabs: [QuickDestination]
        var selectedID: String?
        let chat = EdgeQuickConversationModel()
        var selected: QuickDestination? { tabs.first { $0.sessionID == selectedID } }
        var usesWorkspaceConversation: Bool { id == SessionPaneStore.baseColumnID }
    }

    /// Empty while unsplit; otherwise 2...3 columns, or 1 column holding several tabs.
    @Published private(set) var panels: [Panel] = []
    @Published private(set) var activeIndex = 0
    @Published private(set) var focusedProjection: DockModel?
    weak var runtime: DockModel?
    /// Sidebar status of every open tab; bound by the window shell.
    let tabStatus = SessionPaneTabStatusModel()
    private var showsBotsLayout = false
    private var parkedLayouts: [Bool: (panels: [Panel], activeIndex: Int)] = [:]

    var activePanel: Panel? { panels.indices.contains(activeIndex) ? panels[activeIndex] : nil }

    private var workspacePanelIndex: Int? { panels.firstIndex(where: \.usesWorkspaceConversation) }

    func focusWorkspaceConversation() {
        if let index = workspacePanelIndex {
            if activeIndex != index { activeIndex = index }
        } else if panels.indices.contains(activeIndex) {
            let base = Panel(id: Self.baseColumnID, tabs: [], selectedID: nil)
            if panels.count < Self.maxColumns {
                activeIndex += 1
                panels.insert(base, at: activeIndex)
            } else {
                panels[activeIndex].chat.shutdown()
                panels[activeIndex] = base
            }
        }
        updateFocusedProjection()
    }

    @discardableResult
    func focusOpenSession(_ sessionID: String, profileID: String?, includeWorkspace: Bool = true) -> Bool {
        guard let index = panelIndex(for: sessionID, profileID: profileID, includeWorkspace: includeWorkspace) else {
            return false
        }
        activate(sessionID, at: index)
        return true
    }

    func hasOpenSession(_ sessionID: String, profileID: String?) -> Bool {
        panelIndex(for: sessionID, profileID: profileID, includeWorkspace: true) != nil
    }

    private func panelIndex(for sessionID: String, profileID: String?, includeWorkspace: Bool) -> Int? {
        let identity = ProfileScopedID(profileID: profileID, resourceID: sessionID)
        return panels.firstIndex { panel in
            (includeWorkspace || !panel.usesWorkspaceConversation)
                && panel.tabs.contains {
                    $0.sessionID == sessionID
                        && ProfileScopedID(profileID: $0.profileID, resourceID: sessionID)
                            == identity
                }
        }
    }

    private func updateFocusedProjection() {
        let next = activePanel?.chat.conversation
        if focusedProjection !== next { focusedProjection = next }
    }

    /// Conversations detached into their own windows, mirrored from `ConversationWindowStore`
    /// so the sidebar views that observe this store redraw when one opens or closes.
    @Published var detachedSessionIDs: Set<String> = []

    /// Sessions on screen in any column or detached window; the sidebar highlights all of them.
    var shownSessionIDs: Set<String> { Set(panels.compactMap(\.selectedID)).union(detachedSessionIDs) }

    /// Share of the last column, at its trailing edge, that opens a new column; 0 when full.
    nonisolated static func newColumnZone(columnCount: Int) -> CGFloat {
        let count = max(columnCount, 1)
        return count >= maxColumns ? 0 : count == 1 ? 0.5 : 0.25
    }

    /// The smallest a resized column may get.
    nonisolated static let minColumnWidth: CGFloat = 280

    /// Column shares of the row: the user's resized `fractions` when they match the
    /// column count, otherwise equal shares.
    nonisolated static func fractions(_ fractions: [CGFloat], count: Int) -> [CGFloat] {
        let count = max(count, 1)
        return fractions.count == count ? fractions : Array(repeating: 1 / CGFloat(count), count: count)
    }

    /// Drags the divider before column `divider + 1` by `delta` (a share of the row),
    /// trading width only between its two neighbors, each kept at least `minFraction`.
    nonisolated static func resized(
        _ fractions: [CGFloat], divider: Int, delta: CGFloat, minFraction: CGFloat
    ) -> [CGFloat] {
        guard fractions.indices.contains(divider), fractions.indices.contains(divider + 1) else { return fractions }
        var result = fractions
        let pair = fractions[divider] + fractions[divider + 1]
        let floor = min(minFraction, pair / 2)
        result[divider] = min(max(fractions[divider] + delta, floor), pair - floor)
        result[divider + 1] = pair - result[divider]
        return result
    }

    /// The column under the cursor, using the row's column shares. The trailing zone of
    /// the last column opens a new column while there is room; anywhere else adds a tab
    /// to the column under the cursor, including the first.
    nonisolated static func dropTarget(
        x: CGFloat, width: CGFloat, columnCount: Int, fractions: [CGFloat] = []
    ) -> SessionPaneTarget {
        let count = max(columnCount, 1)
        guard width > 0 else { return .tab(0) }
        let shares = Self.fractions(fractions, count: count)
        var start: CGFloat = 0
        var column = 0
        while column < count - 1, x >= (start + shares[column]) * width {
            start += shares[column]
            column += 1
        }
        let position = min(max((x / width - start) / shares[column], 0), 1)
        let zone = newColumnZone(columnCount: count)
        if zone > 0, column == count - 1, position >= 1 - zone { return .newPanel(count) }
        return .tab(column)
    }

    /// A session already in a column is selected there instead of opening twice; the
    /// unsplit primary session resolves to nil.
    nonisolated static func resolve(
        sessionID: String, primaryID: String?, panelTabs: [[String]], target: SessionPaneTarget
    ) -> SessionPaneResolution? {
        for (panel, tabs) in panelTabs.enumerated() {
            if let tab = tabs.firstIndex(of: sessionID) { return .select(panel: panel, tab: tab) }
        }
        guard sessionID != primaryID else { return nil }
        let count = max(panelTabs.count, 1)
        switch target {
        case .newPanel(let index) where count < maxColumns:
            return .newPanel(min(max(index, 0), count))
        case .newPanel(let index), .tab(let index):
            return .addTab(min(max(index, 0), count - 1))
        }
    }

    /// A new tab opens beside the tab it came from (the selected one), not at the far end.
    nonisolated static func tabInsertionIndex(tabs: [QuickDestination], selectedID: String?) -> Int {
        tabs.firstIndex { $0.sessionID == selectedID }.map { $0 + 1 } ?? tabs.count
    }

    /// The menu action opens beside the active column, not at the far right.
    func open(_ drag: SessionPaneDrag) {
        withAnimation(
            DockMotion.animation(
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, duration: 0.28)
        ) {
            open(drag.destination, target: .newPanel(activeIndex + 1))
        }
    }

    func open(_ destination: QuickDestination, target: SessionPaneTarget) {
        // A detached conversation lives in its own window; bring that forward instead.
        if let id = destination.sessionID, ConversationWindowStore.shared.focus(sessionID: id) { return }
        guard let runtime, let id = destination.sessionID,
            let resolution = Self.resolve(
                sessionID: id, primaryID: runtime.navigationSessionID,
                panelTabs: panels.map { $0.tabs.compactMap(\.sessionID) }, target: target)
        else { return }
        if panels.isEmpty {
            let primary = runtime.navigationSessionID.map { primaryDestination($0) }
            panels = [Panel(id: Self.baseColumnID, tabs: primary.map { [$0] } ?? [], selectedID: primary?.sessionID)]
            activeIndex = 0
        }
        switch resolution {
        case .newPanel(let index):
            panels.insert(Panel(tabs: [destination], selectedID: id), at: index)
            if index <= activeIndex { activeIndex += 1 }
            load(index)
        case .addTab(let index):
            panels[index].tabs.insert(
                destination, at: Self.tabInsertionIndex(tabs: panels[index].tabs, selectedID: panels[index].selectedID))
            select(id, at: index)
        case .select(let panel, _):
            select(id, at: panel)
        }
    }

    func select(_ sessionID: String, in panelID: String) {
        if let index = panels.firstIndex(where: { $0.id == panelID }) { select(sessionID, at: index) }
    }

    /// Makes a column's session the main one (inspector, sidebar and modes follow it).
    func activate(_ sessionID: String, in panelID: String) {
        if let index = panels.firstIndex(where: { $0.id == panelID }) { activate(sessionID, at: index) }
    }

    /// Every column is its own session: picking a tab switches only that column. The
    /// main column's tabs drive the main conversation; other columns load theirs.
    private func select(_ sessionID: String, at index: Int) {
        guard index != activeIndex else { return activate(sessionID, at: index) }
        guard panels[index].tabs.contains(where: { $0.sessionID == sessionID }) else { return }
        guard panels[index].selectedID != sessionID else { return }
        panels[index].selectedID = sessionID
        load(index)
    }

    /// Keeps a tab's title in step after a rename from its column's menu.
    func retitle(_ sessionID: String, to title: String) {
        for index in panels.indices {
            for tab in panels[index].tabs.indices where panels[index].tabs[tab].sessionID == sessionID {
                panels[index].tabs[tab].title = title
            }
        }
    }

    /// Moves the header, inspector and modes to this column.
    private func activate(_ sessionID: String, at index: Int) {
        guard let tab = panels[index].tabs.first(where: { $0.sessionID == sessionID }) else { return }
        refreshWorkspaceTitle()
        let changedTab = panels[index].selectedID != sessionID
        if activeIndex != index { activeIndex = index }
        if changedTab { panels[index].selectedID = sessionID }
        if panels[index].usesWorkspaceConversation || changedTab
            || (panels[index].chat.conversation == nil && tab.groupRoomID == nil)
        {
            load(index)
        }
        updateFocusedProjection()
        collapseIfUnsplit()
    }

    /// Every session with a tab in any column, selected or not.
    var projectedSessionIDs: Set<String> { Set(panels.flatMap { $0.tabs.compactMap(\.sessionID) }) }

    /// Closes a session's tab wherever it is; used when it detaches into its own window.
    func closeSession(_ sessionID: String) {
        guard let panel = panels.first(where: { $0.tabs.contains { $0.sessionID == sessionID } }) else { return }
        closeTab(sessionID, in: panel.id)
    }

    func closeTab(_ sessionID: String, in panelID: String) {
        guard let index = panels.firstIndex(where: { $0.id == panelID }),
            let tab = panels[index].tabs.firstIndex(where: { $0.sessionID == sessionID })
        else { return }
        let wasSelected = panels[index].selectedID == sessionID
        panels[index].tabs.remove(at: tab)
        if !panels[index].tabs.isEmpty {
            if wasSelected, let next = panels[index].tabs[min(tab, panels[index].tabs.count - 1)].sessionID {
                if index == activeIndex {
                    activate(next, at: index)
                } else {
                    panels[index].selectedID = next
                    load(index)
                }
            }
        } else {
            let removed = panels.remove(at: index)
            removed.chat.shutdown()
            if index < activeIndex { activeIndex -= 1 }
            activeIndex = min(activeIndex, max(0, panels.count - 1))
            if removed.usesWorkspaceConversation { runtime?.newChat() }
        }
        updateFocusedProjection()
        collapseIfUnsplit()
    }

    /// Workspace navigation changes the workspace column's tab.
    func syncPrimary(_ sessionID: String?) {
        guard let runtime, !panels.isEmpty else { return }
        if workspacePanelIndex == nil, sessionID != nil { focusWorkspaceConversation() }
        guard let index = workspacePanelIndex else { return }
        guard let sessionID else {
            if let selected = panels[index].selected, selected.groupRoomID == nil { panels[index].selectedID = nil }
            return
        }
        if !panels[index].tabs.contains(where: { $0.sessionID == sessionID }) {
            let destination = QuickDestination(
                profileID: runtime.sessionProfileID, sessionID: sessionID,
                title: runtime.currentSessionTitle ?? "Session")
            if let selected = panels[index].tabs.firstIndex(where: { $0.sessionID == panels[index].selectedID }) {
                panels[index].tabs[selected] = destination
            } else {
                panels[index].tabs.append(destination)
            }
        }
        if panels[index].selectedID != sessionID {
            panels[index].selectedID = sessionID
            activeIndex = index
            updateFocusedProjection()
        }
    }

    /// Sessions and Bots each keep their own columns. Leaving a page parks its columns
    /// (projections shut down); returning restores them and resumes their active session.
    func showLayout(bots: Bool) {
        guard bots != showsBotsLayout else { return }
        refreshWorkspaceTitle()
        for panel in panels { panel.chat.shutdown() }
        parkedLayouts[showsBotsLayout] = (panels, activeIndex)
        showsBotsLayout = bots
        (panels, activeIndex) = parkedLayouts.removeValue(forKey: bots) ?? ([], 0)
        for index in panels.indices { load(index) }
        updateFocusedProjection()
    }

    func retry(_ panelID: String) {
        if let index = panels.firstIndex(where: { $0.id == panelID }) { load(index) }
    }

    private func primaryDestination(_ sessionID: String) -> QuickDestination {
        QuickDestination(
            profileID: runtime?.sessionProfileID, sessionID: sessionID,
            title: runtime?.currentSessionTitle ?? "Session")
    }

    private func refreshWorkspaceTitle() {
        guard let title = runtime?.currentSessionTitle, let index = workspacePanelIndex,
            runtime?.navigationSessionID == panels[index].selectedID,
            let tab = panels[index].tabs.firstIndex(where: { $0.sessionID == panels[index].selectedID }),
            panels[index].tabs[tab].title != title
        else { return }
        panels[index].tabs[tab].title = title
    }

    private func collapseIfUnsplit() {
        // A lone room tab stays: unsplit, the workspace shows only the main conversation.
        guard panels.count <= 1, (panels.first?.tabs.count ?? 0) <= 1, panels.first?.selected?.groupRoomID == nil,
            panels.first?.usesWorkspaceConversation != false
        else { return }
        panels.first?.chat.shutdown()
        panels = []
        activeIndex = 0
        updateFocusedProjection()
    }

    private func load(_ index: Int) {
        guard let runtime, let destination = panels[index].selected else { return }
        if panels[index].usesWorkspaceConversation {
            if destination.groupRoomID == nil, let session = destination.session,
                runtime.navigationSessionID != session.id
            {
                runtime.resumeSession(session, profileID: session.profileID)
            }
            return
        }
        let chat = panels[index].chat
        if destination.groupRoomID != nil {
            chat.shutdown()
            updateFocusedProjection()
            return
        }
        chat.onSessionIdentityChange = { [weak self, weak chat] model in
            guard let self, let chat, let index = panels.firstIndex(where: { $0.chat === chat }) else { return }
            synchronizeProjection(model, at: index)
        }
        chat.startLoad(destination, runtime: runtime)
        updateFocusedProjection()
    }

    private func synchronizeProjection(_ model: DockModel, at index: Int) {
        let selected = panels[index].selectedID
        guard selected != model.navigationSessionID else { return }
        if let id = model.navigationSessionID {
            let destination = QuickDestination(
                profileID: model.sessionProfileID, sessionID: id, title: model.currentSessionTitle ?? "Session")
            if let tab = panels[index].tabs.firstIndex(where: { $0.sessionID == selected }) {
                panels[index].tabs[tab] = destination
            } else if !panels[index].tabs.contains(where: { $0.sessionID == id }) {
                panels[index].tabs.append(destination)
            }
            panels[index].chat.retarget(destination)
        }
        panels[index].selectedID = model.navigationSessionID
    }
}

struct SessionPaneDropDelegate: DropDelegate {
    let store: SessionPaneStore
    let width: CGFloat
    let fractions: [CGFloat]
    /// The inspector's span beside the active column; drops map past it onto the columns.
    var inspectorStart: CGFloat = 0
    var inspectorWidth: CGFloat = 0
    let reduceMotion: Bool
    @Binding var target: SessionPaneTarget?
    /// Runs just before the dropped session opens, e.g. to seat a view that has no column yet.
    var prepare: (@MainActor () -> Void)?

    private var animation: Animation? { DockMotion.animation(reduceMotion: reduceMotion, duration: 0.28) }

    /// The pane type is not declared in the bundle, so its conformance check also matches
    /// Finder files and text drags; those belong to the composer, never the tab/column hints.
    static func isSessionPaneDrag(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [SessionPaneDrag.pasteboardType.rawValue])
            && !info.hasItemsConforming(to: [.fileURL, .url, .plainText, .image])
    }

    func validateDrop(info: DropInfo) -> Bool { Self.isSessionPaneDrag(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // AppKit can deliver one more update after `performDrop`; re-arming the hints then
        // would leave them stuck on screen. Mouse-button state is not a usable signal here:
        // it reads released during an AppKit drag session and with trackpad drag gestures.
        guard Self.isSessionPaneDrag(info), !store.dropPerformed else {
            if target != nil { target = nil }
            return DropProposal(operation: .cancel)
        }
        NSCursor.closedHand.set()
        let x = info.location.x
        let next = SessionPaneStore.dropTarget(
            x: x > inspectorStart ? max(inspectorStart, x - inspectorWidth) : x,
            width: width - inspectorWidth, columnCount: store.panels.count, fractions: fractions)
        if next != target { withAnimation(animation) { target = next } }
        return DropProposal(operation: .copy)
    }

    func dropEntered(info: DropInfo) {
        store.dropPerformed = false
    }

    func dropExited(info: DropInfo) {
        withAnimation(animation) { target = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let dropped = target,
            let provider = info.itemProviders(for: [SessionPaneDrag.pasteboardType.rawValue]).first
        else { return false }
        store.dropPerformed = true
        let store = store
        let animation = animation
        let prepare = prepare
        _ = provider.loadTransferable(type: SessionPaneDrag.self) { result in
            guard case .success(let payload) = result else { return }
            Task { @MainActor in
                withAnimation(animation) {
                    prepare?()
                    store.open(payload.destination, target: dropped)
                }
            }
        }
        withAnimation(animation) { target = nil }
        return true
    }
}

/// Sidebar statuses for the sessions open as split tabs, projected from the same
/// snapshot and resolver as the rail, so a tab never disagrees with its row.
@MainActor
final class SessionPaneTabStatusModel: ObservableObject {
    struct Entry: Equatable {
        let session: HermesSession
        let status: SidebarSessionStatus
    }

    @Published private(set) var entries: [String: Entry] = [:]
    private var sidebar: SessionNavSidebarModel?
    private var cancellable: AnyCancellable?

    /// Binds once; the window shell calls it on appear.
    func bind(model: DockModel, control: ControlCenterModel, store: WorkspaceStore, panes: SessionPaneStore) {
        guard sidebar == nil else { return }
        let sidebar = SessionNavSidebarModel.shared(model: model, control: control, store: store)
        self.sidebar = sidebar
        let seenStore = SidebarSessionSeenStore.shared
        cancellable = Publishers.Merge3(
            sidebar.$snapshot.map { _ in () },
            seenStore.objectWillChange.map { _ in () },
            panes.$panels.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .debounce(for: .milliseconds(1), scheduler: DispatchQueue.main)
        .sink { [weak self, weak panes] _ in
            guard let self, let panes else { return }
            let next = Self.project(sidebar.snapshot, panes: panes, seenStore: seenStore)
            if next != self.entries { self.entries = next }
        }
    }

    private static func project(
        _ snapshot: SessionNavSidebarSnapshot, panes: SessionPaneStore, seenStore: SidebarSessionSeenStore
    ) -> [String: Entry] {
        let open = Set(panes.panels.flatMap { $0.tabs.compactMap(\.sessionID) })
        guard !open.isEmpty else { return [:] }
        let sessions = (snapshot.conversations + snapshot.inputs.pinnedSessions + snapshot.allBotConversations)
            .filter { open.contains($0.id) }
        let statuses = SidebarSessionStatusResolver.statuses(
            for: sessions, snapshot: snapshot, seenStore: seenStore,
            fallbackProfileID: snapshot.inputs.profileScopeID)
        return Dictionary(
            sessions.compactMap { session in
                statuses[session.id].map { (session.id, Entry(session: session, status: $0)) }
            },
            uniquingKeysWith: { first, _ in first })
    }
}
