import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct RichArtifactReference: Codable, Equatable, Hashable, Sendable, Identifiable {
    let profileID: String?
    let sessionID: String
    let rowID: Int?
    let messageUID: String?
    let surfaceID: String
    let sourceDigest: String

    var id: String {
        Self.digest(
            [
                profileID == nil ? "nil" : "profile:" + profileID!, sessionID,
                messageUID.map { "uid:" + $0 } ?? "row:" + (rowID.map(String.init) ?? "pending"),
                surfaceID, sourceDigest,
            ].map { "\($0.utf8.count):\($0)" }.joined())
    }
    var presentationKey: String {
        Self.digest(
            [
                profileID == nil ? "nil" : "profile:" + profileID!, sessionID,
                rowID.map { "row:\($0)" } ?? messageUID.map { "uid:" + $0 } ?? "pending",
                surfaceID, sourceDigest,
            ].map { "\($0.utf8.count):\($0)" }.joined())
    }
    func matches(_ other: Self) -> Bool {
        guard profileID == other.profileID, sessionID == other.sessionID,
            surfaceID == other.surfaceID, sourceDigest == other.sourceDigest
        else { return false }
        if let messageUID, let uid = other.messageUID { return messageUID == uid }
        return rowID != nil && rowID == other.rowID
    }
    var isStored: Bool { messageUID.map { !$0.isEmpty } == true || rowID.map { $0 > 0 } == true }
    static func digest(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct RichArtifactBookmark: Codable, Equatable, Identifiable {
    let reference: RichArtifactReference
    let title: String
    let sessionTitle: String
    var id: String { reference.id }
}

/// A live row may acquire its stored reference; changed content or another row must start fresh.
struct RichArtifactPresentationIdentity: Equatable {
    let key: String
    let reference: RichArtifactReference?
    let messageID: UUID?

    func canMigrate(to next: Self) -> Bool {
        guard key != next.key, let previous = reference, let current = next.reference,
            previous.profileID == current.profileID, previous.sessionID == current.sessionID,
            previous.surfaceID == current.surfaceID, previous.sourceDigest == current.sourceDigest
        else { return false }
        if previous.isStored { return previous.matches(current) }
        return current.isStored && messageID != nil && messageID == next.messageID
    }
}

enum RichSelectionIdentity {
    static func block(_ id: String) -> String { "block:" + id }
    static func dataset(_ id: String) -> String { "dataset:" + id }
    static func edge(_ id: String) -> String { "edge:" + id }
}

struct ArtifactResourceBookmark: Codable, Equatable, Identifiable {
    let value: String
    let sessionID: String
    let profileID: String?
    let sessionTitle: String
    let timestamp: Date
    var id: String { record.id }
    var record: ArtifactRecord {
        ArtifactRecord(
            value: value, sessionID: sessionID, sessionTitle: sessionTitle, timestamp: timestamp, profileID: profileID)
    }
}

@MainActor
final class RichArtifactPresentationState: ObservableObject {
    struct Snapshot: Codable, Equatable {
        var values: [String: [String]] = [:]
        var selected: [String: String] = [:]
        var queries: [String: String] = [:]
        var sortColumns: [String: Int] = [:]
        var descending: Set<String> = []
        var checked: Set<String> = []
        var expanded: Set<String> = []
        var numbers: [String: Double] = [:]
    }
    @Published var snapshot: Snapshot { didSet { persist() } }
    private let key: String
    private let store: WorkspacePresentationStore
    init(key: String, store: WorkspacePresentationStore = .shared) {
        self.key = key
        self.store = store
        snapshot =
            store.defaultsData("rich-state:" + key).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
            ?? Snapshot()
    }
    func reset() { snapshot = Snapshot() }
    private func persist() {
        // User inputs are presentation drafts, never credentials or provider records.
        guard let data = try? JSONEncoder().encode(snapshot), data.count <= 65_536,
            let text = String(data: data, encoding: .utf8), RichContentRedaction.text(text, limit: text.count) == text
        else { return }
        store.saveData(data, identity: "rich-state:" + key)
    }
    func selection(_ blockID: String) -> Binding<String> {
        Binding(get: { self.snapshot.selected[blockID] ?? "" }, set: { self.snapshot.selected[blockID] = $0 })
    }
    func query(_ blockID: String) -> Binding<String> {
        Binding(
            get: { self.snapshot.queries[blockID] ?? "" },
            set: { self.snapshot.queries[blockID] = String($0.prefix(1_000)) })
    }
    func number(_ id: String, default value: Double) -> Binding<Double> {
        Binding(get: { self.snapshot.numbers[id] ?? value }, set: { if $0.isFinite { self.snapshot.numbers[id] = $0 } })
    }
    func expanded(_ id: String) -> Binding<Bool> {
        Binding(
            get: { self.snapshot.expanded.contains(id) },
            set: {
                if $0 { self.snapshot.expanded.insert(id) } else { self.snapshot.expanded.remove(id) }
            })
    }
    func checked(_ itemID: String) -> Binding<Bool> {
        Binding(
            get: { self.snapshot.checked.contains(itemID) },
            set: {
                if $0 { self.snapshot.checked.insert(itemID) } else { self.snapshot.checked.remove(itemID) }
            })
    }
}

@MainActor
final class RichArtifactStateStore: ObservableObject {
    static let shared = RichArtifactStateStore()
    @Published private(set) var bookmarks: [RichArtifactBookmark]
    @Published private(set) var resourceBookmarks: [ArtifactResourceBookmark]
    private var states: [String: RichArtifactPresentationState] = [:]
    private var forms: [String: RichFormDraft] = [:]
    private let store: WorkspacePresentationStore
    init(store: WorkspacePresentationStore = .shared) {
        self.store = store
        resourceBookmarks =
            store.defaultsData("rich-resource-bookmarks").flatMap {
                try? JSONDecoder().decode([ArtifactResourceBookmark].self, from: $0)
            } ?? []
        bookmarks =
            store.defaultsData("rich-bookmarks").flatMap {
                try? JSONDecoder().decode([RichArtifactBookmark].self, from: $0)
            } ?? []
    }
    func isSaved(_ record: ArtifactRecord) -> Bool {
        if let reference = record.generated?.reference ?? record.unavailableBookmark?.reference {
            return bookmarks.contains { $0.reference.matches(reference) }
        }
        return resourceBookmarks.contains { $0.id == record.id }
    }
    func toggleResource(_ record: ArtifactRecord) {
        guard record.kind != .interactive, !record.value.isEmpty else { return }
        if resourceBookmarks.contains(where: { $0.id == record.id }) {
            resourceBookmarks.removeAll { $0.id == record.id }
        } else {
            resourceBookmarks.append(
                .init(
                    value: record.value, sessionID: record.sessionID,
                    profileID: record.profileID, sessionTitle: record.sessionTitle, timestamp: record.timestamp))
        }
        if let data = try? JSONEncoder().encode(resourceBookmarks), data.count <= 1_048_576 {
            store.saveData(data, identity: "rich-resource-bookmarks")
        }
    }
    func state(for key: String) -> RichArtifactPresentationState {
        if let state = states[key] { return state }
        let state = RichArtifactPresentationState(key: key, store: store)
        states[key] = state
        return state
    }
    func form(for key: String) -> RichFormDraft {
        if let value = forms[key] { return value }
        let state = state(for: key)
        let draft = RichFormDraft()
        draft.values = state.snapshot.values
        draft.onValuesChanged = { state.snapshot.values = $0 }
        forms[key] = draft
        return draft
    }
    func migrate(from oldKey: String, to newKey: String) {
        guard oldKey != newKey else { return }
        let previous = state(for: oldKey)
        let current = state(for: newKey)
        if current.snapshot == .init() { current.snapshot = previous.snapshot }
        for (key, draft) in Array(forms) where key.hasPrefix(oldKey + ":") {
            let replacement = newKey + key.dropFirst(oldKey.count)
            let saved = state(for: replacement)
            if saved.snapshot.values.isEmpty { saved.snapshot.values = draft.values }
            draft.onValuesChanged = { saved.snapshot.values = $0 }
            forms[replacement] = draft
            forms.removeValue(forKey: key)
        }
    }
    func resetForms(prefix: String) {
        for (key, draft) in forms where key.hasPrefix(prefix + ":") { draft.values = [:] }
    }
    func reconcile(_ references: [RichArtifactReference]) {
        let updated = bookmarks.map { bookmark in
            if let current = references.first(where: { $0.matches(bookmark.reference) }) {
                return RichArtifactBookmark(
                    reference: current, title: bookmark.title, sessionTitle: bookmark.sessionTitle)
            }
            return bookmark
        }
        if updated != bookmarks {
            bookmarks = updated
            persistBookmarks()
        }
    }
    private func persistBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks), data.count <= 1_048_576 {
            store.saveData(data, identity: "rich-bookmarks")
        }
    }
    func toggle(_ bookmark: RichArtifactBookmark) {
        guard bookmark.reference.isStored else { return }
        if bookmarks.contains(where: { $0.reference.matches(bookmark.reference) }) {
            bookmarks.removeAll { $0.reference.matches(bookmark.reference) }
        } else {
            bookmarks.append(bookmark)
        }
        persistBookmarks()
    }
}

