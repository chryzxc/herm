import SwiftUI

struct GitHubRepositoriesView: View {
    @ObservedObject var model: GitHubRepositoriesModel
    @State var selected: GitHubRepositorySummary?

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if selected == nil || geometry.size.width >= 850 {
                    repositoryList.frame(maxWidth: .infinity)
                }
                if let selected {
                    if geometry.size.width >= 850 { Divider().overlay(Color.dockBorderLight) }
                    GitHubRepositoryOverview(
                        repository: model.repositories.first { $0.id == selected.id } ?? selected,
                        status: model.error ?? model.coverage ?? "Repository details",
                        refreshing: model.loading,
                        refresh: { Task { await model.refresh() } }, close: { self.selected = nil }
                    )
                    .id(selected.id)
                    .frame(width: geometry.size.width >= 850 ? 380 : nil)
                }
            }
        }
        .task { if !model.hasLoaded { await model.refresh() } }
    }

    private var repositoryList: some View {
        VStack(spacing: 0) {
            DockPageHeader(
                title: "Repositories",
                subtitle: model.loading
                    ? "Refreshing repositories…"
                    : (model.error ?? model.coverage ?? "Owned, collaborator & organization repositories"),
                onRefresh: { Task { await model.refresh() } }, isRefreshing: model.loading)
            if let requirement = model.accessRequirement, model.repositories.isEmpty {
                GitHubAccessRecoveryView(feature: "Repositories", requirement: requirement, isRetrying: model.loading) {
                    Task { await model.refresh() }
                }
            } else {
                toolbar
                Divider().overlay(Color.dockBorderLight)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.visible) { repository in
                            row(repository)
                            Divider().overlay(Color.dockBorderLight)
                        }
                        if model.visible.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(
                                    model.loading
                                        ? "Loading repositories…"
                                        : (model.error == nil ? "No repositories found" : "Repositories unavailable")
                                )
                                .font(.system(size: 12, weight: .semibold))
                                Text(
                                    model.error == nil
                                        ? "Try another search or include archived repositories."
                                        : "Refresh to try again."
                                )
                                .foregroundStyle(Color.dockSecondaryText)
                                if model.error != nil {
                                    Button("Retry") { Task { await model.refresh() } }
                                        .buttonStyle(.dockSecondary).disabled(model.loading)
                                }
                            }.padding(.vertical, 28)
                        }
                    }.padding(.horizontal, 16)
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.dockPrimaryText)
        .background(Color.dockCanvas)
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                search
                filters
            }
            VStack(alignment: .leading, spacing: 10) {
                search
                filters
            }
        }.padding(.horizontal, 20).padding(.bottom, 12)
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.dockSecondaryText)
            DockTextField("Find a repository", text: $model.query).textFieldStyle(.plain)
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(Color.dockSurface, in: RoundedRectangle(cornerRadius: DockLayout.controlRadius))
        .frame(minWidth: 180, maxWidth: 420)
    }

    private var filters: some View {
        HStack(spacing: 12) {
            DockMenuPicker(title: model.visibility, selection: $model.visibility) {
                ForEach(["All", "Public", "Private"], id: \.self) { DockMenuOption($0, value: $0) }
            }
            DockMenuPicker(title: model.owner, selection: $model.owner) {
                DockMenuOption("All owners", value: "All owners")
                ForEach(model.owners, id: \.self) { DockMenuOption($0, value: $0) }
            }
            Toggle("Archived", isOn: $model.includesArchived).toggleStyle(.checkbox)
            Spacer(minLength: 0)
        }.controlSize(.small)
    }

    private func row(_ repository: GitHubRepositorySummary) -> some View {
        Button {
            selected = repository
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(repository.languageAccent.color)
                    Text(repository.owner + " /").foregroundStyle(Color.dockSecondaryText)
                    Text(repository.name).fontWeight(.semibold)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10))
                        .foregroundStyle(Color.dockSecondaryText)
                }.lineLimit(1)
                if !repository.description.isEmpty {
                    Text(repository.description).fontWeight(.regular)
                        .foregroundStyle(Color.dockSecondaryText).lineLimit(1)
                }
                GitHubRepositoryMetadata(repository: repository).fontWeight(.regular)
            }
            .font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected?.id == repository.id ? Color.dockSurface : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityAddTraits(selected?.id == repository.id ? [.isSelected] : [])
        .help("View repository details")
    }
}
