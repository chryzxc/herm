import SwiftUI

struct GitHubRepositoriesView: View {
    @ObservedObject var model: GitHubRepositoriesModel
    @State var selected: GitHubRepositorySummary?

    var body: some View {
        VStack(spacing: 0) {
            DockPageHeader(
                title: "Repositories", subtitle: "Browse your GitHub repositories",
                onRefresh: { Task { await model.refresh() } }, isRefreshing: model.loading)
            if let requirement = model.accessRequirement, model.repositories.isEmpty {
                GitHubAccessRecoveryView(feature: "Repositories", requirement: requirement, isRetrying: model.loading) {
                    Task { await model.refresh() }
                }
            } else {
                AdaptiveSplit(
                    primaryMinWidth: 340, primaryIdealWidth: 390, primaryMaxWidth: 460, secondaryMinWidth: 480,
                    alwaysSplitWhenWide: true,
                    showsSecondary: selected != nil, onBack: { selected = nil }
                ) {
                    repositoryList
                } secondary: {
                    if let selected {
                        GitHubRepositoryOverview(
                            repository: model.repositories.first { $0.id == selected.id } ?? selected,
                            client: model.client, close: { self.selected = nil }
                        ).id(selected.id)
                    } else {
                        VStack(spacing: 10) {
                            DockIcon(.folder, size: 28, color: .dockMetadataText)
                            Text("Select a repository").dockFont(.navigation, weight: .medium)
                        }
                        .foregroundStyle(Color.dockMetadataText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .environment(\.dockTitleRow, nil)
            }
        }
        .dockFont(.body)
        .foregroundStyle(Color.dockPrimaryText)
        .background(Color.dockCanvas)
        .task { if !model.hasLoaded { await model.refresh() } }
    }

    private var repositoryList: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView {
                LazyVStack(spacing: 2) {
                    let pinned = model.visible.filter(model.isPinned)
                    if pinned.isEmpty {
                        rows(model.visible)
                    } else {
                        sectionHeader("Pinned", count: pinned.count)
                        rows(pinned)
                        sectionHeader("All repositories", count: model.visible.count - pinned.count)
                            .dockPadding(.top, 8)
                        rows(model.visible.filter { !model.isPinned($0) })
                    }
                    if model.visible.isEmpty { emptyState }
                }.dockPadding(.horizontal, 10).dockPadding(.vertical, 6)
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        DockSectionHeader(title: title, count: count, style: DockThemePalette(theme: DockThemeRuntime.current))
    }

    private func rows(_ repositories: [GitHubRepositorySummary]) -> some View {
        ForEach(repositories) { repository in
            Button {
                selected = repository
            } label: {
                GitHubRepositoryRow(
                    repository: repository, isSelected: selected?.id == repository.id,
                    showsOwner: model.owners.count > 1)
            }
            .buttonStyle(.dockHover)
            .accessibilityAddTraits(selected?.id == repository.id ? [.isSelected] : [])
            .help("View repository details")
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DockIcon(.magnifyingGlass, size: 15, color: .dockMetadataText)
                DockTextField("Search repositories", text: $model.query).textFieldStyle(.plain)
            }
            .dockPadding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 34)
            .background(
                DockThemeShape(cornerRadius: DockLayout.controlRadius).dockSurfaceFill(Color.dockControlSurface))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    visibilityTabs
                    Spacer(minLength: 8)
                    ownerPicker
                }
                VStack(alignment: .leading, spacing: 8) {
                    visibilityTabs
                    ownerPicker
                }
            }
            HStack(spacing: 6) {
                if model.error != nil { DockIcon(.warning, size: 12, color: .dockWarning) }
                Text(
                    model.loading
                        ? "Refreshing repositories…"
                        : (model.error ?? model.coverage
                            ?? "\(model.visible.count) repositories · recently updated first")
                )
                .foregroundStyle(model.error == nil ? Color.dockMetadataText : Color.dockWarning)
                .lineLimit(2)
                Spacer(minLength: 8)
                Toggle("Show archived", isOn: $model.includesArchived).toggleStyle(.checkbox).fixedSize()
            }
            .dockFont(.metadata).frame(minHeight: 22)
        }
        .dockPadding(.horizontal, 14).dockPadding(.vertical, 10)
        .background(Color.dockCanvas)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }

    private var visibilityTabs: some View {
        DockTabBar(options: ["All", "Public", "Private"], selection: $model.visibility, title: { $0 })
            .fixedSize(horizontal: true, vertical: false)
    }

    private var ownerPicker: some View {
        DockMenuPicker(title: model.owner, selection: $model.owner) {
            DockMenuOption("All owners", value: "All owners")
            ForEach(model.owners, id: \.self) { DockMenuOption($0, value: $0) }
        }.help("Filter repositories by account or organization")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(
                model.loading
                    ? "Loading repositories…"
                    : (model.error == nil ? "No repositories match this view" : "Repositories unavailable")
            )
            .dockFont(.body, weight: .semibold)
            Text(model.error == nil ? "Try another search, owner, or visibility filter." : "Refresh to try again.")
                .foregroundStyle(Color.dockMetadataText)
            if model.error != nil {
                Button("Retry") { Task { await model.refresh() } }
                    .buttonStyle(.dockSecondary).disabled(model.loading)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).dockPadding(20)
    }
}

private struct GitHubRepositoryRow: View {
    let repository: GitHubRepositorySummary
    let isSelected: Bool
    let showsOwner: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                (showsOwner
                    ? Text("\(repository.owner) / ").foregroundStyle(Color.dockMetadataText)
                        + Text(repository.name).fontWeight(.semibold)
                    : Text(repository.name).fontWeight(.semibold))
                    .dockFont(.body).foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1).truncationMode(.middle)
                if repository.isPrivate {
                    DockIcon(.lockSimple, size: 11, color: .dockMetadataText)
                        .accessibilityLabel("Private").help("Private repository")
                }
                Spacer(minLength: 4)
                if let updatedAt = repository.updatedAt {
                    Text(HumanDateFormatting.relative(updatedAt))
                        .dockFont(.metadata).foregroundStyle(Color.dockMetadataText).fixedSize()
                        .help("Last updated: \(updatedAt.formatted())")
                }
            }
            if !repository.description.isEmpty {
                Text(repository.description).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
            }
            GitHubRepositoryFacts(repository: repository)
        }
        .multilineTextAlignment(.leading)
        .dockListRow(isHighlighted: isSelected)
    }
}
