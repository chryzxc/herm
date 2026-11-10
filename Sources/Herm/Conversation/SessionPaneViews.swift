import SwiftUI

/// The chat area as a row of equal columns: the primary conversation, then up to
/// two side panes. Dragging a sidebar session over it opens a slot that the other
/// columns slide apart to make room for.
struct SessionPaneRow<Primary: View>: View {
    @ObservedObject var store: SessionPaneStore
    let isEnabled: Bool
    @ViewBuilder let primary: Primary
    @State private var target: SessionPaneTarget?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Slot: Identifiable {
        case pane(SessionPaneStore.Pane)
        case placeholder
        var id: String {
            if case .pane(let pane) = self { return pane.id }
            return "session-pane-placeholder"
        }
    }

    private var slots: [Slot] {
        var slots = store.panes.map(Slot.pane)
        if case .insert(let index) = target { slots.insert(.placeholder, at: min(index, slots.count)) }
        return slots
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: isEnabled && !slots.isEmpty ? DockSpacing.section : 0) {
                primary.frame(maxWidth: .infinity)
                if isEnabled {
                    ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                        Group {
                            switch slot {
                            case .pane(let pane):
                                SessionPaneView(
                                    pane: pane, store: store, isReplaceTarget: target == .replace(index))
                            case .placeholder:
                                SessionPanePlaceholder()
                            }
                        }
                        .frame(minWidth: 320, maxWidth: .infinity)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .scale(scale: 0.96).combined(with: .opacity),
                                    removal: .move(edge: .trailing).combined(with: .opacity)))
                    }
                }
            }
            .animation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.28), value: slots.map(\.id))
            .onDrop(
                of: isEnabled ? [SessionPaneDrag.pasteboardType.rawValue] : [],
                delegate: SessionPaneDropDelegate(
                    store: store, width: geometry.size.width, reduceMotion: reduceMotion, target: $target))
        }
    }
}

private struct SessionPanePlaceholder: View {
    var body: some View {
        VStack(spacing: 6) {
            DockIcon(.columnsPlusRight, size: 20, color: .dockSecondaryText)
            Text("Drop to open here").dockFont(.body, weight: .semibold)
            Text("The session opens beside this conversation.")
                .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dockCard(isActive: true)
        .accessibilityElement(children: .combine)
    }
}

private struct SessionPaneView: View {
    let pane: SessionPaneStore.Pane
    let store: SessionPaneStore
    let isReplaceTarget: Bool
    @ObservedObject private var chat: EdgeQuickConversationModel

    init(pane: SessionPaneStore.Pane, store: SessionPaneStore, isReplaceTarget: Bool) {
        self.pane = pane
        self.store = store
        self.isReplaceTarget = isReplaceTarget
        chat = pane.chat
    }

    private var style: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(chat.conversation?.currentSessionTitle ?? pane.destination.title)
                    .dockFont(.body, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                DockIconButton(
                    icon: .arrowLineLeft, label: "Make primary conversation", size: 28, style: style
                ) { store.promote(pane.id) }
                DockIconButton(icon: .x, label: "Close pane", size: 28, style: style) { store.close(pane.id) }
            }
            .dockPadding(.horizontal, 12).dockPadding(.vertical, 8)
            Color.dockBorderLight.frame(height: DockLayout.hairline)
            content.frame(maxHeight: .infinity)
        }
        .dockCard(padding: 0, isActive: isReplaceTarget)
        .overlay {
            if isReplaceTarget {
                Text("Drop to replace")
                    .dockFont(.body, weight: .semibold)
                    .dockPill(tint: .dockPrimaryText)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let conversation = chat.conversation, !chat.loadFailed {
            SessionPaneChat(model: conversation)
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
                Button("Retry") {
                    Task {
                        guard let runtime = store.runtime else { return }
                        await chat.load(pane.destination, runtime: runtime)
                    }
                }
                .buttonStyle(.dockSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DockLoadingState(title: "Loading conversation…")
        }
    }
}

/// Transcript and composer for a side pane, mirroring the PR floating chat.
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
