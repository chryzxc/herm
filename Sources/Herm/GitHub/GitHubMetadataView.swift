import SwiftUI

@MainActor
final class GitHubMetadataModel: ObservableObject {
    let reference: GitHubItemReference
    let service: GitHubMetadataService
    @Published private(set) var basic: GitHubMetadataSnapshot?
    @Published private(set) var projects: [GitHubProject]?
    @Published private(set) var development: [GitHubDevelopmentLink]?
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var loading = Set<String>()
    @Published private(set) var refreshedAt: Date?
    init(reference: GitHubItemReference, client: GitHubClient) { self.reference = reference; service = GitHubMetadataService(client: client) }
    var resolvedReference: GitHubItemReference { var value = reference; value.nodeID = basic?.nodeID ?? reference.nodeID; return value }
    func refresh() async {
        guard loading.isEmpty else { return }
        loading.insert("Details")
        do { basic = try await service.basic(reference); errors["Details"] = nil; refreshedAt = .now }
        catch { if !Task.isCancelled { errors["Details"] = error.localizedDescription } }
        loading.remove("Details")
        guard !Task.isCancelled, basic?.nodeID != nil else { return }
        async let p: Void = loadProjects()
        async let d: Void = loadDevelopment()
        _ = await (p, d)
    }
    func loadProjects() async {
        guard let id = basic?.nodeID, !loading.contains("Projects") else { return }
        loading.insert("Projects"); defer { loading.remove("Projects") }
        do { projects = try await service.projects(reference, nodeID: id); errors["Projects"] = nil }
        catch { if !Task.isCancelled { errors["Projects"] = error.localizedDescription } }
    }
    func loadDevelopment() async {
        guard let id = basic?.nodeID, !loading.contains("Development") else { return }
        loading.insert("Development"); defer { loading.remove("Development") }
        do { development = try await service.development(reference, nodeID: id); errors["Development"] = nil }
        catch { if !Task.isCancelled { errors["Development"] = error.localizedDescription } }
    }
}

enum GitHubMetadataSection: String, Identifiable, CaseIterable {
    case labels = "Labels", assignees = "Assignees", projects = "Projects", milestone = "Milestone", development = "Development"
    var id: Self { self }
}

