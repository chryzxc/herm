import SwiftUI

/// The conversation workspace as equal columns, each a tab group of sessions. The
/// active column renders the main conversation with the full header (`primary`); the
/// others show a title-row tab strip over a projection. Selecting any tab makes it the
/// active session, so the header moves to that column. Dragging a sidebar session over
/// the row opens a new column or adds a tab to the column under the cursor.
struct SessionPaneRow<Primary: View>: View {
    @ObservedObject var store: SessionPaneStore
    let isEnabled: Bool
    let headerHeight: CGFloat
    let usesWindowChrome: Bool
    /// Sidebar toggle and history, shown by whichever column is leftmost when the chat list is hidden.
    let leadingControls: AnyView?
    /// The active conversation; the flag says whether it is the leftmost column.
    @ViewBuilder let primary: (Bool) -> Primary
    @State private var target: SessionPaneTarget?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Slot: Identifiable {
        case primary
        case panel(SessionPaneStore.Panel)
        case placeholder
        var id: String {
            switch self {
            case .primary: SessionPaneStore.baseColumnID
            case .panel(let panel): panel.id
            case .placeholder: "session-pane-placeholder"
            }
        }
    }

    private var slots: [Slot] {
        guard isEnabled else { return [.primary] }
        var slots: [Slot] =
            store.panels.isEmpty
            ? [.primary]
            : store.panels.enumerated().map { $0.offset == store.activeIndex ? .primary : .panel($0.element) }
        if case .newPanel(let index) = target { slots.insert(.placeholder, at: min(max(index, 0), slots.count)) }
        return slots
    }

    var body: some View {
        GeometryReader { geometry in
            let slots = slots
            // Explicit equal widths: columns never overflow the window or clip a composer.
            let columnWidth = max(
                0, (geometry.size.width - CGFloat(slots.count - 1) * DockLayout.hairline) / CGFloat(slots.count))
            // The placeholder already shows the new column while that zone is hovered.
            let zone = isNewColumnTarget ? 0 : SessionPaneStore.newColumnZone(columnCount: store.panels.count)
            HStack(spacing: 0) {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    HStack(spacing: 0) {
                        if index > 0 { Color.dockBorderLight.frame(width: DockLayout.hairline) }
                        column(slot, isLeading: index == 0)
                            .frame(width: columnWidth)
                            .clipped()
                            // The hovered column's chat clears below its header so the drop hint
                            // never sits over a visible transcript; the header stays put.
                            .mask {
                                VStack(spacing: 0) {
                                    Rectangle().frame(height: headerHeight)
                                    Rectangle().opacity(isTabTarget(slot) ? 0 : 1)
                                }
                            }
                            .overlay(alignment: .leading) {
                                // While a session is dragged over the row, every column shows it
                                // takes a tab; the hovered one lights up.
                                if target != nil, !isPlaceholder(slot) {
                                    SessionPaneDropHint(
                                        title: "Add as tab", icon: .plus, isActive: isTabTarget(slot)
                                    )
                                    .dockPadding(.top, headerHeight)
                                    .frame(width: columnWidth * (index == slots.count - 1 ? 1 - zone : 1))
                                }
                            }
                    }
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .opacity))
                }
            }
            .overlay(alignment: .trailing) {
                if target != nil, zone > 0 {
                    SessionPaneDropHint(title: "New column", icon: .columnsPlusRight, isActive: false)
                        .dockPadding(.top, headerHeight)
                        .frame(width: columnWidth * zone)
                }
            }
            .animation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.28), value: slots.map(\.id))
            .animation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.2), value: target)
            .onDrop(
                of: isEnabled ? [SessionPaneDrag.pasteboardType.rawValue] : [],
                delegate: SessionPaneDropDelegate(
                    store: store, width: geometry.size.width, reduceMotion: reduceMotion, target: $target))
        }
    }

    @ViewBuilder
    private func column(_ slot: Slot, isLeading: Bool) -> some View {
        switch slot {
        case .primary:
            primary(isLeading)
        case .panel(let panel):
            SessionPanelView(panel: panel, store: store) { header($0, isLeading: isLeading) }
        case .placeholder:
            VStack(spacing: 0) {
                header(AnyView(EmptyView()), isLeading: isLeading)
                SessionPaneDropHint(title: "Drop to open a new column", icon: .columnsPlusRight, isActive: true)
            }
        }
    }

    private var isNewColumnTarget: Bool {
        if case .newPanel = target { return true }
        return false
    }

    private func isPlaceholder(_ slot: Slot) -> Bool {
        if case .placeholder = slot { return true }
        return false
    }

    private func isTabTarget(_ slot: Slot) -> Bool {
        guard case .tab(let index) = target else { return false }
        switch slot {
        case .primary: return index == (store.panels.isEmpty ? 0 : store.activeIndex)
        case .panel(let panel): return store.panels.firstIndex { $0.id == panel.id } == index
        case .placeholder: return false
        }
    }

    /// An inactive column's title row, matching the primary header's height, fill and separator.
    private func header(_ content: AnyView, isLeading: Bool) -> some View {
        let showsLeading = isLeading && leadingControls != nil
        return HStack(spacing: 4) {
            if showsLeading, let leadingControls { leadingControls }
            content
        }
        .dockPadding(.leading, showsLeading && usesWindowChrome ? DockWindowChrome.sidebarToggleLeading : 8)
        .dockPadding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: headerHeight)
        .background { if usesWindowChrome { TitlebarDoubleClickArea() } }
        .dockShellChrome(usesWindowChrome)
        .background(usesWindowChrome ? Color.clear : Color.dockCanvas)
        .overlay(alignment: .bottom) { if usesWindowChrome { DockWindowChrome.titleRowSeparator } }
    }
}

