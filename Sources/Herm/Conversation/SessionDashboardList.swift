import SwiftUI

/// Keep transcript publications out of session filtering and grouping.
/// A bot's identity on a tile, shown only when several bots share the board.
struct SessionDashboardBot: Equatable {
    let summary: BotSummary
    let image: Data?
}

struct SessionDashboardList: View, Equatable {
    @ObservedObject var sidebar: SessionNavSidebarModel
    let selection: SessionDashboardSelection
    let isCurrent: Bool
    let onSelect: (HermesSession) -> Void
    var client: HermesRPCClientProtocol? = nil
    var model: DockModel? = nil
    var tileBots: [String: SessionDashboardBot] = [:]
    @ObservedObject private var seen = SidebarSessionSeenStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var project: String?
    @State private var section: SessionDashboardSection?
    @State private var collapsed: Set<SessionDashboardSection> = [.recent]
    private var style: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sidebar === rhs.sidebar && lhs.selection == rhs.selection && lhs.isCurrent == rhs.isCurrent
            && lhs.tileBots == rhs.tileBots
    }

    private var snapshot: SessionNavSidebarSnapshot { sidebar.snapshot }
    private var sessions: [HermesSession] { SessionDashboardProjection.sessions(in: snapshot) }

    private var rows: [SessionDashboardRow] {
        let sessions = sessions
        let aliases = SessionDashboardProjection.aliases(in: snapshot)
        let activeByID = Dictionary(
            snapshot.inputs.activeSessions.map { (aliases[$0.id] ?? $0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let statuses = Dictionary(
            sessions.map { session in
                let summary = activeByID[session.id]
                let activeID = snapshot.inputs.activeSessionID.map { aliases[$0] ?? $0 }
                let status = SidebarSessionStatusResolver.resolve(
                    session: session, summary: summary, activeSessionID: activeID,
                    activeStatus: snapshot.inputs.activeStatus,
                    attention: snapshot.attentionDots[session.id] ?? summary.flatMap { snapshot.attentionDots[$0.id] },
                    seenAt: seen.seenAt(
                        profileID: session.profileID ?? snapshot.inputs.profileScopeID, sessionID: session.id),
                    isProfileBaselined: seen.isBaselined(profileID: session.profileID ?? snapshot.inputs.profileScopeID)
                )
                return (session.id, status)
            }, uniquingKeysWith: { first, _ in first })
        var projects = snapshot.projectNameBySessionID
        for (alias, id) in aliases where projects[id] == nil { projects[id] = projects[alias] }
        return SessionDashboardProjection.rows(
            sessions: sessions, statuses: statuses, projects: projects,
            query: query, project: project)
    }

    var body: some View {
        let projected = self.rows
        let counts = Dictionary(grouping: projected, by: \.section).mapValues(\.count)
        let rows = projected.filter { section == nil || $0.section == section }
        let lookup = RowLookup(snapshot: snapshot)
        let layoutKey = rows.map { "\($0.section.rawValue)/\($0.session.scopedID)" } + collapsed.map(\.rawValue)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    searchField
                    projectFilter
                    Spacer(minLength: 0)
                }
                ViewThatFits(in: .horizontal) {
                    statusFilter(counts)
                    ScrollView(.horizontal) {
                        statusFilter(counts)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dockPadding(.horizontal, 20)
            .dockPadding(.vertical, 16)
            ScrollView {
                if rows.isEmpty {
                    emptyState(
                        query.isEmpty && project == nil ? "No sessions to show" : "No matching sessions",
                        detail: isCurrent
                            ? "Choose another bot or refresh the session list."
                            : "Activity is not current. Refresh to retry.")
                }
                // One grid keeps every card in the same container. A card that changes
                // section is re-created in its new slot; a matched-geometry ghost of the
                // old one lingered with the old status.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)],
                    alignment: .leading, spacing: 16
                ) {
                    ForEach(SessionDashboardSection.allCases) { group in
                        let members = rows.filter { $0.section == group }
                        if !members.isEmpty {
                            Section {
                                if !collapsed.contains(group) {
                                    ForEach(members, id: \.session.scopedID) { row in
                                        sessionRow(row, lookup)
                                    }
                                }
                            } header: {
                                sectionHeader(group, members: members)
                            }
                        }
                    }
                }
                .animation(
                    DockMotion.isEnabled(reduceMotion: reduceMotion)
                        ? .spring(response: 0.8, dampingFraction: 0.9) : nil,
                    value: layoutKey
                )
                .dockPadding(.horizontal, 20)
                .dockPadding(.bottom, 20)
            }
        }
    }

    private func sectionHeader(_ group: SessionDashboardSection, members: [SessionDashboardRow]) -> some View {
        DockSectionHeader(
            title: group.rawValue, count: members.count,
            isExpanded: Binding(
                get: { !collapsed.contains(group) },
                set: { if $0 { collapsed.remove(group) } else { collapsed.insert(group) } }),
            style: style
        ) {
            Spacer(minLength: 0)
            if group == .review, let model {
                DockIconButton(icon: .checks, label: "Mark all as read", size: 24, style: style) {
                    model.markSessionsRead(members.map(\.session), at: .now)
                }
                .help("Mark all as read")
            }
        }
    }

    /// Per-body indexes so each card finds its data without scanning every list.
    private struct RowLookup {
        var attention: [String: AttentionItem] = [:]
        var activity: [String: LatestActivityItem] = [:]
        var runtimeIDs: [String: [String]] = [:]
        var live: Set<String> = []

        init(snapshot: SessionNavSidebarSnapshot) {
            let aliases = SessionDashboardProjection.aliases(in: snapshot)
            func canonical(_ id: String) -> String { aliases[id] ?? id }
            for request in snapshot.inputs.attention where request.state == .open {
                guard let id = request.reference.sessionID.map(canonical), attention[id] == nil else { continue }
                attention[id] = request
            }
            for item in snapshot.inputs.latestActivities where activity[canonical(item.sessionID)] == nil {
                activity[canonical(item.sessionID)] = item
            }
            for (alias, id) in aliases { runtimeIDs[id, default: []].append(alias) }
            for session in snapshot.inputs.activeSessions
            where SessionLifecyclePresentation.status(for: session) == .active {
                live.insert(canonical(session.id))
            }
        }
    }

    private func sessionRow(_ row: SessionDashboardRow, _ lookup: RowLookup) -> some View {
        SessionDashboardCard(
            row: row, isCurrent: isCurrent, isLoadingSession: selection.isLoading,
            request: lookup.attention[row.id], activity: lookup.activity[row.id],
            profileID: snapshot.inputs.profileScopeID, client: client,
            runtimeIDs: lookup.runtimeIDs[row.id] ?? [],
            isGatewayLive: lookup.live.contains(row.id),
            model: model, bot: tileBots[row.session.profileID ?? "default"], onRespond: { onSelect(row.session) }
        )
    }

    private var searchField: some View {
        DockSearchField(placeholder: "Search sessions", text: $query)
            .frame(minWidth: 140, maxWidth: 320)
    }

    private var projectFilter: some View {
        DockMenuPicker(title: project ?? "All projects", selection: $project) {
            DockMenuOption("All projects", value: nil as String?)
            ForEach(Array(Set(snapshot.projectNameBySessionID.values)).sorted(), id: \.self) { name in
                DockMenuOption(name, value: Optional(name))
            }
        }
    }

    private func statusFilter(_ counts: [SessionDashboardSection: Int]) -> some View {
        DockSegmentedPicker(
            selection: $section,
            options: [(nil, "All")]
                + SessionDashboardSection.allCases.map { group in
                    (Optional(group), counts[group].map { "\(group.rawValue) \($0)" } ?? group.rawValue)
                })
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).dockFont(.body, weight: .semibold)
            Text(detail).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
        }
        .dockPadding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

}
