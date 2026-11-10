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

/// Where a session lands among the side panes: a new slot, or replacing a pane when full.
enum SessionPaneTarget: Equatable {
    case insert(Int)
    case replace(Int)
}

/// Side panes beside the primary conversation. Each pane is a disposable projection
/// (`EdgeQuickConversationModel`); Hermes owns the history, and panes are not persisted.
@MainActor
final class SessionPaneStore: ObservableObject {
    static let shared = SessionPaneStore()
    nonisolated static let maxSidePanes = 2

    struct Pane: Identifiable {
        let id: String
        let destination: QuickDestination
        let chat: EdgeQuickConversationModel
    }

    @Published private(set) var panes: [Pane] = []
    weak var runtime: DockModel?

    /// The slot under the cursor. Columns are equal width, so only the drop x, the
    /// row width and the pane count matter; the placeholder never feeds back into it.
    nonisolated static func dropTarget(x: CGFloat, width: CGFloat, sidePaneCount: Int) -> SessionPaneTarget {
        let columns = CGFloat(sidePaneCount + 1)
        let column = width > 0 ? x / (width / columns) : columns
        if sidePaneCount >= maxSidePanes {
            return .replace(min(max(Int(column.rounded(.down)) - 1, 0), sidePaneCount - 1))
        }
        return .insert(min(max(Int(column.rounded()) - 1, 0), sidePaneCount))
    }

    /// Nil when the session is already visible as the primary or a side pane.
    nonisolated static func placement(
        sessionID: String, primaryID: String?, openIDs: [String], target: SessionPaneTarget
    ) -> SessionPaneTarget? {
        guard sessionID != primaryID, !openIDs.contains(sessionID) else { return nil }
        let count = openIDs.count
        switch target {
        case .insert(let index) where count < maxSidePanes:
            return .insert(min(max(index, 0), count))
        case .insert(let index), .replace(let index):
            return count == 0 ? .insert(0) : .replace(min(max(index, 0), count - 1))
        }
    }

    func open(_ session: HermesSession) {
        open(SessionPaneDrag(session: session).destination, target: .insert(panes.count))
    }

    func open(_ destination: QuickDestination, target: SessionPaneTarget) {
        guard let runtime, let id = destination.sessionID,
            let placement = Self.placement(
                sessionID: id, primaryID: runtime.navigationSessionID, openIDs: panes.map(\.id), target: target)
        else { return }
        let pane = Pane(id: id, destination: destination, chat: EdgeQuickConversationModel())
        switch placement {
        case .insert(let index): panes.insert(pane, at: index)
        case .replace(let index):
            panes[index].chat.shutdown()
            panes[index] = pane
        }
        Task { await pane.chat.load(destination, runtime: runtime) }
    }

    func close(_ id: String) {
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return }
        panes.remove(at: index).chat.shutdown()
    }

    /// Swaps a side pane with the primary conversation, keeping the slot order.
    func promote(_ id: String) {
        guard let runtime, let index = panes.firstIndex(where: { $0.id == id }),
            let session = panes[index].destination.session
        else { return }
        let previousID = runtime.navigationSessionID
        let previous = QuickDestination(
            profileID: runtime.sessionProfileID, sessionID: previousID,
            title: runtime.currentSessionTitle ?? "Session")
        panes[index].chat.shutdown()
        runtime.resumeSession(session, profileID: session.profileID)
        guard let previousID else {
            panes.remove(at: index)
            return
        }
        let pane = Pane(id: previousID, destination: previous, chat: EdgeQuickConversationModel())
        panes[index] = pane
        Task { await pane.chat.load(previous, runtime: runtime) }
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
        let next = SessionPaneStore.dropTarget(x: info.location.x, width: width, sidePaneCount: store.panes.count)
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
