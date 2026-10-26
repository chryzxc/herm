import SwiftUI

/// Keep transcript publications out of session filtering and grouping.
struct MissionControlDashboardList: View, Equatable {
    @ObservedObject var sidebar: MissionControlSidebarModel
    let selection: MissionControlDashboardSelection
    let isCurrent: Bool
    let onSelect: (HermesSession) -> Void
    var client: HermesRPCClientProtocol? = nil
    @ObservedObject private var seen = SidebarSessionSeenStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var cardPositions
    @State private var query = ""
    @State private var project: String?
    @State private var section: MissionControlDashboardSection?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sidebar === rhs.sidebar && lhs.selection == rhs.selection && lhs.isCurrent == rhs.isCurrent
    }

    private var snapshot: MissionControlSidebarSnapshot { sidebar.snapshot }
    private var sessions: [HermesSession] { MissionControlDashboardProjection.sessions(in: snapshot) }

    private var rows: [MissionControlDashboardRow] {
        let sessions = sessions
        let aliases = MissionControlDashboardProjection.aliases(in: snapshot)
        let statuses = Dictionary(
            sessions.map { session in
                let summary = snapshot.inputs.activeSessions.first { (aliases[$0.id] ?? $0.id) == session.id }
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
        return MissionControlDashboardProjection.rows(
            sessions: sessions, statuses: statuses, projects: projects,
            profileID: snapshot.inputs.profileScopeID, query: query, project: project)
    }

    var body: some View {
        let projected = self.rows
        let rows = MissionControlDashboardSection.allCases.flatMap { section in
            projected.filter { $0.section == section }
        }.filter { section == nil || $0.section == section }
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    searchField
                    projectFilter
                    statusFilter
                }
                VStack(alignment: .leading, spacing: 10) {
                    searchField
                    projectFilter
                    statusFilter
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if rows.isEmpty {
                        emptyState(
                            query.isEmpty && project == nil ? "No sessions to show" : "No matching sessions",
                            detail: isCurrent
                                ? "Choose another bot or refresh the session list."
                                : "Activity is not current. Refresh to retry.")
                    }
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)],
                        alignment: .leading, spacing: 16
                    ) {
                        ForEach(rows, id: \.session.scopedID) { row in
                            sessionRow(row)
                                .matchedGeometryEffect(
                                    id: row.session.scopedID, in: cardPositions, properties: .position
                                )
                                .transition(.opacity)
                        }
                    }
                    .animation(
                        DockMotion.isEnabled(reduceMotion: reduceMotion)
                            ? .spring(response: 0.55, dampingFraction: 0.88) : nil,
                        value: rows.map { $0.session.scopedID })
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    private func sessionRow(_ row: MissionControlDashboardRow) -> some View {
        let aliases = MissionControlDashboardProjection.aliases(in: snapshot)
        return MissionControlDashboardCard(
            row: row, isCurrent: isCurrent, isLoadingSession: selection.isLoading,
            request: snapshot.inputs.attention.first {
                $0.reference.sessionID.map { aliases[$0] ?? $0 } == row.id && $0.state == .open
            },
            activity: snapshot.inputs.latestActivities.first { (aliases[$0.sessionID] ?? $0.sessionID) == row.id },
            profileID: snapshot.inputs.profileScopeID, client: client, onRespond: { onSelect(row.session) }
        )
    }

    private var searchField: some View {
        DockTextField("Search sessions", text: $query).frame(minWidth: 140, maxWidth: 420)
    }

    private var projectFilter: some View {
        Picker("Project", selection: $project) {
            Text("All projects").tag(nil as String?)
            ForEach(Array(Set(snapshot.projectNameBySessionID.values)).sorted(), id: \.self) { name in
                Text(name).tag(Optional(name))
            }
        }
    }

    private var statusFilter: some View {
        Picker("Status", selection: $section) {
            Text("All sessions").tag(nil as MissionControlDashboardSection?)
            ForEach(MissionControlDashboardSection.allCases) { section in
                Text(section.rawValue).tag(Optional(section))
            }
        }
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).dockFont(.body, weight: .semibold)
            Text(detail).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

}
