import SwiftUI

/// Keep transcript publications out of session filtering and grouping.
struct SessionDashboardList: View, Equatable {
    @ObservedObject var sidebar: SessionNavSidebarModel
    let selection: SessionDashboardSelection
    let isCurrent: Bool
    let onSelect: (HermesSession) -> Void
    var client: HermesRPCClientProtocol? = nil
    var model: DockModel? = nil
    @ObservedObject private var seen = SidebarSessionSeenStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var project: String?
    @State private var section: SessionDashboardSection?
    @State private var collapsed: Set<SessionDashboardSection> = [.recent]
    private var style: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sidebar === rhs.sidebar && lhs.selection == rhs.selection && lhs.isCurrent == rhs.isCurrent
    }

    private var snapshot: SessionNavSidebarSnapshot { sidebar.snapshot }
    private var sessions: [HermesSession] { SessionDashboardProjection.sessions(in: snapshot) }

    private var rows: [SessionDashboardRow] {
        let sessions = sessions
        let aliases = SessionDashboardProjection.aliases(in: snapshot)
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
        return SessionDashboardProjection.rows(
            sessions: sessions, statuses: statuses, projects: projects,
            profileID: snapshot.inputs.profileScopeID, query: query, project: project)
    }

    var body: some View {
        let projected = self.rows
        let counts = Dictionary(grouping: projected, by: \.section).mapValues(\.count)
        let rows = projected.filter { section == nil || $0.section == section }
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
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
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
                                        sessionRow(row)
                                    }
                                }
                            } header: {
                                sectionHeader(group, count: members.count)
                            }
                        }
                    }
                }
                .animation(
                    DockMotion.isEnabled(reduceMotion: reduceMotion)
                        ? .spring(response: 0.8, dampingFraction: 0.9) : nil,
                    value: rows.map { "\($0.section.rawValue)/\($0.session.scopedID)" } + collapsed.map(\.rawValue)
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    private func sectionHeader(_ group: SessionDashboardSection, count: Int) -> some View {
        DockSectionHeader(
            title: group.rawValue, count: count,
            isExpanded: Binding(
                get: { !collapsed.contains(group) },
                set: { if $0 { collapsed.remove(group) } else { collapsed.insert(group) } }),
            style: style)
    }

    private func sessionRow(_ row: SessionDashboardRow) -> some View {
        let aliases = SessionDashboardProjection.aliases(in: snapshot)
        return SessionDashboardCard(
            row: row, isCurrent: isCurrent, isLoadingSession: selection.isLoading,
            request: snapshot.inputs.attention.first {
                $0.reference.sessionID.map { aliases[$0] ?? $0 } == row.id && $0.state == .open
            },
            activity: snapshot.inputs.latestActivities.first { (aliases[$0.sessionID] ?? $0.sessionID) == row.id },
            profileID: snapshot.inputs.profileScopeID, client: client,
            runtimeIDs: aliases.filter { $0.value == row.id }.map(\.key),
            isGatewayLive: snapshot.inputs.activeSessions.contains {
                (aliases[$0.id] ?? $0.id) == row.id && SessionLifecyclePresentation.status(for: $0) == .active
            },
            model: model, onRespond: { onSelect(row.session) }
        )
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            DockIcon(.magnifyingGlass, size: 13, color: Color.dockMetadataText)
            DockTextField("Search sessions", text: $query)
                .textFieldStyle(.plain)
                .dockFont(.body)
                .accessibilityLabel("Search sessions")
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 140, maxWidth: 320, minHeight: 32)
        .background(DockThemeShape(cornerRadius: DockLayout.controlRadius).fill(Color.dockControlSurface))
        .overlay {
            DockThemeShape(cornerRadius: DockLayout.controlRadius)
                .stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline)
        }
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
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

}
