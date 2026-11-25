import Foundation

struct VoiceWidgetCaption: Equatable {
    enum Handoff: Hashable {
        case transcript
        case line(String)
    }

    let text: String
    let handoff: Handoff

    init(_ text: String, live: Bool = false) {
        self.text = text
        handoff = live ? .transcript : .line(text)
    }
}

/// What every voice surface (Talk tab, notch stage, island) shows for the
/// current voice state. Pure, so the Talk tab and the notch never disagree.
struct VoiceStagePresentation: Equatable {
    var voiceState: HermesVoiceState
    var status: HermesStatus
    var isMicMuted = false
    var hasSpokenCaption = false
    var answersAloud = true
    var wakesByVoice = false
    var wakeName = VoiceWakeShortcut.defaultWakeName
    /// Local-fallback capture and playback, owned by the Talk tab.
    var isRecording = false
    var isFallbackSpeaking = false
    var isCompacting = false
    var isReasoning = false
    var runningToolName: String?
    /// The latest tool step in plain words, for surfaces too small for the HUD cards.
    var stepTitle: String?
    var hasApproval = false
    var hasQuestion = false
    var sendingClarification = false
    var hasValuePrompt = false

    var orbMode: VoiceOrbMode {
        if isRecording { return .listening }
        if isFallbackSpeaking { return .speaking }
        switch voiceState {
        case .listening: return .listening
        case .transcribing, .interrupted: return .transcribing
        case .preparing, .thinking: return .thinking
        case .speaking: return hasSpokenCaption ? .speaking : .thinking
        case .paused, .inactive, .localFallback: return status == .working ? .thinking : .idle
        }
    }

    var orbHelp: String {
        switch orbMode {
        case .listening: "Send now"
        case .thinking, .speaking: "Interrupt"
        case .transcribing: "Transcribing"
        case .idle: "Resume listening"
        }
    }

    var statusText: String {
        if isMicMuted { return "MIC MUTED — TAP TO RESUME" }
        if voiceState == .speaking, !hasSpokenCaption { return "PREPARING SPOKEN REPLY" }
        if voiceState == .paused, wakesByVoice { return "SAY “HEY \(wakeName.uppercased())” OR TAP" }
        return voiceState.label
    }

    var interactionHint: String {
        if isMicMuted { return "Your microphone is off." }
        // While tools run, say what the agent is doing rather than a generic hint.
        if status == .working, voiceState != .listening, voiceState != .speaking, let stepTitle { return stepTitle }
        switch voiceState {
        case .listening: return "Speak naturally. Your request sends after a short pause."
        case .speaking: return answersAloud ? "Speak to interrupt, or tap Interrupt." : "Tap Interrupt to speak."
        case .thinking: return "You can keep talking to add to your request."
        case .paused: return "Tap Resume listening when you’re ready."
        default: return ""
        }
    }

    private var showsCompaction: Bool {
        isCompacting && orbMode == .thinking && !isMicMuted && !hasApproval && !hasQuestion && !hasValuePrompt
    }

    /// The voice widget's one quiet status word, in sentence case: what is happening now.
    var widgetStatus: String {
        if isMicMuted { return "Mic off" }
        if hasApproval { return "Approval needed" }
        if hasQuestion { return sendingClarification ? "Sending answer" : "Clarification needed" }
        if hasValuePrompt { return "Input needed in chat" }
        if showsCompaction { return "Compacting conversation" }
        switch orbMode {
        case .listening: return "Listening"
        case .transcribing: return "Got it"
        case .speaking: return "Speaking"
        case .thinking:
            if status == .working, let stepTitle { return stepTitle }
            return voiceState == .preparing ? "Starting" : "Thinking"
        case .idle: return wakesByVoice ? "Say “Hey \(wakeName)”" : "Paused"
        }
    }

    /// The widget's line, with one identity for all revisions to the live transcript.
    func widgetCaption(heard: String, said: String?, caption: String?, heldSpeech: String? = nil) -> VoiceWidgetCaption?
    {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = rawWidgetCaption(heard: heard, said: said, caption: caption, heldSpeech: heldSpeech)
        // A bullet or stray punctuation alone is not a line worth showing.
        guard let line, line.text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else {
            return nil
        }
        return line
    }

