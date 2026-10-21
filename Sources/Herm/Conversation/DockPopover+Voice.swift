import AppKit
import Combine
import SwiftUI
import Foundation
import UniformTypeIdentifiers

extension DockPopover {
    /// Full voice mode: the stage covers the navigation and inspector panels,
    /// with activity cards popping in around the orb.
    var immersiveVoiceStage: some View {
        ZStack {
            Color.dockCanvas
            RadialGradient(colors: [Color.dockAccent.opacity(0.10), .clear], center: .center, startRadius: 40, endRadius: 700)
            voiceStage(immersive: true)
        }
        .ignoresSafeArea()
    }

    func voiceStage(immersive: Bool) -> some View {
        let style = DockThemePalette(theme: dockThemeStore.selectedThemeID)
        let captions = voiceCaptions
        let orbScale: CGFloat = immersive ? 1.45 : 1
        return VStack(spacing: 0) {
            VoiceStatusStrip(model: model, repositoryPath: activeSessionRepositoryPath)
                .padding(.top, 12)
                .padding(.horizontal, 16)
            Spacer(minLength: 12)
            Button(action: handleVoiceOrbTap) {
                VoiceMeteredOrb(
                    mode: voiceOrbMode, speech: speechInput.reading, mic: micLevelMeter.reading,
                    showsRing: voiceOrbMode == .listening && !speechInput.isRecording,
                    hermFaceID: conversationHermFaceID)
                    .scaleEffect(orbScale)
                    .frame(width: 320 * orbScale, height: 320 * orbScale)
                    .contentShape(Circle())
            }
            .buttonStyle(.dockHover)
            .help(voiceOrbHelp)
            .accessibilityLabel(voiceOrbHelp)

            voiceStatusLabel
                .frame(height: 40)

            if !model.activeSubagents.isEmpty {
                VoiceSubagentOrbs(agents: model.activeSubagents)
                    .padding(.bottom, 8)
            }

            if hasPendingVoicePrompt {
                // Approvals and questions block the turn, so they take the
                // captions' place until answered.
                voicePromptCard
                    .frame(maxWidth: immersive ? 520 : 420)
                    .shadow(color: (model.approvalText != nil ? Color.dockWarning : Color.dockAccent).opacity(0.35), radius: 28)
                    .padding(.horizontal, 16)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            } else {
            VStack(spacing: 8) {
                if let user = captions.user {
                    Text(user)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if let reply = captions.reply {
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        let cue = voiceSubtitles.cue(
                            messageID: reply.id,
                            text: reply.text,
                            now: context.date.timeIntervalSinceReferenceDate
                        )
                        MarkdownMessageView(
                            markdown: cue ?? "",
                            bodySize: immersive ? 17 : 14, bodyWeight: .medium
                        )
                            .equatable()
                            .lineLimit(3)
                            .id(cue)
                            .transition(.opacity)
                            .animation(.dockEase(duration: 0.2), value: cue)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: immersive ? 560 : 360, minHeight: 96, alignment: .top)
            .padding(.horizontal, 16)
            }

            voiceControls(style: style)
                .padding(.top, 10)
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // A pending approval or question dims everything else.
            VoiceActivityPillsLayer(model: model, cardWidth: immersive ? 280 : 200, cronJobs: controlCenter.cronJobs,
                                    leavesLeftFree: !voiceHUD.cards.isEmpty)
                .padding(immersive ? 24 : 12)
                .opacity(hasPendingVoicePrompt ? 0.2 : 1)
        }
        .overlay(alignment: .leading) {
            GeometryReader { geometry in
                let inset: CGFloat = immersive ? 24 : 12
                let width = min(immersive ? 300.0 : 210.0, max(0, (geometry.size.width - inset * 2 - 12) / 2))
                ViewThatFits(in: .vertical) {
                    VoiceHUDDeck(state: voiceHUD, width: width)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView(.vertical) {
                        VoiceHUDDeck(state: voiceHUD, width: width)
                    }
                    .scrollIndicators(.hidden)
                }
                .frame(width: width, height: geometry.size.height)
                .padding(.leading, inset)
                .opacity(hasPendingVoicePrompt ? 0.2 : 1)
                .allowsHitTesting(!hasPendingVoicePrompt)
            }
        }
        .overlay { VoiceWakeFlash(count: model.wakeCount) }
        .onChange(of: model.activeToolCalls) { _, calls in voiceHUD = VoiceHUDState(calls: calls) }
        .animation(.dockEase(duration: 0.3), value: model.voiceState)
        .animation(.dockEase(duration: 0.25), value: captions.user)
        .animation(.dockEase(duration: 0.25), value: captions.reply == nil)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: hasPendingVoicePrompt)
        .onAppear {
            voiceHUD = VoiceHUDState(calls: model.activeToolCalls)
            beginVoiceConversation()
        }
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
        case .speaking: return .speaking
        case .paused, .inactive, .localFallback: return model.status == .working ? .thinking : .idle
        }
    }

