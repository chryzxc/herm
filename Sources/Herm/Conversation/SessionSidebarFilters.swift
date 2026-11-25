import Foundation

extension SessionRailSection {
    // The order defines the persisted hidden-option bits. Recents is always visible.
    static let filterOptions: [Self] = [.pinned, .projects, .automations, .unread, .needsYou, .running, .archived]
    static let defaultHiddenOptions = filterOptions.filter { $0 != .pinned && $0 != .projects }
        .reduce(0) { $1.toggled(in: $0) }

    var title: String {
        switch self {
        case .pinned: "Pinned"
        case .recents: "Recents"
        case .projects: "Projects"
        case .automations: "Automations"
        case .unread: "Unread"
        case .needsYou: "Needs you"
        case .running: "Running"
        case .archived: "Archived"
        }
    }

    private var bit: Int { Self.filterOptions.firstIndex(of: self).map { 1 << $0 } ?? 0 }
    func isVisible(in hidden: Int) -> Bool { hidden & bit == 0 }
    func toggled(in hidden: Int) -> Int { hidden ^ bit }
}

/// Filter membership must not reuse historical activity badges or bare session
/// IDs: the live/attention inputs and the seen store have different owners.
struct SessionSidebarFilterInventory {
    let inputs: SessionNavSidebarSnapshot.Inputs
    private let approvals: Set<ProfileScopedID>
    private let clarifications: Set<ProfileScopedID>
    private let running: Set<ProfileScopedID>
    private let unreadSessions: Set<ProfileScopedID>

    init(
        inputs: SessionNavSidebarSnapshot.Inputs, unreadSessions: Set<ProfileScopedID> = [],
        confirmedApprovals: Set<ProfileScopedID>? = nil,
        confirmedRunning: Set<ProfileScopedID>? = nil,
        activeProfileID: String? = nil
    ) {
        self.inputs = inputs
        self.unreadSessions = unreadSessions
        let scope = inputs.profileScopeID
        let active = inputs.activeSessionID.map {
            ProfileScopedID(profileID: activeProfileID ?? scope, resourceID: $0)
        }
        let liveByID = Dictionary(inputs.activeSessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var approvals = confirmedApprovals ?? []
        var clarifications = Set<ProfileScopedID>()
        var running = confirmedRunning ?? []
        for item in inputs.attention where item.state == .open {
            guard let id = item.reference.sessionID else { continue }
            let live = liveByID[id]
            let storedID = live?.storedSessionID ?? id
            guard let owner = live?.profileID else { continue }
            let key = ProfileScopedID(profileID: owner, resourceID: storedID)
            if item.kind == .approval, confirmedApprovals == nil { approvals.insert(key) }
            if item.kind == .clarification { clarifications.insert(key) }
        }
        for row in inputs.activeSessions where confirmedRunning == nil {
            let id = row.storedSessionID ?? row.id
            guard let owner = row.profileID else { continue }
            let key = ProfileScopedID(profileID: owner, resourceID: id)
            if Self.isRunning(row) { running.insert(key) }
        }
        if let active {
            // The foreground conversation can finish before the next active-list read.
            running.remove(active)
            if inputs.activeStatus == .working { running.insert(active) }
            if inputs.activeStatus == .needsApproval { approvals.insert(active) }
            if inputs.activeStatus == .needsClarification { clarifications.insert(active) }
        }
        self.approvals = approvals
        self.clarifications = clarifications
        self.running = running
    }

    static func isRunning(_ row: SessionSummary) -> Bool {
        ["starting", "working", "running", "busy", "streaming"].contains(row.state.lowercased())
    }

    func matches(_ session: HermesSession, section: SessionRailSection) -> Bool {
        switch section {
        case .unread: isUnread(session)
        case .needsYou: status(for: session) == .needsApproval
        case .running:
            switch status(for: session) {
            case .working: true
            case .needsClarification: session.isWorking
            default: false
            }
        // Archived rows come from the archive-only projection.
        case .archived: true
        default: false
        }
    }

    func results(
        _ sessions: [HermesSession], section: SessionRailSection, query: String, scope: SessionSidebarSearch.Scope,
        projectNames: [String: String]
    ) -> [HermesSession] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopedProfile = inputs.profileScopeID ?? "default"
        let profile = scope.selectedBotID ?? scopedProfile
        let projectProfile = inputs.projectProfileID ?? scopedProfile
        var seen = Set<ProfileScopedID>()
        return sessions.filter { session in
            let owner = session.profileID ?? scopedProfile
            let key = ProfileScopedID(profileID: owner, resourceID: session.id)
            guard scope.showsAllProfiles || owner == profile, scope.includes(session),
                matches(session, section: section), seen.insert(key).inserted
            else { return false }
            return query.isEmpty
                || session.displayTitle.localizedCaseInsensitiveContains(query)
                || session.displayPreview?.localizedCaseInsensitiveContains(query) == true
                || (owner == projectProfile
                    && projectNames[session.id]?.localizedCaseInsensitiveContains(query) == true)
        }.sorted { ($0.lastUpdatedAt ?? .distantPast) > ($1.lastUpdatedAt ?? .distantPast) }
    }

    func status(for session: HermesSession) -> SidebarSessionStatus {
        let key = ProfileScopedID(profileID: session.profileID ?? inputs.profileScopeID, resourceID: session.id)
        if approvals.contains(key) { return .needsApproval }
        if running.contains(key) { return .working }
        if clarifications.contains(key) { return .needsClarification }
        if session.isWorking { return .working }
        return isUnread(session) ? .unreadComplete : .none
    }

    func isUnread(_ session: HermesSession) -> Bool {
        let profileID = session.profileID ?? inputs.profileScopeID
        let key = ProfileScopedID(profileID: profileID, resourceID: session.id)
        return session.hasUnreadUpdate || unreadSessions.contains(key)
    }
}

struct SessionSidebarLiveStatus: Equatable {
    var ids: Set<ProfileScopedID> = []
    var isIncomplete = false
}

struct SessionSidebarArchive: Equatable, Sendable {
    enum Scope: Hashable, Sendable {
        case allProfiles
        case profile(String)

        var queryValue: String {
            switch self {
            case .allProfiles: "all"
            case .profile(let id): id
            }
        }

        func includes(_ profileID: String) -> Bool {
            switch self {
            case .allProfiles: true
            case .profile(let id): id == profileID
            }
        }
    }

    let sessions: [HermesSession]
    let isIncomplete: Bool
}
