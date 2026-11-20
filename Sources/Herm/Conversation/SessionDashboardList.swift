import Combine
import SwiftUI

/// Keep transcript publications out of session filtering and grouping.
/// A bot's identity on a tile, shown only when several bots share the board.
struct SessionDashboardBot: Equatable {
    let summary: BotSummary
    let image: Data?
}

/// Owns the board projection so it is rebuilt once per snapshot or seen-state
/// change, and filtered once per search edit, instead of on every render.
@MainActor
final class SessionDashboardBoardModel: ObservableObject {
    @Published private(set) var board = SessionDashboardBoard()
    @Published private(set) var visible = SessionDashboardVisibleRows()
    private var query = ""
    private var project: String?
    private var cancellables: Set<AnyCancellable> = []

    init(sidebar: SessionNavSidebarModel, seen: SidebarSessionSeenStore = .shared) {
        rebuild(sidebar.snapshot, seen: seen)
        // `@Published` emits before it stores, so take the new snapshot from the stream.
        sidebar.$snapshot.dropFirst()
            .sink { [weak self] in self?.rebuild($0, seen: seen) }
            .store(in: &cancellables)
        // The seen store has no value to hand over; read it once the change lands.
        seen.$seenAtByKey.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self, weak sidebar] _ in
                guard let sidebar else { return }
                self?.rebuild(sidebar.snapshot, seen: seen)
            }
            .store(in: &cancellables)
    }

    func filter(query: String, project: String?) {
        guard query != self.query || project != self.project else { return }
        self.query = query
        self.project = project
        refilter()
    }

    private func rebuild(_ snapshot: SessionNavSidebarSnapshot, seen: SidebarSessionSeenStore) {
        board = SessionDashboardBoard(snapshot: snapshot, seen: seen)
        refilter()
    }

    private func refilter() {
        visible = SessionDashboardVisibleRows(
            SessionDashboardProjection.filter(board.rows, query: query, project: project))
    }
}

struct SessionDashboardList: View, Equatable {
    /// Not observed: the board is projected once per snapshot in `rebuild`, not on every render.
    let sidebar: SessionNavSidebarModel
    let selection: SessionDashboardSelection
    let isCurrent: Bool
    let onSelect: (HermesSession) -> Void
    let client: HermesRPCClientProtocol?
    let model: DockModel?
    let tileBots: [String: SessionDashboardBot]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var project: String?
    @State private var section: SessionDashboardSection?
    @State private var collapsed: Set<SessionDashboardSection> = [.recent]
    @StateObject private var projection: SessionDashboardBoardModel
    private var board: SessionDashboardBoard { projection.board }
    private var visible: SessionDashboardVisibleRows { projection.visible }
    private var style: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }

    init(
        sidebar: SessionNavSidebarModel, selection: SessionDashboardSelection, isCurrent: Bool,
        onSelect: @escaping (HermesSession) -> Void, client: HermesRPCClientProtocol? = nil,
        model: DockModel? = nil, tileBots: [String: SessionDashboardBot] = [:]
    ) {
        self.sidebar = sidebar
        self.selection = selection
        self.isCurrent = isCurrent
        self.onSelect = onSelect
        self.client = client
        self.model = model
        self.tileBots = tileBots
        _projection = StateObject(wrappedValue: SessionDashboardBoardModel(sidebar: sidebar))
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sidebar === rhs.sidebar && lhs.selection == rhs.selection && lhs.isCurrent == rhs.isCurrent
            && lhs.tileBots == rhs.tileBots
    }

    var body: some View {
        let counts = visible.counts
        let groups = SessionDashboardSection.allCases.filter { section == nil || $0 == section }
        let isEmpty = groups.allSatisfy { visible.members($0).isEmpty }
        var layoutKey = Hasher()
        layoutKey.combine(visible.layoutSignature)
        layoutKey.combine(collapsed)
        layoutKey.combine(section)
        return VStack(spacing: 0) {
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
                if isEmpty {
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
                    ForEach(groups) { group in
                        let members = visible.members(group)
                        if !members.isEmpty {
                            Section {
                                if !collapsed.contains(group) {
                                    ForEach(members, id: \.session.scopedID) { row in
                                        sessionRow(row)
                                    }
                                }
                            } header: {
                                sectionHeader(group, members: members)
                            }
                        }
                    }
                }
                // Short, and keyed on card order only: live status ticks arrive several
                // times a second and a long spring kept the whole grid mid-animation.
                .animation(
                    DockMotion.animation(reduceMotion: reduceMotion, duration: 0.25), value: layoutKey.finalize()
                )
                .dockPadding(.horizontal, 20)
                .dockPadding(.bottom, 20)
            }
        }
        .onChange(of: query) { _, value in projection.filter(query: value, project: project) }
        .onChange(of: project) { _, value in projection.filter(query: query, project: value) }
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

    private func sessionRow(_ row: SessionDashboardRow) -> some View {
        SessionDashboardCard(
            row: row, isCurrent: isCurrent, isLoadingSession: selection.isLoading,
            request: board.attention[row.id], activity: board.activity[row.id],
            profileID: board.profileScopeID, client: client,
            runtimeIDs: board.runtimeIDs[row.id] ?? [],
            isGatewayLive: board.live.contains(row.id),
            model: model, bot: tileBots[row.session.profileID ?? "default"], onRespond: { onSelect(row.session) }
        )
        .equatable()
    }

    private var searchField: some View {
        DockSearchField(placeholder: "Search sessions", text: $query)
            .frame(minWidth: 140, maxWidth: 320)
    }

    private var projectFilter: some View {
        DockMenuPicker(title: project ?? "All projects", selection: $project) {
            DockMenuOption("All projects", value: nil as String?)
            ForEach(board.projectNames, id: \.self) { name in
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
        DockEmptyState(title: title, detail: detail)
            .dockPadding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

}
