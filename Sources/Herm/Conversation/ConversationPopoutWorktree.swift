import Combine
import Foundation

/// The worktree bar under a detached conversation's composer. The main window's bar reads
/// `DeveloperWorkflowModel.shared`, which follows the main chat's repository, so a detached
/// window lists its own session's worktrees instead of moving the shared model.
@MainActor
final class ConversationWorktreeState: ObservableObject {
    @Published private(set) var repositoryPath: String?
    /// Nil while loading, outside a Git repository, or when Git cannot list worktrees.
    @Published private(set) var worktrees: [RepositoryWorktreeSummary]?

    private let store = WorkspaceStore.shared
    private weak var model: DockModel?
    private weak var control: ControlCenterModel?
    private var link: AnyCancellable?
    private var projectsLink: AnyCancellable?
    private var loadTask: Task<Void, Never>?

    /// Follows the session's folder, which a worktree move or Hermes can change.
    func track(_ model: DockModel, control: ControlCenterModel) {
        self.model = model
        self.control = control
        link = Publishers.CombineLatest(model.$sessionWorkspace.map { $0?.repositoryPath }, model.$sessionID)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] _ in
                // The publishers fire in willSet; read the model once the change lands.
                DispatchQueue.main.async { self?.reload() }
            }
        // Hermes' project list can arrive after the window opens; resolve the folder again.
        projectsLink = control.$projects.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reload() } }
    }

    func stop() {
        link = nil
        projectsLink = nil
        loadTask?.cancel()
        loadTask = nil
    }

    func reload() {
        guard let model else { return }
        // The same lookup as the main chat: Hermes' folder first, then the sidebar's project.
        let path =
            model.sessionWorkspace?.repositoryPath
            ?? store.projectPath(forSessionID: model.navigationSessionID)
            ?? store.resolvedProjectPath(
                forSessionID: model.sessionID,
                hermesProjectPath: model.sessionID.flatMap { control?.project(forSessionID: $0)?.name },
                createdSessionProjectPath: model.sessionID.flatMap { model.createdSessionProjectPaths[$0] })
        if path != repositoryPath { worktrees = nil }
        repositoryPath = path
        loadTask?.cancel()
        guard let path else { return }
        loadTask = Task { [weak self] in
            let trees = await RepositoryService.worktrees(path: path)
            guard !Task.isCancelled, let self, self.repositoryPath == path else { return }
            self.worktrees = trees
        }
    }

    /// `openInMain` starts a chat in the main window, carrying this window's draft.
    func picker(for model: DockModel, openInMain: @escaping (String) -> Void) -> WorktreePicker? {
        guard let path = repositoryPath, let worktrees else { return nil }
        return WorktreePicker(
            worktrees: worktrees,
            selection: path,
            onOpenWorktree: { [weak self] target in
                guard await self?.isSelectable(target, from: path) == true else { return }
                openInMain(target)
            },
            onMoveChat: model.sessionID == nil
                ? nil
                : { [weak self, weak model] target in
                    guard await self?.isSelectable(target, from: path) == true, let model else { return }
                    await model.moveSessionWorkspace(to: target)
                },
            canMoveChat: model.canMoveSessionWorkspace,
            newTask: { [weak self] in await self?.startTask(from: path, openInMain: openInMain) }
        )
    }

    /// Re-reads the registered worktrees so a stale picker row cannot act.
    private func isSelectable(_ target: String, from path: String) async -> Bool {
        guard let trees = await RepositoryService.worktrees(path: path), repositoryPath == path,
            trees.contains(where: { $0.path == target && !$0.isPrunable }),
            FileManager.default.fileExists(atPath: target)
        else {
            if repositoryPath == path {
                model?.reportAttachmentError("The worktree is unavailable. Refresh and try again.")
            }
            return false
        }
        return target != path
    }

    /// Branches the shown worktree into a fresh one, as the main chat's **New task** does.
    private func startTask(from path: String, openInMain: (String) -> Void) async {
        do {
            let worktree = try await RepositoryService.createTaskWorktree(path: path, id: UUID())
            guard repositoryPath == path else { return }
            openInMain(worktree)
        } catch {
            model?.reportAttachmentError(HermesDiagnosticsService.safeSummary(error.localizedDescription))
        }
    }
}
