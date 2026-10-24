import Combine
import Foundation

/// References and disposable projections only; conversation history stays in Hermes.
@MainActor
final class PullRequestChatStore: ObservableObject {
    private var chats: [String: PullRequestChatModel] = [:]
    func chat(for record: PullRequestRecord) -> PullRequestChatModel {
        if let chat = chats[record.id] { return chat }
        let chat = PullRequestChatModel()
        chats[record.id] = chat
        return chat
    }
}

@MainActor
final class PullRequestChatModel: ObservableObject {
    @Published private(set) var conversation: DockModel?
    private let links: UserDefaults
    private var sessionLink: AnyCancellable?
    private var connectionLink: AnyCancellable?
    private var presentationSuite: String?
    private var eventSubscription: UUID?
    private weak var eventOwner: DockModel?

    init(links: UserDefaults = .standard) {
        self.links = links
    }

    func linkedDestination(for pr: PullRequestRecord) -> QuickDestination? {
        guard let data = links.data(forKey: "herm.pull-request-chat." + pr.id) else { return nil }
        return try? JSONDecoder().decode(QuickDestination.self, from: data)
    }

    func prepareConversation(for pr: PullRequestRecord, runtime: DockModel) async {
        guard conversation == nil else { return }
        // Keep this panel's preferences and disposable caches away from the workspace model.
        let identity = UUID().uuidString
        let suite = "herm.pr-chat.presentation." + identity
        let defaults = UserDefaults(suiteName: suite)!
        presentationSuite = suite
        defaults.set("default", forKey: runtime.profileScopeKey)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("herm-pr-chat-" + identity)
        let model = DockModel(
            sessionAgentStateFileURL: cache.appendingPathComponent("agents.json"), defaults: defaults,
            botActivityFileURL: cache.appendingPathComponent("bots.json"), rpcClient: runtime.controlRPCClient)
        connectionLink = runtime.$isHermesConnected.sink { [weak model] in model?.isHermesConnected = $0 }
        conversation = model
        eventOwner = runtime
        eventSubscription = runtime.eventRouter.subscribe { [weak model] type, params in
            model?.receiveGatewayEvent(type, params: params)
        }
        let linked = linkedDestination(for: pr)
        sessionLink = model.$sessionStorageID.compactMap { $0 }.sink { [weak self, weak model] sessionID in
            guard let self, let model else { return }
            let destination = QuickDestination(
                profileID: model.sessionProfileID ?? "default", sessionID: sessionID, runtimeID: model.sessionID,
                title: "PR #\(pr.displayNumber)", projectPath: pr.localPath.isEmpty ? nil : pr.localPath)
            if let data = try? JSONEncoder().encode(destination) {
                self.links.set(data, forKey: "herm.pull-request-chat." + pr.id)
            }
            runtime.rememberQuickSession(destination)
        }
        if let session = linked?.session {
            model.isRestoringSession = true
            _ = await model.resumeSession(session, reportFailure: true)
            model.isRestoringSession = false
        } else {
            model.newChat(projectPath: pr.localPath.isEmpty ? nil : pr.localPath)
        }
        model.attachedContexts.append(ChatContext(pullRequest: pr))
        model.refreshRuntimeModelOptions(sessionID: model.sessionID)
    }

    func shutdown() {
        if let eventSubscription { eventOwner?.eventRouter.unsubscribe(eventSubscription) }
        eventSubscription = nil
        sessionLink = nil
        connectionLink = nil
        if let presentationSuite { UserDefaults.standard.removePersistentDomain(forName: presentationSuite) }
        conversation?.shutdown()
    }
}
