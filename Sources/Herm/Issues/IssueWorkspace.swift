import Foundation
import SwiftUI

struct IssueWorkspace: View {
    @ObservedObject var center: IssueCenterModel
    let projects: [ProjectSummary]
    let onOpenChat: (GitHubIssueRecord) -> Void
    var hidesList = false
    @State private var collapsedRepositories: Set<String> = []
    @State private var showsDetail = false
    @State private var refreshID = 0
    @State private var loadedBrowse = GitHubBrowseOptions()
    @Environment(\.openGitHubItem) private var openItem
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let requirement = center.accessRequirement, center.records.isEmpty {
                GitHubAccessRecoveryView(feature: "Issues", requirement: requirement, isRetrying: center.isRefreshing) {
                    refresh()
                }
            } else {
                AdaptiveSplit(
                    primaryMinWidth: 340, secondaryMinWidth: 480, alwaysSplitWhenWide: true, hidesPrimary: hidesList,
                    showsSecondary: showsDetail, onBack: { showsDetail = false }
                ) {
                    listPane.frame(idealWidth: 390, maxWidth: 460)
                } secondary: {
                    IssueDetailView(center: center, onOpenChat: onOpenChat)
                }
            }
        }
        .background(Color.dockCanvas)
        .task(id: refreshID) {
            if refreshID > 0 || !center.hasLoaded {
                if refreshID > 0 { center.cancelLoads() }
                await center.refresh(projects: projects)
                if !Task.isCancelled, center.errorMessage == nil { loadedBrowse = center.browsing }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                if scenePhase == .active && center.errorMessage == nil {
                    await center.refresh(projects: projects)
                    await center.refreshSelectedDetail()
                }
            }
        }
        .onDisappear { center.cancelLoads() }
        .onChange(of: center.filter) { _, _ in center.repairSelection() }
        .onChange(of: center.query) { _, _ in center.repairSelection() }
        .onChange(of: center.repositoryScope) { _, _ in center.repairSelection() }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            issueToolbar
            ScrollView {
                LazyVStack(spacing: 2) {
                    if center.isRefreshing && (center.records.isEmpty || center.browsing != loadedBrowse) {
                        ForEach(0..<6, id: \.self) { _ in issueLoadingRow }
                    } else if !center.hasLoaded && center.errorMessage != nil {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Issues unavailable").dockFont(.body, weight: .semibold)
                            Text("Check your GitHub sign-in and try again.").dockFont(.body).foregroundStyle(
                                Color.dockMetadataText)
                            Button("Try again") { refresh() }.buttonStyle(.dockCompact).foregroundStyle(
                                Color.dockAccent)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    } else if center.visible.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(center.hasActiveFilters ? "No issues match this view" : "No open issues")
                                .dockFont(.body, weight: .semibold)
                            Text(
                                center.hasActiveFilters
                                    ? "Try another filter or search term."
                                    : "Issues from your repositories will appear here."
                            )
                            .dockFont(.body).foregroundStyle(Color.dockMetadataText)
                            if center.hasActiveFilters {
                                Button("Clear filters") { center.resetFilters() }
                                    .buttonStyle(.dockCompact)
                                    .foregroundStyle(Color.dockAccent)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    } else {
                        ForEach(center.visibleGroups, id: \.repository) { group in
                            DockSectionHeader(
                                title: group.repository,
                                count: group.issues.count,
                                isExpanded: expansion(for: group.repository),
                                style: DockThemePalette(theme: DockThemeRuntime.current)
                            )
                            .padding(.top, 6)
                            if !collapsedRepositories.contains(group.repository) {
                                ForEach(group.issues) { issue in
                                    Button {
                                        center.selectedIssueID = issue.id
                                        showsDetail = true
                                    } label: {
                                        HStack(spacing: 4) {
                                            IssueRowView(
                                                issue: issue, isSelected: center.selectedIssueID == issue.id,
                                                viewer: center.viewerLogin)
                                            if center.changedIDs.contains(issue.id) {
                                                Circle().fill(Color.dockAccent).frame(width: 6, height: 6)
                                                    .accessibilityLabel("Changed since last viewed").help(
                                                        "Changed on GitHub since last viewed")
                                            }
                                        }
                                    }
                                    .buttonStyle(.dockHover)
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .dockPaneTint(Color.dockSurface2.opacity(0.55))
        .onMoveCommand { direction in
            let rows = center.visible
            guard !rows.isEmpty, direction == .up || direction == .down else { return }
            let index = rows.firstIndex { $0.id == center.selectedIssueID } ?? 0
            center.selectedIssueID = rows[max(0, min(rows.count - 1, index + (direction == .down ? 1 : -1)))].id
        }
    }

    private var issueToolbar: some View {
        VStack(spacing: 8) {
            GitHubBrowseControls(
                kind: .issue, client: center.api.client, repositories: center.repositories, options: $center.browsing,
                refresh: refresh, onCreated: { openItem($0) }, isLoading: center.isRefreshing)
            HStack(spacing: 8) {
                DockIcon(.magnifyingGlass, size: 15, color: Color.dockMetadataText)
                TextField("Search issues", text: $center.query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).dockSurfaceFill(
                    Color.dockControlSurface)
            )
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    filterTabs
                    Spacer(minLength: 8)
                    repositoryPicker
                }
                VStack(alignment: .leading, spacing: 8) {
                    filterTabs
                    repositoryPicker
                }
            }.frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if center.errorMessage != nil { DockIcon(.warning, size: 12, color: Color.dockWarning) }
                Text(
                    center.isRefreshing
                        ? "Loading \(center.browsing.state.rawValue.lowercased()) issues…"
                        : (center.errorMessage ?? center.coverage ?? "\(center.visible.count) issues")
                ).foregroundStyle(center.errorMessage == nil ? Color.dockMetadataText : Color.dockWarning)
                Spacer(minLength: 0)
            }.dockFont(.metadata).lineLimit(2).frame(height: 28, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.dockCanvas)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private var filterTabs: some View {
        HStack(spacing: 4) {
            ForEach(GitHubIssueFilter.allCases) { filter in
                DockTabButton(
                    title: center.hasLoaded ? "\(filter.rawValue)  \(center.count(for: filter))" : filter.rawValue,
                    isSelected: center.filter == filter
                ) {
                    center.filter = filter
                }
            }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var repositoryPicker: some View {
        DockMenu {
            Button("All repositories") { center.repositoryScope = nil }
            ForEach(Array(Set(center.records.map(\.repository.id))).sorted(), id: \.self) { repository in
                Button(repository) { center.repositoryScope = repository }
            }
        } label: {
            HStack(spacing: 4) {
                DockIcon(.folder, size: 12, color: Color.dockSecondaryText)
                Text(center.repositoryScope ?? "All repositories")
                    .dockFont(.control).lineLimit(1).truncationMode(.middle)
                DockIcon(.caretDown, size: 9, color: Color.dockMetadataText)
            }
            .foregroundStyle(Color.dockSecondaryText)
            .padding(.horizontal, 8).frame(height: 28)
            .background(
                DockThemeShape(cornerRadius: DockLayout.controlRadius - 1).dockSurfaceFill(
                    Color.dockControlSurface.opacity(0.6)))
        }.help("Filter loaded issues by repository")
    }

    private var issueLoadingRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.dockSurface4.opacity(0.6)).frame(
                height: 13)
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.dockSurface4.opacity(0.35)).frame(
                width: 190, height: 10)
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(.horizontal, 14)
    }

    private func expansion(for repository: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedRepositories.contains(repository) },
            set: { expanded in
                if expanded {
                    collapsedRepositories.remove(repository)
                } else {
                    collapsedRepositories.insert(repository)
                }
            }
        )
    }

    private func refresh() {
        refreshID += 1
    }
}

struct IssueWorkspacePage: View {
    @ObservedObject var center: IssueCenterModel
    let projects: [ProjectSummary]
    let onOpenChat: (GitHubIssueRecord) -> Void
    @AppStorage("herm.repositoryListCollapsed") private var collapsed = false
    private var header: some View {
        DockPageHeader(
            title: "Issues", subtitle: "Triage your GitHub work",
            onRefresh: { Task { await center.refresh(projects: projects) } }, isRefreshing: center.isRefreshing,
            sidebarCollapsed: $collapsed)
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            IssueWorkspace(center: center, projects: projects, onOpenChat: onOpenChat, hidesList: collapsed)
                .environment(\.dockTitleRow, nil)
        }
    }
}
