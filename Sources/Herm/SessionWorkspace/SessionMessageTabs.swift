import SwiftUI

/// Disposable reading copies only; transcript history remains in Hermes.
@MainActor
final class SessionMessageTabs: ObservableObject {
    static let shared = SessionMessageTabs()
    @Published private(set) var tabs: [String: [SessionPreviewTab]] = [:]
    @Published private(set) var selection: [String: UUID] = [:]
    @Published private(set) var openRequest: String?

    func open(_ message: ChatMessage, in workspace: String) {
        open(.message(message), in: workspace)
    }

    func open(_ content: SessionPreviewContent, in workspace: String) {
        if let index = tabs[workspace]?.firstIndex(where: { $0.content.key == content.key }) {
            tabs[workspace]?[index].content = content
            selection[workspace] = tabs[workspace]?[index].id
        } else {
            let tab = SessionPreviewTab(content: content)
            tabs[workspace, default: []].append(tab)
            selection[workspace] = tab.id
        }
        openRequest = workspace
    }

    func select(_ id: UUID?, in workspace: String) {
        selection[workspace] = id
    }

    func close(_ id: UUID, in workspace: String) {
        tabs[workspace]?.removeAll { $0.id == id }
        if selection[workspace] == id { selection[workspace] = tabs[workspace]?.last?.id }
        if tabs[workspace]?.isEmpty == true { tabs[workspace] = nil }
    }
}

struct SessionPreviewTab: Identifiable {
    let id: UUID
    var content: SessionPreviewContent

    init(content: SessionPreviewContent) {
        self.content = content
        if case .message(let message) = content { id = message.id } else { id = UUID() }
    }
}

enum SessionPreviewContent {
    case message(ChatMessage)
    case bot(BotSummary)
    case dispatch(BotActivityRecord)
    case tool(ActiveToolCall)
    case activity(ChatMessage, [ActiveToolCall])

    var key: String {
        switch self {
        case .message(let value): "message:" + value.id.uuidString
        case .bot(let value): "bot:" + value.id
        case .dispatch(let value): "dispatch:" + value.id
        case .tool(let value): "tool:" + value.id
        case .activity(let message, _): "activity:" + message.id.uuidString
        }
    }

    var title: String {
        switch self {
        case .message(let message): String(message.text.split(separator: "\n").first ?? "Message")
        case .bot(let bot): bot.name
        case .dispatch(let record): record.botName + " · Task"
        case .tool(let call): AgentActivityPresentation.toolActivityTitle(name: call.name, context: call.context)
        case .activity: "Activity"
        }
    }

    var icon: Ph {
        switch self {
        case .message: .chatText
        case .bot: .robot
        case .dispatch: .paperPlaneTilt
        case .tool(let call): TurnActivityView.icon(for: call.name)
        case .activity: .chartBarHorizontal
        }
    }
}

private struct SessionPreviewWorkspaceKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var sessionPreviewWorkspace: String? {
        get { self[SessionPreviewWorkspaceKey.self] }
        set { self[SessionPreviewWorkspaceKey.self] = newValue }
    }
}

struct SessionMessageTabView: View {
    let message: ChatMessage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if let author = message.role == .user ? "You" : message.botDisplayName {
                        Text(author).dockFont(.body, weight: .semibold)
                    }
                    Text(message.timeLabel).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                    Spacer(minLength: 0)
                    DockCopyButton(message.text, accessibilityLabel: "Copy message", presentation: .icon)
                        .buttonStyle(DockPressButtonStyle())
                        .frame(width: 28, height: 28)
                }
                .frame(maxWidth: .infinity)
                ForEach(message.images.indices, id: \.self) { index in
                    Image(nsImage: message.images[index]).resizable().scaledToFit()
                }
                if message.role == .user {
                    Text(GenerativeUIIntegration.displayUserText(message.text))
                        .dockFont(.body).textSelection(.enabled)
                } else {
                    ForEach(
                        Array(
                            ChatMediaSegment.split(
                                message.text, delivered: ArtifactService.deliveredFiles(in: message.activity)
                            ).enumerated()), id: \.offset
                    ) { _, segment in
                        switch segment {
                        case .markdown(let text): MarkdownMessageView(markdown: text).equatable()
                        case .media(let path): ChatMediaAttachmentCard(path: path)
                        }
                    }
                }
            }
            .foregroundStyle(Color.dockPrimaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DockSpacing.inspectorInset)
        }
        .id(message.id)
    }
}
