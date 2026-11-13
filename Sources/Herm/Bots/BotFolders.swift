import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A Bots page folder: a Hermes Agent Desktop bot section. A bot's membership
/// lives on its profile (`ui_meta['hermes-bots']` `sectionId`/`sectionName`), so
/// every client sees the same filing. The section list, its order, collapse
/// state and group-chat filing stay local, exactly as in Hermes Agent Desktop.
struct BotFolder: Codable, Identifiable, Equatable, Sendable {
    /// Hermes Agent Desktop's id format, `sec-<base36 ms>-<5 base36>`.
    let id: String
    var name: String
    /// Group-chat items only: a room has no profile to carry its section.
    var itemIDs: [String]
    var isCollapsed: Bool

    init(id: String = BotFolder.newID(), name: String, itemIDs: [String] = [], isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.itemIDs = itemIDs
        self.isCollapsed = isCollapsed
    }

    static func newID(now: Date = Date()) -> String {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let random = String((0..<5).map { _ in digits.randomElement()! })
        return "sec-\(String(Int(now.timeIntervalSince1970 * 1000), radix: 36))-\(random)"
    }
}

/// Bots page folders. The list persists as a local preference; bot membership
/// is read from the roster and written back to each bot's profile.
@MainActor
final class BotFolderStore: ObservableObject {
    static let shared = BotFolderStore()
    static let storageKey = "herm.bots.sections.v1"
    /// Pre-sync Herm-only folders; discarded in favor of the profile sections.
    static let legacyStorageKey = "herm.bots.folders"

    @Published private(set) var folders: [BotFolder]
    /// `bot:<id>` item → section id: the roster, with in-flight moves applied.
    @Published private(set) var botSections: [String: String] = [:]
    private var roster: [BotSummary] = []
    /// Bot id → the section a move is writing (`nil` = unassigned), until the roster shows it.
    private var pending: [String: String?] = [:]
    /// Deleted sections whose members are still being cleared; a member not yet
    /// cleared must not bring the section back.
    private var deleting: Set<String> = []
    private weak var bots: BotModeModel?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.removeObject(forKey: Self.legacyStorageKey)
        folders =
            defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode([BotFolder].self, from: $0) }
            ?? []
    }

    /// Takes the roster Hermes reports. Sections another client made are
    /// adopted from their members' `sectionName`; a known section takes the
    /// members' name only when they all agree (a finished rename elsewhere).
    func sync(_ roster: [BotSummary], model: BotModeModel? = nil) {
        if let model { bots = model }
        self.roster = roster
        let reported = Dictionary(roster.map { ($0.id, $0.sectionID) }, uniquingKeysWith: { first, _ in first })
        pending = pending.filter { id, section in reported[id].map { $0 != section } ?? false }

        var names: [String: Set<String>] = [:]
        for bot in roster {
            if let id = bot.sectionID, let name = bot.sectionName { names[id, default: []].insert(name) }
        }
        var next = folders.map { folder -> BotFolder in
            var folder = folder
            if let agreed = names[folder.id], agreed.count == 1, let name = agreed.first { folder.name = name }
            return folder
        }
        let known = Set(next.map(\.id))
        for id in names.keys.sorted() where !known.contains(id) && !deleting.contains(id) {
            next.append(BotFolder(id: id, name: names[id]!.sorted()[0]))
        }
        if next != folders {
            folders = next
            persist()
        }
        recompute()
    }

    @discardableResult
    func create(name: String = "New Folder", containing itemID: String? = nil) -> String {
        let folder = BotFolder(name: name)
        folders.append(folder)
        persist()
        if let itemID { move(itemID, to: folder.id) }
        return folder.id
    }

    /// Re-stamps the members too: the name on them is how other clients see a rename.
    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == id }), folders[index].name != trimmed
        else { return }
        folders[index].name = trimmed
        persist()
        file(members(of: id), in: id)
    }

    /// Deleting a folder returns its items to the top level; bots are cleared on their profiles.
    func delete(_ id: String) {
        let members = members(of: id)
        folders.removeAll { $0.id == id }
        persist()
        deleting.insert(id)
        file(members, in: nil) { [weak self] in self?.deleting.remove(id) }
    }

    func toggleCollapsed(_ id: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].isCollapsed.toggle()
        persist()
    }

    func folderID(containing itemID: String) -> String? {
        if itemID.hasPrefix("bot:") { return botSections[itemID] }
        return folders.first { $0.itemIDs.contains(itemID) }?.id
    }

    /// Moves an item into a folder, or to the top level when `folderID` is nil.
    /// An item lives in at most one folder.
    func move(_ itemID: String, to folderID: String?) {
        guard self.folderID(containing: itemID) != folderID else { return }
        if itemID.hasPrefix("bot:") {
            file([String(itemID.dropFirst(4))], in: folderID)
            return
        }
        for index in folders.indices { folders[index].itemIDs.removeAll { $0 == itemID } }
        if let folderID, let index = folders.firstIndex(where: { $0.id == folderID }) {
            folders[index].itemIDs.append(itemID)
        }
        persist()
    }

    /// Places a folder before another, or last when `target` is nil.
    func moveFolder(_ id: String, before target: String?) {
        guard id != target, let from = folders.firstIndex(where: { $0.id == id }) else { return }
        let folder = folders.remove(at: from)
        let to = target.flatMap { target in folders.firstIndex { $0.id == target } } ?? folders.endIndex
        folders.insert(folder, at: to)
        persist()
    }

    private func members(of id: String) -> [String] {
        roster.map(\.id).filter { botSections["bot:\($0)"] == id }
    }

    /// Shows the move at once, then writes one profile at a time (as Hermes
    /// Agent Desktop does). A failed write drops back to what Hermes reports.
    private func file(_ botIDs: [String], in sectionID: String?, completion: (@MainActor () -> Void)? = nil) {
        guard !botIDs.isEmpty else {
            completion?()
            return
        }
        for id in botIDs { pending[id] = .some(sectionID) }
        recompute()
        let model = bots
        Task { @MainActor in
            var failure: Error?
            for id in botIDs {
                // Deleted while earlier writes ran: do not refile into a missing section.
                let name = sectionID.flatMap { section in folders.first { $0.id == section }?.name }
                if sectionID != nil, name == nil { break }
                do {
                    guard let model else { throw CocoaError(.featureUnsupported) }
                    try await model.setSection(id: sectionID, name: name, for: id)
                } catch {
                    pending.removeValue(forKey: id)
                    failure = failure ?? error
                }
            }
            if let failure { DockActionErrorCenter.shared.report("Could not move Bot", error: failure) }
            await model?.refreshNow()
            for id in botIDs where pending[id] == .some(sectionID) { pending.removeValue(forKey: id) }
            if let model { sync(model.bots) } else { recompute() }
            completion?()
        }
    }

    private func recompute() {
        var next: [String: String] = [:]
        for bot in roster { if let section = bot.sectionID { next["bot:\(bot.id)"] = section } }
        for (id, section) in pending { next["bot:\(id)"] = section }
        if next != botSections { botSections = next }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(folders) { defaults.set(data, forKey: Self.storageKey) }
    }
}