    private func rawWidgetCaption(
        heard: String, said: String?, caption: String?, heldSpeech: String?
    ) -> VoiceWidgetCaption? {
        // Do not flash back to the request while the next spoken sentence synthesizes.
        if voiceState == .speaking, let speech = caption ?? heldSpeech { return VoiceWidgetCaption(speech) }
        let transcript = heard.isEmpty ? nil : VoiceWidgetCaption(heard, live: true)
        let request = said.map { VoiceWidgetCaption($0) }
        if showsCompaction, transcript == nil {
            return VoiceWidgetCaption("Summarizing earlier messages before continuing.")
        }
        switch orbMode {
        case .listening:
            if caption == VoiceAssistantSession.pendingPromptMessage { return caption.map { VoiceWidgetCaption($0) } }
            return transcript
        case .transcribing:
            return transcript ?? request
        case .speaking:
            return caption.map { VoiceWidgetCaption($0) } ?? request
        case .thinking:
            if caption == VoiceAssistantSession.busyMessage || caption == VoiceAssistantSession.pendingPromptMessage {
                return caption.map { VoiceWidgetCaption($0) }
            }
            return voiceState == .thinking ? transcript ?? request : request
        case .idle:
            return nil
        }
    }

    /// Talk keeps its chat controls. The notch uses the caption instead.
    func showsPromptCard(clarificationCard: Bool) -> Bool {
        hasApproval || (clarificationCard && hasQuestion) || hasValuePrompt
    }

    var activityText: String {
        if isReasoning { return "HERM IS REASONING" }
        if let runningToolName { return "RUNNING \(runningToolName.uppercased())" }
        return "HERM IS THINKING"
    }
}

/// Where a voice stage is drawn. `floating` is the notch and the island.
enum VoiceSurface { case talkTab, maximized, floating }

enum VoicePreview: Equatable {
    case tab(SessionInspector.Section)
    /// The reply's generative UI.
    case visual
    /// The agent's screen: read-only extracts of its tool work.
    case agentScreen
}

extension VoiceStagePresentation {
    /// The one rule for what a voice surface previews this turn, until the next request or "close".
    /// The reply's generative UI shows everywhere. Herm's tabs, and the agent's screen built from
    /// them, show only in maximized Talk: the notch and island float over the real desktop, where
    /// the browser or terminal is already in view, and the Talk tab is too small.
    /// Order: a tab asked for this turn, then the visual, then the agent's screen (every step
    /// while it works, then only a step with a real view).
    static func preview(
        on surface: VoiceSurface, tab: SessionInspector.Section?, hasVisual: Bool, dismissed: Bool,
        working: Bool, calls: [ActiveToolCall]
    ) -> VoicePreview? {
        guard !dismissed else { return nil }
        if surface == .maximized, let tab { return .tab(tab) }
        if hasVisual { return .visual }
        guard surface == .maximized,
            working ? VoiceAgentScreen.hasSteps(calls) : VoiceAgentScreen.hasVisual(calls)
        else { return nil }
        return .agentScreen
    }

    @MainActor
    init(model: DockModel, isRecording: Bool = false, isFallbackSpeaking: Bool = false) {
        self.init(
            voiceState: model.voiceState, status: model.status,
            isMicMuted: model.isVoiceMicMuted, hasSpokenCaption: model.voiceSpokenCaption != nil,
            answersAloud: model.answersVoicePromptsAloud,
            wakesByVoice: model.voiceWakesByVoice && model.voiceMic.isRunning && model.voiceMic.isEndpointing
                && model.voiceMic.errorMessage == nil && model.voiceMic.utteranceTranscript != nil,
            wakeName: model.voiceWakeName,
            isRecording: isRecording, isFallbackSpeaking: isFallbackSpeaking,
            isCompacting: model.compactingSessionID.map { $0 == (model.voiceSessionID ?? model.sessionID) } ?? false,
            isReasoning: !(model.reasoningState?.text.isEmpty ?? true),
            runningToolName: model.activeToolCalls.first { !$0.isComplete }?.name,
            stepTitle: model.activeToolCalls.last { !$0.name.hasPrefix("__") }.map(model.toolStepTitle),
            hasApproval: model.approvalText != nil,
            hasQuestion: (model.status == .needsClarification || model.isRespondingToClarification)
                && model.clarificationQuestion != nil,
            sendingClarification: model.isRespondingToClarification,
            hasValuePrompt: model.valuePrompt != nil)
    }
}

/// The exact options for the current voice question, without an independent answer path.
struct VoiceClarificationPreview: Equatable {
    let key: VoiceStageState.ClarificationKey
    let choices: [String]
    let progress: String?
    let hint: String?

    @MainActor init?(model: DockModel) {
        guard model.voiceState.isNativeConversationActive, model.approvalText == nil, model.valuePrompt == nil,
            !model.clarificationChoices.isEmpty, let key = model.voiceClarificationKey
        else { return nil }
        self.key = key
        choices = model.clarificationChoices
        progress = model.clarificationProgress
        hint =
            (model.voiceState == .listening || model.voiceState == .speaking)
                && model.answersVoicePromptsAloud && !model.isVoiceMicMuted && !model.isRespondingToClarification
            ? VoicePrompts.clarificationHint(choices: choices, multiSelect: model.clarificationMultiSelect)
            : nil
    }
}
