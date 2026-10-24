import Combine
import Foundation

/// A disposable chat projection; Hermes owns its history and the notch owns its draft.
@MainActor
final class EdgeQuickConversationModel: ObservableObject {
    @Published private(set) var conversation: DockModel?
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    private var destinationKey: String?
    private var generation = UUID()
    private var presentationSuite: String?
    private var connectionLink: AnyCancellable?
    private var statusLink: AnyCancellable?
    private var eventSubscription: UUID?
    private weak var eventOwner: DockModel?

    var unavailableReason: String? {
        if isLoading { return "Wait for the conversation to finish loading." }
        if loadFailed { return "Reload the conversation before sending another message." }
        return conversation?.quickMessageUnavailableReason(for: conversation?.workflowSession)
    }

    func load(_ destination: QuickDestination, runtime: DockModel) async {
        guard let session = destination.session else {
            shutdown()
            return
        }
        if destinationKey != destination.sessionKey || conversation == nil {
            shutdown()
            destinationKey = destination.sessionKey
            let identity = UUID().uuidString
            let suite = "herm.quick-chat.presentation." + identity
            let defaults = UserDefaults(suiteName: suite)!
            presentationSuite = suite
            defaults.set(destination.profileID, forKey: runtime.profileScopeKey)
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent("herm-quick-chat-" + identity)
            let model = DockModel(
                sessionAgentStateFileURL: cache.appendingPathComponent("agents.json"), defaults: defaults,
                botActivityFileURL: cache.appendingPathComponent("bots.json"), rpcClient: runtime.controlRPCClient)
            conversation = model
            connectionLink = runtime.$isHermesConnected.sink { [weak model] in model?.isHermesConnected = $0 }
            statusLink = Publishers.CombineLatest3(model.$status, model.$isSending, model.$isRestoringSession)
                .sink { [weak self] _ in self?.objectWillChange.send() }
            eventOwner = runtime
            eventSubscription = runtime.eventRouter.subscribe { [weak model] type, params in
                model?.receiveGatewayEvent(type, params: params)
            }
        }
        guard let model = conversation else { return }
        let request = UUID()
        generation = request
        isLoading = true
        loadFailed = false
        model.isRestoringSession = true
        let loaded = await model.resumeSession(session, reportFailure: true)
        guard generation == request, !Task.isCancelled else { return }
        model.isRestoringSession = false
        loadFailed = !loaded
        isLoading = false
    }

    func shutdown() {
        generation = UUID()
        if let eventSubscription { eventOwner?.eventRouter.unsubscribe(eventSubscription) }
        eventSubscription = nil
        eventOwner = nil
        connectionLink = nil
        statusLink = nil
        if let conversation { conversation.sessionResumeGeneration &+= 1 }
        conversation?.shutdown()
        conversation = nil
        destinationKey = nil
        isLoading = false
        loadFailed = false
        if let presentationSuite { UserDefaults.standard.removePersistentDomain(forName: presentationSuite) }
        presentationSuite = nil
    }
}
