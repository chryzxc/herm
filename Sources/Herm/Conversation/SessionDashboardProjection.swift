import Foundation

/// Dashboard rows share the sidebar's canonical session and attention projection.
enum SessionDashboardSection: String, CaseIterable, Identifiable {
    case attention = "Needs you"
    case review = "Ready to review"
    case working = "In progress"
    case recent = "Recent"

    var id: Self { self }

    static func section(for status: SidebarSessionStatus) -> Self {
        switch status {
        case .needsApproval, .needsClarification, .failed: .attention
        case .unreadComplete: .review
        case .working: .working
        case .none: .recent
        }
    }
}

struct SessionDashboardRow: Identifiable, Equatable {
    let session: HermesSession
    let status: SidebarSessionStatus
    let project: String?
    var id: String { session.id }
    var section: SessionDashboardSection { .section(for: status) }
    /// A running chat's update time moves every poll; its start keeps tiles from reshuffling.
    var sortDate: Date {
        (status == .working ? session.startedAt : nil) ?? session.lastUpdatedAt ?? .distantPast
    }
}

enum SessionDashboardProjection {
    static func aliases(in snapshot: SessionNavSidebarSnapshot) -> [String: String] {
        Dictionary(
            snapshot.inputs.activeSessions.filter {
                $0.profileID == nil || ($0.profileID ?? "default") == (snapshot.inputs.profileScopeID ?? "default")
            }.compactMap { summary in
                summary.storedSessionID.map { (summary.id, $0) }
            }, uniquingKeysWith: { first, _ in first })
    }

    static func sessions(in snapshot: SessionNavSidebarSnapshot) -> [HermesSession] {
        let aliases = aliases(in: snapshot)
        // Saved records own identity and visibility; a live runtime alias is not another chat.
        // Every bot's chats share one board; the all-bot scan covers the unselected bots.
        let saved = snapshot.inputs.sessions + snapshot.inputs.pinnedSessions + snapshot.allBotConversations
        let savedIDs = Set(saved.map(\.id))
        let known = saved.filter { session in
            guard let storedID = aliases[session.id], storedID != session.id else { return true }
            return !savedIDs.contains(storedID)
        }.map { session in
            guard let id = aliases[session.id], id != session.id else { return session }
            return HermesSession(
                id: id, profileID: session.profileID, title: session.title, preview: session.preview,
                startedAt: session.startedAt, updatedAt: session.updatedAt, messageCount: session.messageCount,
                source: session.source, isHidden: session.isHidden, isWorking: session.isWorking,
                hasUnreadUpdate: session.hasUnreadUpdate, isPinned: session.isPinned, modelName: session.modelName)
        }

        let knownIDs = Set(known.map(\.id))
        let active = snapshot.inputs.activeSessions.filter { !knownIDs.contains(aliases[$0.id] ?? $0.id) }.map {
            summary in
            HermesSession(
                id: aliases[summary.id] ?? summary.id, profileID: summary.profileID ?? snapshot.inputs.profileScopeID,
                title: summary.title, preview: summary.preview ?? "", startedAt: nil,
                updatedAt: summary.updatedAt, messageCount: 0, source: HermesFeatureIDs.sessionSource,
                isWorking: SessionLifecyclePresentation.status(for: summary) == .active)
        }
        return known + active
    }

    static func rows(
        sessions: [HermesSession], statuses: [String: SidebarSessionStatus],
        projects: [String: String], query: String = "", project: String? = nil
    ) -> [SessionDashboardRow] {
        var seen = Set<ProfileScopedID>()
        let rows = sessions.compactMap { session -> SessionDashboardRow? in
            guard seen.insert(session.scopedID).inserted, !session.isHidden else { return nil }
            return SessionDashboardRow(
                session: session, status: statuses[session.id] ?? .none, project: projects[session.id])
        }.sorted {
            let left = $0.sortDate
            let right = $1.sortDate
            return left == right ? $0.id < $1.id : left > right
        }
        return filter(rows, query: query, project: project)
    }

    /// Search and project filters only narrow already-projected rows, so typing never re-resolves statuses.
    static func filter(_ rows: [SessionDashboardRow], query: String, project: String?) -> [SessionDashboardRow] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty || project != nil else { return rows }
        return rows.filter { row in
            guard project == nil || row.project == project else { return false }
            return query.isEmpty
                || [row.session.displayTitle, row.session.displayPreview ?? "", row.project ?? ""]
                    .contains(where: { $0.localizedCaseInsensitiveContains(query) })
        }
    }
}

