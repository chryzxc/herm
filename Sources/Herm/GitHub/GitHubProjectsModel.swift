import SwiftUI

@MainActor
final class GitHubProjectsModel: ObservableObject {
    let service: GitHubProjectsService
    @Published var owner = ""
    @Published var search = ""
    @Published var showsClosed = false
    @Published var draftTitle = ""
    @Published var newProjectTitle = ""
    @Published private(set) var projects: [GitHubProject] = []
    @Published private(set) var board: GitHubProjectBoard?
    @Published private(set) var selectedID: String?
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var needsProjectAccess = false
    private var loadedOwner: String?
    private var generation = 0

    init(client: GitHubClient = GitHubClient()) { service = GitHubProjectsService(client: client) }

    var visibleProjects: [GitHubProject] {
        projects.filter { $0.closed == showsClosed && (search.isEmpty || $0.title.localizedStandardContains(search)) }
    }
    var visibleItems: [GitHubProjectItem] {
        (board?.items ?? []).filter {
            !$0.archived
                && (search.isEmpty || $0.title.localizedStandardContains(search)
                    || $0.reference?.repository.id.localizedStandardContains(search) == true)
        }
    }

    func browse() async {
        guard !saving else { return }
        generation += 1
        let request = generation
        selectedID = nil
        board = nil
        let scope = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        if loadedOwner != scope { projects = [] }
        search = ""
        loading = true
        error = nil
        needsProjectAccess = false
        defer { if request == generation { loading = false } }
        do {
            let result = try await service.projects(owner: scope)
            try Task.checkCancellation()
            guard request == generation else { return }
            projects = result
            loadedOwner = scope
        } catch {
            if request == generation && !Task.isCancelled {
                needsProjectAccess = error as? GitHubRequestError == .insufficientScopes
                self.error = Self.message(error)
            }
        }
    }

    func open(_ project: GitHubProject) async {
        guard !saving else { return }
        generation += 1
        let request = generation
        selectedID = project.id
        board = nil
        search = ""
        draftTitle = ""
        error = nil
        loading = true
        defer { if request == generation { loading = false } }
        do {
            let result = try await service.board(project.id)
            try Task.checkCancellation()
            guard request == generation else { return }
            board = result
        } catch { if request == generation && !Task.isCancelled { self.error = Self.message(error) } }
    }

    func refresh() async {
        guard !loading, !saving else { return }
        guard let id = selectedID else {
            await browse()
            return
        }
        loading = true
        let request = generation
        defer { if request == generation { loading = false } }
        do {
            let result = try await service.board(id)
            try Task.checkCancellation()
            guard request == generation else { return }
            board = result
            error = nil
        } catch { if request == generation && !Task.isCancelled { self.error = Self.message(error) } }
    }

    func createProject() async {
        guard !saving, !loading, selectedID == nil else { return }
        saving = true
        do {
            let project = try await service.createProject(title: newProjectTitle)
            newProjectTitle = ""
            owner = ""
            showsClosed = false
            projects.append(project)
            saving = false
            await open(project)
        } catch {
            saving = false
            self.error = Self.message(error)
            DockActionErrorCenter.shared.report("Could not create project", error: error)
        }
    }

    func save(item: GitHubProjectItem? = nil, statusID: String? = nil) async {
        guard let id = selectedID, let board, board.project.canEdit, !board.project.closed,
            !saving, !loading, error == nil
        else { return }
        saving = true
        defer { saving = false }
        do {
            if let item {
                try await service.setStatus(projectID: id, item: item, statusID: statusID)
            } else {
                try await service.addDraft(projectID: id, title: draftTitle)
                draftTitle = ""
            }
            do {
                self.board = try await service.board(id)
                error = nil
            } catch { self.error = "Saved on GitHub. Refresh to reload the board. " + Self.message(error) }
        } catch {
            self.error = Self.message(error)
            DockActionErrorCenter.shared.report("Could not update project", error: error)
        }
    }

    static func message(_ error: Error) -> String {
        if error as? GitHubRequestError == .insufficientScopes {
            return
                "GitHub Projects access is missing. Authorize Projects for your existing GitHub credential, then retry."
        }
        return HermesDiagnosticsService.safeSummary(error.localizedDescription)
    }
}
