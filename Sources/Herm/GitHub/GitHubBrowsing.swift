import SwiftUI

enum GitHubBrowseState: String, CaseIterable, Identifiable, Codable {
    case open = "Open"
    case closed = "Closed"
    case all = "History"
    var id: Self { self }
    var qualifier: String {
        switch self {
        case .open: "is:open"
        case .closed: "is:closed"
        case .all: ""
        }
    }
}
enum GitHubBrowseSort: String, CaseIterable, Identifiable, Codable {
    case updated = "Recently updated"
    case oldest = "Oldest updated"
    case newest = "Newest created"
    var id: Self { self }
}
struct GitHubBrowseOptions: Codable, Equatable {
    var repository = ""
    var state: GitHubBrowseState = .open
    var sort: GitHubBrowseSort = .updated
    var label = ""
    var milestone = ""
    var assignee = ""
    var usesCustomQuery: Bool {
        !repository.isEmpty || state != .open || !label.isEmpty || !milestone.isEmpty || !assignee.isEmpty
    }
    func query(kind: GitHubItemKind, viewer: String?) throws -> String {
        var parts = [kind == .issue ? "is:issue" : "is:pr", state.qualifier]
        if !repository.isEmpty {
            guard GitHubReferenceParser.repository(repository) != nil else { throw GitHubRequestError.malformed }
            parts.append("repo:" + repository)
        } else {
            guard let viewer, !viewer.isEmpty else { throw GitHubRequestError.unauthorized }
            parts.append("involves:" + viewer)
        }
        for (name, value) in [("label", label), ("milestone", milestone), ("assignee", assignee)] where !value.isEmpty {
            guard !value.contains("\n"), !value.contains("\""), !value.contains("\\"), value.count <= 200 else {
                throw GitHubRequestError.malformed
            }
            parts.append(name + ":\"" + value + "\"")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct GitHubBrowseControls: View {
    let kind: GitHubItemKind
    let client: GitHubClient
    let repositories: [GitHubRepositoryReference]
    @Binding var options: GitHubBrowseOptions
    let refresh: () -> Void
    let onCreated: (GitHubItemReference) -> Void
    var isLoading = false
    @State private var editing = false
    @State private var filters = false
    @State private var draft = GitHubBrowseOptions()
    @State private var saved: GitHubBrowseOptions?
    private var key: String { "hermes.github.\(kind.rawValue).saved-view" }
    var body: some View {
        HStack(spacing: 6) {
            DockMenu {
                Button(kind == .issue ? "Your work and projects" : "My work") {
                    options.repository = ""
                    refresh()
                }
                ForEach(repositories) { repo in
                    Button(repo.id) {
                        options.repository = repo.id
                        refresh()
                    }
                }
                Divider()
                Button("Repository and metadata filters…") {
                    draft = options
                    filters = true
                }
            } label: {
                HStack(spacing: 4) {
                    DockIcon(.caretUpDown, size: 11, color: .dockSecondaryText)
                    if !options.repository.isEmpty { Text(options.repository).lineLimit(1) }
                }
            }
            .help("Repository")
            .accessibilityLabel(options.repository.isEmpty ? "Repository: all" : "Repository: \(options.repository)")
            HStack(spacing: 4) {
                DockOptionPicker(
                    selection: $options.state, options: GitHubBrowseState.allCases.map { ($0, $0.rawValue) }
                )
                .accessibilityLabel("State")
                .disabled(isLoading)
                .onChange(of: options.state) { _, _ in refresh() }
                ProgressView().controlSize(.mini)
                    .frame(width: 14, height: 14)
                    .opacity(isLoading ? 1 : 0)
                    .accessibilityLabel(
                        "Loading \(options.state.rawValue.lowercased()) \(kind == .issue ? "issues" : "pull requests")"
                    )
                    .accessibilityHidden(!isLoading)
            }
            Spacer(minLength: 0)
            Button(action: refresh) {
                DockIcon(.arrowClockwise, size: 14, color: Color.dockSecondaryText)
                    .frame(width: 28, height: 28)
                    .background(
                        DockThemeShape(cornerRadius: DockLayout.controlRadius - 1).dockSurfaceFill(
                            Color.dockControlSurface.opacity(0.6)))
            }
            .buttonStyle(.dockHover)
            .disabled(isLoading)
            .help("Refresh")
            .accessibilityLabel("Refresh \(kind == .issue ? "issues" : "pull requests")")
            DockMenu {
                DockMenuSection("Sort by") {
                    ForEach(GitHubBrowseSort.allCases) { sort in
                        DockMenuCheckRow(title: sort.rawValue, isSelected: options.sort == sort) {
                            options.sort = sort
                        }
                    }
                }
                Divider()
                DockMenuSection("Saved view") {
                    Button(saved == nil ? "Save current view" : "Update saved view", icon: .floppyDisk) {
                        if let data = try? JSONEncoder().encode(options) {
                            UserDefaults.standard.set(data, forKey: key)
                            saved = options
                        }
                    }
                    if let saved {
                        Button("Restore saved view", icon: .arrowCounterClockwise) {
                            options = saved
                            refresh()
                        }
                    }
                }
            } label: {
                DockIcon(.sliders, size: 14, color: Color.dockSecondaryText)
                    .frame(width: 28, height: 28)
                    .background(
                        DockThemeShape(cornerRadius: DockLayout.controlRadius - 1).dockSurfaceFill(
                            Color.dockControlSurface.opacity(0.6)))
            }
            .help("Sort and saved view")
            .accessibilityLabel("Sort and saved view")
            Button("New") { editing = true }.buttonStyle(.dockCompact).help(
                kind == .issue ? "Create issue" : "Create draft pull request")
        }.dockFont(.body)
            .task {
                if let data = UserDefaults.standard.data(forKey: key) {
                    saved = try? JSONDecoder().decode(GitHubBrowseOptions.self, from: data)
                }
            }
            .dockSheet(isPresented: $editing) {
                GitHubItemEditor(
                    kind: kind, client: client, repositories: repositories,
                    initialRepository: GitHubReferenceParser.repository(options.repository), onSaved: onCreated)
            }
            .dockSheet(isPresented: $filters) {
                DockModal(
                    title: "GitHub filters", subtitle: "Leave repository blank for your GitHub activity", width: 440
                ) {
                    TextField("owner/repository", text: $draft.repository).textFieldStyle(.dockGlass)
                    TextField("Label", text: $draft.label).textFieldStyle(.dockGlass)
                    TextField("Milestone", text: $draft.milestone).textFieldStyle(.dockGlass)
                    TextField("Assignee", text: $draft.assignee).textFieldStyle(.dockGlass)
                } footer: {
                    Button("Cancel") { filters = false }.buttonStyle(.dockSecondary)
                    Spacer()
                    Button("Apply filters") {
                        options = draft
                        filters = false
                        refresh()
                    }.buttonStyle(.dockPrimary).disabled(
                        !draft.repository.isEmpty && GitHubReferenceParser.repository(draft.repository) == nil)
                }
            }
    }
}
