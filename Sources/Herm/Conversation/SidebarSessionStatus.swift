import Combine
import Foundation

/// The small, semantic state marker shared by every session row in the
/// fullscreen navigation rail. It intentionally contains no view concerns so
/// the same state can drive accessibility, help, and rendering.
enum SidebarSessionStatus: Equatable, Codable, Sendable {
    case working
    case needsApproval
    case needsClarification
    case failed
    case unreadComplete
    case none

    var allowsUnreadCount: Bool { self == .unreadComplete || self == .none }

    var label: String {
        switch self {
        case .working: "Working"
        case .needsApproval: "Needs your approval"
        case .needsClarification: "Needs your answer"
        case .failed: "Failed"
        case .unreadComplete: "Completed with new activity"
        case .none: "No new status"
        }
    }

    var help: String { label }
}

enum SidebarSessionStatusResolver {
    static func resolve(
        session: HermesSession,
        summary: SessionSummary?,
        activeSessionID: String?,
        activeStatus: HermesStatus?,
        attention: SessionAttentionDot?,
        seenAt: Date?,
        isProfileBaselined: Bool
    ) -> SidebarSessionStatus {
        if attention == .warning { return .needsApproval }
        if attention == .clarification { return .needsClarification }
        // A failure from an earlier turn is stale once a new turn is running.
        let isLive = session.isWorking
        if attention == .failure, !isLive { return .failed }

        if session.id == activeSessionID {
            if activeStatus == .needsApproval { return .needsApproval }
            if activeStatus == .needsClarification { return .needsClarification }
        }

        let lifecycle: SessionLifecycleStatus = {
            if session.id == activeSessionID, let activeStatus {
                switch activeStatus {
                case .needsApproval, .needsClarification: return .stale
                // The open chat's own turn is observed directly, as the composer's Stop shows.
                case .working: return .active
                case .idle: return session.isWorking ? .active : .completed
                case .offline: return .unavailable
                }
            }
            // The session row is reconciled with the live gateway list. A separately
            // refreshed summary must neither hide new work nor revive a finished turn.
            if session.isWorking { return .active }
            guard let summary else { return .completed }
            let status = SessionLifecyclePresentation.status(for: summary)
            return status == .active ? .completed : status
        }()

        switch lifecycle {
        case .active: return .working
        case .failed: return .failed
        case .completed:
            if session.hasUnreadUpdate { return .unreadComplete }
            guard isProfileBaselined else { return .none }
            guard let updatedAt = session.lastUpdatedAt ?? summary?.lastUpdatedAt else { return .none }
            return updatedAt > (seenAt ?? .distantPast) ? .unreadComplete : .none
        case .stale, .unavailable: return .none
        }
    }

    /// One status per session from the same snapshot the rail renders, so the
    /// rail and the compact session picker always agree.
    @MainActor
    static func statuses(
        for sessions: [HermesSession],
        snapshot: SessionNavSidebarSnapshot,
        seenStore: SidebarSessionSeenStore,
        fallbackProfileID: String?
    ) -> [String: SidebarSessionStatus] {
        statuses(
            for: sessions, inputs: snapshot.inputs, attention: snapshot.attentionDots,
            seenAtByKey: seenStore.seenAtByKey, baselinedProfiles: seenStore.baselinedProfiles,
            fallbackProfileID: fallbackProfileID)
    }

    static func statuses(
        for sessions: [HermesSession], inputs: SessionNavSidebarSnapshot.Inputs,
        attention: [String: SessionAttentionDot], seenAtByKey: [String: Date], baselinedProfiles: Set<String>,
        fallbackProfileID: String? = nil
    ) -> [String: SidebarSessionStatus] {
        let summaries = Dictionary(
            inputs.activeSessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(
            sessions.map { session in
                (
                    session.id,
                    status(
                        for: session, summary: summaries[session.id], inputs: inputs, attention: attention[session.id],
                        seenAtByKey: seenAtByKey, baselinedProfiles: baselinedProfiles,
                        fallbackProfileID: fallbackProfileID)
                )
            }, uniquingKeysWith: { first, _ in first })
    }

    static func status(
        for session: HermesSession, summary: SessionSummary?, inputs: SessionNavSidebarSnapshot.Inputs,
        attention: SessionAttentionDot?, seenAtByKey: [String: Date], baselinedProfiles: Set<String>,
        fallbackProfileID: String? = nil
    ) -> SidebarSessionStatus {
        let profileID = session.profileID ?? inputs.profileScopeID ?? fallbackProfileID
        return resolve(
            session: session, summary: summary, activeSessionID: inputs.activeSessionID,
            activeStatus: inputs.activeStatus, attention: attention,
            seenAt: seenAtByKey[SidebarSessionSeenStore.key(profileID: profileID, sessionID: session.id)],
            isProfileBaselined: baselinedProfiles.contains(profileID ?? ""))
    }
}

/// Dock-owned, profile-scoped seen timestamps. Historical sessions are
/// baselined once per profile so enabling this feature never floods the rail
/// with unread markers; new completed updates naturally become unread again.
@MainActor
final class SidebarSessionSeenStore: ObservableObject {
    /// The rail and the session picker mark and read the same seen state.
    static let shared = SidebarSessionSeenStore()