/// The board's projection of one sidebar snapshot. It is rebuilt only when the
/// snapshot or seen state changes, never per render: resolving every session's
/// status on each body pass stalled scrolling with a thousand-plus chats.
@MainActor
struct SessionDashboardBoard {
    /// Every visible session, sorted, before search and project filters.
    private(set) var rows: [SessionDashboardRow] = []
    private(set) var attention: [String: AttentionItem] = [:]
    private(set) var activity: [String: LatestActivityItem] = [:]
    private(set) var runtimeIDs: [String: [String]] = [:]
    private(set) var live: Set<String> = []
    private(set) var projectNames: [String] = []
    private(set) var profileScopeID: String?

    init() {}

    init(snapshot: SessionNavSidebarSnapshot, seen: SidebarSessionSeenStore) {
        let inputs = snapshot.inputs
        let aliases = SessionDashboardProjection.aliases(in: snapshot)
        func canonical(_ id: String) -> String { aliases[id] ?? id }
        let sessions = SessionDashboardProjection.sessions(in: snapshot)
        let activeByID = Dictionary(
            inputs.activeSessions.map { (canonical($0.id), $0) }, uniquingKeysWith: { first, _ in first })
        let activeID = inputs.activeSessionID.map(canonical)
        var statuses: [String: SidebarSessionStatus] = [:]
        statuses.reserveCapacity(sessions.count)
        for session in sessions where statuses[session.id] == nil {
            let summary = activeByID[session.id]
            let owner = session.profileID ?? inputs.profileScopeID
            statuses[session.id] = SidebarSessionStatusResolver.resolve(
                session: session, summary: summary, activeSessionID: activeID,
                activeStatus: inputs.activeStatus,
                attention: snapshot.attentionDots[session.id] ?? summary.flatMap { snapshot.attentionDots[$0.id] },
                seenAt: seen.seenAt(profileID: owner, sessionID: session.id),
                isProfileBaselined: seen.isBaselined(profileID: owner))
        }
        var projects = snapshot.projectNameBySessionID
        for (alias, id) in aliases where projects[id] == nil { projects[id] = projects[alias] }
        rows = SessionDashboardProjection.rows(sessions: sessions, statuses: statuses, projects: projects)

        for request in inputs.attention where request.state == .open {
            guard let id = request.reference.sessionID.map(canonical), attention[id] == nil else { continue }
            attention[id] = request
        }
        for item in inputs.latestActivities where activity[canonical(item.sessionID)] == nil {
            activity[canonical(item.sessionID)] = item
        }
        for (alias, id) in aliases { runtimeIDs[id, default: []].append(alias) }
        for session in inputs.activeSessions where SessionLifecyclePresentation.status(for: session) == .active {
            live.insert(canonical(session.id))
        }
        projectNames = Set(snapshot.projectNameBySessionID.values).sorted()
        profileScopeID = inputs.profileScopeID
    }
}

struct SessionDashboardVisibleRows {
    private(set) var bySection: [SessionDashboardSection: [SessionDashboardRow]] = [:]
    var isEmpty: Bool { bySection.isEmpty }

    init() {}

    init(_ rows: [SessionDashboardRow]) {
        bySection = Dictionary(grouping: rows, by: \.section)
    }

    func members(_ section: SessionDashboardSection) -> [SessionDashboardRow] { bySection[section] ?? [] }
    var counts: [SessionDashboardSection: Int] { bySection.mapValues(\.count) }
}

/// A completed load must still belong to the selected row before enabling replies.
struct SessionDashboardSelection: Equatable {
    private(set) var session: HermesSession?
    private(set) var generation = UUID()
    private(set) var isLoading = false
    private(set) var isLoaded = false

    mutating func begin(_ session: HermesSession) -> UUID {
        self.session = session
        generation = UUID()
        isLoading = true
        isLoaded = false
        return generation
    }

    mutating func finish(_ request: UUID, loaded: Bool) {
        guard generation == request else { return }
        isLoading = false
        isLoaded = loaded
    }

    func canRespond(activeSessionID: String?, activeProfileID: String?, profileID: String?) -> Bool {
        isLoaded && !isLoading
            && matches(activeSessionID: activeSessionID, activeProfileID: activeProfileID, profileID: profileID)
    }

    func matches(activeSessionID: String?, activeProfileID: String?, profileID: String?) -> Bool {
        guard let session else { return false }
        return session.id == activeSessionID
            && (session.profileID ?? profileID ?? "default") == (activeProfileID ?? "default")
    }
}
