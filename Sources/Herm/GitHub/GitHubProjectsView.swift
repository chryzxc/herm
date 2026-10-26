import SwiftUI

struct GitHubProjectsView: View {
    @ObservedObject var model: GitHubProjectsModel
    @Environment(\.openGitHubItem) private var openItem
    @State private var pendingStatus: GitHubProjectStatusChange?
    @State private var confirmsDraft = false
    @State private var confirmsProject = false
    @State private var choosingOwner = false
    private var style: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }
    private var canEdit: Bool {
        model.board?.project.canEdit == true && model.board?.project.closed == false
            && !model.loading && !model.saving && model.error == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            DockPageHeader(
                title: model.board?.project.title ?? "Projects",
                subtitle: model.loading ? "Refreshing…" : (model.error == nil ? subtitle : "Projects need attention")
            ) {
                if model.selectedID == nil && !model.needsProjectAccess {
                    Button("New project") { confirmsProject = true }
                        .buttonStyle(.dockPrimary).disabled(model.loading || model.saving || model.error != nil)
                }
                if model.saving { ProgressView().controlSize(.small).accessibilityLabel("Saving project") }
                DockIconButton(
                    icon: .arrowsClockwise, label: "Refresh projects", isBusy: model.loading, size: 28, style: style
                ) { Task { await model.refresh() } }
                .disabled(model.saving || model.loading)
            }
            toolbar
                .padding(.horizontal, 20).padding(.bottom, 12)
            Divider().overlay(Color.dockBorderLight)
            if let board = model.board {
                projectBoard(board)
            } else if model.needsProjectAccess {
                accessRecovery
            } else if model.selectedID != nil {
                emptyState(
                    "Project unavailable",
                    detail: model.loading ? "Fetching items from GitHub." : "Refresh to retry loading this project.")
            } else {
                projectList
            }
        }
        .background(Color.dockCanvas)
        .task { if model.projects.isEmpty && model.selectedID == nil { await model.browse() } }
        .confirmationDialog(
            "Change project status?",
            isPresented: Binding(
                get: { pendingStatus != nil }, set: { if !$0 { pendingStatus = nil } }
            ), titleVisibility: .visible
        ) {
            if let change = pendingStatus {
                Button("Move to \(change.name)") {
                    pendingStatus = nil
                    Task { await model.save(item: change.item, statusID: change.statusID) }
                }
            }
        } message: {
            if let change = pendingStatus {
                Text(
                    "Move “\(change.item.title)” to \(change.name) in \(model.board?.project.title ?? "this project") on GitHub."
                )
            }
        }
        .alert("Create a GitHub project", isPresented: $confirmsProject) {
            TextField("Project title", text: $model.newProjectTitle)
            Button("Cancel", role: .cancel) {}
            Button("Create project") { Task { await model.createProject() } }
                .disabled(model.newProjectTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Create a project owned by your signed-in GitHub account.")
        }
        .confirmationDialog("Add draft to GitHub project?", isPresented: $confirmsDraft, titleVisibility: .visible) {
            Button("Add draft") { Task { await model.save() } }
        } message: {
            Text("Add “\(model.draftTitle)” to \(model.board?.project.title ?? "this project").")
        }
    }

    private var subtitle: String {
        if let board = model.board {
            return
                "\(board.items.filter { !$0.archived }.count) items · \(board.project.closed ? "Closed project" : "GitHub Projects")"
        }
        return model.owner.isEmpty ? "Your GitHub projects" : "Projects owned by \(model.owner)"
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                scopePicker
                filters
            }
            VStack(alignment: .leading, spacing: 10) {
                scopePicker
                filters
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
    }

    @ViewBuilder private var scopePicker: some View {
        if model.selectedID != nil {
            Button("All projects") { Task { await model.browse() } }
                .buttonStyle(.dockCompact).disabled(model.saving)
        } else {
            Button {
                choosingOwner = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle")
                    Text(model.owner.isEmpty ? "My projects" : model.owner).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
            }
            .buttonStyle(.dockSecondary).disabled(model.saving || model.loading)
            .popover(isPresented: $choosingOwner) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Browse projects").font(.system(size: 12, weight: .semibold))
                    DockTextField("Account or organization", text: $model.owner).textFieldStyle(.dockGlass)
                    Text("Leave blank for your signed-in account.")
                        .font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
                    Button("Browse") {
                        choosingOwner = false
                        Task { await model.browse() }
                    }.buttonStyle(.dockPrimary)
                }.padding(16).frame(width: 300).background(Color.dockCanvas)
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.dockSecondaryText)
                DockTextField(model.selectedID == nil ? "Filter projects" : "Filter items", text: $model.search)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color.dockSurface, in: RoundedRectangle(cornerRadius: DockLayout.controlRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius).stroke(Color.dockBorderLight, lineWidth: 0.5)
            )
            .frame(maxWidth: 420)
            if model.selectedID == nil {
                DockMenuPicker(title: model.showsClosed ? "Closed" : "Open", selection: $model.showsClosed) {
                    DockMenuOption("Open", value: false)
                    DockMenuOption("Closed", value: true)
                }
            } else if let url = model.board?.project.url {
                Link("GitHub ↗", destination: url).buttonStyle(.dockCompact)
            }
            Spacer(minLength: 0)
        }
    }

    private var projectList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.visibleProjects) { project in
                    Button {
                        Task { await model.open(project) }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "rectangle.split.3x1").font(.system(size: 18))
                                .foregroundStyle(Color.dockSecondaryText)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(project.title).font(.system(size: 13, weight: .semibold))
                                Text(project.canEdit ? "Project · Can edit" : "Project · Read only")
                                    .font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Color.dockSecondaryText)
                        }.padding(.vertical, 16).padding(.horizontal, 12).contentShape(Rectangle())
                    }.buttonStyle(.dockHover).disabled(model.saving)
                    Divider().overlay(Color.dockBorderLight)
                }
                if model.visibleProjects.isEmpty && !model.loading {
                    emptyState(
                        model.error == nil ? "No projects found" : "Projects unavailable",
                        detail: model.error == nil
                            ? "Try another account, state, or search." : "Check GitHub access and refresh to retry.")
                }
            }.padding(20)
        }
    }

    private func projectBoard(_ board: GitHubProjectBoard) -> some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    column("No status", statusID: nil, board: board)
                    ForEach(board.project.statusOptions) { status in
                        column(status.name, statusID: status.id, board: board)
                    }
                }.padding(20)
            }
            if board.project.canEdit && !board.project.closed {
                HStack(spacing: 10) {
                    DockTextField("Add a draft item…", text: $model.draftTitle).textFieldStyle(.dockGlass)
                        .disabled(model.saving)
                    Button("Add item") { confirmsDraft = true }.buttonStyle(.dockPrimary)
                        .disabled(!canEdit || model.draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(20)
            }
        }
    }

    private func column(_ title: String, statusID: String?, board: GitHubProjectBoard) -> some View {
        let items = model.visibleItems.filter { item in
            statusID == nil
                ? item.statusID == nil
                    || !board.project.statusOptions.contains(where: { option in option.id == item.statusID })
                : item.statusID == statusID
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text("\(items.count)").font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText)
                Spacer()
            }.padding(.horizontal, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { item in itemCard(item, board: board) }
                    if items.isEmpty {
                        Text("No items").font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                }
            }
        }.padding(12).frame(width: 280).frame(maxHeight: .infinity)
            .background(Color.dockSidebar, in: RoundedRectangle(cornerRadius: 12))
    }

    private func itemCard(_ item: GitHubProjectItem, board: GitHubProjectBoard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let reference = item.reference {
                Text("\(reference.repository.id) #\(reference.number)")
                    .font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText)
                Button {
                    openItem(reference)
                } label: {
                    Text(item.title).multilineTextAlignment(.leading).font(.system(size: 12, weight: .semibold))
                }.buttonStyle(.dockLink)
            } else {
                Text(item.title).font(.system(size: 12, weight: .semibold)).textSelection(.enabled)
                if !item.body.isEmpty {
                    Text(item.body).font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(5).textSelection(.enabled)
                }
            }
            if board.project.statusFieldID != nil {
                Menu {
                    Button("No status") { pendingStatus = .init(item: item, statusID: nil, name: "No status") }
                    ForEach(board.project.statusOptions) { option in
                        Button(option.name) {
                            pendingStatus = .init(item: item, statusID: option.id, name: option.name)
                        }
                        .disabled(option.id == item.statusID)
                    }
                } label: {
                    Text(board.project.statusOptions.first { $0.id == item.statusID }?.name ?? "No status")
                }.menuStyle(.button).buttonStyle(.dockCompact).fixedSize().font(.system(size: 11))
                    .disabled(!canEdit)
                    .accessibilityLabel("Status for \(item.title)")
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.dockCanvas, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.dockBorderLight, lineWidth: 1))
    }

    private var accessRecovery: some View {
        GitHubAccessRecoveryView(
            feature: "Projects", requirement: .permission, projects: true,
            isRetrying: model.loading || model.saving
        ) { Task { await model.refresh() } }
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.loading ? "Loading project…" : title).font(.system(size: 12, weight: .semibold))
            Text(model.error ?? detail).font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
            if model.error != nil {
                Button("Retry") { Task { await model.refresh() } }
                    .buttonStyle(.dockSecondary).disabled(model.loading || model.saving)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(24)
    }
}

private struct GitHubProjectStatusChange {
    let item: GitHubProjectItem
    let statusID: String?
    let name: String
}