/// Shared by Issues and Pull requests; it owns only the selected item's metadata/editor projection.
struct GitHubMetadataView: View {
    @StateObject private var model: GitHubMetadataModel
    @State private var editing: GitHubMetadataSection?
    @Environment(\.openGitHubItem) private var openItem
    let onChanged: () -> Void
    private var style: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }
    init(reference: GitHubItemReference, client: GitHubClient, onChanged: @escaping () -> Void = {}) {
        _model = StateObject(wrappedValue: GitHubMetadataModel(reference: reference, client: client)); self.onChanged = onChanged
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DockSectionHeader(title: "Details", style: style) {
                DockIconButton(icon: .arrowsClockwise, label: "Refresh GitHub details", isBusy: !model.loading.isEmpty, size: 24, style: style) { Task { await model.refresh() } }
            }
            if let error = model.errors["Details"] { Text(error).foregroundStyle(Color.dockWarning) }
            if model.basic == nil {
                Text(model.loading.contains("Details") ? "Loading details…" : "Details unavailable. Refresh to retry.").foregroundStyle(Color.dockSecondaryText)
            } else {
                metadataSection(.labels, editable: model.basic?.canTriage == true) {
                    if let labels = model.basic?.labels, !labels.isEmpty {
                        DockChipFlow {
                            ForEach(labels) { label in DockMetadataPill(text: label.name, colorHex: label.color).textSelection(.enabled) }
                        }
                    } else { none("No labels") }
                }
                metadataSection(.assignees, editable: model.basic?.canTriage == true) {
                    if let assignees = model.basic?.assignees, !assignees.isEmpty {
                        DockChipFlow {
                            ForEach(assignees, id: \.self) { DockMetadataPill(text: $0).textSelection(.enabled) }
                        }
                    } else { none("Unassigned") }
                }
                metadataSection(.projects, editable: model.projects != nil) {
                    if let projects = model.projects {
                        if projects.isEmpty { none("No projects") }
                        DockChipFlow {
                            ForEach(projects) { project in
                                let title = "\(project.title) · \(project.statusName ?? "No status")"
                                if let url = project.url {
                                    Link(destination: url) { DockMetadataPill(text: title, navigationIcon: .arrowSquareOut) }.buttonStyle(.dockHover)
                                } else { DockMetadataPill(text: title).textSelection(.enabled) }
                            }
                        }
                    } else if model.errors["Projects"] == nil {
                        none(model.loading.contains("Projects") ? "Loading…" : "Unavailable")
                    }
                }
                metadataSection(.milestone, editable: model.basic?.canTriage == true) {
                    if let milestone = model.basic?.milestone {
                        if let url = milestone.url {
                            Link(destination: url) { DockMetadataPill(text: milestone.title, navigationIcon: .arrowSquareOut) }.buttonStyle(.dockHover)
                        } else { DockMetadataPill(text: milestone.title).textSelection(.enabled) }
                        if let due = milestone.dueAt { Text("Due \(due.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(Color.dockMetadataText) }
                    } else { none("No milestone") }
                }
                metadataSection(.development, editable: model.development != nil && (model.basic?.canTriage == true || model.basic?.canUpdate == true)) {
                    if let links = model.development {
                        if links.isEmpty { none("No linked development work") }
                        ForEach(links) { link in
                            VStack(alignment: .leading, spacing: 3) {
                                if let ref = link.reference {
                                    Button { openItem(ref) } label: { DockMetadataPill(text: "\(ref.title) · \(link.title)", navigationIcon: .caretRight).multilineTextAlignment(.leading) }.buttonStyle(.dockHover)
                                } else if let url = link.url { Link(destination: url) { DockMetadataPill(text: link.title, navigationIcon: .arrowSquareOut) }.buttonStyle(.dockHover) }
                                Text(link.reference == nil ? "Linked branch" : "\(link.state.capitalized) · \(link.manuallyLinked ? "Manually linked" : "Linked by description")")
                                    .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                            }
                        }
                    } else { none(model.loading.contains("Development") ? "Loading development…" : "Development unavailable") }
                }
            }
        }
        .dockFont(.body).foregroundStyle(Color.dockPrimaryText).tint(Color.dockAccent)
        .dockCard(padding: 12)
        .task { await model.refresh() }
        .sheet(item: $editing) { section in
            GitHubMetadataEditor(model: model, section: section) { onChanged() }
        }
    }
    private func none(_ text: String) -> some View { Text(text).foregroundStyle(Color.dockSecondaryText) }
    private func metadataSection<Content: View>(_ section: GitHubMetadataSection, editable: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            DockSectionHeader(title: section.rawValue, style: style)
                .frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                content()
                if let error = model.errors[section.rawValue] {
                    HStack(spacing: 6) {
                        if section == .projects {
                            Text(model.projects == nil ? "Unavailable" : "Couldn’t refresh").foregroundStyle(Color.dockMetadataText)
                        } else {
                            Text("Couldn’t load").foregroundStyle(Color.dockMetadataText)
                        }
                        Button {
                            Task {
                                if section == .projects { await model.loadProjects() }
                                else { await model.loadDevelopment() }
                            }
                        } label: { GitHubActionLabel(title: "Retry", isBusy: model.loading.contains(section.rawValue)) }
                        .buttonStyle(.dockCompact).disabled(model.loading.contains(section.rawValue))
                    }.help(error)
                    .accessibilityHint(error)
                }
            }
            .padding(.top, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            if editable {
                DockIconButton(icon: .pencil, label: "Edit \(section.rawValue.lowercased())", size: 24, style: style) { editing = section }.disabled(!model.loading.isEmpty)
            }
        }
        .padding(.vertical, 6)
    }
}

