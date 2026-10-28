import SwiftUI

struct PullRequestFloatingChatView: View {
    @ObservedObject var chat: PullRequestChatModel
    @ObservedObject var runtime: DockModel
    let record: PullRequestRecord
    @Binding var expanded: Bool

    var body: some View {
        Group {
            if let conversation = chat.conversation {
                PullRequestSessionChatView(model: conversation, runtime: runtime, record: record, expanded: $expanded)
            } else {
                DockLoadingState(title: "Loading conversation…", minHeight: expanded ? 100 : 28)
            }
        }
        .frame(idealWidth: expanded ? 520 : nil, maxWidth: expanded ? 620 : 200)
        .task { await chat.prepareConversation(for: record, runtime: runtime) }
    }
}

private struct PullRequestSessionChatView: View {
    @ObservedObject var model: DockModel
    let runtime: DockModel
    let record: PullRequestRecord
    @Binding var expanded: Bool
    @Environment(\.chatContextRouter) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var control = ControlCenterModel()
    @StateObject private var bots = BotModeModel()
    @StateObject private var speech = SpeechInput()
    @StateObject private var voice = VoiceOutput()
    @StateObject private var actions = ConversationMessageActionState()
    @State private var searching = false
    @State private var jumpID: UUID?
    @State private var image: ChatImagePreview?
    private let metrics = ConversationWorkspaceMetrics.resolve(isFullscreen: false)
    private var chatBots: BotModeModel { router?.bots ?? bots }
    private var style: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }

    var body: some View {
        VStack(spacing: 0) {
            if expanded {
                HStack(spacing: 8) {
                    DockIcon(.chatCircleText, size: 16, color: .dockSecondaryText)
                    Text("Chat").dockFont(.body, weight: .semibold)
                    Text("· #\(record.displayNumber)").dockFont(.body).foregroundStyle(Color.dockMetadataText)
                    Spacer(minLength: 0)
                    if model.sessionID != nil {
                        DockIconButton(
                            icon: .arrowSquareOut, label: "Open PR conversation", size: 28, style: style,
                            action: openConversation)
                    }
                    DockIconButton(
                        icon: expanded ? .caretDown : .caretUp,
                        label: expanded ? "Minimize PR chat" : "Show PR chat", size: 28, style: style
                    ) { expanded.toggle() }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Color.dockBorderLight.frame(height: DockLayout.hairline)
                ConversationTranscriptView(
                    model: model, controlCenter: control, botMode: chatBots, messageActionState: actions,
                    voiceOutput: voice, conversationMetrics: metrics, conversationHermFaceID: nil,
                    isShowingMessageSearch: $searching, pinnedMessageJumpID: $jumpID, selectedChatImage: $image
                )
                .equatable()
                .frame(height: 320)
                ChatComposerView(
                    model: model, composer: model.composer, speechInput: speech, botMode: chatBots,
                    onStop: { model.stop() }, requiredContext: ChatContext(pullRequest: record), metrics: metrics)
            } else {
                Button {
                    expanded = true
                    model.requestComposerFocus()
                } label: {
                    HStack(spacing: 8) {
                        DockIcon(.chatCircleText, size: 14, color: .dockSecondaryText)
                        Text("Chat · #\(record.displayNumber)").dockFont(.body, weight: .semibold)
                        DockIcon(.caretUp, size: 12, color: .dockSecondaryText)
                    }
                }
                .buttonStyle(.dockSecondary)
                .accessibilityLabel("Show PR #\(record.displayNumber) chat")
                .help("Show pull request chat")
            }
        }
        .background {
            if expanded {
                DockThemeShape(cornerRadius: DockLayout.paneRadius).dockSurfaceFill(Color.dockCanvas)
            }
        }
        .clipShape(DockThemeShape(cornerRadius: DockLayout.paneRadius))
        .overlay {
            if expanded {
                DockThemeShape(cornerRadius: DockLayout.paneRadius).stroke(
                    Color.dockBorder, lineWidth: DockLayout.hairline)
            }
        }
        .shadow(color: Color.dockPrimaryText.opacity(0.08), radius: 16, y: 4)
        .animation(reduceMotion ? nil : .dockEase(duration: 0.2), value: expanded)
        .onReceive(model.composer.$text.dropFirst()) { if !$0.isEmpty { expanded = true } }
        .onChange(of: model.isSending) { _, sending in if sending { expanded = true } }
        .task { control.bind(to: model) }
        .onChange(of: model.sessionID) { _, id in control.focus(sessionID: id) }
        .dockSheet(item: $image) { ChatImagePreviewModal(image: $0.image) }
    }

    private func openConversation() {
        guard let sessionID = model.sessionStorageID ?? model.sessionID else { return }
        runtime.resumeSession(
            HermesSession(
                id: sessionID, profileID: model.sessionProfileID, title: "PR #\(record.displayNumber)",
                preview: "", startedAt: nil, messageCount: 0, source: HermesFeatureIDs.sessionSource))
        router?.onOpened(sessionID)
    }
}
