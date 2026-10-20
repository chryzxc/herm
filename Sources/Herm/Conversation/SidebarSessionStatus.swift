import Foundation
import Combine

/// The small, semantic state marker shared by every session row in the
/// fullscreen navigation rail. It intentionally contains no view concerns so
/// the same state can drive accessibility, help, and rendering.
enum SidebarSessionStatus: Equatable, Codable {
    case working
    case needsApproval
    case needsClarification
    case failed
    case unreadComplete
    case none

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
        let isLive = session.isWorking || (session.id == activeSessionID && activeStatus == .working)
        if attention == .failure, !isLive { return .failed }

        if session.id == activeSessionID {
            if activeStatus == .needsApproval { return .needsApproval }
            if activeStatus == .needsClarification { return .needsClarification }
        }

        let lifecycle: SessionLifecycleStatus = {
            if session.id == activeSessionID, let activeStatus {
                switch activeStatus {
                case .needsApproval, .needsClarification: return .stale
                case .working: return .active
                case .idle: return .completed
                case .offline: return .unavailable
                }
            }
            // Only open sessions have a summary; the index row's own flags cover the rest.
            guard let summary else { return session.isWorking ? .active : .completed }
            return SessionLifecyclePresentation.status(for: summary)
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
}

/// Dock-owned, profile-scoped seen timestamps. Historical sessions are
/// baselined once per profile so enabling this feature never floods the rail
/// with unread markers; new completed updates naturally become unread again.
@MainActor
final class SidebarSessionSeenStore: ObservableObject {
    private struct Payload: Codable {
        var seenAt: [String: Date]
        var baselinedProfiles: Set<String>
    }

    private let defaults: UserDefaults
    private let storageKey = "hermes.sidebar.session-seen.v1"
    @Published private(set) var seenAtByKey: [String: Date]
    private(set) var baselinedProfiles: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            seenAtByKey = payload.seenAt
            baselinedProfiles = payload.baselinedProfiles
        } else {
            seenAtByKey = [:]
            baselinedProfiles = []
        }
    }

    func key(profileID: String?, sessionID: String) -> String {
        "\(profileID ?? "")|\(sessionID)"
    }

    func seenAt(profileID: String?, sessionID: String) -> Date? {
        seenAtByKey[key(profileID: profileID, sessionID: sessionID)]
    }

    func isBaselined(profileID: String?) -> Bool {
        baselinedProfiles.contains(profileID ?? "")
    }

    func baseline(profileID: String?, sessions: [HermesSession]) {
        let profileKey = profileID ?? ""
        guard !baselinedProfiles.contains(profileKey) else { return }
        let now = Date()
        for session in sessions {
            let storageKey = key(profileID: profileID, sessionID: session.id)
            seenAtByKey[storageKey] = session.lastUpdatedAt ?? now
        }
        baselinedProfiles.insert(profileKey)
        persist()
    }

    func markSeen(profileID: String?, sessionID: String, at date: Date? = nil) {
        let storageKey = key(profileID: profileID, sessionID: sessionID)
        let value = date ?? Date()
        guard seenAtByKey[storageKey] != value else { return }
        seenAtByKey[storageKey] = value
        persist()
    }

    func reconcile(profileID: String?, availableSessionIDs: Set<String>) {
        let prefix = "\(profileID ?? "")|"
        let retained = seenAtByKey.filter { key, _ in
            guard key.hasPrefix(prefix) else { return true }
            return availableSessionIDs.contains(String(key.dropFirst(prefix.count)))
        }
        guard retained.count != seenAtByKey.count else { return }
        seenAtByKey = retained
        persist()
    }

    private func persist() {
        let payload = Payload(seenAt: seenAtByKey, baselinedProfiles: baselinedProfiles)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
