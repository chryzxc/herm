import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A sidebar session dragged toward the chat area to open beside the primary conversation.
struct SessionPaneDrag: Codable, Transferable {
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

    /// A Bot's canonical chat; nil until Hermes has created it (the roster then only knows its title).
    init?(bot: BotSummary) {
        guard let chat = bot.chat else { return nil }
        self.init(sessionID: chat.sessionID, profileID: chat.profileID, title: bot.name)
    }
}

extension View {
    /// Lets a sidebar row be dragged into the chat area to open in split view.
    @ViewBuilder
    func sessionPaneDraggable(_ drag: SessionPaneDrag?, isEnabled: Bool = true) -> some View {
        if let drag {
            draggable(drag) {
                HStack(spacing: 8) {
                    DockIcon(.chatCircle, size: 14, weight: .fill, color: .dockPrimaryText)
                    Text(drag.title)
                        .dockFont(.navigation, weight: .semibold)
                        .lineLimit(1)
                        .frame(maxWidth: 260, alignment: .leading)
                }
                .dockCard(padding: 10, isActive: true)
                .rotationEffect(.degrees(-2))
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

/// Split chat columns. Every column is a tab group of sessions; exactly one column is
/// active and shows its selected tab through the main `DockModel` (with the full header).
/// The other columns load their selected tab into a disposable projection
/// (`EdgeQuickConversationModel`). Hermes owns the history; columns are not persisted.
@MainActor
final class SessionPaneStore: ObservableObject {
    static let shared = SessionPaneStore()
    nonisolated static let maxColumns = 3
    /// The unsplit primary column keeps this id once split, so it never re-animates in.
    nonisolated static let baseColumnID = "session-pane-base"

    @MainActor struct Panel: Identifiable {
        var id = UUID().uuidString
        var tabs: [QuickDestination]
        var selectedID: String?
        let chat = EdgeQuickConversationModel()
        var selected: QuickDestination? { tabs.first { $0.sessionID == selectedID } }
    }

    /// Empty while unsplit; otherwise 2...3 columns, or 1 column holding several tabs.
    @Published private(set) var panels: [Panel] = []
    @Published private(set) var activeIndex = 0
    weak var runtime: DockModel?
    private var showsBotsLayout = false
    private var parkedLayouts: [Bool: (panels: [Panel], activeIndex: Int)] = [:]

    var activePanel: Panel? { panels.indices.contains(activeIndex) ? panels[activeIndex] : nil }

    /// Sessions on screen in any column; the sidebar highlights all of them.
    var shownSessionIDs: Set<String> { Set(panels.compactMap(\.selectedID)) }

    /// Share of the last column, at its trailing edge, that opens a new column; 0 when full.
    nonisolated static func newColumnZone(columnCount: Int) -> CGFloat {
        let count = max(columnCount, 1)
        return count >= maxColumns ? 0 : count == 1 ? 0.5 : 0.25
    }

    /// The column under the cursor; columns are equal width. The trailing zone of the
    /// last column opens a new column while there is room; anywhere else adds a tab to
    /// the column under the cursor, including the first.
    nonisolated static func dropTarget(x: CGFloat, width: CGFloat, columnCount: Int) -> SessionPaneTarget {
        let count = max(columnCount, 1)
        let columnWidth = width / CGFloat(count)
        guard columnWidth > 0 else { return .tab(0) }
        let position = x / columnWidth
        let column = min(max(Int(position.rounded(.down)), 0), count - 1)
        let zone = newColumnZone(columnCount: count)
        if zone > 0, column == count - 1, position - CGFloat(column) >= 1 - zone { return .newPanel(count) }
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

    /// Selecting a tab makes it the active session; the header moves to its column.
    private func select(_ sessionID: String, at index: Int) {
        guard let runtime, let session = panels[index].tabs.first(where: { $0.sessionID == sessionID })?.session
        else { return }
        if index != activeIndex {
            let previous = activeIndex
            refreshActiveTitle()
            panels[index].chat.shutdown()
            activeIndex = index
            // The old active column now projects its session; an unsaved new chat has none.
            if panels[previous].selected == nil { panels[previous].selectedID = panels[previous].tabs.first?.sessionID }
            if panels[previous].selected == nil {
                panels.remove(at: previous)
                if previous < activeIndex { activeIndex -= 1 }
            } else {
                load(previous)
            }
        }
        panels[activeIndex].selectedID = sessionID
        if runtime.navigationSessionID != sessionID { runtime.resumeSession(session, profileID: session.profileID) }
        collapseIfUnsplit()
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
                    select(next, at: index)
                } else {
                    panels[index].selectedID = next
                    load(index)
                }
            }
        } else if index != activeIndex {
            panels.remove(at: index).chat.shutdown()
            if index < activeIndex { activeIndex -= 1 }
        } else {
            // The active column emptied: the nearest column becomes active.
            panels.remove(at: index)
            activeIndex = max(0, min(index, panels.count - 1))
            if panels.indices.contains(activeIndex), let session = panels[activeIndex].selected?.session {
                panels[activeIndex].chat.shutdown()
                runtime?.resumeSession(session, profileID: session.profileID)
            }
        }
        collapseIfUnsplit()
    }

    /// Keeps the active column in step with sidebar navigation: a session already in a
    /// column activates it; any other session replaces the active tab (like navigating
    /// in a browser tab).
    func syncPrimary(_ sessionID: String?) {
        guard let sessionID, let runtime, panels.indices.contains(activeIndex) else { return }
        // A session already in another column activates that column instead of moving.
        if let column = panels.firstIndex(where: { $0.tabs.contains { $0.sessionID == sessionID } }),
            column != activeIndex
        {
            select(sessionID, at: column)
            return
        }
        let index = activeIndex
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
        panels[index].selectedID = sessionID
    }

    /// Sessions and Bots each keep their own columns. Leaving a page parks its columns
    /// (projections shut down); returning restores them and resumes their active session.
    func showLayout(bots: Bool) {
        guard bots != showsBotsLayout else { return }
        refreshActiveTitle()
        for panel in panels { panel.chat.shutdown() }
        parkedLayouts[showsBotsLayout] = (panels, activeIndex)
        showsBotsLayout = bots
        (panels, activeIndex) = parkedLayouts.removeValue(forKey: bots) ?? ([], 0)
        for index in panels.indices { load(index) }
        if let runtime, let session = activePanel?.selected?.session, runtime.navigationSessionID != session.id {
            runtime.resumeSession(session, profileID: session.profileID)
        }
    }

    func retry(_ panelID: String) {
        if let index = panels.firstIndex(where: { $0.id == panelID }) { load(index) }
    }

    private func primaryDestination(_ sessionID: String) -> QuickDestination {
        QuickDestination(
            profileID: runtime?.sessionProfileID, sessionID: sessionID,
            title: runtime?.currentSessionTitle ?? "Session")
    }

    private func refreshActiveTitle() {
        guard let title = runtime?.currentSessionTitle, panels.indices.contains(activeIndex),
            runtime?.navigationSessionID == panels[activeIndex].selectedID,
            let tab = panels[activeIndex].tabs.firstIndex(where: { $0.sessionID == panels[activeIndex].selectedID })
        else { return }
        panels[activeIndex].tabs[tab].title = title
    }

    private func collapseIfUnsplit() {
        guard panels.count <= 1, (panels.first?.tabs.count ?? 0) <= 1 else { return }
        panels.first?.chat.shutdown()
        panels = []
        activeIndex = 0
    }

    private func load(_ index: Int) {
        guard let runtime, index != activeIndex, let destination = panels[index].selected else { return }
        let chat = panels[index].chat
        Task { await chat.load(destination, runtime: runtime) }
    }
}

struct SessionPaneDropDelegate: DropDelegate {
    let store: SessionPaneStore
    let width: CGFloat
    let reduceMotion: Bool
    @Binding var target: SessionPaneTarget?

    private var animation: Animation? { DockMotion.animation(reduceMotion: reduceMotion, duration: 0.28) }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [SessionPaneDrag.pasteboardType.rawValue])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        NSCursor.closedHand.set()
        let next = SessionPaneStore.dropTarget(x: info.location.x, width: width, columnCount: store.panels.count)
        if next != target { withAnimation(animation) { target = next } }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        withAnimation(animation) { target = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let dropped = target,
            let provider = info.itemProviders(for: [SessionPaneDrag.pasteboardType.rawValue]).first
        else { return false }
        let store = store
        let animation = animation
        _ = provider.loadTransferable(type: SessionPaneDrag.self) { result in
            guard case .success(let payload) = result else { return }
            Task { @MainActor in withAnimation(animation) { store.open(payload.destination, target: dropped) } }
        }
        withAnimation(animation) { target = nil }
        return true
    }
}
