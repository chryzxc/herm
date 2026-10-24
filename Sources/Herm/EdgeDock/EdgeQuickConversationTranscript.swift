import SwiftUI

struct EdgeQuickConversationTranscript: View {
    @ObservedObject var model: DockModel
    let control: ControlCenterModel
    let onReply: (ReplyQuote) -> Void
    let onSessionChanged: (HermesSession) -> Void
    @StateObject private var bots = BotModeModel()
    @StateObject private var voice = VoiceOutput()
    @StateObject private var actions = ConversationMessageActionState()
    @State private var searching = false
    @State private var jumpID: UUID?
    @State private var image: ChatImagePreview?

    var body: some View {
        ConversationTranscriptView(
            model: model, controlCenter: control, botMode: bots, messageActionState: actions,
            voiceOutput: voice, conversationMetrics: .resolve(isFullscreen: false), conversationHermFaceID: nil,
            isShowingMessageSearch: $searching, pinnedMessageJumpID: $jumpID, selectedChatImage: $image
        )
        .equatable()
        .sheet(item: $image) { ChatImagePreviewModal(image: $0.image) }
        .onChange(of: model.replyQuote) { _, quote in
            guard let quote else { return }
            onReply(quote)
            model.replyQuote = nil
        }
        .onChange(of: actions.pendingActions) { previous, current in
            guard previous.values.contains(.branch), !current.values.contains(.branch),
                let session = model.workflowSession
            else { return }
            onSessionChanged(session)
        }
        .onDisappear { voice.stop() }
    }
}