/// A folder header being dragged to reorder folders.
struct BotFolderDrag: Codable, Transferable {
    let folderID: String
    static let pasteboardType = NSPasteboard.PasteboardType("io.github.chryzxc.Herm.bot-folder")

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: pasteboardType.rawValue, conformingTo: .data))
    }
}

/// One folder and the listed items it holds, in activity order.
struct BotFolderSection: Identifiable {
    let folder: BotFolder
    let items: [BotChatsItem]
    var id: String { folder.id }
}

extension BotChatsOrdering {
    /// Splits the activity-ordered list into folders (in the user's order) and
    /// top-level items. A search flattens everything so matches are never hidden
    /// inside a collapsed folder.
    /// Bots file by `botSections` (their profile's section), rooms by the
    /// folder's local `itemIDs`; an id naming no folder stays top level.
    static func sections(
        _ items: [BotChatsItem], folders: [BotFolder], botSections: [String: String] = [:], isSearching: Bool
    ) -> (folders: [BotFolderSection], loose: [BotChatsItem]) {
        guard !isSearching else { return ([], items) }
        let known = Set(folders.map(\.id))
        var owner = botSections.filter { $0.key.hasPrefix("bot:") && known.contains($0.value) }
        for folder in folders {
            for id in folder.itemIDs where !id.hasPrefix("bot:") && owner[id] == nil { owner[id] = folder.id }
        }
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
    var onCreated: (String) -> Void = { _ in }

    var body: some View {
        let current = folders.folderID(containing: itemID)
        DockMenu("Move to Folder", icon: .folderSimple) {
            ForEach(folders.folders.filter { $0.id != current }) { folder in
                Button(folder.name, icon: .folderSimple) {
                    withAnimation(BotFolderMotion.spring) { folders.move(itemID, to: folder.id) }
                }
            }
            Button("New Folder", icon: .folderSimplePlus) {
                var id = ""
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
