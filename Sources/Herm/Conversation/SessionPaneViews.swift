import SwiftUI

/// The conversation workspace as equal columns: the primary conversation (with its
/// own header), then up to two side panels, each a tab group of sessions whose tab
/// strip sits in the title row. Dragging a sidebar session over it opens a new
/// panel slot or adds a tab to the panel under the cursor.
struct SessionPaneRow<Primary: View>: View {
    @ObservedObject var store: SessionPaneStore
    let isEnabled: Bool
    let headerHeight: CGFloat
    let usesWindowChrome: Bool
    @ViewBuilder let primary: Primary
    @State private var target: SessionPaneTarget?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Slot: Identifiable {
        case panel(SessionPaneStore.Panel)
        case placeholder
        var id: String {
            if case .panel(let panel) = self { return panel.id }
            return "session-pane-placeholder"
        }
    }

    private var slots: [Slot] {
        guard isEnabled else { return [] }
        var slots = store.panels.map(Slot.panel)
        if case .newPanel(let index) = target { slots.insert(.placeholder, at: min(index, slots.count)) }
        return slots
    }

    var body: some View {
        GeometryReader { geometry in
            let slots = slots
            // Explicit equal widths: columns never overflow the window or clip a composer.
            let columnWidth =
                (geometry.size.width - CGFloat(slots.count) * DockLayout.hairline) / CGFloat(slots.count + 1)
            HStack(spacing: 0) {
                primary.frame(width: max(0, columnWidth))
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    HStack(spacing: 0) {
                        Color.dockBorderLight.frame(width: DockLayout.hairline)
                        Group {
                            switch slot {
                            case .panel(let panel):
                                SessionPanelView(
                                    panel: panel, store: store, header: header,
                                    isTabTarget: target == .tab(store.panels.firstIndex { $0.id == panel.id } ?? -1))
                            case .placeholder:
                                VStack(spacing: 0) {
                                    header(AnyView(EmptyView()))
                                    SessionPaneDropHint(title: "Drop to open a new panel")
                                }
                            }
                        }
                        .frame(width: max(0, columnWidth))
                    }
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity))
                    )
                    .id(slot.id)
                    .zIndex(Double(index))
                }
            }
            .animation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.28), value: slots.map(\.id))
            .onDrop(
                of: isEnabled ? [SessionPaneDrag.pasteboardType.rawValue] : [],
                delegate: SessionPaneDropDelegate(
                    store: store, width: geometry.size.width, reduceMotion: reduceMotion, target: $target))
        }
    }

    /// A side panel's title row, matching the primary header's height, fill and separator.
    private func header(_ content: AnyView) -> some View {
        HStack(spacing: 4) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: headerHeight)
            .background { if usesWindowChrome { TitlebarDoubleClickArea() } }
            .dockShellChrome(usesWindowChrome)
            .background(usesWindowChrome ? Color.clear : Color.dockCanvas)
            .overlay(alignment: .bottom) { if usesWindowChrome { DockWindowChrome.titleRowSeparator } }
    }
}

private struct SessionPaneDropHint: View {
    let title: String

    var body: some View {
        VStack(spacing: 6) {
            DockIcon(.columnsPlusRight, size: 20, color: .dockSecondaryText)
            Text(title).dockFont(.body, weight: .semibold)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dockCard(isActive: true)
        .dockPadding(12)
        .accessibilityElement(children: .combine)
    }
}

private struct SessionPanelView<Header: View>: View {
    let panel: SessionPaneStore.Panel
    let store: SessionPaneStore
    let header: (AnyView) -> Header
    let isTabTarget: Bool
    @ObservedObject private var chat: EdgeQuickConversationModel

    init(
        panel: SessionPaneStore.Panel, store: SessionPaneStore, header: @escaping (AnyView) -> Header,
        isTabTarget: Bool
    ) {
        self.panel = panel
        self.store = store
        self.header = header
        self.isTabTarget = isTabTarget
        chat = panel.chat
    }

    private var style: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }

    private var tabs: [SessionInspectorTabItem] {
        panel.tabs.compactMap { tab in
            guard let id = tab.sessionID else { return nil }
            let isSelected = id == panel.selectedID
            return SessionInspectorTabItem(
                id: id, title: isSelected ? chat.conversation?.currentSessionTitle ?? tab.title : tab.title,
                icon: .chatCircle, isSelected: isSelected,
                select: { store.select(id, in: panel.id) }, close: { store.closeTab(id, in: panel.id) })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header(
                AnyView(
                    HStack(spacing: 4) {
                        SessionInspectorTabStrip(tabs: tabs, workspace: panel.id) { drag, target in
                            store.moveTab(drag.id, before: target, in: panel.id)
                        }
                        DockIconButton(
                            icon: .arrowLineLeft, label: "Make primary conversation", size: 28, style: style
                        ) { store.promote(panel.id) }
                        .dockPadding(.trailing, 8)
                    }))
            content
                .frame(maxHeight: .infinity)
                .overlay {
                    if isTabTarget {
                        SessionPaneDropHint(title: "Drop to add a tab").transition(.opacity)
                    }
                }
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

/// Transcript and composer for a side panel, mirroring the PR floating chat.
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