    private struct Payload: Codable, Sendable {
        var seenAt: [String: Date]
        var baselinedProfiles: Set<String>
    }

    private let defaults: UserDefaults
    private let storageKey = "hermes.sidebar.session-seen.v1"
    @Published private(set) var seenAtByKey: [String: Date]
    private(set) var baselinedProfiles: Set<String>
    private enum Change {
        case sessions(Set<String>)
        case profile(String)
    }
    private let changes = PassthroughSubject<Change, Never>()
    private var persistence: Task<Void, Never>?
    private var needsPersistence = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        {
            seenAtByKey = payload.seenAt
            baselinedProfiles = payload.baselinedProfiles
        } else {
            seenAtByKey = [:]
            baselinedProfiles = []
        }
    }

    nonisolated static func key(profileID: String?, sessionID: String) -> String {
        "\(profileID ?? "")|\(sessionID)"
    }

    func seenAt(profileID: String?, sessionID: String) -> Date? {
        seenAtByKey[Self.key(profileID: profileID, sessionID: sessionID)]
    }

    func isBaselined(profileID: String?) -> Bool {
        baselinedProfiles.contains(profileID ?? "")
    }

    func changes(profileID: String?, sessionID: String) -> AnyPublisher<Void, Never> {
        let key = Self.key(profileID: profileID, sessionID: sessionID)
        return changes.filter { change in
            switch change {
            case .sessions(let keys): keys.contains(key)
            case .profile(let profile): profile == (profileID ?? "")
            }
        }.map { _ in () }.eraseToAnyPublisher()
    }

    func baseline(profileID: String?, sessions: [HermesSession]) {
        let profileKey = profileID ?? ""
        guard !baselinedProfiles.contains(profileKey) else { return }
        let now = Date()
        var next = seenAtByKey
        for session in sessions {
            let storageKey = Self.key(profileID: profileID, sessionID: session.id)
            next[storageKey] = session.lastUpdatedAt ?? now
        }
        baselinedProfiles.insert(profileKey)
        // Baseline membership also drives the unread projection.
        seenAtByKey = next
        changes.send(.profile(profileKey))
        persist()
    }

    func markSeen(_ sessions: [HermesSession], fallbackProfileID: String?, at date: Date?) {
        var next = seenAtByKey
        var touched = Set<String>()
        let now = Date()
        for session in sessions {
            let key = Self.key(profileID: session.profileID ?? fallbackProfileID, sessionID: session.id)
            next[key] = date ?? session.lastUpdatedAt ?? now
            touched.insert(key)
        }
        let changed = touched.filter { next[$0] != seenAtByKey[$0] }
        guard !changed.isEmpty else { return }
        seenAtByKey = next
        changes.send(.sessions(changed))
        persist()
    }

    func markSeen(profileID: String?, sessionID: String, at date: Date? = nil) {
        let storageKey = Self.key(profileID: profileID, sessionID: sessionID)
        let value = date ?? Date()
        guard seenAtByKey[storageKey] != value else { return }
        seenAtByKey[storageKey] = value
        changes.send(.sessions([storageKey]))
        persist()
    }

    func reconcile(profileID: String?, availableSessionIDs: Set<String>) {
        let prefix = "\(profileID ?? "")|"
        let removed = Set(
            seenAtByKey.keys.filter { key in
                key.hasPrefix(prefix) && !availableSessionIDs.contains(String(key.dropFirst(prefix.count)))
            })
        guard !removed.isEmpty else { return }
        var retained = seenAtByKey
        for key in removed {
            retained.removeValue(forKey: key)
        }
        seenAtByKey = retained
        changes.send(.sessions(removed))
        persist()
    }

    private func persist() {
        needsPersistence = true
        guard persistence == nil else { return }
        persistence = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            await self?.persistPendingChanges()
        }
    }

    private func persistPendingChanges() async {
        while needsPersistence && !Task.isCancelled {
            needsPersistence = false
            let payload = Payload(seenAt: seenAtByKey, baselinedProfiles: baselinedProfiles)
            let data = await Task.detached(priority: .utility) { try? JSONEncoder().encode(payload) }.value
            guard !Task.isCancelled else { return }
            if let data { defaults.set(data, forKey: storageKey) }
        }
        persistence = nil
    }

    func flushPersistence() {
        guard let persistence else { return }
        persistence.cancel()
        self.persistence = nil
        needsPersistence = false
        let payload = Payload(seenAt: seenAtByKey, baselinedProfiles: baselinedProfiles)
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
