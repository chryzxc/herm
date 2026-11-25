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
    private var identityLink: AnyCancellable?
    private var eventSubscription: UUID?
    private weak var eventOwner: DockModel?
    var onSessionIdentityChange: ((DockModel) -> Void)?

    var unavailableReason: String? {
        if isLoading { return "Wait for the conversation to finish loading." }
        if loadFailed { return "Reload the conversation before sending another message." }
        return conversation?.quickMessageUnavailableReason(for: conversation?.workflowSession)
    }

    var paneLoadFailed: Bool { loadFailed || conversation?.sessionTranscriptLoadState.failureMessage != nil }

    private func prepare(_ destination: QuickDestination, session: HermesSession, runtime: DockModel) -> DockModel {
        if destinationKey == destination.sessionKey, let conversation { return conversation }
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
            botActivityFileURL: cache.appendingPathComponent("bots.json"), loadArchives: false,
            rpcClient: runtime.controlRPCClient, refreshesSessionIndexFromEvents: false,
            sessionTranscriptCache: runtime.sessionTranscriptCache)
        model.defaultBotName = runtime.defaultBotName
        conversation = model
        connectionLink = runtime.$isHermesConnected.sink { [weak model] in model?.isHermesConnected = $0 }
        statusLink = Publishers.CombineLatest4(
            model.$status.removeDuplicates(), model.$isSending.removeDuplicates(),
            model.$isRestoringSession.removeDuplicates(), model.$sessionTranscriptLoadState.removeDuplicates()
        )
        .sink { [weak self] _ in self?.objectWillChange.send() }
        if onSessionIdentityChange != nil {
            identityLink = model.$sessionStorageID.combineLatest(model.$sessionID)
                .map { $0 ?? $1 }.removeDuplicates().receive(on: DispatchQueue.main)
                .sink { [weak self, weak model] _ in
                    guard let self, let model, conversation === model, !isLoading else { return }
                    onSessionIdentityChange?(model)
                }
        }
        eventOwner = runtime
        eventSubscription = model.subscribeSessionEvents(from: runtime.eventRouter, requestedSessionID: session.id)
        return model
    }

    func load(_ destination: QuickDestination, runtime: DockModel) async {
        guard !Task.isCancelled, let task = startLoad(destination, runtime: runtime) else { return }
        await withTaskCancellationHandler {
            _ = await task.value
        } onCancel: {
            task.cancel()
        }
    }

    @discardableResult
    func startLoad(_ destination: QuickDestination, runtime: DockModel) -> Task<Bool, Never>? {
        guard let session = destination.session else {
            shutdown()
            return nil
        }
        let model = prepare(destination, session: session, runtime: runtime)
        let request = UUID()
        generation = request
        isLoading = true
        loadFailed = false
        model.isRestoringSession = true
        let resume = model.startSessionResume(session, reportFailure: true)
        return Task { [weak self, weak model] in
            let loaded = await withTaskCancellationHandler {
                await resume.value
            } onCancel: {
                resume.cancel()
            }
            guard let self, let model, generation == request else { return false }
            model.isRestoringSession = false
            loadFailed = !loaded
            isLoading = false
            if loaded { onSessionIdentityChange?(model) }
            return loaded
        }
    }

    func retarget(_ destination: QuickDestination) { destinationKey = destination.sessionKey }

    func shutdown() {
        generation = UUID()
        if let eventSubscription { eventOwner?.eventRouter.unsubscribe(eventSubscription) }
        eventSubscription = nil
        eventOwner = nil
        connectionLink = nil
        statusLink = nil
        identityLink = nil
        if let conversation {
            conversation.cacheLeavingTranscript()
            conversation.sessionResumeGeneration &+= 1
        }
        conversation?.shutdown()
        conversation = nil
        destinationKey = nil
        isLoading = false
        loadFailed = false
        if let presentationSuite { UserDefaults.standard.removePersistentDomain(forName: presentationSuite) }
        presentationSuite = nil
    }
}