    var voiceOrbHelp: String {
        switch voiceOrbMode {
        case .listening: "Tap to send now"
        case .thinking, .speaking: "Tap to interrupt"
        case .transcribing: "Transcribing"
        case .idle: "Tap to resume listening"
        }
    }

    @ViewBuilder
    var voiceStatusLabel: some View {
        if let detail = model.voiceState.fallbackDetail, !speechInput.isRecording, !voiceOutput.isSpeaking {
            Text("LOCAL FALLBACK · \(detail)")
                .font(.system(size: 12, weight: .medium))
                .tracking(0.35)
                .foregroundStyle(Color.dockWarning)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        } else if model.voiceState.isNativeConversationActive {
            VStack(spacing: 4) {
                Text(voiceStatusText)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.75)
                    .foregroundStyle(model.voiceState == .listening ? Color.dockSuccess : (model.voiceState == .paused ? Color.dockMetadataText : Color.dockAccent))
                    .contentTransition(.opacity)
            }
        } else if model.status == .working && !speechInput.isRecording {
            voiceActivityIndicator
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else if speechInput.isRecording || voiceOutput.isSpeaking {
            Text(speechInput.isRecording ? "\(model.agentDisplayName.uppercased()) IS LISTENING" : "\(model.agentDisplayName.uppercased()) IS SPEAKING")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.75)
                .foregroundStyle(speechInput.isRecording ? Color.dockSuccess : Color.dockAccent)
        }
    }

    /// Approvals keep their card so the command stays readable; questions
    /// are asked aloud instead when spoken answers work.
    var hasPendingVoicePrompt: Bool {
        model.approvalText != nil
            || (showsVoiceClarificationCard && model.status == .needsClarification && model.clarificationQuestion != nil)
            || model.valuePrompt != nil
    }

    var showsVoiceClarificationCard: Bool {
        model.voiceState.isNativeConversationActive ? !model.answersVoicePromptsAloud : speechInput.isUnavailable
    }

    /// The same prompt rows the chat shows, floated on the voice stage.
    @ViewBuilder
    var voicePromptCard: some View {
        if let approval = model.approvalText {
            approvalRow(model.approvalDetails ?? ApprovalPresentation(
                title: model.approvalTitle ?? "Review requested action",
                detail: approval,
                detailIsCommand: model.approvalTitle == "Run command"
            ))
        } else if showsVoiceClarificationCard, model.status == .needsClarification, model.clarificationQuestion != nil {
            clarificationRow
        } else if let prompt = model.valuePrompt {
            valuePromptRow(prompt)
        }
    }

    /// What you said and what the agent is saying, so the conversation reads
    /// like live captions rather than a hidden transcript.
    var voiceCaptions: (user: String?, reply: (id: UUID, text: String)?) {
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
              let userIndex = model.messages.lastIndex(where: { $0.role == .user }) else { return (nil, nil) }
        let reply = model.messages[(userIndex + 1)...].last { $0.role == .hermes }
        let text = reply.map(GenerativeUIIntegration.readableText)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (
            "“" + model.messages[userIndex].text + "”",
            reply.flatMap { text.isEmpty ? nil : ($0.id, text) }
        )
    }

    func voiceControls(style: DockThemePalette) -> some View {
        HStack(spacing: 14) {
            if model.voiceState.isNativeConversationActive {
                DockIconButton(
                    icon: .waveform,
                    label: model.voiceRepliesEnabled ? "Mute spoken replies" : "Speak replies aloud",
                    isProminent: model.voiceRepliesEnabled,
                    size: 34,
                    style: style
                ) { model.toggleVoiceReplies() }
                DockIconButton(
                    icon: model.isVoiceMicMuted ? .microphoneSlash : .microphone,
                    label: model.isVoiceMicMuted ? "Unmute microphone" : "Mute microphone",
                    isProminent: model.isVoiceMicMuted,
                    size: 34,
                    style: style
                ) { model.toggleVoiceMicMuted() }
            }
            switch voiceOrbMode {
            case .listening:
                DockIconButton(icon: .arrowUp, label: "Send now", size: 34, style: style, action: handleVoiceOrbTap)
            case .thinking, .speaking:
                DockIconButton(icon: .stop, label: "Interrupt", size: 34, style: style, action: handleVoiceOrbTap)
            case .idle:
                // While muted, the mute toggle is the resume control.
                if !model.isVoiceMicMuted {
                    DockIconButton(icon: .play, label: "Resume listening", size: 34, style: style, action: handleVoiceOrbTap)
                }
            case .transcribing:
                DockIconButton(icon: .microphone, label: "Transcribing", isBusy: true, size: 34, style: style) {}
            }
            DockIconButton(
                icon: isVoiceImmersive ? .cornersIn : .cornersOut,
                label: isVoiceImmersive ? "Exit full voice mode" : "Full voice mode",
                size: 34,
                style: style
            ) { isVoiceImmersive.toggle() }
            .keyboardShortcut(isVoiceImmersive ? .cancelAction : nil)
            DockIconButton(icon: .x, label: "End voice conversation", size: 34, style: style, action: exitVoiceMode)
        }
    }

    var wakesByVoice: Bool {
        model.answersVoicePromptsAloud && MicLevelMeter.canDetectWakePhrase
    }

    var voiceStatusText: String {
        if model.isVoiceMicMuted { return "MIC MUTED — TAP TO RESUME" }
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
        // A pending approval or question waits for a spoken answer.
        let awaitsAnswer = model.voicePromptSpeech != nil
        guard sessionWorkspaceMode == .voice,
              !model.voiceState.isNativeConversationActive,
              model.status == .idle || awaitsAnswer,
              !model.isSending || awaitsAnswer,
              !speechInput.isRecording,
              !speechInput.isStarting,
              !voiceOutput.isSpeaking else { return }
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
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.6)
                .lineLimit(1)
        }
        .foregroundStyle(Color.dockAccent)
        .padding(.horizontal, 13)
        .frame(height: 32)
        .background(Capsule().fill(Color.dockSurface6).stroke(Color.dockAccent.opacity(0.25), lineWidth: 0.5))
        .shadow(color: Color.dockAccent.opacity(0.12), radius: 10)
    }

    var voiceActivityText: String {
        if let reasoning = model.reasoningState, !reasoning.text.isEmpty {
            return "HERMES IS REASONING"
        }
        if let tool = model.activeToolCalls.first(where: { !$0.isComplete }) {
            return "RUNNING \(tool.name.uppercased())"
        }
        return "HERMES IS THINKING"
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
                if showsRing { VoiceListeningRing(progress: mic.turnProgress).padding(36) }
            }
    }
}
