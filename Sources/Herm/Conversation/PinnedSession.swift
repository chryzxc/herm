import Combine
import SwiftUI
import UniformTypeIdentifiers

enum PinnedSessionOrderScope: Hashable, Codable, Sendable {
    case all
    case profile(String?)
}

/// Pin membership belongs to Hermes. Only the presentation order is local.
@MainActor
final class PinnedSessionOrder: ObservableObject {
    @Published private var orders: [PinnedSessionOrderScope: [ProfileScopedID]]
    private let defaults: UserDefaults
    private static let key = "herm.sidebar.pinnedSessionOrder"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.orders =
            defaults.data(forKey: Self.key).flatMap {
                try? JSONDecoder().decode([PinnedSessionOrderScope: [ProfileScopedID]].self, from: $0)
            } ?? [:]
    }

    func ordered(_ sessions: [HermesSession], in scope: PinnedSessionOrderScope) -> [HermesSession] {
        guard let keys = orders[scope] else { return sessions }
        let ranks = Dictionary(
            keys.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return sessions.enumerated().sorted {
            (ranks[$0.element.scopedID] ?? keys.count + $0.offset)
                < (ranks[$1.element.scopedID] ?? keys.count + $1.offset)
        }.map(\.element)
    }

    func move(
        _ source: ProfileScopedID, relativeTo target: ProfileScopedID, after: Bool,
        sessions: [HermesSession], in scope: PinnedSessionOrderScope
    ) {
        let current = ordered(sessions, in: scope).map(\.scopedID)
        guard source != target, current.contains(source) else { return }
        var moved = current.filter { $0 != source }
        guard let index = moved.firstIndex(of: target) else { return }
        moved.insert(source, at: index + (after ? 1 : 0))
        guard moved != current else { return }
        let visible = Set(current)
        orders[scope] = moved + (orders[scope] ?? []).filter { !visible.contains($0) }
        defaults.set(try? JSONEncoder().encode(orders), forKey: Self.key)
    }
}

/// Only drags started in Pinned carry the reorder type. The proxy preserves opening a split pane.
struct PinnedSessionDrag: Codable, Equatable, Transferable {
    let session: SessionPaneDrag
    let scope: PinnedSessionOrderScope
    var id: ProfileScopedID { ProfileScopedID(profileID: session.profileID, resourceID: session.sessionID) }

    static let pasteboardType = "io.github.chryzxc.Herm.pinned-session"

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: pasteboardType, conformingTo: .data))
        ProxyRepresentation(exporting: \.session)
    }
}

struct PinnedSessionReorderTarget: ViewModifier {
    let enabled: Bool
    let move: @MainActor (PinnedSessionDrag, Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false
    @State private var after = false
    @State private var height: CGFloat = 0

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            dropTarget(content)
        } else {
            content
        }
    }

    private func dropTarget(_ content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                height = $0
            }
            .overlay(alignment: after ? .bottom : .top) {
                Capsule()
                    .fill(Color.dockAccent)
                    .frame(height: 2)
                    .scaleEffect(x: isTargeted ? 1 : 0.6, anchor: .leading)
                    .opacity(isTargeted ? 1 : 0)
                    .animation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.16), value: isTargeted)
                    .dockPadding(.horizontal, DockSidebarListMetrics.rowLeading)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onDrop(
                of: [PinnedSessionDrag.pasteboardType],
                delegate: SidebarListDropDelegate(
                    isTargeted: $isTargeted, onItem: { item, location in move(item, location.y >= height / 2) },
                    itemType: PinnedSessionDrag.pasteboardType,
                    onItemHover: { after = $0.y >= height / 2 },
                    animation: DockMotion.isEnabled(reduceMotion: reduceMotion) ? BotFolderMotion.spring : nil))
    }
}

enum PinnedSessionPresentationStatus: Equatable {
    case ready
    case empty
    case loading
    case stale(String)
    case unavailable(String)
    case failed(String)
}

/// The sidebar's Pinned section. Pins are Hermes' `sessions.pinned` flag; this
/// only prefers the live index row (working/unread state) when one exists.
struct PinnedSessionPresentation: Equatable {
    let sessions: [HermesSession]
    let status: PinnedSessionPresentationStatus

    init(
        pinned: [HermesSession],
        live: [HermesSession],
        projection: HermesProjectionState<[HermesSession]>,
        hasRequestedSessionIndex: Bool = true,
        matchesProfile: Bool = false,
        scopeProfileID: String? = nil
    ) {
        switch projection {
        case .ready, .empty, .stale, .loading:
            if pinned.isEmpty {
                sessions = []
            } else {
                func key(_ session: HermesSession) -> ProfileScopedID {
                    matchesProfile
                        ? AllProfilesSessions.pinKey(session, scopeProfileID: scopeProfileID)
                        : ProfileScopedID(profileID: nil, resourceID: session.id)
                }
                let liveByKey = Dictionary(live.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
                sessions = pinned.map { pin in
                    let pinKey = key(pin)
                    let row = liveByKey[pinKey] ?? pin
                    guard matchesProfile else { return row }
                    let owner = row.profileID ?? pinKey.profileID
                    // The live overlay can be the raw scan used by Recents. Keep its
                    // activity metadata without undoing a reconciled pin title.
                    guard row.title != pin.title || row.profileID != owner else { return row }
                    return HermesSession(
                        id: row.id, profileID: owner, title: pin.title, preview: row.preview, startedAt: row.startedAt,
                        updatedAt: row.updatedAt, messageCount: row.messageCount, source: row.source,
                        isHidden: row.isHidden, isWorking: row.isWorking, hasUnreadUpdate: row.hasUnreadUpdate,
                        isPinned: row.isPinned, modelName: row.modelName)
                }.sorted {
                    ($0.lastUpdatedAt ?? .distantPast) > ($1.lastUpdatedAt ?? .distantPast)
                }
            }
        case .unavailable, .failed:
            sessions = []
        }
        switch projection {
        case .ready: status = .ready
        case .empty: status = !hasRequestedSessionIndex ? .loading : .empty
        case .loading: status = .loading
        case .stale(_, let message): status = .stale(message)
        case .unavailable(let message): status = .unavailable(message)
        case .failed(let message): status = .failed(message)
        }
    }

    var count: Int { sessions.count }

    func selectedRow(_ selected: ProfileScopedID) -> HermesSession? {
        sessions.first { $0.scopedID == selected }
    }

    func withInitialRequestPending() -> Self {
        status == .empty ? Self(sessions: sessions, status: .loading) : self
    }

    private init(sessions: [HermesSession], status: PinnedSessionPresentationStatus) {
        self.sessions = sessions
        self.status = status
    }
}

struct PinnedSessionRowControls {
    let select: () -> Void
    let togglePin: () -> Void
}

enum PinnedSessionRowInteraction {
    static func select(
        _ sessionID: String,
        selectedSessionID: inout String?
    ) {
        selectedSessionID = sessionID
    }
}
