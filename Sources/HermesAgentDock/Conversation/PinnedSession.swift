import Foundation
import Combine

struct PinnedSessionReference: Hashable, Codable, Sendable {
    let profileID: String
    let sessionID: String

    init(profileID: String, sessionID: String) {
        self.profileID = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionID = sessionID
    }
}

struct PinnedSessionState: Equatable, Codable, Sendable {
    private(set) var references: [PinnedSessionReference]

    init(references: [PinnedSessionReference] = []) {
        self.references = Self.deduplicated(references)
    }

    var count: Int { references.count }

    func contains(profileID: String, sessionID: String) -> Bool {
        references.contains(PinnedSessionReference(profileID: profileID, sessionID: sessionID))
    }

    func references(for profileID: String) -> [PinnedSessionReference] {
        references.filter { $0.profileID == profileID }
    }

    mutating func toggle(profileID: String, sessionID: String) {
        let reference = PinnedSessionReference(profileID: profileID, sessionID: sessionID)
        if let index = references.firstIndex(of: reference) {
            references.remove(at: index)
        } else {
            references.append(reference)
        }
    }

    @discardableResult
    mutating func reconcile(available: [PinnedSessionReference]) -> Bool {
        let availableSet = Set(available)
        let reconciled = references.filter { availableSet.contains($0) }
        guard reconciled != references else { return false }
        references = reconciled
        return true
    }

    @discardableResult
    mutating func reconcile(
        available: [PinnedSessionReference],
        profileID: String
    ) -> Bool {
        let availableSet = Set(available)
        let reconciled = references.filter { reference in
            reference.profileID != profileID || availableSet.contains(reference)
        }
        guard reconciled != references else { return false }
        references = reconciled
        return true
    }

    private static func deduplicated(_ references: [PinnedSessionReference]) -> [PinnedSessionReference] {
        var seen = Set<PinnedSessionReference>()
        return references.filter { seen.insert($0).inserted }
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

struct PinnedSessionPresentation: Equatable {
    let sessions: [HermesSession]
    let status: PinnedSessionPresentationStatus
    private let storedCount: Int

    init(sessions: [HermesSession], state: PinnedSessionState, profileID: String) {
        self.init(sessions: sessions, state: state, profileID: profileID, projection: .ready(sessions))
    }

    init(
        sessions: [HermesSession],
        state: PinnedSessionState,
        profileID: String,
        projection: HermesProjectionState<[HermesSession]>,
        hasRequestedSessionIndex: Bool = true
    ) {
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let references = state.references(for: profileID)
        let isInitialProjection = !hasRequestedSessionIndex && projection == .empty
        let projectedSessions: [HermesSession]
        switch projection {
        case .ready, .empty:
            projectedSessions = projection == .empty ? [] : references.compactMap { byID[$0.sessionID] }
        case .stale(let previousSessions, _):
            let previousByID = Dictionary(uniqueKeysWithValues: previousSessions.map { ($0.id, $0) })
            projectedSessions = references.compactMap { previousByID[$0.sessionID] }
        case .loading, .unavailable, .failed:
            projectedSessions = []
        }
        self.sessions = projectedSessions
        self.storedCount = references.count
        switch projection {
        case .ready:
            self.status = .ready
        case .empty:
            self.status = isInitialProjection ? .loading : .empty
        case .loading:
            self.status = .loading
        case .stale(_, let safeMessage):
            self.status = .stale(safeMessage)
        case .unavailable(let safeMessage):
            self.status = .unavailable(safeMessage)
        case .failed(let safeMessage):
            self.status = .failed(safeMessage)
        }
    }

    var count: Int { status == .ready || status == .empty ? sessions.count : storedCount }
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

enum PinnedSessionReconciliation {
    static func authoritativeReferences(
        sessions: [HermesSession],
        projection: HermesProjectionState<[HermesSession]>,
        profileID: String
    ) -> [PinnedSessionReference]? {
        switch projection {
        case .ready, .empty:
            return sessions.map {
                PinnedSessionReference(profileID: $0.profileID ?? profileID, sessionID: $0.id)
            }
        case .loading, .stale, .unavailable, .failed:
            return nil
        }
    }
}

final class PinnedSessionStore: ObservableObject {
    @Published private(set) var state: PinnedSessionState

    private let defaults: UserDefaults
    private let storageKey = "hermes.dock.pinned-sessions.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(PinnedSessionState.self, from: data) {
            state = saved
        } else {
            state = PinnedSessionState()
        }
    }

    func toggle(profileID: String, sessionID: String) {
        state.toggle(profileID: profileID, sessionID: sessionID)
        save()
    }

    @discardableResult
    func reconcile(available: [PinnedSessionReference]) -> Bool {
        guard state.reconcile(available: available) else { return false }
        save()
        return true
    }

    @discardableResult
    func reconcile(
        available: [PinnedSessionReference],
        profileID: String
    ) -> Bool {
        guard state.reconcile(available: available, profileID: profileID) else { return false }
        save()
        return true
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
