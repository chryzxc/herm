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
    /// The bot's profile editor (Settings › Bots' editor) as a tab.
    case botSettings(BotSummary)
    case dispatch(BotActivityRecord)
    case tool(ActiveToolCall)
    case activity(ChatMessage, [ActiveToolCall])
    case output(ArtifactRecord)
    case file(URL)
    case pullRequest(GitHubItemReference)

    var key: String {
        switch self {
        case .message(let value): "message:" + value.id.uuidString
        case .bot(let value): "bot:" + value.id
        case .botSettings(let value): "botSettings:" + value.id
        case .dispatch(let value): "dispatch:" + value.id
        case .tool(let value): "tool:" + value.id
        case .activity(let message, _): "activity:" + message.id.uuidString
        case .output(let record): "output:" + record.id
        case .file(let url): "file:" + url.path
        case .pullRequest(let reference): "pullRequest:" + reference.id
        }
    }

    var title: String {
        switch self {
        case .message(let message): String(message.text.split(separator: "\n").first ?? "Message")
        case .bot(let bot): bot.name
        case .botSettings(let bot): bot.name + " settings"
        case .dispatch(let record): record.botName + " · Task"
        case .tool(let call): AgentActivityPresentation.toolActivityTitle(name: call.name, context: call.context)
        case .activity: "Activity"
        case .output(let record): record.label
        case .file(let url): url.lastPathComponent
        case .pullRequest(let reference): reference.title
        }
    }

    var icon: Ph {
        switch self {
        case .message: .chatText
        case .bot: .robot
        case .botSettings: .gear
        case .dispatch: .paperPlaneTilt
        case .tool(let call): TurnActivityView.icon(for: call.name)
        case .activity: .chartBarHorizontal
        case .output(let record): record.kind == .interactive ? .squaresFour : record.kind == .link ? .link : .file
        case .file: .file
        case .pullRequest: .gitPullRequest
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

/// A chat message in its own tab. Annotate swaps the rich rendering (images,
/// attachment cards) for the shared text annotator over the message text.
struct SessionMessageTabView: View {
    let message: ChatMessage
    @ObservedObject var model: DockModel
    @State private var isAnnotating = false

    private var text: String {
        message.role == .user ? GenerativeUIIntegration.displayUserText(message.text) : message.text
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let author = message.role == .user ? "You" : message.botDisplayName {
                    Text(author).dockFont(.body, weight: .semibold).lineLimit(1)
                }
                Text(message.timeLabel).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                Spacer(minLength: 0)
                AnnotateToggle(isOn: $isAnnotating)
                DockCopyButton(message.text, accessibilityLabel: "Copy message")
                    .buttonStyle(.dockSecondary)
            }
            .foregroundStyle(Color.dockPrimaryText)
            .dockPadding(.horizontal, DockSpacing.inspectorInset)
            .frame(height: 48)
            .dockButtonSize(.compact)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
            if isAnnotating {
                TextAnnotator(
                    source: .message(id: message.id, text: text), text: text,
                    isMarkdown: message.role != .user, isAnnotating: $isAnnotating, model: model)
            } else {
                richContent
            }
        }
        .onAppear {
            isAnnotating = FilePreviewCenter.shared.hasDrafts(AnnotationSource.message(id: message.id, text: "").key)
        }
        .id(message.id)
    }

    private var richContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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
            .dockPadding(DockSpacing.inspectorInset)
        }
    }
}