/// Tabs of the active column, shown in the main header in place of the session title
/// once the column holds more than one session.
struct SessionPaneActiveTabs<Fallback: View>: View {
    @ObservedObject var store: SessionPaneStore
    @ObservedObject var runtime: DockModel
    @ViewBuilder let fallback: Fallback

    var body: some View {
        if let panel = store.activePanel, panel.tabs.count > 1 {
            SessionPaneTabStrip(
                tabs: SessionPaneTabStrip.items(panel: panel, store: store, liveTitle: runtime.currentSessionTitle))
        } else {
            fallback
        }
    }
}

/// Session tabs that share the row width; titles truncate with an ellipsis instead of
/// collapsing to icons, and the selected tab keeps its title longest.
struct SessionPaneTabStrip: View {
    let tabs: [SessionInspectorTabItem]

    static func items(panel: SessionPaneStore.Panel, store: SessionPaneStore, liveTitle: String?)
        -> [SessionInspectorTabItem]
    {
        panel.tabs.compactMap { tab in
            guard let id = tab.sessionID else { return nil }
            let isSelected = id == panel.selectedID
            return SessionInspectorTabItem(
                id: id, title: isSelected ? liveTitle ?? tab.title : tab.title, icon: .chatCircle,
                isSelected: isSelected,
                select: { store.select(id, in: panel.id) }, close: { store.closeTab(id, in: panel.id) })
        }
    }

    @Environment(\.chatContextRouter) private var router

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                // A Bot's main chat shows the Bot's avatar instead of the chat glyph.
                let bot = router?.bots?.bots.first { $0.chat?.sessionID == tab.id }
                SessionPaneTab(tab: tab, bot: bot, avatar: bot.flatMap { router?.bots?.avatarImages[$0.id] })
                    .layoutPriority(tab.isSelected ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Hugs its content up to `maxWidth`, truncating past it; `.frame(maxWidth:)` would stretch to it.
private struct SessionPaneTabWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? maxWidth, maxWidth)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private struct SessionPaneTab: View {
    let tab: SessionInspectorTabItem
    let bot: BotSummary?
    let avatar: Data?
    @State private var hovered = false

