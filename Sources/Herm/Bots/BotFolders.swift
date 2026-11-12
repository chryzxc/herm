import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A local folder on the Bots page. Folders are Herm-only organization; Hermes
/// knows nothing about them. `itemIDs` are `BotChatsItem.id` values.
struct BotFolder: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var itemIDs: [String]
    var isCollapsed: Bool

    init(id: UUID = UUID(), name: String, itemIDs: [String] = [], isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.itemIDs = itemIDs
        self.isCollapsed = isCollapsed
    }
}

/// Persists the Bots page folders as a local preference. Ids that Hermes no
/// longer lists are kept (a bot can be briefly missing) and skipped on render.
@MainActor
final class BotFolderStore: ObservableObject {
    static let shared = BotFolderStore()
    static let storageKey = "herm.bots.folders"

    @Published private(set) var folders: [BotFolder]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folders =
            defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode([BotFolder].self, from: $0) }
            ?? []
    }

    @discardableResult
    func create(name: String = "New Folder", containing itemID: String? = nil) -> UUID {
        var folder = BotFolder(name: name)
        if let itemID {
            remove(itemID)
            folder.itemIDs = [itemID]
        }
        folders.append(folder)
        persist()
        return folder.id
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = trimmed
        persist()
    }

    /// Deleting a folder returns its items to the top level.
    func delete(_ id: UUID) {
        folders.removeAll { $0.id == id }
        persist()
    }

    func toggleCollapsed(_ id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].isCollapsed.toggle()
        persist()
    }

    func folderID(containing itemID: String) -> UUID? {
        folders.first { $0.itemIDs.contains(itemID) }?.id
    }

    /// Moves an item into a folder, or to the top level when `folderID` is nil.
    /// An item lives in at most one folder.
    func move(_ itemID: String, to folderID: UUID?) {
        guard self.folderID(containing: itemID) != folderID else { return }
        remove(itemID)
        if let folderID, let index = folders.firstIndex(where: { $0.id == folderID }) {
            folders[index].itemIDs.append(itemID)
        }
        persist()
    }

    /// Places a folder before another, or last when `target` is nil.
    func moveFolder(_ id: UUID, before target: UUID?) {
        guard id != target, let from = folders.firstIndex(where: { $0.id == id }) else { return }
        let folder = folders.remove(at: from)
        let to = target.flatMap { target in folders.firstIndex { $0.id == target } } ?? folders.endIndex
        folders.insert(folder, at: to)
        persist()
    }

    private func remove(_ itemID: String) {
        for index in folders.indices { folders[index].itemIDs.removeAll { $0 == itemID } }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(folders) { defaults.set(data, forKey: Self.storageKey) }
    }
}

/// A folder header being dragged to reorder folders.
struct BotFolderDrag: Codable, Transferable {
    let folderID: UUID
    static let pasteboardType = NSPasteboard.PasteboardType("io.github.chryzxc.Herm.bot-folder")

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: pasteboardType.rawValue, conformingTo: .data))
    }
}

/// One folder and the listed items it holds, in activity order.
struct BotFolderSection: Identifiable {
    let folder: BotFolder
    let items: [BotChatsItem]
    var id: UUID { folder.id }
}

extension BotChatsOrdering {
    /// Splits the activity-ordered list into folders (in the user's order) and
    /// top-level items. A search flattens everything so matches are never hidden
    /// inside a collapsed folder.
    static func sections(_ items: [BotChatsItem], folders: [BotFolder], isSearching: Bool)
        -> (folders: [BotFolderSection], loose: [BotChatsItem])
    {
        guard !isSearching else { return ([], items) }
        var owner: [String: UUID] = [:]
        for folder in folders { for id in folder.itemIDs where owner[id] == nil { owner[id] = folder.id } }
        let grouped = Dictionary(grouping: items.filter { owner[$0.id] != nil }) { owner[$0.id]! }
        return (
            folders.map { BotFolderSection(folder: $0, items: grouped[$0.id] ?? []) },
            items.filter { owner[$0.id] == nil }
        )
    }

