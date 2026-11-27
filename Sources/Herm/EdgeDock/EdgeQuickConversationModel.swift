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
    private var projection: DisposableChatProjection?
    private var statusLink: AnyCancellable?
    private var identityLink: AnyCancellable?

    var onSessionIdentityChange: ((DockModel) -> Void)?

    var unavailableReason: String? {
        if isLoading { return "Wait for the conversation to finish loading." }
        if loadFailed { return "Reload the conversation before sending another message." }
        return conversation?.quickMessageUnavailableReason(for: conversation?.workflowSession)
    }

    var paneLoadFailed: Bool { loadFailed || conversation?.sessionTranscriptLoadState.failureMessage != nil }

    /// Owns the hands-free call separately from the workspace's selected chat.
    func prepareVoice(runtime: DockModel) -> DockModel {
        let model = prepare(QuickDestination(), runtime: runtime, voiceTimers: runtime.voiceTimers)
        model.isNotchVoiceConversation = true
        model.voiceAssistant.preferenceDefaults = runtime.defaults
        model.botMode = runtime.botMode
        model.briefingFacts = { [weak runtime] in await runtime?.briefingFacts?() ?? VoiceBriefing.Facts() }
        return model
    }

    private func prepare(
        _ destination: QuickDestination, runtime: DockModel, voiceTimers: VoiceTimerBoard? = nil
    ) -> DockModel {
        if destinationKey == destination.sessionKey, let conversation { return conversation }
        shutdown()
        destinationKey = destination.sessionKey
        let projection = DisposableChatProjection(
            surface: .quick, profileID: destination.profileID, sessionID: destination.sessionID,
            runtime: runtime, voiceTimers: voiceTimers)
        self.projection = projection
        let model = projection.model
        model.defaultBotName = runtime.defaultBotName
        conversation = model

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
        let model = prepare(destination, runtime: runtime)
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
        statusLink = nil
        identityLink = nil
        projection?.shutdown(invalidateResume: true)
        projection = nil
        conversation = nil
        destinationKey = nil
        isLoading = false
        loadFailed = false
    }
}
