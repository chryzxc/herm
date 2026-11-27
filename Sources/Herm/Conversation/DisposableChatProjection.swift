import Combine
import Foundation

/// Owns only the resources borrowed by a disposable conversation projection.
@MainActor
final class DisposableChatProjection {
    enum Surface {
        case pullRequest
        case quick

        var prefix: String {
            switch self {
            case .pullRequest: return "pr-chat"
            case .quick: return "quick-chat"
            }
        }

        var loadsArchives: Bool { self == .pullRequest }
        var followsReasoning: Bool { self == .pullRequest }
    }

    let model: DockModel
    private let suite: String
    private weak var eventOwner: DockModel?
    private var eventSubscription: UUID?
    private var connectionLink: AnyCancellable?
    private var reasoningLink: AnyCancellable?

    init(
        surface: Surface, profileID: String, sessionID: String?, runtime: DockModel,
        voiceTimers: VoiceTimerBoard? = nil, identity: String = UUID().uuidString
    ) {
        suite = "herm.\(surface.prefix).presentation." + identity
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(profileID, forKey: runtime.profileScopeKey)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("herm-\(surface.prefix)-" + identity)
        model = DockModel(
            sessionAgentStateFileURL: cache.appendingPathComponent("agents.json"), defaults: defaults,
            botActivityFileURL: cache.appendingPathComponent("bots.json"), loadArchives: surface.loadsArchives,
            rpcClient: runtime.controlRPCClient, refreshesSessionIndexFromEvents: false,
            sessionTranscriptCache: runtime.sessionTranscriptCache, voiceTimers: voiceTimers,
            voiceCapture: surface == .quick ? runtime.voiceCapture : nil)
        connectionLink = runtime.$isHermesConnected.sink { [weak model] in model?.isHermesConnected = $0 }
        if surface.followsReasoning {
            reasoningLink = runtime.$defaultReasoningVariant.sink { [weak model] in model?.defaultReasoningVariant = $0 }
        }
        eventOwner = runtime
        eventSubscription = model.subscribeSessionEvents(from: runtime.eventRouter, requestedSessionID: sessionID)
    }

    func shutdown(invalidateResume: Bool) {
        if let eventSubscription { eventOwner?.eventRouter.unsubscribe(eventSubscription) }
        eventSubscription = nil
        eventOwner = nil
        connectionLink = nil
        reasoningLink = nil
        UserDefaults.standard.removePersistentDomain(forName: suite)
        model.cacheLeavingTranscript()
        if invalidateResume { model.sessionResumeGeneration &+= 1 }
        model.shutdown()
    }
}
