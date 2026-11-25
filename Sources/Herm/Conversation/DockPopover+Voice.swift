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
        let stageModel = model
        return GeometryReader { geometry in
            VoiceStageVisualContent(stage: stageModel.voiceStage) {
                VoiceMicrophoneContent(meter: stageModel.voiceMic) { meter in
                    voiceStage(immersive: immersive, size: geometry.size, meter: meter)
                }
            }
        }
        .onAppear {
            stageModel.mountedTalkStages += 1
            beginVoiceConversation()
        }
        .onDisappear { stageModel.mountedTalkStages -= 1 }
        .id(ObjectIdentifier(stageModel))
    }

    private func voiceStage(immersive: Bool, size: CGSize, meter: MicLevelMeter) -> some View {
        let style = DockThemePalette(theme: dockThemeStore.selectedThemeID)
        let captions = voiceCaptions(meter: meter)
        let preview = model.voicePreview(on: immersive ? .maximized : .talkTab)
        let shownTab: SessionInspector.Section? = if case .tab(let section) = preview { section } else { nil }
        let generativeReply = preview == .visual ? model.voiceGenerativeReply : nil
        let showsScreen = preview == .agentScreen
        let layout = VoiceStageLayout(
            size: size, immersive: immersive, hasPanel: shownTab != nil || generativeReply != nil || showsScreen,
            cardsEnabled: UserDefaults.standard.object(forKey: VoiceStageSettings.activityPillsKey) as? Bool ?? true)
        let orbScale = layout.orbSide / 320
        let stage = VStack(spacing: 0) {
            VoiceStatusStrip(model: model)
                .dockPadding(.top, 12)
                .dockPadding(.horizontal, 16)
            Spacer(minLength: 12)
            Button(action: handleVoiceOrbTap) {
                VoiceMeteredOrb(
                    mode: voiceOrbMode, speech: speechInput.reading, mic: meter.reading,
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
                if let error = meter.errorMessage {
                    Text(error)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockWarning)
                        .multilineTextAlignment(.center)
                    Button("Retry microphone") {
                        meter.stop()
                        model.syncVoiceCapture()
                    }
                    .buttonStyle(.dockCompact)
                } else if model.voiceState == .paused, let message = model.messages.last, message.isError {
                    Text(message.text)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockWarning)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                } else if meter.isStarting {
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
                    } else if showsScreen, !layout.showsPanelBeside {
                        // Too narrow to sit beside the stage: the screen takes the reply caption's slot.
                        VoiceAgentScreen(model: model, showsLog: false)
                            .frame(maxHeight: 260)
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
            // The agent screen's step log carries the steps while it shows.
            .opacity(showsScreen ? 0 : hasPendingVoicePrompt ? 0.2 : 1)
        }
        // Very short panes scroll rather than clip the controls.
        let scrollingStage = ScrollView(.vertical) { stage }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
        // A reply with generative UI slides in on the right and pushes the
        // stage left; the next user message returns the stage to the center.
        return HStack(spacing: 0) {
            scrollingStage
            if let shownTab, layout.showsPanelBeside {
                voiceTabPanel(shownTab, style: style)
                    .transition(voicePanelTransition)
            } else if let generativeReply, layout.showsPanelBeside {
                voiceGenerativePanel(generativeReply, immersive: immersive)
                    .transition(voicePanelTransition)
            } else if showsScreen, layout.showsPanelBeside {
                VoiceAgentScreen(model: model)
                    .frame(maxWidth: immersive ? 560 : 440)
                    .dockPadding(.vertical, immersive ? 56 : 40)
                    .dockPadding(.trailing, immersive ? 40 : 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(voicePanelTransition)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: generativeReply?.id)
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: showsScreen)
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: shownTab)
        .animation(.dockEase(duration: 0.3), value: model.voiceState)
        .animation(.dockEase(duration: 0.25), value: captions.user)
        .animation(.dockEase(duration: 0.25), value: captions.reply == nil)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: hasPendingVoicePrompt)
    }

    /// A floating card beside the stage: inset from every edge, centered,
    /// hugging short replies and scrolling tall ones.
    /// Side panels slide in from the right and push the stage left.
    var voicePanelTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity)
                .combined(with: .scale(scale: 0.96, anchor: .trailing)),
            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
    }

    func voiceGenerativePanel(_ message: ChatMessage, immersive: Bool) -> some View {
        voiceGenerativeCard(message, immersive: immersive)
            .dockPadding(.vertical, immersive ? 56 : 40)
            .dockPadding(.trailing, immersive ? 40 : 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The real inspector tab beside full voice mode, so asking to see the browser shows the browser.
    func voiceTabPanel(_ section: SessionInspector.Section, style: DockThemePalette) -> some View {
        let shape = RoundedRectangle(cornerRadius: DockLayout.paneRadius + 8, style: .continuous)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                DockIcon(section.icon).foregroundStyle(Color.dockSecondaryText)
                Text(section.navigationTitle).dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                Spacer(minLength: 4)
                DockIconButton(
                    icon: .x, label: "Close \(section.navigationTitle)", style: style,
                    action: model.dismissVoicePreview)
            }
            .dockPadding(12)
            Divider()
            sessionInspector(talkPanel: true)
        }
        .frame(maxWidth: 720, maxHeight: .infinity)
        .clipShape(shape)
        .dockFloatingSurface(shape, stroke: Color.dockBorderLight)
        .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
        .dockPadding(.vertical, 56)
        .dockPadding(.trailing, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func voiceGenerativeCard(_ message: ChatMessage, immersive: Bool) -> some View {
        VoiceGenerativeCard(model: model, message: message, maxWidth: immersive ? 560 : 440)
    }

    var conversationHermFaceID: String? {
        botMode.orbHermFaceID(profileID: model.activeBotProfileID ?? model.sessionProfileID)
    }

    var voicePresentation: VoiceStagePresentation {
        VoiceStagePresentation(
            model: model, isRecording: speechInput.isRecording, isFallbackSpeaking: voiceOutput.isSpeaking)
    }

    var voiceOrbMode: VoiceOrbMode { voicePresentation.orbMode }
    var voiceOrbHelp: String { voicePresentation.orbHelp }

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
                    .foregroundStyle(voicePresentation.statusTint)
                    .contentTransition(.opacity)
            }
        } else if model.status == .working && !speechInput.isRecording {
            voiceActivityIndicator
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else if speechInput.isRecording || voiceOutput.isSpeaking {
            Text(speechInput.isRecording ? "HERM IS LISTENING" : "HERM IS SPEAKING")
                .dockFont(.body, weight: .semibold)
                .tracking(0.75)
                .foregroundStyle(speechInput.isRecording ? Color.dockSuccess : Color.dockAccent)
        }
    }

    /// Approvals keep their card so the command stays readable; questions
    /// are asked aloud instead when spoken answers work.
    var hasPendingVoicePrompt: Bool {
        voicePresentation.showsPromptCard(clarificationCard: showsVoiceClarificationCard)
    }

    var showsVoiceClarificationCard: Bool {
        model.voiceState.isNativeConversationActive ? !model.answersVoicePromptsAloud : speechInput.isUnavailable
    }

    /// The same prompt rows the chat shows, floated on the voice stage.
    @ViewBuilder
    var voicePromptCard: some View {
        VoiceConversationPromptRows(
            model: model, conversationMetrics: conversationMetrics,
            showsClarification: showsVoiceClarificationCard
        )
    }

    /// What you said and what the agent is saying, so the conversation reads
    /// like live captions rather than a hidden transcript.
    private func voiceCaptions(meter: MicLevelMeter) -> (user: String?, reply: (id: UUID, text: String)?) {
        if model.voiceState == .preparing { return (nil, nil) }
        if speechInput.isRecording || (model.voiceState.isNativeConversationActive && voiceOrbMode == .listening) {
            let live = speechInput.isRecording ? speechInput.transcript : meter.transcript
            let partial = live.trimmingCharacters(in: .whitespacesAndNewlines)
            return (partial.isEmpty ? nil : partial, nil)
        }
        // Talking over a running turn steers it; show what is being heard.
        let steering = meter.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Call-style controls: toggles on the left, the turn action in the
    /// middle, layout and End voice on the right. Narrow panes stack the turn
    /// action above its companions.
    func voiceControls(style: DockThemePalette) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                voiceMuteControls
                voiceTurnButton.dockPadding(.horizontal, 4)
                voiceImmersiveButton(style: style)
                endVoiceButton
            }
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    voiceTurnButton
                    voiceImmersiveButton(style: style)
                }
                HStack(spacing: 8) {
                    voiceMuteControls
                    endVoiceButton
                }
            }
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    voiceTurnButton
                    voiceImmersiveButton(style: style)
                }
                HStack(spacing: 8) { voiceMuteControls }
                endVoiceButton
            }
        }
    }

    private var voiceTurnButton: some View {
        Button(action: handleVoiceOrbTap) {
            voiceControlLabel(voiceOrbHelp, icon: voiceOrbMode == .listening ? .paperPlaneRight : .stop)
        }
        .buttonStyle(.dockPrimary)
        .disabled(model.voiceState == .preparing || model.voiceState == .transcribing)
    }

    private func voiceImmersiveButton(style: DockThemePalette) -> some View {
        DockIconButton(
            icon: isVoiceImmersive ? .cornersIn : .cornersOut,
            label: isVoiceImmersive ? "Exit full voice mode" : "Full voice mode",
            style: style
        ) { isVoiceImmersive.toggle() }
        .keyboardShortcut(isVoiceImmersive ? .cancelAction : nil)
    }

    @ViewBuilder
    private var voiceMuteControls: some View {
        if model.voiceState.isNativeConversationActive { VoiceMuteControls(model: model) }
    }

    private var endVoiceButton: some View {
        Button(action: exitVoiceMode) {
            voiceControlLabel("End voice", icon: .phoneDisconnect, tint: .dockDestructive)
        }
        .buttonStyle(.dockSecondary)
    }

    /// Icon and title; a tint marks an off or destructive state on the icon.
    private func voiceControlLabel(_ title: String, icon: Ph, tint: Color? = nil) -> some View {
        VoiceControlLabel(title: title, icon: icon, tint: tint)
    }

    var voiceInteractionHint: String { voicePresentation.interactionHint }
    var voiceStatusText: String { voicePresentation.statusText }

    func handleVoiceOrbTap() {
        if model.voiceOrbTapped() { return }
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

    var voiceActivityText: String { voicePresentation.activityText }
}

private struct VoiceStageVisualContent<Content: View>: View {
    @ObservedObject var stage: VoiceStageState
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}

/// Keeps recognition and microphone startup updates inside the Talk stage.
struct VoiceMicrophoneContent<Content: View>: View {
    @ObservedObject var meter: MicLevelMeter
    @ViewBuilder let content: (MicLevelMeter) -> Content

    var body: some View { content(meter) }
}
