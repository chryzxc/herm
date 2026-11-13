import Combine
import SwiftUI

/// Reuse the sidebar's filtered, coalesced projection; transcript changes never
/// enter this observer. Only a changed aggregate invalidates the badge view.
@MainActor
final class ChatRailActivityModel: ObservableObject {
    @Published private(set) var activity: ChatRailActivity
    private(set) var projectionCount = 1
    private let sidebar: SessionNavSidebarModel
    private let model: DockModel
    private let seenStore: SidebarSessionSeenStore
    private var cancellable: AnyCancellable?

    init(
        model: DockModel, control: ControlCenterModel, store: WorkspaceStore,
        seenStore: SidebarSessionSeenStore = .shared
    ) {
        self.model = model
        self.seenStore = seenStore
        let sidebar = SessionNavSidebarModel(model: model, control: control, store: store)
        self.sidebar = sidebar
        activity = Self.project(sidebar.snapshot, seenStore: seenStore, isConnected: model.isHermesConnected)
        cancellable = Publishers.Merge3(
            sidebar.$snapshot.dropFirst().map { _ in () },
            seenStore.objectWillChange.map { _ in () },
            model.$isHermesConnected.removeDuplicates().dropFirst().map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .debounce(for: .milliseconds(1), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        projectionCount += 1
        let next = Self.project(sidebar.snapshot, seenStore: seenStore, isConnected: model.isHermesConnected)
        if next != activity { activity = next }
    }

    private static func project(
        _ snapshot: SessionNavSidebarSnapshot,
        seenStore: SidebarSessionSeenStore, isConnected: Bool
    ) -> ChatRailActivity {
        let statuses = SidebarSessionStatusResolver.statuses(
            for: (snapshot.conversations + snapshot.inputs.pinnedSessions).filter {
                // Bot main chats belong to the Bots page, not the Chats badge.
                !$0.isHidden && !BotMentions.mainChatSessionIDs.contains($0.id)
            },
            snapshot: snapshot, seenStore: seenStore,
            fallbackProfileID: snapshot.inputs.profileScopeID
        )
        return ChatRailActivity(
            statuses: Array(statuses.values),
            foregroundWorking: snapshot.inputs.activeStatus == .working,
            isConnected: isConnected)
    }
}

struct ChatRailButton: View {
    @StateObject private var source: ChatRailActivityModel
    let isSelected: Bool
    let isVisible: Bool
    let style: DockThemePalette
    let action: () -> Void

    init(
        model: DockModel, control: ControlCenterModel, store: WorkspaceStore,
        isSelected: Bool, isVisible: Bool, style: DockThemePalette, action: @escaping () -> Void
    ) {
        _source = StateObject(wrappedValue: ChatRailActivityModel(model: model, control: control, store: store))
        self.isSelected = isSelected
        self.isVisible = isVisible
        self.style = style
        self.action = action
    }

    private var chatActivity: ChatRailActivity { source.activity }

    var body: some View {
        DockRailButton(title: "Chats", icon: .chatsCircle, isSelected: isSelected, style: style, action: action)
            .overlay(alignment: .topTrailing) {
                if chatActivity.isWorking || chatActivity.unreadCount > 0 { badge }
            }
            .help(chatActivity.summary.isEmpty ? "Chats" : "Chats, \(chatActivity.summary)")
            .accessibilityValue(chatActivity.summary)
    }

    private var badge: some View {
        HStack(spacing: 2) {
            if chatActivity.isWorking {
                DockActivityIndicator(state: .running, size: 9, animates: isVisible && style.theme.style.animates)
                    .dockPadding(.horizontal, 3)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(Capsule().fill(style.sidebarBackground))
                    .overlay(Capsule().strokeBorder(style.secondaryText.opacity(0.3), lineWidth: 0.5))
            }
            if chatActivity.unreadCount > 0 { UnreadCountPill(label: chatActivity.unreadBadgeLabel) }
        }
        .fixedSize(horizontal: true, vertical: false)
        .dockPadding(1)
        .offset(x: 0, y: -6)  // sits above the icon; the rail reserves this room
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

}
