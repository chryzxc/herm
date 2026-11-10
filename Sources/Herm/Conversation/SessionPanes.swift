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

    init(session: HermesSession) {
        sessionID = session.id
        profileID = session.profileID
        title = session.displayTitle
    }

    var destination: QuickDestination { QuickDestination(profileID: profileID, sessionID: sessionID, title: title) }
}

/// Where a dropped session lands: a new panel at a slot, or a tab in an existing panel.
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

/// Side panels beside the primary conversation. Each panel is a tab group of
/// sessions; only its selected tab is loaded, into one disposable projection
/// (`EdgeQuickConversationModel`). Hermes owns the history; panels are not persisted.
@MainActor
final class SessionPaneStore: ObservableObject {
    static let shared = SessionPaneStore()
    nonisolated static let maxPanels = 2

    @MainActor struct Panel: Identifiable {
        let id = UUID().uuidString
        var tabs: [QuickDestination]
        var selectedID: String
        let chat = EdgeQuickConversationModel()
        var selected: QuickDestination? { tabs.first { $0.sessionID == selectedID } }
    }

    @Published private(set) var panels: [Panel] = []
    weak var runtime: DockModel?

    /// The column under the cursor. Columns are equal width, so only the drop x, the
    /// row width and the panel count matter; the placeholder never feeds back into it.
    /// The primary column and the trailing quarter of the last panel open a new panel
    /// while there is room; anywhere else adds a tab to the panel under the cursor.
    nonisolated static func dropTarget(x: CGFloat, width: CGFloat, panelCount: Int) -> SessionPaneTarget {
        let columnWidth = width / CGFloat(panelCount + 1)
        guard columnWidth > 0 else { return panelCount < maxPanels ? .newPanel(panelCount) : .tab(0) }
        let position = x / columnWidth
        let column = min(max(Int(position.rounded(.down)), 0), panelCount)
        let hasRoom = panelCount < maxPanels
        if column == 0 { return hasRoom ? .newPanel(0) : .tab(0) }
        if hasRoom, column == panelCount, position - CGFloat(column) > 0.75 { return .newPanel(panelCount) }
        return .tab(column - 1)
    }

    /// Nil when the session is already the primary conversation. A session already in
    /// a panel is selected there instead of opening twice.
    nonisolated static func resolve(
        sessionID: String, primaryID: String?, panelTabs: [[String]], target: SessionPaneTarget
    ) -> SessionPaneResolution? {
        guard sessionID != primaryID else { return nil }
        for (panel, tabs) in panelTabs.enumerated() {
            if let tab = tabs.firstIndex(of: sessionID) { return .select(panel: panel, tab: tab) }
        }
        let count = panelTabs.count
        switch target {
        case .newPanel(let index) where count < maxPanels:
            return .newPanel(min(max(index, 0), count))
        case .newPanel(let index), .tab(let index):
            return count == 0 ? .newPanel(0) : .addTab(min(max(index, 0), count - 1))
        }
    }

    func open(_ session: HermesSession) {
        let target: SessionPaneTarget = panels.count < Self.maxPanels ? .newPanel(panels.count) : .tab(panels.count - 1)
        open(SessionPaneDrag(session: session).destination, target: target)
    }

    func open(_ destination: QuickDestination, target: SessionPaneTarget) {
        guard let runtime, let id = destination.sessionID,
            let resolution = Self.resolve(
                sessionID: id, primaryID: runtime.navigationSessionID,
                panelTabs: panels.map { $0.tabs.compactMap(\.sessionID) }, target: target)
        else { return }
        switch resolution {
        case .newPanel(let index):
            panels.insert(Panel(tabs: [destination], selectedID: id), at: index)
            load(index)
        case .addTab(let index):
            panels[index].tabs.append(destination)
            select(id, in: panels[index].id)
        case .select(let panel, _):
            select(id, in: panels[panel].id)
        }
    }

    func select(_ sessionID: String, in panelID: String) {
        guard let index = panels.firstIndex(where: { $0.id == panelID }) else { return }
        guard panels[index].selectedID != sessionID else { return }
        panels[index].selectedID = sessionID
        load(index)
    }

    func retry(_ panelID: String) {
        if let index = panels.firstIndex(where: { $0.id == panelID }) { load(index) }
    }

    func closeTab(_ sessionID: String, in panelID: String) {
        guard let index = panels.firstIndex(where: { $0.id == panelID }),
            let tab = panels[index].tabs.firstIndex(where: { $0.sessionID == sessionID })
        else { return }
        panels[index].tabs.remove(at: tab)
        if panels[index].tabs.isEmpty {
            panels.remove(at: index).chat.shutdown()
        } else if panels[index].selectedID == sessionID {
            let next = panels[index].tabs[min(tab, panels[index].tabs.count - 1)]
            panels[index].selectedID = next.sessionID ?? ""
            load(index)
        }
    }

    /// A session opened as the primary conversation leaves the panels so it never streams twice.
    func remove(_ sessionID: String) {
        for panel in panels where panel.tabs.contains(where: { $0.sessionID == sessionID }) {
            closeTab(sessionID, in: panel.id)
        }
    }

    @discardableResult
    func moveTab(_ sessionID: String, before targetID: String, in panelID: String) -> Bool {
        guard let index = panels.firstIndex(where: { $0.id == panelID }), sessionID != targetID,
            let from = panels[index].tabs.firstIndex(where: { $0.sessionID == sessionID }),
            let to = panels[index].tabs.firstIndex(where: { $0.sessionID == targetID })
        else { return false }
        panels[index].tabs.insert(panels[index].tabs.remove(at: from), at: to)
        return true
    }

    /// Swaps a panel's selected tab with the primary conversation, keeping tab order.
    func promote(_ panelID: String) {
        guard let runtime, let index = panels.firstIndex(where: { $0.id == panelID }),
            let tab = panels[index].tabs.firstIndex(where: { $0.sessionID == panels[index].selectedID }),
            let session = panels[index].tabs[tab].session
        else { return }
        guard let previousID = runtime.navigationSessionID else {
            panels[index].chat.shutdown()
            runtime.resumeSession(session, profileID: session.profileID)
            closeTab(panels[index].selectedID, in: panelID)
            return
        }
        panels[index].tabs[tab] = QuickDestination(
            profileID: runtime.sessionProfileID, sessionID: previousID,
            title: runtime.currentSessionTitle ?? "Session")
        panels[index].selectedID = previousID
        panels[index].chat.shutdown()
        runtime.resumeSession(session, profileID: session.profileID)
        load(index)
    }

    private func load(_ index: Int) {
        guard let runtime, let destination = panels[index].selected else { return }
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
        let next = SessionPaneStore.dropTarget(x: info.location.x, width: width, panelCount: store.panels.count)
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
