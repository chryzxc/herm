import Foundation

enum SessionSidebarVisibility: Int, CaseIterable {
    case pinned, projects, automations, unread, needsYou, running, archived

    var title: String {
        switch self {
        case .pinned: "Pinned"
        case .projects: "Projects"
        case .automations: "Automations"
        case .unread: "Unread"
        case .needsYou: "Needs you"
        case .running: "Running"
        case .archived: "Archived"
        }
    }

    private var bit: Int { 1 << rawValue }
    func isVisible(in hidden: Int) -> Bool { hidden & bit == 0 }
    func toggled(in hidden: Int) -> Int { hidden ^ bit }

    static func visibleSections(_ sections: [SessionRailSection], hidden: Int) -> [SessionRailSection] {
        sections.filter { section in
            switch section {
            case .pinned: pinned.isVisible(in: hidden)
            case .projects: projects.isVisible(in: hidden)
            case .automations: automations.isVisible(in: hidden)
            case .recents: true
            }
        }
    }
}

enum SessionSidebarFilter: CaseIterable {
    case all, unread, needsYou, running, archived

    var visibility: SessionSidebarVisibility? {
        switch self {
        case .all: nil
        case .unread: .unread
        case .needsYou: .needsYou
        case .running: .running
        case .archived: .archived
        }
    }

    var title: String { visibility?.title ?? "All" }

    func enabled(in hidden: Int) -> Self {
        visibility?.isVisible(in: hidden) == false ? .all : self
    }

    func matches(_ session: HermesSession, status: SidebarSessionStatus, isUnread: Bool) -> Bool {
        switch self {
        case .all: true
        case .unread: isUnread
        case .needsYou: status == .needsApproval
        case .running: status == .working || (session.isWorking && status == .needsClarification)
        // Archive membership is established by the archive-only projection.
        case .archived: false
        }
    }

    static func results(
        _ sessions: [HermesSession], query: String, profileID: String?,
        projectNames: [ProfileScopedID: String], fallbackProfileID: String? = nil
    ) -> [HermesSession] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<ProfileScopedID>()
        return sessions.filter { session in
            let key = ProfileScopedID(profileID: session.profileID ?? fallbackProfileID, resourceID: session.id)
            guard profileID == nil || profileID == key.profileID, seen.insert(key).inserted else { return false }
            return query.isEmpty
                || session.displayTitle.localizedCaseInsensitiveContains(query)
                || session.displayPreview?.localizedCaseInsensitiveContains(query) == true
                || projectNames[key]?.localizedCaseInsensitiveContains(query) == true
        }.sorted { ($0.lastUpdatedAt ?? .distantPast) > ($1.lastUpdatedAt ?? .distantPast) }
    }
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

struct SessionSidebarLiveStatus {
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
