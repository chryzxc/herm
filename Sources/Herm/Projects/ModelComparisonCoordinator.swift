import Foundation

struct ModelComparisonRun: Identifiable {
    let id = UUID()
    let option: HermesModelOption
    var directory: String?
    var session: HermesSession?
    var taskID: String?
    var error: String?
}

/// An explicit fan-out using Hermes' existing background task contract.
@MainActor
final class ModelComparisonCoordinator: ObservableObject {
    @Published private(set) var runs: [ModelComparisonRun] = []
    @Published private(set) var starting = false
    func start(path: String, prompt: String, options: [HermesModelOption], model: DockModel) {
        guard !starting, runs.isEmpty, (2...3).contains(options.count),
            !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        starting = true
        runs = options.map { ModelComparisonRun(option: $0) }
        let profile = model.profileScopeID
        let client = model.controlRPCClient
        Task { @MainActor in
            defer { starting = false }
            let workflow = HermesWorkflowRPC(client: client, profileID: profile)
            for index in runs.indices {
                do {
                    let directory = try await RepositoryService.createTaskWorktree(path: path, id: runs[index].id)
                    runs[index].directory = directory
                    let setup = await workflow.createIsolatedSession(path: directory, text: prompt, id: runs[index].id)
                    runs[index].session = setup.draft.destination.session
                    guard setup.error == nil, let session = setup.draft.destination.session else {
                        throw QuickDraftError.message(
                            setup.error ?? "The comparison session could not be confirmed. The worktree was kept.")
                    }
                    try await workflow.setSessionModel(session, option: runs[index].option)
                    let (runtime, running) = try await workflow.resumeOwned(session)
                    guard !running else {
                        throw QuickDraftError.message(
                            "The comparison session is already busy. Open it before retrying.")
                    }
                    let result = try await HermesControlRPC(client: client).startBackgroundPrompt(
                        sessionID: runtime, text: GenerativeUIIntegration.preparePrompt(prompt))
                    guard let taskID = result["task_id"] as? String, !taskID.isEmpty else {
                        throw QuickDraftError.message(
                            "Hermes did not confirm a background task. Check the comparison session before retrying.")
                    }
                    runs[index].taskID = taskID
                    model.registerBackgroundTask(id: taskID, prompt: prompt, parentSessionID: session.id)
                } catch { runs[index].error = error.localizedDescription }
            }
        }
    }
}
