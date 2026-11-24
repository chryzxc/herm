import Combine
import SwiftUI

/// Disposable reading copies only; transcript history remains in Hermes.
@MainActor
final class SessionMessageTabs {
    struct Snapshot {
        var tabs: [SessionPreviewTab] = []
        var selection: UUID?
    }

    @Observable
    final class Workspace {
        @ObservationIgnored let openRequests = PassthroughSubject<Void, Never>()
        fileprivate var snapshot = Snapshot()

        var tabs: [SessionPreviewTab] { snapshot.tabs }
        var selection: UUID? { snapshot.selection }
    }

    static let shared = SessionMessageTabs()
    private var workspaces: [String: Workspace] = [:]

    func workspace(_ key: String) -> Workspace {
        if let workspace = workspaces[key] { return workspace }
        let workspace = Workspace()
        workspaces[key] = workspace
        return workspace
    }

    func open(_ message: ChatMessage, in workspace: String) {
        open(.message(message), in: workspace)
    }

    func open(_ content: SessionPreviewContent, in workspace: String) {
        let state = self.workspace(workspace)
        var snapshot = state.snapshot
        if let index = snapshot.tabs.firstIndex(where: { $0.content.key == content.key }) {
            snapshot.tabs[index].content = content
            snapshot.selection = snapshot.tabs[index].id
        } else {
            let tab = SessionPreviewTab(content: content)
            snapshot.tabs.append(tab)
            snapshot.selection = tab.id
        }
        state.snapshot = snapshot
        state.openRequests.send()
    }

    func select(_ id: UUID?, in workspace: String) {
        let state = self.workspace(workspace)
        guard state.selection != id else { return }
        state.snapshot.selection = id
    }

    func close(_ id: UUID, in workspace: String) {
        let state = self.workspace(workspace)
        guard let index = state.tabs.firstIndex(where: { $0.id == id }) else { return }
        var snapshot = state.snapshot
        snapshot.tabs.remove(at: index)
        if snapshot.selection == id { snapshot.selection = snapshot.tabs.last?.id }
        state.snapshot = snapshot
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

    /// The file this tab shows, so its tab can carry the file-type icon; nil for non-file content.
    var fileName: String? {
        switch self {
        case .file(let url): url.lastPathComponent
        case .output(let record) where record.kind == .file || record.kind == .image: record.label
        default: nil
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
                AnnotateToggle(isOn: $isAnnotating).dockTabTrack()
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