enum RichArtifactExport {
    static func document(source: String) throws -> Data {
        guard source.utf8.count <= RichDocument.maximumBytes,
            let surface = try? JSONDecoder().decode(RichSurface.self, from: Data(source.utf8)), surface.validate()
        else {
            throw QuickDraftError.message("This visual reply cannot be exported because its format is unavailable.")
        }
        return Data(source.utf8)
    }
    @MainActor static func save(surface: RichSurface, source: String, html: Bool = false) async throws {
        let validated = try document(source: source)
        let data = html ? Data((surface.html ?? "").utf8) : validated
        let panel = NSSavePanel()
        panel.allowedContentTypes = [html ? .html : .json]
        panel.nameFieldStringValue = html ? "interactive.html" : "artifact.herm-ui.json"
        guard await panel.begin() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
    }
}

private struct RichArtifactReferenceKey: EnvironmentKey {
    static let defaultValue: RichArtifactReference? = nil
}
extension EnvironmentValues {
    var richArtifactReference: RichArtifactReference? {
        get { self[RichArtifactReferenceKey.self] }
        set { self[RichArtifactReferenceKey.self] = newValue }
    }
}

extension RichArtifactPresentationState {
    func selectionText(in surface: RichSurface) -> String {
        var parts: [String] = []
        for dataset in surface.datasets ?? [] {
            if let row = dataset.rows.first(where: {
                $0.id == snapshot.selected[RichSelectionIdentity.dataset(dataset.id)]
            }) {
                parts.append(zip(dataset.columns, row.values).map { "\($0.title): \($1)" }.joined(separator: ", "))
            }
        }
        for (index, block) in (surface.blocks ?? []).enumerated() {
            let id = block.id ?? block.type.rawValue
            let selected = snapshot.selected[RichSelectionIdentity.block(id)]
            switch block.payload {
            case .comparison(let value):
                if let item = value.options.first(where: { $0.id == selected }) {
                    parts.append(
                        item.title + ": "
                            + zip(value.criteria, item.values).map { "\($0): \($1)" }.joined(separator: ", "))
                }
            case .graph(let value):
                if let item = value.nodes.first(where: { $0.id == selected }) {
                    parts.append(item.title + "\n" + (item.detail ?? ""))
                }
                if let edge = snapshot.selected[RichSelectionIdentity.edge(id)], let index = Int(edge),
                    value.edges.indices.contains(index)
                {
                    let edge = value.edges[index]
                    let source = value.nodes.first { $0.id == edge.source }?.title ?? edge.source
                    let target = value.nodes.first { $0.id == edge.target }?.title ?? edge.target
                    parts.append(source + " → " + target + (edge.label.map { ": " + $0 } ?? ""))
                }
            case .timeline(let value):
                if let item = value.items.first(where: { $0.id == selected }) {
                    parts.append(item.title + "\n" + (item.detail ?? ""))
                }
            case .checklist(let value):
                parts += value.items.filter { snapshot.checked.contains(id + ":" + $0.id) }.map(\.title)
            default:
                if let rowID = snapshot.selected[RichSelectionIdentity.dataset("legacy:\(index)")],
                    let row = Int(rowID),
                    let rows = block.rows, rows.indices.contains(row)
                {
                    parts.append(zip(block.columns ?? [], rows[row]).map { "\($0): \($1)" }.joined(separator: ", "))
                }
                if let pointID = snapshot.selected[RichSelectionIdentity.dataset("legacy-chart:\(index)")],
                    let point = Int(pointID),
                    let points = block.points, points.indices.contains(point)
                {
                    parts.append("\(points[point].label): \(points[point].value)")
                }
            }
        }
        return parts.isEmpty ? "No items selected." : String(parts.joined(separator: "\n").prefix(12_000))
    }
}

extension RichArtifactPresentationState.Snapshot {
    private enum CodingKeys: String, CodingKey {
        case values, selected, queries, sortColumns, descending, checked, expanded, numbers
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.values = try values.decodeIfPresent([String: [String]].self, forKey: .values) ?? [:]
        selected = try values.decodeIfPresent([String: String].self, forKey: .selected) ?? [:]
        queries = try values.decodeIfPresent([String: String].self, forKey: .queries) ?? [:]
        sortColumns = try values.decodeIfPresent([String: Int].self, forKey: .sortColumns) ?? [:]
        descending = try values.decodeIfPresent(Set<String>.self, forKey: .descending) ?? []
        checked = try values.decodeIfPresent(Set<String>.self, forKey: .checked) ?? []
        expanded = try values.decodeIfPresent(Set<String>.self, forKey: .expanded) ?? []
        numbers = try values.decodeIfPresent([String: Double].self, forKey: .numbers) ?? [:]
    }
}
