import Combine
import Foundation

/// Voice-only state for the notch widget, the island, and the Talk stage, kept off
/// `DockModel` so a streamed token or a session refresh elsewhere in the model doesn't
/// redraw them, and a voice-only change doesn't redraw the rest of Herm.
@MainActor
final class VoiceStageState: ObservableObject {
    /// Apple Intelligence's plain-words line per tool step, keyed by
    /// `toolNarrationKey`; the voice stages show it in place of the tool's terms.
    @Published var toolNarrations: [String: String] = [:]
    /// The turn (its user message) whose Talk preview was closed; a new request brings previews back.
    @Published var dismissedVoicePreviewTurn: UUID?? = nil
    /// The inspector tab Talk shows beside the orb, asked for by voice or by Hermes this turn.
    @Published var voiceRevealedTab: VoiceTabReveal?
    /// Talk tabs on screen; while one shows voice, the notch stage stays out of the way.
    @Published var mountedTalkStages = 0
    /// What voice read from the front app for this turn, so sharing the screen is never silent.
    @Published var screenContext: VoiceScreenContext?
    @Published var localVisual: ChatMessage?
    @Published var liveVisual: ChatMessage?
    @Published var previewNavigation = RichVoicePreview.Navigation()
    var liveVisualTask: Task<Void, Never>?

    func clearLiveVisual() {
        liveVisualTask?.cancel()
        liveVisualTask = nil
        if liveVisual != nil { liveVisual = nil }
    }

    /// What the voice views read from the model. It republishes only when one of those values
    /// changes, which is what redraws the views; they still read the model itself.
    @Published private(set) var snapshot = VoiceStageSnapshot()

    private var sources: [AnyCancellable] = []
    private var scheduled = false
    private var spokenPrompt: SpokenPrompt?
    private var approvalReadoutTask: Task<Void, Never>?
    var explainApproval: (ApprovalPresentation) async -> String? = { approval in
        await OnDeviceAssist.explainApprovalForVoice(title: approval.title, detail: approval.detail)
    }
    var spokenApprovalID: UUID? { spokenPrompt?.approvalID }
    private var promptReadout: String?

    struct ClarificationKey: Hashable {
        let requestID: String
        let questionID: String?
    }

    func recordPromptReadout(_ text: String) {
        if spokenPrompt != nil { promptReadout = text }
    }

    func approvalReadout(for id: UUID?) -> String? {
        guard let id, spokenApprovalID == id else { return nil }
        return promptReadout
    }

    func matchesClarification(_ key: ClarificationKey, call: Int) -> Bool {
        spokenPrompt?.call == call && spokenPrompt?.clarification == key
    }

    func clarificationReadout(for key: ClarificationKey, call: Int) -> String? {
        matchesClarification(key, call: call) ? promptReadout : nil
    }

    private struct SpokenPrompt: Equatable {
        let call: Int
        let clarification: ClarificationKey?
        let approvalID: UUID?
        let speech: String
    }

    private func updateSpokenPrompt(_ model: DockModel) {
        guard model.voiceState.isNativeConversationActive else {
            cancelApprovalReadout()
            spokenPrompt = nil
            return
        }
        guard let speech = model.voicePromptSpeech else {
            cancelApprovalReadout()
            if spokenPrompt != nil { model.presentVoicePrompt(nil) }
            spokenPrompt = nil
            return
        }
        guard model.voiceState != .preparing, model.voiceState != .paused, model.answersVoicePromptsAloud
        else { return }
        let next = SpokenPrompt(
            call: model.voiceConversationGeneration,
            clarification: model.approvalText == nil ? model.voiceClarificationKey : nil,
            approvalID: model.approvalText == nil ? nil : model.currentConversationApproval?.id,
            speech: speech)
        guard next != spokenPrompt else { return }
        cancelApprovalReadout()
        promptReadout = nil
        spokenPrompt = next
        guard let approvalID = next.approvalID, let approval = model.approvalDetails,
            model.voiceRepliesEnabled, !approval.smartDenied, VoicePrompts.knownApprovalDescription(approval) == nil,
            model.voicePreferenceDefaults.bool(forKey: OnDeviceAssist.explainApprovalsKey)
        else {
            model.presentVoicePrompt(speech)
            return
        }
        // Keep the mic open while composing the readout. A late summary must not
        // interrupt the user's answer or describe a replaced request.
        model.presentVoicePrompt(speech, awaitingReadout: true)
        approvalReadoutTask = Task { [weak self, weak model, explainApproval] in
            let explanation = await explainApproval(approval)
            guard !Task.isCancelled, let self, self.spokenPrompt == next, let model,
                model.voiceConversationGeneration == next.call, model.voiceState == .listening,
                model.isVoicePromptActive, model.voiceRepliesEnabled, !model.isVoiceMicMuted,
                model.approvalDetails == approval, model.voiceApproval?.record.id == approvalID,
                model.voiceApproval?.answer?.blocksSubmission != true, model.voiceMic.transcript.isEmpty
            else { return }
            model.speakPresentedVoicePrompt(VoicePrompts.approvalSpeech(approval, explanation: explanation))
        }
    }

    private func cancelApprovalReadout() {
        approvalReadoutTask?.cancel()
        approvalReadoutTask = nil
    }

    /// Recomputes the snapshot once per main-queue turn after any model change.
    func observe(_ model: DockModel) {
        let schedule: () -> Void = { [weak self, weak model] in
            guard let self, !self.scheduled else { return }
            self.scheduled = true
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.scheduled = false
                    guard let model else { return }
                    self.updateSpokenPrompt(model)
                    let next =
                        model.voiceState == .inactive && self.mountedTalkStages == 0
                        ? VoiceStageSnapshot() : VoiceStageSnapshot(model: model)
                    if next != self.snapshot { self.snapshot = next }
                }
            }
        }
        sources = [
            model.objectWillChange.sink { _ in schedule() },
            // Helper bots change through the coalesced activity revision, not the model.
            model.activityPresentation.objectWillChange.sink { _ in schedule() },
        ]
    }
}

/// Every model value a voice view reads; equal snapshots mean nothing on the stage changed.
struct VoiceStageSnapshot: Equatable {
    var presentation: VoiceStagePresentation?
    var prompt: ConversationPromptState?
    var clarificationPreview: VoiceClarificationPreview?
    var actionsReady = false
    var lastUserText: String?
    var lastError: String?
    var caption: String?
    var botProfileID: String?
    var helpers: [HermesSubagent] = []
    var reply: ChatMessage?
    var floatingPreview: VoicePreview?
    var turnCalls: [ActiveToolCall] = []
    var working = false
    var repliesEnabled = true

    init() {}

    @MainActor init(model: DockModel) {
        presentation = VoiceStagePresentation(model: model)
        prompt = ConversationPromptState(model: model)
        clarificationPreview = VoiceClarificationPreview(model: model)
        actionsReady = model.sessionActionsReady
        lastUserText = model.messages.last(where: { $0.role == .user })?.text
        lastError = model.messages.last.flatMap { $0.isError ? $0.text : nil }
        caption = model.voiceSpokenCaption
        botProfileID = model.activeBotProfileID ?? model.sessionProfileID
        helpers = model.activeSubagents.filter(\.isRunning)
        reply = model.voiceGenerativeReply
        floatingPreview = model.voicePreview(on: .floating)
        turnCalls = model.voiceTurnToolCalls
        working = model.status == .working
        repliesEnabled = model.voiceRepliesEnabled
    }
}
