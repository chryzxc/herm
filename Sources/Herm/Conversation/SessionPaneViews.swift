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
    /// The inspector, drawn right after the active column while split (one at a time).
    var inspector: AnyView?
    /// Opens the inspector; inactive columns call it after taking over as the active column.
    var onOpenInspector: () -> Void = {}
    /// Mode tabs and the actions menu for an inactive column's session; every action
    /// first makes that column active.
    var columnControls: ((_ sessionID: String, _ activate: @escaping () -> Void) -> AnyView)?
    /// The main conversation's metrics, so every column's composer sits at the same height.
    var metrics = ConversationWorkspaceMetrics.resolve(isFullscreen: false)
    /// The active conversation; the flag says whether it is the leftmost column.
    @ViewBuilder let primary: (Bool) -> Primary
    @State private var target: SessionPaneTarget?
    /// Resized column shares; ignored (equal columns) once the column count changes.
    @State private var columnFractions: [CGFloat] = []
    @State private var resizeStart: [CGFloat]?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Slot: Identifiable {
        /// The active column, keyed by its own panel id: a fixed id would collide with the
        /// base column once another column is active, and SwiftUI would draw one view twice.
        case primary(id: String)
        case panel(SessionPaneStore.Panel)
        var id: String {
            switch self {
            case .primary(let id): id
            case .panel(let panel): panel.id
            }
        }
    }

    private var slots: [Slot] {
        let base = Slot.primary(id: SessionPaneStore.baseColumnID)
        guard isEnabled, !store.panels.isEmpty else { return [base] }
        return store.panels.enumerated().map {
            $0.offset == store.activeIndex ? .primary(id: $0.element.id) : .panel($0.element)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let slots = slots
            // The inspector follows the main conversation, which a room tab hides.
            let inspector =
                slots.count > 1 && store.activePanel?.selected?.groupRoomID == nil ? inspector : nil
            // Beside the active column while every column keeps its minimum width; when that
            // would crowd them, it floats over the neighbor instead of squeezing every column.
            let fitsBeside =
                (geometry.size.width - Self.inspectorWidth) / CGFloat(slots.count) >= SessionPaneStore.minColumnWidth
            let docked = fitsBeside ? inspector : nil
            let inspectorWidth = docked == nil ? 0 : Self.inspectorWidth + DockLayout.hairline
            // Explicit widths from the column shares: columns never overflow the window or clip a composer.
            let available = max(
                0, geometry.size.width - inspectorWidth - CGFloat(slots.count - 1) * DockLayout.hairline)
            let fractions = SessionPaneStore.fractions(columnFractions, count: slots.count)
            let widths = fractions.map { $0 * available }
            let activeSlot = slots.firstIndex { if case .primary = $0 { true } else { false } } ?? 0
            let inspectorStart = widths.prefix(activeSlot + 1).reduce(0, +) + CGFloat(activeSlot) * DockLayout.hairline
            // Columns keep their widths while a drag hovers: only the hints change, so the
            // transcripts never re-lay out mid-drag. The new column appears on drop.
            let zone = SessionPaneStore.newColumnZone(columnCount: store.panels.count)
            let isLast = { (index: Int) in index == slots.count - 1 }
            HStack(spacing: 0) {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    HStack(spacing: 0) {
                        if index > 0 {
                            divider(before: index, fractions: fractions, available: available).zIndex(1)
                        }
                        column(slot, isLeading: index == 0, width: widths[index])
                            .frame(width: widths[index])
                            .clipped()
                            // The hovered column's chat clears below its header so the drop hint
                            // never sits over a visible transcript; the header stays put.
                            .mask {
                                VStack(spacing: 0) {
                                    Rectangle().frame(height: headerHeight)
                                    HStack(spacing: 0) {
                                        Rectangle().opacity(isTabTarget(slot) ? 0 : 1)
                                        if isNewColumnTarget, isLast(index) {
                                            Color.clear.frame(width: widths[index] * zone)
                                        }
                                    }
                                }
                            }
                            .overlay(alignment: .leading) {
                                // While a session is dragged over the row, every column shows it
                                // takes a tab; the hovered one lights up.
                                if target != nil {
                                    SessionPaneDropHint(
                                        title: "Add as tab", icon: .plus, isActive: isTabTarget(slot)
                                    )
                                    .dockPadding(.top, headerHeight)
                                    .frame(width: widths[index] * (isLast(index) ? 1 - zone : 1))
                                }
                            }
                        if index == activeSlot, let inspector = docked {
                            Color.dockBorderLight.frame(width: DockLayout.hairline)
                            inspector.frame(width: Self.inspectorWidth)
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
            .overlay(alignment: .topLeading) {
                if let inspector, docked == nil {
                    // After the active column, or before it when that would run off the window.
                    let end = inspectorStart
                    let x =
                        end + Self.inspectorWidth <= geometry.size.width
                        ? end : max(0, end - widths[activeSlot] - Self.inspectorWidth - DockLayout.hairline)
                    HStack(spacing: 0) {
                        Color.dockBorderLight.frame(width: DockLayout.hairline)
                        inspector.frame(width: Self.inspectorWidth)
                        Color.dockBorderLight.frame(width: DockLayout.hairline)
                    }
                    .frame(height: geometry.size.height)
                    .background(Color.dockOpaqueCanvas)
                    .offset(x: x)
                }
            }
            .overlay(alignment: .trailing) {
                if target != nil, zone > 0 {
                    SessionPaneDropHint(title: "New column", icon: .columnsPlusRight, isActive: isNewColumnTarget)
                        .dockPadding(.top, headerHeight)
                        .frame(width: (widths.last ?? 0) * zone)
                }
            }
            .animation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.28), value: slots.map(\.id))
            .animation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.2), value: target)
            .onDrop(
                of: isEnabled ? [SessionPaneDrag.pasteboardType.rawValue] : [],
                delegate: SessionPaneDropDelegate(
                    store: store, width: geometry.size.width,
                    fractions: fractions, inspectorStart: inspectorStart, inspectorWidth: inspectorWidth,
                    reduceMotion: reduceMotion, target: $target))
        }
    }

    static var inspectorWidth: CGFloat { 360 }

    /// A hairline with a wider grab area: dragging trades width between its two
    /// neighbors (each at least `minColumnWidth`); double-clicking evens the columns.
    private func divider(before index: Int, fractions: [CGFloat], available: CGFloat) -> some View {
        Color.dockBorderLight
            .frame(width: DockLayout.hairline)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .modifier(ColumnResizeCursor())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if #unavailable(macOS 15) { NSCursor.resizeLeftRight.set() }
                                guard available > 0 else { return }
                                let start = resizeStart ?? fractions
                                resizeStart = start
                                columnFractions = SessionPaneStore.resized(
                                    start, divider: index - 1, delta: value.translation.width / available,
                                    minFraction: SessionPaneStore.minColumnWidth / available)
                            }
                            .onEnded { _ in resizeStart = nil }
                    )
                    .onTapGesture(count: 2) { columnFractions = [] }
                    .accessibilityLabel("Resize columns")
            }
    }

    @ViewBuilder
    private func column(_ slot: Slot, isLeading: Bool, width: CGFloat) -> some View {
        switch slot {
        case .primary:
            // A group chat tab in the active column shows the room, not the main conversation.
            if let panel = store.activePanel, panel.selected?.groupRoomID != nil {
                SessionPanelView(panel: panel, store: store, metrics: metrics) {
                    header($0, panel: panel, isLeading: isLeading, width: width)
                }
            } else {
                primary(isLeading)
            }
        case .panel(let panel):
            SessionPanelView(panel: panel, store: store, metrics: metrics) {
                header($0, panel: panel, isLeading: isLeading, width: width)
            }
        }
    }

    private var isNewColumnTarget: Bool {
        if case .newPanel = target { return true }
        return false
    }

    private func isTabTarget(_ slot: Slot) -> Bool {
        guard case .tab(let index) = target else { return false }
        switch slot {
        case .primary: return index == (store.panels.isEmpty ? 0 : store.activeIndex)
        case .panel(let panel): return store.panels.firstIndex { $0.id == panel.id } == index
        }
    }

    /// An inactive column's title row, matching the primary header's height, fill and separator.
    private func header(_ content: AnyView, panel: SessionPaneStore.Panel, isLeading: Bool, width: CGFloat)
        -> some View
    {
        let showsLeading = isLeading && leadingControls != nil
        return HStack(spacing: 4) {
            if showsLeading, let leadingControls { leadingControls }
            content
            // A room column has no session to activate; its actions sit in the room's own bar.
            if let selectedID = panel.selectedID, panel.selected?.groupRoomID == nil {
                let activate = { store.activate(selectedID, in: panel.id) }
                Spacer(minLength: 8)
                columnControls?(selectedID, activate)
                // The inspector follows the active column: opening it here makes this column active.
                DockSidebarToggle(isCollapsed: true, edge: .trailing) {
                    activate()
                    onOpenInspector()
                }
            }
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

/// Re-renders only its content when the column count changes, so the window shell can
/// move the inspector beside the active column without observing every pane update.
struct SessionPaneSplitReader<Content: View>: View {
    @ObservedObject var store: SessionPaneStore
    @ViewBuilder let content: (Bool) -> Content

    var body: some View { content(store.panels.count > 1) }
}

/// Tabs of the active column, shown in the main header in place of the session title
/// once the column holds more than one session.
struct SessionPaneActiveTabs<Fallback: View>: View {
    @ObservedObject var store: SessionPaneStore
    @ObservedObject var runtime: DockModel
    @ViewBuilder let fallback: Fallback

    var body: some View {
        // While split, the active column keeps its tab strip too, so its close button is always reachable.
        if let panel = store.activePanel, panel.tabs.count > 1 || store.panels.count > 1, panel.selected != nil {
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
                id: id, title: isSelected ? liveTitle ?? tab.title : tab.title,
                icon: tab.groupRoomID == nil ? .chatCircle : .usersThree,
                isSelected: isSelected,
                select: { store.select(id, in: panel.id) }, close: { store.closeTab(id, in: panel.id) },
                groupRoomID: tab.groupRoomID)
        }
    }

    @Environment(\.chatContextRouter) private var router
    @ObservedObject private var status = SessionPaneStore.shared.tabStatus

    var body: some View {
        // Tabs keep readable titles (up to 220pt each); a narrow column scrolls the strip
        // sideways instead of squeezing every title to a letter.
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs) { tab in
                        // A Bot's main chat shows the Bot's avatar instead of the chat glyph.
                        let bot = router?.bots?.bots.first { $0.chat?.sessionID == tab.id }
                        // A group chat shows its members' avatars instead of the group glyph.
                        let members: [BotSummary] =
                            tab.groupRoomID.flatMap { roomID in
                                router?.bots?.groupChats.rooms.first { $0.id == roomID }?.members.compactMap {
                                    router?.bots?.botsByID[$0.profile]
                                }
                            } ?? []
                        SessionPaneTab(
                            tab: tab, bot: bot, avatar: bot.flatMap { router?.bots?.avatarImages[$0.id] },
                            members: members, avatarImages: router?.bots?.avatarImages ?? [:],
                            status: status.entries[tab.id]
                        )
                        .id(tab.id)
                    }
                }
            }
            .onAppear { scrollToSelected(proxy) }
            .onChange(of: selectedID) { _, _ in scrollToSelected(proxy) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Wins width over the header's spacer, which would otherwise take half and clip the tabs.
        .layoutPriority(1)
    }

    private var selectedID: String? { tabs.first(where: \.isSelected)?.id }

    private func scrollToSelected(_ proxy: ScrollViewProxy) {
        guard let selectedID else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(selectedID) }
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
    var members: [BotSummary] = []
    var avatarImages: [String: Data] = [:]
    let status: SessionPaneTabStatusModel.Entry?
    @State private var hovered = false

    /// A Bot's main chat carries Hermes' canonical "Bot Chat" title; the Bot's name identifies it.
    private var title: String { bot?.name ?? tab.title }

    var body: some View {
        SessionPaneTabWidth(maxWidth: 220) {
            HStack(spacing: 0) {
                Button(action: tab.select) {
                    HStack(spacing: 6) {
                        if let bot {
                            BotAvatarView(bot: bot, imageData: avatar, size: 16, animated: false)
                        } else if !members.isEmpty {
                            HStack(spacing: -5) {
                                ForEach(members.prefix(3)) { member in
                                    BotAvatarView(
                                        bot: member, imageData: avatarImages[member.id], size: 16, animated: false
                                    )
                                    .overlay(Circle().stroke(Color.dockCanvas, lineWidth: 1))
                                }
                            }
                        } else {
                            DockIcon(
                                tab.icon, size: 12, weight: tab.isSelected ? .fill : .regular,
                                color: tab.isSelected ? .dockPrimaryText : .dockSecondaryText)
                        }
                        Text(title).lineLimit(1).truncationMode(.tail)
                        if let status {
                            SidebarSessionStatusIndicator(session: status.session, status: status.status)
                        }
                    }
                    .dockPadding(.leading, 8)
                    .dockPadding(.trailing, 2)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                .help(title)
                .accessibilityAddTraits(tab.isSelected ? .isSelected : [])
                Button(action: tab.close) {
                    DockIcon(.x, size: 10, color: tab.isSelected ? .dockPrimaryText : .dockSecondaryText)
                        .frame(width: 22, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                .accessibilityLabel("Close \(title)")
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

/// A group chat opened from Bots has no columns yet. Dropping a session on it makes the room
/// the first column's tab and opens the session as a tab or new column beside it, like any chat.
struct SessionPaneRoomDrop: ViewModifier {
    let store: SessionPaneStore
    let room: GroupRoom
    let headerHeight: CGFloat
    /// The room now lives in the columns; the caller stops showing it on its own.
    let onAdopted: () -> Void
    @State private var target: SessionPaneTarget?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let zone = SessionPaneStore.newColumnZone(columnCount: 1)
            content
                .overlay {
                    if let target {
                        HStack(spacing: 0) {
                            SessionPaneDropHint(title: "Add as tab", icon: .plus, isActive: target == .tab(0))
                                .frame(width: geometry.size.width * (1 - zone))
                            SessionPaneDropHint(
                                title: "New column", icon: .columnsPlusRight, isActive: target != .tab(0)
                            )
                            .frame(width: geometry.size.width * zone)
                        }
                        .dockPadding(.top, headerHeight)
                    }
                }
                .onDrop(
                    of: [SessionPaneDrag.pasteboardType.rawValue],
                    delegate: SessionPaneDropDelegate(
                        store: store, width: geometry.size.width, fractions: [], reduceMotion: reduceMotion,
                        target: $target,
                        prepare: {
                            store.open(SessionPaneDrag(room: room).destination, target: .tab(0))
                            onAdopted()
                        }))
        }
    }
}

extension View {
    func sessionPaneRoomDrop(
        store: SessionPaneStore, room: GroupRoom, headerHeight: CGFloat, onAdopted: @escaping () -> Void
    ) -> some View {
        modifier(SessionPaneRoomDrop(store: store, room: room, headerHeight: headerHeight, onAdopted: onAdopted))
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
        // Mutes the transcript underneath so the drop choices read clearly.
        .background(Color.dockOpaqueCanvas.opacity(isActive ? 0.92 : 0.8))
        .animation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.18), value: isActive)
        .transition(.opacity)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

private struct SessionPanelView<Header: View>: View {
    let panel: SessionPaneStore.Panel
    let store: SessionPaneStore
    let metrics: ConversationWorkspaceMetrics
    let header: (AnyView) -> Header
    @ObservedObject private var chat: EdgeQuickConversationModel

    init(
        panel: SessionPaneStore.Panel, store: SessionPaneStore, metrics: ConversationWorkspaceMetrics,
        header: @escaping (AnyView) -> Header
    ) {
        self.panel = panel
        self.store = store
        self.metrics = metrics
        self.header = header
        chat = panel.chat
    }

    private var tabStrip: some View {
        SessionPaneTabStrip(
            tabs: SessionPaneTabStrip.items(
                panel: panel, store: store, liveTitle: chat.conversation?.currentSessionTitle))
    }

    var body: some View {
        if let roomID = panel.selected?.groupRoomID, let bots = router?.bots {
            // The tab names the room; its thread and room actions sit at the tab row's trailing
            // edge, where a bot chat keeps its menu.
            GroupChatView(
                store: bots.groupChats, botMode: bots, roomID: roomID, metrics: metrics,
                toolbar: { _, actions in
                    AnyView(
                        header(
                            AnyView(
                                HStack(spacing: 4) {
                                    tabStrip
                                    Spacer(minLength: 8)
                                    actions
                                })))
                }
            ) {
                store.closeTab(panel.selectedID ?? "", in: panel.id)
            } onOpenRoom: { id in
                // A group edited into a new one opens as a tab beside this room.
                guard let room = bots.groupChats.rooms.first(where: { $0.id == id }),
                    let index = store.panels.firstIndex(where: { $0.id == panel.id })
                else { return }
                store.open(SessionPaneDrag(room: room).destination, target: .tab(index))
            }
            .id(roomID)
        } else {
            VStack(spacing: 0) {
                header(AnyView(tabStrip))
                Group {
                    if panel.selected?.groupRoomID != nil {
                        DockLoadingState(title: "Loading group chat…")
                    } else {
                        sessionContent
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    @Environment(\.chatContextRouter) private var router

    @ViewBuilder
    private var sessionContent: some View {
        // One loading state at a time: the transcript has its own, so the column never
        // overlays a second one on top of it.
        if let conversation = chat.conversation, !chat.loadFailed,
            !(chat.isLoading && conversation.messages.isEmpty)
        {
            SessionPaneChat(model: conversation, metrics: metrics)
                .id(panel.selectedID)
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
    let metrics: ConversationWorkspaceMetrics
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

/// The divider's resize cursor. A push/pop pair loses to the transcripts' text cursors and the
/// app's cursor arbiter, which reset it the moment it shows; the native pointer style rides
/// SwiftUI's own cursor updates, and the macOS 14 fallback re-asserts it on every move.
private struct ColumnResizeCursor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.columnResize)
        } else {
            content.onContinuousHover { phase in
                if case .active = phase { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
        }
    }
}
