import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension DockPopover {
    /// Full voice mode: the stage covers the navigation and inspector panels,
    /// with activity cards popping in around the orb.
    var immersiveVoiceStage: some View {
        ZStack {
            Color.dockCanvas
            RadialGradient(
                colors: [Color.dockAccent.opacity(0.10), .clear], center: .center, startRadius: 40, endRadius: 700)
            voiceStage(immersive: true)
        }
        .ignoresSafeArea()
    }

    func voiceStage(immersive: Bool) -> some View {
        GeometryReader { geometry in
            voiceStage(immersive: immersive, size: geometry.size)
        }
        .onAppear {
            beginVoiceConversation()
        }
    }

    private func voiceStage(immersive: Bool, size: CGSize) -> some View {
        let style = DockThemePalette(theme: dockThemeStore.selectedThemeID)
        let captions = voiceCaptions
        let generativeReply = voiceGenerativeReply
        let layout = VoiceStageLayout(
            size: size, immersive: immersive, hasPanel: generativeReply != nil,
            cardsEnabled: UserDefaults.standard.object(forKey: VoiceStageSettings.activityPillsKey) as? Bool ?? true)
        let orbScale = layout.orbSide / 320
        let stage = VStack(spacing: 0) {
            VoiceStatusStrip(model: model)
                .dockPadding(.top, 12)
                .dockPadding(.horizontal, 16)
            Spacer(minLength: 12)
            Button(action: handleVoiceOrbTap) {
                VoiceMeteredOrb(
                    mode: voiceOrbMode, speech: speechInput.reading, mic: micLevelMeter.reading,
                    showsRing: voiceOrbMode == .listening && !speechInput.isRecording,
                    hermFaceID: conversationHermFaceID
                )
                .scaleEffect(orbScale)
                .frame(width: 320 * orbScale, height: 320 * orbScale)
                .contentShape(Circle())
            }
            .buttonStyle(.dockHover)
            .help(voiceOrbHelp)
            .accessibilityLabel(voiceOrbHelp)

            VStack(spacing: 6) {
                if let error = micLevelMeter.errorMessage {
                    Text(error)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockWarning)
                        .multilineTextAlignment(.center)
                    Button("Retry microphone") {
                        micLevelMeter.stop()
                        handleVoiceStateChange(model.voiceState)
                    }
                    .buttonStyle(.dockCompact)
                } else if model.voiceState == .paused, let message = model.messages.last, message.isError {
                    Text(message.text)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockWarning)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                } else if micLevelMeter.isStarting {
                    Text("Starting microphone…")
                        .dockFont(.body)
                        .foregroundStyle(Color.dockSecondaryText)
                } else {
                    voiceStatusLabel
                    Text(voiceInteractionHint)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockSecondaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: min(480, layout.columnWidth), minHeight: 76, maxHeight: 76)
            .dockPadding(.horizontal, 16)

            if !model.activeSubagents.isEmpty {
                VoiceSubagentOrbs(agents: model.activeSubagents)
                    .dockPadding(.bottom, 8)
            }

            if hasPendingVoicePrompt {
                // Approvals and questions block the turn, so they take the
                // captions' place until answered.
                voicePromptCard
                    .frame(maxWidth: min(immersive ? 520 : 420, max(0, size.width - 32)))
                    .shadow(
                        color: (model.approvalText != nil ? Color.dockWarning : Color.dockAccent).opacity(0.35),
                        radius: 28
                    )
                    .dockPadding(.horizontal, 16)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            } else {
                VStack(spacing: 8) {
                    if let user = captions.user {
                        Text(user)
                            .dockFont(.navigation, weight: .medium)
                            .foregroundStyle(Color.dockSecondaryText)
                            .lineLimit(2)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if let generativeReply, !layout.showsPanelBeside {
                        // Too narrow to sit beside the stage: the panel
                        // takes the reply caption's place.
                        voiceGenerativeCard(generativeReply, immersive: immersive)
                            .frame(maxHeight: 260)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else if let caption = model.voiceState.isNativeConversationActive
                        ? model.voiceSpokenCaption : captions.reply?.text
                    {
                        VoiceReplyCaption(text: caption, immersive: immersive)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: layout.columnWidth, minHeight: 96, alignment: .top)
                .dockPadding(.horizontal, 16)
            }

            voiceControls(style: style)
                .dockPadding(.top, 10)
                .dockPadding(.horizontal, 16)
            Spacer(minLength: 12)
            // Fixed slot so the compact card never covers the controls.
            Color.clear.frame(height: layout.compactCardSlot)
        }
        .frame(maxWidth: .infinity, minHeight: size.height)
        .background {
            // A pending approval or question dims everything else.
            VoiceActivityPillsLayer(
                model: model, cardWidth: layout.cardWidth, isCompact: layout.isCompact,
                cronJobs: controlCenter.cronJobs
            )
            .dockPadding(immersive ? 24 : 12)
            .opacity(hasPendingVoicePrompt ? 0.2 : 1)
        }
        // Very short panes scroll rather than clip the controls.
        let scrollingStage = ScrollView(.vertical) { stage }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
        // A reply with generative UI slides in on the right and pushes the
        // stage left; the next user message returns the stage to the center.
        return HStack(spacing: 0) {
            scrollingStage
            if let generativeReply, layout.showsPanelBeside {
                voiceGenerativePanel(generativeReply, immersive: immersive)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity)
                                .combined(with: .scale(scale: 0.96, anchor: .trailing)),
                            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .trailing))))
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: generativeReply?.id)
        .animation(.dockEase(duration: 0.3), value: model.voiceState)
        .animation(.dockEase(duration: 0.25), value: captions.user)
        .animation(.dockEase(duration: 0.25), value: captions.reply == nil)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: hasPendingVoicePrompt)
    }

    /// The current turn's reply when it carries generative UI.
    var voiceGenerativeReply: ChatMessage? {
        guard GenerativeUIIntegration.isEnabled else { return nil }
        let start = model.messages.lastIndex { $0.role == .user }.map { $0 + 1 } ?? model.messages.startIndex
        return model.messages[start...].last {
            $0.role == .hermes && !$0.isError && RichDocument.mentionsSurface($0.text)
        }
    }

    /// A floating card beside the stage: inset from every edge, centered,
    /// hugging short replies and scrolling tall ones.
    func voiceGenerativePanel(_ message: ChatMessage, immersive: Bool) -> some View {
        voiceGenerativeCard(message, immersive: immersive)
            .dockPadding(.vertical, immersive ? 56 : 40)
            .dockPadding(.trailing, immersive ? 40 : 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func voiceGenerativeCard(_ message: ChatMessage, immersive: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: DockLayout.paneRadius + 8, style: .continuous)
        let content = GenerativeUIIntegration.renderReply(message.text) { MarkdownMessageView(markdown: message.text) }
            .generativeUIMessage(model: model, message: message)
            .textSelection(.enabled)
            .dockPadding(18)
        return ViewThatFits(in: .vertical) {
            content.fixedSize(horizontal: false, vertical: true)
            ScrollView { content }.scrollIndicators(.never)
        }
        .frame(maxWidth: immersive ? 560 : 440)
        .clipShape(shape)
        .dockFloatingSurface(shape, stroke: Color.dockBorderLight)
        .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
    }

    var conversationHermFaceID: String? {
        botMode.orbHermFaceID(profileID: model.activeBotProfileID ?? model.sessionProfileID)
    }

    var voiceOrbMode: VoiceOrbMode {
        if speechInput.isRecording { return .listening }
        if voiceOutput.isSpeaking { return .speaking }
        switch model.voiceState {
        case .listening: return .listening
        case .transcribing, .interrupted: return .transcribing
        case .preparing, .thinking: return .thinking
        case .speaking: return model.voiceSpokenCaption == nil ? .thinking : .speaking
        case .paused, .inactive, .localFallback: return model.status == .working ? .thinking : .idle
        }
    }

    var voiceOrbHelp: String {
        switch voiceOrbMode {
        case .listening: "Send now"
        case .thinking, .speaking: "Interrupt"
        case .transcribing: "Transcribing"
        case .idle: "Resume listening"
        }
    }

    @ViewBuilder
    var voiceStatusLabel: some View {
        if let detail = model.voiceState.fallbackDetail, !speechInput.isRecording, !voiceOutput.isSpeaking {
            Text("LOCAL FALLBACK · \(detail)")
                .dockFont(.body, weight: .medium)
                .tracking(0.35)
                .foregroundStyle(Color.dockWarning)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        } else if model.voiceState.isNativeConversationActive {
            VStack(spacing: 4) {
                Text(voiceStatusText)
                    .dockFont(.body, weight: .semibold)
                    .tracking(0.75)
                    .foregroundStyle(
                        model.voiceState == .listening
                            ? Color.dockSuccess
                            : (model.voiceState == .paused ? Color.dockMetadataText : Color.dockAccent)
                    )
                    .contentTransition(.opacity)
            }
        } else if model.status == .working && !speechInput.isRecording {
            voiceActivityIndicator
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else if speechInput.isRecording || voiceOutput.isSpeaking {
            Text(
                speechInput.isRecording
                    ? "\(model.agentDisplayName.uppercased()) IS LISTENING"
                    : "\(model.agentDisplayName.uppercased()) IS SPEAKING"
            )
            .dockFont(.body, weight: .semibold)
            .tracking(0.75)
            .foregroundStyle(speechInput.isRecording ? Color.dockSuccess : Color.dockAccent)
        }
    }

    /// Approvals keep their card so the command stays readable; questions
    /// are asked aloud instead when spoken answers work.
    var hasPendingVoicePrompt: Bool {
        model.approvalText != nil
            || (showsVoiceClarificationCard && model.status == .needsClarification
                && model.clarificationQuestion != nil)
            || model.valuePrompt != nil
    }

    var showsVoiceClarificationCard: Bool {
        model.voiceState.isNativeConversationActive ? !model.answersVoicePromptsAloud : speechInput.isUnavailable
    }

    /// The same prompt rows the chat shows, floated on the voice stage.
    @ViewBuilder
    var voicePromptCard: some View {
        ConversationPromptRows(
            model: model, conversationMetrics: conversationMetrics,
            showsClarification: showsVoiceClarificationCard, exclusive: true
        )
    }

    /// What you said and what the agent is saying, so the conversation reads
    /// like live captions rather than a hidden transcript.
    var voiceCaptions: (user: String?, reply: (id: UUID, text: String)?) {
        if model.voiceState == .preparing { return (nil, nil) }
        if speechInput.isRecording || (model.voiceState.isNativeConversationActive && voiceOrbMode == .listening) {
            let live = speechInput.isRecording ? speechInput.transcript : micLevelMeter.transcript
            let partial = live.trimmingCharacters(in: .whitespacesAndNewlines)
            return (partial.isEmpty ? nil : partial, nil)
        }
        // Talking over a running turn steers it; show what is being heard.
        let steering = micLevelMeter.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.voiceState == .thinking, !steering.isEmpty { return ("→ " + steering, nil) }
        // While Hermes transcribes, the last user line is the previous turn.
        guard voiceOrbMode != .listening, voiceOrbMode != .idle, voiceOrbMode != .transcribing,
            let userIndex = model.messages.lastIndex(where: { $0.role == .user })
        else { return (nil, nil) }
        let reply = model.messages[(userIndex + 1)...].last { $0.role == .hermes }
        let text =
            reply.map(GenerativeUIIntegration.readableText)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (
            "“" + model.messages[userIndex].text + "”",
            reply.flatMap { text.isEmpty ? nil : ($0.id, text) }
        )
    }

    func voiceControls(style: DockThemePalette) -> some View {
        VStack(spacing: 12) {
            // Narrow panes put End voice on its own row instead of clipping.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    voiceMuteControls
                    endVoiceButton
                }
                VStack(spacing: 10) {
                    HStack(spacing: 10) { voiceMuteControls }
                    endVoiceButton
                }
            }
            HStack(spacing: 12) {
                Button(voiceOrbHelp, action: handleVoiceOrbTap)
                    .buttonStyle(.dockPrimary)
                    .disabled(model.voiceState == .preparing || model.voiceState == .transcribing)
                DockIconButton(
                    icon: isVoiceImmersive ? .cornersIn : .cornersOut,
                    label: isVoiceImmersive ? "Exit full voice mode" : "Full voice mode",
                    size: 34, style: style
                ) { isVoiceImmersive.toggle() }
                .keyboardShortcut(isVoiceImmersive ? .cancelAction : nil)
            }
        }
    }

    @ViewBuilder
    private var voiceMuteControls: some View {
        if model.voiceState.isNativeConversationActive {
            Button(model.isVoiceMicMuted ? "Unmute mic" : "Mute mic") { model.toggleVoiceMicMuted() }
                .buttonStyle(.dockSecondary)
            Button(model.voiceRepliesEnabled ? "Mute replies" : "Speak replies") { model.toggleVoiceReplies() }
                .buttonStyle(.dockSecondary)
        }
    }

    private var endVoiceButton: some View {
        Button("End voice", action: exitVoiceMode)
            .buttonStyle(.dockSecondary)
    }

    var voiceInteractionHint: String {
        if model.isVoiceMicMuted { return "Your microphone is off." }
        switch model.voiceState {
        case .listening: return "Speak naturally. Your request sends after a short pause."
        case .speaking:
            return model.answersVoicePromptsAloud ? "Speak to interrupt, or tap Interrupt." : "Tap Interrupt to speak."
        case .thinking: return "You can keep talking to add to your request."
        case .paused: return "Tap Resume listening when you’re ready."
        default: return ""
        }
    }

    var wakesByVoice: Bool {
        model.answersVoicePromptsAloud && MicLevelMeter.canDetectWakePhrase
    }

    var voiceStatusText: String {
        if model.isVoiceMicMuted { return "MIC MUTED — TAP TO RESUME" }
        if model.voiceState == .speaking, model.voiceSpokenCaption == nil { return "PREPARING SPOKEN REPLY" }
        if model.voiceState == .paused, wakesByVoice {
            return "SAY “HEY \(model.agentDisplayName.uppercased())” OR TAP"
        }
        return model.voiceState.label(agentName: model.agentDisplayName)
    }

    func handleVoiceOrbTap() {
        switch model.voiceState {
        case .listening:
            model.finishVoiceUtterance(transcript: micLevelMeter.utteranceTranscript)
            return
        case .thinking, .speaking:
            model.interruptVoiceTurn()
            return
        case .paused:
            model.resumeVoiceListening()
            return
        case .preparing, .transcribing, .interrupted:
            return
        case .inactive, .localFallback:
            break
        }
        if speechInput.isRecording {
            speechInput.finishUtterance()
        } else if voiceOutput.isSpeaking {
            voiceOutput.stop()
        } else if model.status == .working {
            stopCurrentRequest()
        } else {
            beginVoiceConversation()
        }
    }

    func beginVoiceConversation() {
        if case .localFallback = model.voiceState {
            resumeVoiceConversationIfReady()
        } else {
            model.startVoiceConversation()
        }
    }

    func resumeVoiceConversationIfReady() {
        guard case .localFallback = model.voiceState, model.voiceSessionID == model.sessionID else { return }
        // A pending approval or question waits for a spoken answer.
        let awaitsAnswer = model.voicePromptSpeech != nil
        guard sessionWorkspaceMode == .voice,
            !model.voiceState.isNativeConversationActive,
            model.status == .idle || awaitsAnswer,
            !model.isSending || awaitsAnswer,
            !speechInput.isRecording,
            !speechInput.isStarting,
            !voiceOutput.isSpeaking
        else { return }
        // A new local turn resets transient capture failures. Leaving the old
        // error as a guard made the voice orb's retry action a permanent no-op.
        speechInput.startListening()
    }

    func exitVoiceMode() {
        releaseVoiceCapture()
        sessionWorkspaceMode = .chat
    }

    func stopCurrentRequest() {
        if sessionWorkspaceMode == .voice {
            suppressNextVoiceResponse = true
            voiceOutput.stop()
        }
        model.stop()
    }

    var voiceActivityIndicator: some View {
        HStack(spacing: 8) {
            ThinkingDots()
            Text(voiceActivityText)
                .dockFont(.body, weight: .semibold)
                .tracking(0.6)
                .lineLimit(1)
        }
        .foregroundStyle(Color.dockAccent)
        .dockPadding(.horizontal, 13)
        .frame(height: 32)
        .background(Capsule().fill(Color.dockSurface6).stroke(Color.dockAccent.opacity(0.25), lineWidth: 0.5))
        .shadow(color: Color.dockAccent.opacity(0.12), radius: 10)
    }

    var voiceActivityText: String {
        if let reasoning = model.reasoningState, !reasoning.text.isEmpty {
            return "HERM IS REASONING"
        }
        if let tool = model.activeToolCalls.first(where: { !$0.isComplete }) {
            return "RUNNING \(tool.name.uppercased())"
        }
        return "HERM IS THINKING"
    }
}

/// Observes only the meter readings, so per-buffer level changes redraw the
/// orb and not the whole popover.
private struct VoiceMeteredOrb: View {
    let mode: VoiceOrbMode
    @ObservedObject var speech: VoiceMeterReading
    @ObservedObject var mic: VoiceMeterReading
    let showsRing: Bool
    let hermFaceID: String?

    var body: some View {
        VoiceOrbView(mode: mode, audioLevel: max(speech.level, mic.level), hermFaceID: hermFaceID)
            .frame(width: 320, height: 320)
            .overlay {
                if showsRing { VoiceListeningRing(progress: mic.turnProgress).dockPadding(36) }
            }
    }
}
