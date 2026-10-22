import SwiftUI

struct PullRequestWorkspace: View {
    @AppStorage("herm.repositoryListCollapsed") private var isListCollapsed = false
    @ObservedObject var center: PullRequestCenterModel
    let projects: [ProjectSummary]
    let onOpenChat: (PullRequestRecord) -> Void
    @State private var showsDetail = false
    @State private var refreshID = 0
    @State private var loadedBrowse = GitHubBrowseOptions()
    @Environment(\.openGitHubItem) private var openItem
    @Environment(\.scenePhase) private var scenePhase

    private var header: some View {
        DockPageHeader(
            title: "Pull requests",
            subtitle: "Review your GitHub work",
            onRefresh: { refreshID += 1 },
            isRefreshing: center.isRefreshing,
            sidebarCollapsed: $isListCollapsed
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            AdaptiveSplit(primaryMinWidth: 300, secondaryMinWidth: 360, alwaysSplitWhenWide: true, hidesPrimary: isListCollapsed, showsSecondary: showsDetail, onBack: { showsDetail = false }) {
                listPane.frame(idealWidth: 390, maxWidth: 460)
            } secondary: {
                PullRequestDetailView(center: center, onOpenChat: onOpenChat)
            }
            .environment(\.dockTitleRow, nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dockCanvas)
        .task(id: refreshID) {
            if refreshID > 0 || !center.hasLoaded {
                if refreshID > 0 { center.cancelLoads() }
                await refreshActiveWorkspace()
                if !Task.isCancelled, center.errorMessage == nil { loadedBrowse = center.browsing }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                if scenePhase == .active && center.errorMessage == nil { await center.refresh(projects: projects); await center.refreshSelectedDetail() }
            }
        }
        .onDisappear {
            center.cancelLoads()
        }
        .onChange(of: center.filter) { _, _ in center.repairSelection() }
        .onChange(of: center.query) { _, _ in center.repairSelection() }
    }

    private func refreshActiveWorkspace() async { await center.refresh(projects: projects) }

    private var listPane: some View { VStack(spacing: 0) {
        VStack(spacing: 8) {
            GitHubBrowseControls(kind: .pullRequest, client: center.api.client, repositories: center.repositories, options: $center.browsing, refresh: { refreshID += 1 }, onCreated: { item in openItem(item) }, isLoading: center.isRefreshing)
            HStack(spacing: 8) {
                DockIcon(.magnifyingGlass, size: 15, color: Color.dockMetadataText)
                TextField("", text: $center.query, prompt: Text("Search pull requests").foregroundColor(Color.dockMetadataText))
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).dockSurfaceFill(Color.dockControlSurface))
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))

            PullRequestFilterPicker(selection: $center.filter)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.dockCanvas)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
        Text(center.isRefreshing ? "Loading \(center.browsing.state.rawValue.lowercased()) pull requests…" : (center.errorMessage ?? center.coverage ?? "\(center.visible.count) pull requests"))
            .dockFont(.metadata).foregroundStyle(center.errorMessage != nil ? Color.dockWarning : Color.dockMetadataText).lineLimit(2).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).padding(.horizontal, 18)
        ScrollView {
            LazyVStack(spacing: 2) {
                if center.isInitialLoad || (center.isRefreshing && center.browsing != loadedBrowse) {
                    ForEach(0..<6, id: \.self) { index in listLoadingRow(index: index) }
                } else if center.visible.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No pull requests match this view").dockFont(size: 12, weight: .semibold)
                        Text("Change the scope or filters, or create a draft pull request using New.").dockFont(.body).foregroundStyle(Color.dockMetadataText)
                        Button("Clear filters") { center.query = ""; center.filter = .all; center.browsing = GitHubBrowseOptions(); refreshID += 1 }.buttonStyle(.dockCompact)
                        Button("Retry") { refreshID += 1 }.buttonStyle(.dockCompact)
                    }.padding(16)
                } else {
                    ForEach(center.visible) { pr in
                        Button { center.selectedID = pr.id; showsDetail = true } label: { HStack(spacing: 4) { PullRequestRowView(pullRequest: pr, isSelected: center.selectedID == pr.id); if center.changedIDs.contains(pr.id) { Circle().fill(Color.dockAccent).frame(width: 6, height: 6).accessibilityLabel("Changed since last viewed").help("Changed on GitHub since last viewed") } } }
                            .buttonStyle(.dockHover)
                            .task(id: center.isRefreshing) {
                                guard !center.isRefreshing else { return }
                                await center.loadSummary(for: pr)
                            }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }.background(Color.dockSurface2.opacity(0.55))
        .onMoveCommand { direction in
            let rows = center.visible
            guard !rows.isEmpty, direction == .up || direction == .down else { return }
            let index = rows.firstIndex { $0.id == center.selectedID } ?? 0
            center.selectedID = rows[max(0, min(rows.count - 1, index + (direction == .down ? 1 : -1)))].id
        }
    }

    private func listLoadingRow(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                RepositoryShimmerBlock(width: 18, height: 18, cornerRadius: 5)
                RepositoryShimmerBlock(width: index.isMultiple(of: 2) ? 184 : 228, height: 12, cornerRadius: 4)
            }
            RepositoryShimmerBlock(width: index.isMultiple(of: 3) ? 122 : 160, height: 9, cornerRadius: 3)
            RepositoryShimmerBlock(width: 48, height: 8, cornerRadius: 3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius + 1, style: .continuous).fill(Color.dockSurface2))
        .accessibilityHidden(true)
    }
}
