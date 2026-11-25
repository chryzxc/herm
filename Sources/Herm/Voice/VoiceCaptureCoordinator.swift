/// One voice call per Hermes runtime, even when its conversation has several workspace projections.
@MainActor
final class VoiceCaptureCoordinator {
    private(set) weak var owner: DockModel?
    weak var standby: DockModel?
    var onStartNotchVoice: (() -> Void)?
    private var recorderShutdown: Task<Void, Never>?

    func claim(_ model: DockModel) -> Task<Void, Never>? {
        guard owner !== model else { return recorderShutdown }
        // Reserve before stopping the old owner so standby can't restart in the handoff.
        let previous = owner
        owner = model
        if standby !== model, standby?.voiceState == .inactive { standby?.syncVoiceCapture() }
        previous?.stopVoiceConversation()
        if let cleanup = previous?.voiceRequestChain { recorderShutdown = cleanup }
        return recorderShutdown
    }

    func release(_ model: DockModel) {
        guard owner === model else { return }
        if let cleanup = model.voiceRequestChain { recorderShutdown = cleanup }
        owner = nil
        standby?.syncVoiceCapture()
    }
}
