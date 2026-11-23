import SwiftUI

/// What a detached window's title row names; the window controller keeps it current.
@MainActor
final class ConversationPopoutHeader: ObservableObject {
    @Published var title: String
    let profileLabel: String?
    /// The native titlebar's height and the traffic lights' trailing edge, measured from the
    /// window so the title sits on the same line as the lights.
    @Published var titleRowHeight: CGFloat = 38
    @Published var titleLeading: CGFloat = 78

    init(title: String, profileLabel: String?) {
        self.title = title
        self.profileLabel = profileLabel
    }
}

/// A detached conversation: a title row naming the chat and its profile, then the same
/// transcript and composer a split column shows. No sidebar or session tools; what the chat
/// opens as a tab (a message, file, tool call, bot) shows in a trailing preview panel.
struct ConversationPopoutView: View {
    /// The preview panel's width; the window grows by this much when it opens.
    static let previewWidth: CGFloat = 380

    @ObservedObject var header: ConversationPopoutHeader
    @ObservedObject var worktree: ConversationWorktreeState
    @ObservedObject var chat: EdgeQuickConversationModel
    let control: ControlCenterModel
    let bots: BotModeModel
    let openQuota: () -> Void
    /// Starts a chat in the main window at a worktree, carrying this window's draft.
    let openInMain: (String) -> Void
    let onRetry: () -> Void
    /// Resizes the window for the preview panel opening (`true`) or closing.
    var onPreviewPanel: (Bool) -> Void = { _ in }
    @ObservedObject private var previews = SessionMessageTabs.shared
    @State private var showsPreviews = false

    private var workspace: String? { chat.conversation.map { WorkspaceIdentity.session($0) } }
    private var previewTabs: [SessionPreviewTab] { workspace.flatMap { previews.tabs[$0] } ?? [] }
    private var isPreviewPanelVisible: Bool { showsPreviews && !previewTabs.isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            conversation
            if isPreviewPanelVisible, let model = chat.conversation, let workspace {
                Color.dockBorderLight.frame(width: DockLayout.hairline)
                ConversationPopoutPreviewPanel(
                    model: model, bots: bots, workspace: workspace, tabs: previewTabs,
                    selection: previews.selection[workspace]
                )
                .frame(width: Self.previewWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .underTitlebar(header.titleRowHeight)
        .overlay(alignment: .top) { titleRow }
        .popoutCanvas()
        .onReceive(previews.$openRequest) { request in
            guard let request, request == workspace else { return }
            showsPreviews = true
        }
        .onChange(of: isPreviewPanelVisible) { _, visible in
            if !visible { showsPreviews = false }
            onPreviewPanel(visible)
        }
    }

    private var conversation: some View {
        SessionPaneChatContent(
            chat: chat, control: control, bots: bots,
            metrics: ConversationWorkspaceMetrics.resolve(isFullscreen: false),
            accessories: SessionPaneChatAccessories(
                openQuota: openQuota,
                worktreeBar: { [worktree, openInMain] in worktree.picker(for: $0, openInMain: openInMain) },
                isStandalone: true),
            onRetry: onRetry
        )
        .environment(\.composerReservesFolderBar, false)
        // Lift the composer clear of the window's rounded bottom corners.
        .dockPadding(.bottom, 6)
        .frame(minWidth: ConversationWindowController.minimumSize.width, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            identity
                // The strip underneath drags and zooms the window.
                .allowsHitTesting(false)
            if !previewTabs.isEmpty {
                DockSidebarToggle(isCollapsed: !isPreviewPanelVisible, edge: .trailing, panel: "previews") {
                    showsPreviews.toggle()
                }
            }
        }
        .padding(.leading, header.titleLeading)
        .padding(.trailing, 8)
        .frame(height: header.titleRowHeight)
    }

    private var identity: some View {
        HStack(spacing: 8) {
            Text(header.title)
                .dockFont(.rowTitle, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            if let profile = header.profileLabel {
                Text(profile)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
                    .dockPill()
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The popout's preview panel: the selected (or newest) preview this chat opened, with no tab
/// strip. The title row's trailing toggle collapses it.
private struct ConversationPopoutPreviewPanel: View {
    let model: DockModel
    let bots: BotModeModel
    let workspace: String
    let tabs: [SessionPreviewTab]
    let selection: UUID?

    /// The selected tab, or the newest when the selection was closed elsewhere.
    private var selected: SessionPreviewTab? { tabs.first { $0.id == selection } ?? tabs.last }

    var body: some View {
        if let selected {
            // Pull request tabs open only from the main window's rail, which starts their chats.
            SessionDataPreviewView(
                content: selected.content, model: model, botMode: bots, workspace: workspace,
                onOpenPullRequestChat: { _ in }
            )
            .id(selected.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A detached group room. Rooms are not Hermes sessions, so it renders the Bots page's
/// `GroupChatView`; the room's own toolbar (live name, members, thread and room actions)
/// becomes the title row beside the traffic lights.
struct ConversationPopoutRoomView: View {
    @ObservedObject var header: ConversationPopoutHeader
    let bots: BotModeModel
    let roomID: String
    let control: ControlCenterModel
    /// The room was disbanded, here or elsewhere; its window closes.
    let onDisbanded: () -> Void

    var body: some View {
        GroupChatView(
            store: bots.groupChats, botMode: bots, roomID: roomID,
            metrics: ConversationWorkspaceMetrics.resolve(isFullscreen: false),
            quotaControl: control,
            toolbar: { [header] identity, actions in
                AnyView(
                    HStack(spacing: 4) {
                        // Drawn over the drag strip, which takes clicks the identity ignores.
                        identity.allowsHitTesting(false)
                        Spacer(minLength: 8)
                        actions
                    }
                    .padding(.leading, header.titleLeading - 8)
                    .padding(.trailing, 12)
                    .frame(height: header.titleRowHeight)
                    .background { TitlebarDoubleClickArea().dockShellChrome() }
                    .overlay(alignment: .bottom) { DockWindowChrome.titleRowSeparator })
            }
        ) {
            onDisbanded()
        } onOpenRoom: { [bots] id in
            // A group an edit creates opens in its own window, as a split column opens a tab.
            guard let room = bots.groupChats.rooms.first(where: { $0.id == id }) else { return }
            ConversationWindowStore.shared.open(SessionPaneDrag(room: room).destination)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .popoutCanvas()
    }
}

extension View {
    /// The window's canvas, with links opening in Herm's browser as in the main window.
    fileprivate func popoutCanvas() -> some View {
        background { Rectangle().dockSurfaceFill(Color.dockCanvas) }
            .environment(
                \.openURL,
                OpenURLAction {
                    InAppBrowser.open($0)
                    return .handled
                })
    }
}
