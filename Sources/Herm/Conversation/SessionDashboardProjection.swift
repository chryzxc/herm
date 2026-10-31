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
                hasUnreadUpdate: session.hasUnreadUpdate)
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
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<ProfileScopedID>()
        return sessions.compactMap { session in
            guard seen.insert(session.scopedID).inserted, !session.isHidden,
                project == nil || projects[session.id] == project
            else { return nil }
            let name = projects[session.id]
            guard
                query.isEmpty
                    || [session.displayTitle, session.displayPreview ?? "", name ?? ""]
                        .contains(where: { $0.localizedCaseInsensitiveContains(query) })
            else { return nil }
            return SessionDashboardRow(
                session: session, status: statuses[session.id] ?? .none, project: name)
        }.sorted {
            let left = $0.sortDate
            let right = $1.sortDate
            return left == right ? $0.id < $1.id : left > right
        }
    }
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
        guard let session, isLoaded, !isLoading else { return false }
        return session.id == activeSessionID
            && (session.profileID ?? profileID ?? "default") == (activeProfileID ?? "default")
    }
}
