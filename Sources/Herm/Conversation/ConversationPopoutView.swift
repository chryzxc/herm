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
/// transcript and composer a split column shows. No sidebar, tabs, or session tools.
struct ConversationPopoutView: View {
    @ObservedObject var header: ConversationPopoutHeader
    @ObservedObject var worktree: ConversationWorktreeState
    let chat: EdgeQuickConversationModel
    let control: ControlCenterModel
    let bots: BotModeModel
    let openQuota: () -> Void
    /// Starts a chat in the main window at a worktree, carrying this window's draft.
    let openInMain: (String) -> Void
    let onRetry: () -> Void

    var body: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .underTitlebar(header.titleRowHeight)
        .overlay(alignment: .top) {
            titleRow
                // The strip underneath drags and zooms the window.
                .allowsHitTesting(false)
        }
        .popoutCanvas()
    }

    private var titleRow: some View {
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
        .padding(.leading, header.titleLeading)
        .padding(.trailing, 12)
        .frame(height: header.titleRowHeight)
        .accessibilityElement(children: .combine)
    }
}

/// A detached group room. Rooms are not Hermes sessions, so it renders the Bots page's
/// `GroupChatView`; the room's own toolbar (live name, members, thread and room actions)
/// becomes the title row beside the traffic lights.
struct ConversationPopoutRoomView: View {
    @ObservedObject var header: ConversationPopoutHeader
    let bots: BotModeModel
    let roomID: String
    /// The room was disbanded, here or elsewhere; its window closes.
    let onDisbanded: () -> Void

    var body: some View {
        GroupChatView(
            store: bots.groupChats, botMode: bots, roomID: roomID,
            metrics: ConversationWorkspaceMetrics.resolve(isFullscreen: false),
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