struct GitHubMetadataEditor: View {
    @ObservedObject var model: GitHubMetadataModel
    let section: GitHubMetadataSection
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var names: Set<String>
    @State private var milestone: Int
    @State private var projectIDs: Set<String>
    @State private var statuses: [String: String]
    @State private var links: [GitHubDevelopmentLink]
    @State private var labels: [GitHubLabel] = []
    @State private var assignees: [String] = []
    @State private var milestones: [GitHubMilestone] = []
    @State private var projects: [GitHubProject] = []
    @State private var search = ""
    @State private var lookup = ""
    @State private var lookingUp = false
    @State private var saving = false
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?
    @State private var confirm = false
    private let original: GitHubMetadataSnapshot
    private let originalProjects: [GitHubProject]
    private let originalLinks: [GitHubDevelopmentLink]
    init(model: GitHubMetadataModel, section: GitHubMetadataSection, onChanged: @escaping () -> Void) {
        self.model = model; self.section = section; self.onChanged = onChanged
        let snapshot = model.basic ?? GitHubMetadataSnapshot(); original = snapshot
        originalProjects = model.projects ?? []; originalLinks = model.development ?? []
        _names = State(initialValue: section == .labels ? Set(snapshot.labels.map(\.name)) : Set(snapshot.assignees))
        _milestone = State(initialValue: snapshot.milestone?.number ?? 0)
        _projectIDs = State(initialValue: Set((model.projects ?? []).map(\.id)))
        _statuses = State(initialValue: Dictionary(uniqueKeysWithValues: (model.projects ?? []).map { ($0.id, $0.statusID ?? "") }))
        _links = State(initialValue: model.development ?? [])
    }
    var body: some View {
        DockModal(title: "Edit \(section.rawValue.lowercased())", subtitle: model.reference.title, width: 520) {
            TextField("Filter choices", text: $search).textFieldStyle(.dockGlass)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) { choices }.disabled(busy)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 120, maxHeight: 340)
            if section == .projects || section == .development {
                HStack {
                    TextField(section == .projects ? "GitHub Project URL" : "owner/repo#number or GitHub URL", text: $lookup).textFieldStyle(.dockGlass)
                    Button { Task { await lookUp() } } label: { GitHubActionLabel(title: lookingUp ? "Looking up…" : "Look up", isBusy: lookingUp) }.buttonStyle(.dockCompact).disabled(busy || lookup.isEmpty)
                }
            }
            Text(error ?? " ").dockFont(.body).foregroundStyle(Color.dockWarning).frame(minHeight: 34, alignment: .topLeading)
        } footer: {
            Button("Cancel") { dismiss() }.buttonStyle(.dockSecondary).disabled(busy)
            Spacer()
            Button { confirm = true } label: { GitHubActionLabel(title: saving ? "Saving…" : "Review changes", isBusy: saving) }.buttonStyle(.dockPrimary).disabled(!loaded || busy)
        }
        .confirmationDialog("Save changes to \(model.reference.title)?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Save \(section.rawValue.lowercased())") { Task { await save() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(changeSummary) }
        .interactiveDismissDisabled(busy)
        .task { await loadChoices() }
    }
    @ViewBuilder private var choices: some View {
        if !loaded {
            if busy { ProgressView("Loading choices…") }
            else { Button("Retry loading choices") { Task { await loadChoices() } }.buttonStyle(.dockCompact) }
        }
        switch section {
        case .labels:
            ForEach(labels.filter { matches($0.name) }) { label in
                Toggle(isOn: selection(label.name)) { VStack(alignment: .leading) { DockMetadataPill(text: label.name, colorHex: label.color); if !label.description.isEmpty { Text(label.description).foregroundStyle(Color.dockSecondaryText) } } }.toggleStyle(.dockSwitch)
            }
        case .assignees:
            ForEach(assignees.filter(matches), id: \.self) { name in Toggle(name, isOn: selection(name)).toggleStyle(.dockSwitch) }
        case .milestone:
            Picker("Milestone", selection: $milestone) {
                Text("None").tag(0)
                ForEach(milestones.filter { matches($0.title) }) { value in Text(value.title + (value.state == "closed" ? " (closed)" : "")).tag(value.number) }
            }.pickerStyle(.menu)
        case .projects:
            ForEach(projects.filter { matches($0.title) }) { project in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(project.title, isOn: Binding(get: { projectIDs.contains(project.id) }, set: { if $0 { projectIDs.insert(project.id) } else { projectIDs.remove(project.id) } })).toggleStyle(.dockSwitch).disabled(!project.canEdit)
                    if projectIDs.contains(project.id), project.statusFieldID != nil {
                        Picker("Status", selection: Binding(get: { statuses[project.id] ?? "" }, set: { statuses[project.id] = $0 })) {
                            Text("No status").tag("")
                            ForEach(project.statusOptions) { option in Text(option.name).tag(option.id) }
                        }.pickerStyle(.menu).disabled(!project.canEdit)
                    }
                    if !project.canEdit { Text("Read-only project").foregroundStyle(Color.dockSecondaryText) }
                }
            }
        case .development:
            ForEach(links.filter { matches($0.title) }) { link in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) { Text((link.reference.map { $0.title + " · " } ?? "") + link.title); if !link.manuallyLinked { Text("Edit the PR description to change keyword links.").foregroundStyle(Color.dockSecondaryText) } }
                    Spacer()
                    if link.manuallyLinked { Button("Remove") { links.removeAll { $0.id == link.id } }.buttonStyle(.dockCompact) }
                }
            }
        }
    }
    private func matches(_ value: String) -> Bool { search.isEmpty || value.localizedCaseInsensitiveContains(search) }
    private func selection(_ name: String) -> Binding<Bool> { Binding(get: { names.contains(name) }, set: { if $0 { names.insert(name) } else { names.remove(name) } }) }
    private var changeSummary: String {
        switch section {
        case .labels, .assignees: return "Selected \(section.rawValue.lowercased()): " + (names.isEmpty ? "None" : names.sorted().joined(separator: ", "))
        case .milestone: return "Milestone: " + (milestones.first { $0.number == milestone }?.title ?? "None")
        case .projects: return projects.map { project in project.title + ": " + (projectIDs.contains(project.id) ? (project.statusOptions.first { $0.id == statuses[project.id] }?.name ?? "No status") : "Not included") }.joined(separator: "\n")
        case .development: return "Linked work: " + links.map { $0.reference?.title ?? $0.title }.joined(separator: ", ")
        }
    }
    private func loadChoices() async {
        busy = true; defer { busy = false }
        do {
            switch section {
            case .labels: labels = try await model.service.labels(model.reference)
            case .assignees: assignees = Array(Set(try await model.service.assignees(model.reference)).union(original.assignees)).sorted()
            case .milestone: milestones = try await model.service.milestones(model.reference)
            case .projects:
                var all = Dictionary(uniqueKeysWithValues: try await model.service.projectChoices(model.reference).map { ($0.id, $0) })
                for current in originalProjects { all[current.id] = current }
                projects = all.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            case .development: break
            }
            loaded = true; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func lookUp() async {
        guard !busy else { return }
        busy = true; lookingUp = true; defer { busy = false; lookingUp = false }
        do {
            if section == .projects {
                let project = try await model.service.project(at: lookup)
                if !projects.contains(where: { $0.id == project.id }) { projects.append(project) }
            } else {
                let kind: GitHubItemKind = model.reference.kind == .issue ? .pullRequest : .issue
                guard let ref = GitHubReferenceParser.item(lookup, repository: model.reference.repository, kind: kind) else { throw GitHubRequestError.malformed }
                let link = try await model.service.resolve(ref)
                if !links.contains(where: { $0.id == link.id }) { links.append(link) }
            }
            lookup = ""; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard !busy else { return }; busy = true; saving = true; defer { busy = false; saving = false }
        do {
            let reference = model.resolvedReference
            switch section {
            case .labels: try await model.service.changeLabels(reference, adding: names.subtracting(original.labels.map(\.name)), removing: Set(original.labels.map(\.name)).subtracting(names))
            case .assignees: try await model.service.changeAssignees(reference, adding: names.subtracting(original.assignees), removing: Set(original.assignees).subtracting(names))
            case .milestone:
                let fresh = try await model.service.basic(reference)
                guard fresh.milestone == original.milestone else { throw GitHubRequestError.changed }
                try await model.service.setMilestone(reference, number: milestone == 0 ? nil : milestone)
            case .projects:
                guard let id = reference.nodeID else { throw GitHubRequestError.malformed }
                let current = try await model.service.projects(reference, nodeID: id)
                for project in projects {
                    let existing = originalProjects.first { $0.id == project.id }
                    let included = projectIDs.contains(project.id)
                    let status = statuses[project.id].flatMap { $0.isEmpty ? nil : $0 }
                    guard included != (existing != nil) || (included && status != existing?.statusID) else { continue }
                    guard project.canEdit else { throw GitHubRequestError.forbidden }
                    guard current.first(where: { $0.id == project.id })?.statusID == existing?.statusID else { throw GitHubRequestError.changed }
                    try await model.service.changeProject(existing ?? project, subjectID: id, included: included, statusID: status)
                }
            case .development:
                for link in originalLinks where link.manuallyLinked && !links.contains(where: { $0.id == link.id }) {
                    if let target = link.reference { try await model.service.link(reference, to: target, adding: false) }
                }
                for link in links where !originalLinks.contains(where: { $0.id == link.id }) {
                    if let target = link.reference { try await model.service.link(reference, to: target, adding: true) }
                }
            }
            await model.refresh(); onChanged(); dismiss()
        } catch {
            await model.refresh()
            self.error = "Could not save all changes. Current GitHub values were refreshed; your choices are retained. \(error.localizedDescription)"
        }
    }
}