    /// The list item a split-view drag payload names: a group room by its tab
    /// prefix, else the bot whose main chat it is.
    static func itemID(for drag: SessionPaneDrag, bots: [BotSummary]) -> String? {
        if let roomID = drag.destination.groupRoomID { return "room:\(roomID)" }
        return bots.first { $0.chat?.sessionID == drag.sessionID }.map { "bot:\($0.id)" }
    }
}

/// "Move to Folder" for a row's menu: the drag-free path, also used by bots
/// that have no main chat yet (and so no drag payload).
struct BotFolderMoveMenu: View {
    let itemID: String
    @ObservedObject var folders: BotFolderStore = .shared
    var onCreated: (UUID) -> Void = { _ in }

    var body: some View {
        let current = folders.folderID(containing: itemID)
        DockMenu("Move to Folder", icon: .folderSimple) {
            ForEach(folders.folders.filter { $0.id != current }) { folder in
                Button(folder.name, icon: .folderSimple) {
                    withAnimation(BotFolderMotion.spring) { folders.move(itemID, to: folder.id) }
                }
            }
            Button("New Folder", icon: .folderSimplePlus) {
                var id = UUID()
                withAnimation(BotFolderMotion.spring) { id = folders.create(containing: itemID) }
                onCreated(id)
            }
        }
        if current != nil {
            Button("Remove from Folder", icon: .folderSimpleMinus) {
                withAnimation(BotFolderMotion.spring) { folders.move(itemID, to: nil) }
            }
        }
    }
}

enum BotFolderMotion {
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.85)
    /// The folder lifts and opens under a drag; bouncier than list moves.
    static let hover = Animation.spring(response: 0.28, dampingFraction: 0.55)
    /// How long a collapsed folder waits under a drag before springing open.
    static let springLoadDelay = Duration.milliseconds(650)
}

/// One drop target for both payloads the Bots list drags: a row (the split-view
/// `SessionPaneDrag`) and, when `onFolder` is set, a folder header.
struct BotListDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onItem: @MainActor (SessionPaneDrag) -> Void
    var onFolder: (@MainActor (BotFolderDrag) -> Void)?
    /// Called when a dragged folder (not a row) enters or leaves, so the target can open a gap.
    var onFolderHover: (@MainActor (Bool) -> Void)?

    private var types: [String] {
        [SessionPaneDrag.pasteboardType.rawValue] + (onFolder == nil ? [] : [BotFolderDrag.pasteboardType.rawValue])
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: types) }
    func dropEntered(info: DropInfo) {
        withAnimation(BotFolderMotion.spring) {
            isTargeted = true
            if info.hasItemsConforming(to: [BotFolderDrag.pasteboardType.rawValue]) { onFolderHover?(true) }
        }
    }
    func dropExited(info: DropInfo) {
        withAnimation(BotFolderMotion.spring) {
            isTargeted = false
            onFolderHover?(false)
        }
    }
    /// `.copy`: a SwiftUI `.draggable` source offers only copy, so a move proposal is refused.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        NSCursor.closedHand.set()
        return DropProposal(operation: .copy)
    }

    /// Rows first: `itemProviders(for:)` matches any of a provider's types, so asking for the
    /// folder type first can hand back a row's provider whose folder decode then fails silently.
    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        onFolderHover?(false)
        let rowType = SessionPaneDrag.pasteboardType.rawValue
        if info.hasItemsConforming(to: [rowType]), let provider = info.itemProviders(for: [rowType]).first {
            let onItem = onItem
            _ = provider.loadTransferable(type: SessionPaneDrag.self) { result in
                guard case .success(let payload) = result else { return }
                Task { @MainActor in withAnimation(BotFolderMotion.spring) { onItem(payload) } }
            }
            return true
        }
        guard let onFolder, let provider = info.itemProviders(for: [BotFolderDrag.pasteboardType.rawValue]).first
        else { return false }
        _ = provider.loadTransferable(type: BotFolderDrag.self) { result in
            guard case .success(let payload) = result else { return }
            Task { @MainActor in withAnimation(BotFolderMotion.spring) { onFolder(payload) } }
        }
        return true
    }
}