    var body: some View {
        SessionPaneTabWidth(maxWidth: 220) {
            HStack(spacing: 0) {
                Button(action: tab.select) {
                    HStack(spacing: 6) {
                        if let bot {
                            BotAvatarView(bot: bot, imageData: avatar, size: 16, animated: false)
                        } else {
                            DockIcon(
                                tab.icon, size: 12, weight: tab.isSelected ? .fill : .regular,
                                color: tab.isSelected ? .dockPrimaryText : .dockSecondaryText)
                        }
                        Text(tab.title).lineLimit(1).truncationMode(.tail)
                    }
                    .dockPadding(.leading, 8)
                    .dockPadding(.trailing, 2)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                .help(tab.title)
                .accessibilityAddTraits(tab.isSelected ? .isSelected : [])
                Button(action: tab.close) {
                    DockIcon(.x, size: 10, color: tab.isSelected ? .dockPrimaryText : .dockSecondaryText)
                        .frame(width: 22, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                .accessibilityLabel("Close \(tab.title)")
            }
        }
        .dockFont(.control, weight: .medium)
        .foregroundStyle(tab.isSelected ? Color.dockPrimaryText : Color.dockSecondaryText)
        .dockSelectionBackground(
            DockThemeShape(cornerRadius: DockLayout.controlRadius - 1), active: tab.isSelected,
            fill: DockThemePalette(theme: DockThemeRuntime.current).selectedFill, allowsInvert: false
        )
        .background(!tab.isSelected && hovered ? Color.dockSurface2 : Color.clear)
        .clipShape(DockThemeShape(cornerRadius: DockLayout.controlRadius - 1))
        .onHover { hovered = $0 }
        .contextMenu { Button("Close tab", action: tab.close) }
    }
}

/// A drop zone. Idle zones are a small solid pill; the hovered zone is a dashed outline
/// over its column, whose chat the row masks away while hovered.
private struct SessionPaneDropHint: View {
    let title: String
    let icon: Ph
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isActive {
                DockThemeShape(cornerRadius: DockLayout.paneRadius, role: .pane)
                    .stroke(Color.dockBorderStrong, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .dockPadding(12)
                    .transition(.opacity)
            }
            HStack(spacing: 6) {
                DockIcon(icon, size: isActive ? 16 : 13, color: isActive ? .dockPrimaryText : .dockSecondaryText)
                Text(title).dockFont(.body, weight: .semibold)
                    .foregroundStyle(isActive ? Color.dockPrimaryText : Color.dockSecondaryText)
                    .lineLimit(1)
            }
            .dockPadding(.horizontal, 12)
            .dockPadding(.vertical, 7)
            .dockHUDSurface(tint: .dockBorderStrong)
            .scaleEffect(isActive ? 1.06 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.18), value: isActive)
        .transition(.opacity)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

private struct SessionPanelView<Header: View>: View {
    let panel: SessionPaneStore.Panel
    let store: SessionPaneStore
    let header: (AnyView) -> Header
    @ObservedObject private var chat: EdgeQuickConversationModel

    init(panel: SessionPaneStore.Panel, store: SessionPaneStore, header: @escaping (AnyView) -> Header) {
        self.panel = panel
        self.store = store
        self.header = header
        chat = panel.chat
    }

    var body: some View {
        VStack(spacing: 0) {
            header(
                AnyView(
                    SessionPaneTabStrip(
                        tabs: SessionPaneTabStrip.items(
                            panel: panel, store: store, liveTitle: chat.conversation?.currentSessionTitle))))
            content.frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let conversation = chat.conversation, !chat.loadFailed {
            SessionPaneChat(model: conversation)
                .id(panel.selectedID)
                .overlay {
                    if chat.isLoading, conversation.messages.isEmpty {
                        DockLoadingState(title: "Loading conversation…")
                    }
                }
        } else if chat.loadFailed {
            VStack(spacing: 6) {
                Text("Conversation unavailable").dockFont(.body, weight: .semibold)
                Text("Hermes couldn't load this session.")
                    .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                Button("Retry") { store.retry(panel.id) }
                    .buttonStyle(.dockSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DockLoadingState(title: "Loading conversation…")
        }
    }
}

/// Transcript and composer for an inactive column, mirroring the PR floating chat.
private struct SessionPaneChat: View {
    @ObservedObject var model: DockModel
    @Environment(\.chatContextRouter) private var router
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

    var body: some View {
        VStack(spacing: 0) {
            ConversationTranscriptView(
                model: model, controlCenter: control, botMode: chatBots, messageActionState: actions,
                voiceOutput: voice, conversationMetrics: metrics, conversationHermFaceID: nil,
                isShowingMessageSearch: $searching, pinnedMessageJumpID: $jumpID, selectedChatImage: $image
            )
            .equatable()
            .frame(maxHeight: .infinity)
            ChatComposerView(
                model: model, composer: model.composer, speechInput: speech, botMode: chatBots,
                onStop: { model.stop() }, metrics: metrics, controlCenter: control)
        }
        .task { control.bind(to: model) }
        .onChange(of: model.sessionID) { _, id in control.focus(sessionID: id) }
        .dockSheet(item: $image) { ChatImagePreviewModal(image: $0.image) }
    }
}
