import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Fullscreen navigation stays visible as a quiet operational queue. It is
/// intentionally list-led rather than another dashboard: selecting an item
/// always changes the central work surface.
enum SessionAttentionDot: Equatable, Sendable {
    case warning, clarification, failure, success, activity

    var color: Color {
        switch self {
        case .warning: .dockWarning
        case .clarification: DockStatusTone.working.color
        case .failure: .dockDestructive
        case .success: .dockSuccess
        case .activity: DockStatusTone.working.color
        }
    }
}

/// A session's live working/unread state, shown alongside `SessionAttentionDot`
/// wherever a session row is rendered. Working takes priority over unread; both
/// stay silent when the session is idle and read.
struct SessionActivityGlyph: View {
    let isWorking: Bool
    let hasUnreadUpdate: Bool
    var session: HermesSession? = nil

    var body: some View {
        if isWorking {
            DockActivityIndicator(state: .running, role: .compact)
        } else if hasUnreadUpdate, let session {
            SessionUnreadReplyBadge(session: session)
        }
    }
}

/// Aggregate the resolved statuses used by conversation rows.
struct ChatRailActivity: Equatable {
    let isWorking: Bool
    let unreadCount: Int

    init(statuses: [SidebarSessionStatus], foregroundWorking: Bool, isConnected: Bool) {
        isWorking = isConnected && (foregroundWorking || statuses.contains(.working))
        unreadCount = statuses.filter { $0 == .unreadComplete }.count
    }

    var unreadBadgeLabel: String { unreadCount > 99 ? "99+" : "\(unreadCount)" }

    var summary: String {
        var parts: [String] = []
        if isWorking { parts.append("Sessions running") }
        if unreadCount > 0 {
            parts.append("\(unreadCount) completed chat\(unreadCount == 1 ? "" : "s") to review")
        }
        return parts.joined(separator: ", ")
    }
}

struct ConversationRepositoryBadgePresentation: Equatable {
    static let maximumLabelLength = 24

    let label: String
    let accessibilityLabel: String

    static func make(projectName: String?, isProjectLinked: Bool) -> Self? {
        guard isProjectLinked,
            let projectName,
            !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let trimmedName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastPathComponent = URL(fileURLWithPath: trimmedName).lastPathComponent
        let normalizedName = lastPathComponent.isEmpty ? trimmedName : lastPathComponent
        guard !normalizedName.isEmpty else { return nil }

        let label: String
        if normalizedName.count > maximumLabelLength {
            label = String(normalizedName.prefix(maximumLabelLength - 1)) + "…"
        } else {
            label = normalizedName
        }
        return Self(
            label: label,
            accessibilityLabel: "Repository \(label)"
        )
    }
}

struct ConversationRepositoryBadgeAssociationProjection {
    struct Group {
        let sessionIDs: Set<String>
        let title: String
        let isLinked: Bool

        init(sessionIDs: [String], title: String, isLinked: Bool) {
            self.sessionIDs = Set(sessionIDs)
            self.title = title
            self.isLinked = isLinked
        }
    }

    let linkedSessionIDs: Set<String>
    let projectNameBySessionID: [String: String]

    init(groups: [Group]) {
        var linkedSessionIDs = Set<String>()
        var projectNameBySessionID: [String: String] = [:]
        for group in groups where group.isLinked {
            linkedSessionIDs.formUnion(group.sessionIDs)
            for sessionID in group.sessionIDs where projectNameBySessionID[sessionID] == nil {
                projectNameBySessionID[sessionID] = group.title
            }
        }
        self.linkedSessionIDs = linkedSessionIDs
        self.projectNameBySessionID = projectNameBySessionID
    }

    func badge(for sessionID: String) -> ConversationRepositoryBadgePresentation? {
        ConversationRepositoryBadgePresentation.make(
            projectName: projectNameBySessionID[sessionID],
            isProjectLinked: linkedSessionIDs.contains(sessionID)
        )
    }

    func isLinked(sessionID: String) -> Bool {
        linkedSessionIDs.contains(sessionID)
    }

    func projectName(for sessionID: String) -> String? {
        projectNameBySessionID[sessionID]
    }
}

/// Primary navigation: Chats, pinned destinations, and a menu for every destination. Chats opens the
/// session lists panel; GitHub supplies its own section navigation beside its page.
struct SessionNavRail: View {
    let model: DockModel
    let controlCenter: ControlCenterModel
    let workspaceStore: WorkspaceStore
    @ObservedObject var agentUpdateService: HermesUpdateService
    @ObservedObject var appUpdater = HermAppUpdater.shared
    @ObservedObject var navigationState: SessionNavigationState
    @ObservedObject var dockThemeStore: DockThemeStore
    @AppStorage(DockRailDestination.pinsKey) private var pinnedDestinations = DockRailDestination.defaultPins
    @AppStorage(QuotaRailRing.preferenceKey) private var showsQuotaRings = QuotaRailRing.defaultShown
    @State private var showsDestinations = false
    @State private var showsViewMenu = false
    @State private var showsSkinMenu = false
    @State private var showsDensityMenu = false
    @State private var showsNotchMenu = false
    @State private var showsStatusBarMenu = false
    @AppStorage(DockWorkspaceScale.preferenceKey) private var textSize = DockWorkspaceScale.defaultTextSize
    @ObservedObject private var desktopPlugins = DesktopPluginStore.shared
    @State private var dragOrder: [DockRailItem]?
    @State private var draggingItem: DockRailItem?
    @State private var dragOffset: CGFloat = 0
    @State private var dragStartIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isChatsActive: Bool
    let isGitHubActive: Bool
    let onOpenChats: () -> Void
    let onOpenGlobal: (ControlTab) -> Void
    let onOpenArtifacts: () -> Void
    let onOpenGitHub: (GitHubWorkspaceSection) -> Void
    let onOpenPlugin: (String) -> Void
    let isFullscreen: Bool
    var isHermesConnected = true
    var hermesConnectionIssue: String?
    var onReconnect: () async -> Void = {}
    let isDockedWindow: Bool
    let onFullscreenToggle: () -> Void
    let onOpenWindow: (() -> Void)?

    var body: some View {
        let style = DockThemePalette(theme: dockThemeStore.selectedThemeID)
        GeometryReader { proxy in
            railContent(style: style, quotaHeight: proxy.size.height / 2)
        }
        .dockPadding(.horizontal, 7)
        .dockPadding(.top, 12)
        .dockPadding(.bottom, 8)
        .frame(width: 52)
        .frame(maxHeight: .infinity)
        .dockShellChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Herm navigation")
        .task { await desktopPlugins.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await desktopPlugins.refresh() }
        }
    }

    private func railContent(style: DockThemePalette, quotaHeight: CGFloat) -> some View {
        VStack(spacing: 4) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    VStack(spacing: 4) {
                        ChatRailButton(
                            model: model, control: controlCenter, store: workspaceStore,
                            isSelected: isChatsActive, style: style, action: onOpenChats
                        )
                    }
                    ForEach(dragOrder ?? orderedPins) { item in
                        let isDragging = draggingItem == item
                        destination(
                            title(item), icon: icon(item), isSelected: isSelected(item),
                            glyph: pluginGlyph(item, size: 17), style: style
                        ) { open(item) }
                        .contextMenu {
                            Button("Unpin \(title(item)) from sidebar", icon: .pushPinSlash) { togglePin(item) }
                        }
                        .scaleEffect(isDragging && DockMotion.isEnabled(reduceMotion: reduceMotion) ? 1.045 : 1)
                        .shadow(color: .black.opacity(isDragging ? 0.18 : 0), radius: 4, y: 2)
                        .offset(y: isDragging ? dragOffset : 0)
                        .zIndex(isDragging ? 1 : 0)
                        .simultaneousGesture(reorderGesture(for: item))
                    }
                    destination(
                        "More destinations", icon: .dotsThree,
                        isSelected: menuItems.contains { !pins.contains($0) && isSelected($0) },
                        style: style
                    ) { showsDestinations.toggle() }
                    .dockPopover(isPresented: $showsDestinations, arrowEdge: .trailing) {
                        destinationMenu
                    }
                }
                .padding(.top, 6)  // room for the chat badge above its icon
            }
            // Global window chrome: applies to the whole workspace, not one chat.
            VStack(spacing: 4) {
                if showsQuotaRings {
                    QuotaRailRings(control: controlCenter, maximumListHeight: quotaHeight)
                }
                HermesConnectionButton(
                    isConnected: isHermesConnected, issue: hermesConnectionIssue,
                    endpoint: (model.controlRPCClient as? HermesGateway)?.endpointDescription ?? "Hermes Agent",
                    // The installed CLI only describes a local backend.
                    version: GatewayConnectionStore.isLocalBackend
                        ? agentUpdateService.installed.map { "Hermes \($0.displayVersion)" } : nil,
                    service: controlCenter.gatewayService, style: style, onReconnect: onReconnect)
                destination(
                    "Settings and appearance", icon: .gear,
                    isSelected: navigationState.selection.isGlobalSelected(.core),
                    showsUpdateBadge: hasUpdateBadge, style: style
                ) {
                    showsViewMenu.toggle()
                }
                .dockPopover(isPresented: $showsViewMenu, arrowEdge: .trailing) { viewMenu }
            }
        }
    }

    private func destination(
        _ title: String, icon: Ph, isSelected: Bool, showsUpdateBadge: Bool = false, glyph: Text? = nil,
        style: DockThemePalette, action: @escaping () -> Void
    ) -> some View {
        DockRailButton(
            title: title, icon: icon, isSelected: isSelected, showsUpdateBadge: showsUpdateBadge, glyph: glyph,
            style: style, action: action)
    }

    private var pins: Set<DockRailItem> { DockRailItem.pins(pinnedDestinations) }
    /// Pins the rail can show now; a plugin that is uninstalled keeps its pin, hidden.
    private var orderedPins: [DockRailItem] { DockRailItem.ordered(pinnedDestinations).filter(isAvailable) }
    /// Built-in destinations, then the installed Desktop plugin pages that run in Herm.
    private var menuItems: [DockRailItem] {
        DockRailDestination.allCases.map(DockRailItem.builtIn) + desktopPlugins.pages.map { .plugin($0.id) }
    }

    private func isAvailable(_ item: DockRailItem) -> Bool {
        guard case .plugin(let id) = item else { return true }
        return desktopPlugins.pages.contains { $0.id == id }
    }

    private func title(_ item: DockRailItem) -> String {
        switch item {
        case .builtIn(let destination): destination.title
        case .plugin(let id): desktopPlugins.plugin(id)?.name ?? id
        }
    }

    private func icon(_ item: DockRailItem) -> Ph {
        switch item {
        case .builtIn(let destination): destination.icon
        case .plugin: .puzzlePiece
        }
    }

    /// The plugin's own sidebar icon when Herm can draw it; the puzzle `icon(item)` otherwise.
    private func pluginGlyph(_ item: DockRailItem, size: CGFloat) -> Text? {
        guard case .plugin(let id) = item else { return nil }
        return DesktopPluginIcon.glyph(desktopPlugins.plugin(id)?.codicon, size: size)
    }

    /// One rail slot: button height plus the stack spacing.
    private static let slotHeight: CGFloat = 42

    /// The lifted button follows the pointer while its neighbours spring aside.
    private func reorderGesture(for item: DockRailItem) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                var order = dragOrder ?? orderedPins
                guard let current = order.firstIndex(of: item) else { return }
                if draggingItem != item {
                    draggingItem = item
                    dragOrder = order
                    dragStartIndex = current
                }
                let target = min(
                    max(dragStartIndex + Int((value.translation.height / Self.slotHeight).rounded()), 0),
                    order.count - 1)
                if target != current {
                    order = DockRailItem.moving(item, to: target, in: order)
                    withAnimation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.16)) {
                        dragOrder = order
                    }
                }
                // Keep the button under the pointer even though its slot moved.
                dragOffset = value.translation.height - CGFloat(target - dragStartIndex) * Self.slotHeight
            }
            .onEnded { _ in
                let order = dragOrder ?? orderedPins
                withAnimation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.2)) {
                    dragOffset = 0
                    draggingItem = nil
                    pinnedDestinations = DockRailItem.raw(visible: order, keepingHiddenFrom: pinnedDestinations)
                }
                dragOrder = nil
            }
    }

    private func isSelected(_ item: DockRailItem) -> Bool {
        switch item {
        case .plugin(let id): navigationState.selection.selection == .plugin(id)
        case .builtIn(.github): isGitHubActive
        case .builtIn(.artifacts): navigationState.selection.selection == .artifacts
        case .builtIn(let destination):
            destination.tab.map { navigationState.selection.isGlobalSelected($0) } ?? false
        }
    }

    private func togglePin(_ item: DockRailItem) {
        pinnedDestinations = DockRailItem.toggling(item, in: pinnedDestinations)
    }

    private func open(_ item: DockRailItem) {
        showsDestinations = false
        switch item {
        case .plugin(let id): onOpenPlugin(id)
        case .builtIn(.github): onOpenGitHub(navigationState.selectedGitHubSection)
        case .builtIn(.artifacts): onOpenArtifacts()
        case .builtIn(let destination):
            if let tab = destination.tab { onOpenGlobal(tab) }
        }
    }

    private var hasUpdateBadge: Bool { agentUpdateService.phase == .updateAvailable || appUpdater.hasUpdate }

    /// Settings, appearance, status bar preferences and window mode.
    private var viewMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            viewMenuRow(
                "Settings", selected: navigationState.selection.isGlobalSelected(.core),
                badgeColor: hasUpdateBadge ? DockThemePalette(theme: dockThemeStore.selectedThemeID).warning : nil
            ) {
                showsViewMenu = false
                onOpenGlobal(.core)
            }
            viewMenuRow("Skins", selected: false, hasSubmenu: true) { showsSkinMenu.toggle() }
                .dockPopover(isPresented: $showsSkinMenu, arrowEdge: .trailing) { skinMenu }
            viewMenuRow("Density", selected: false, hasSubmenu: true) { showsDensityMenu.toggle() }
                .dockPopover(isPresented: $showsDensityMenu, arrowEdge: .trailing) { densityMenu }
            viewMenuRow("Notch", selected: false, hasSubmenu: true) { showsNotchMenu.toggle() }
                .dockPopover(isPresented: $showsNotchMenu, arrowEdge: .trailing) { NotchQuickMenu() }
            viewMenuRow("Status bar", selected: false, hasSubmenu: true) { showsStatusBarMenu.toggle() }
                .dockPopover(isPresented: $showsStatusBarMenu, arrowEdge: .trailing) {
                    WorkspaceStatusBarSettings.QuickMenu()
                }
            if let onOpenWindow {
                Color.dockBorderLight.frame(height: 0.5).dockPadding(.vertical, 4)
                viewMenuRow(isDockedWindow ? "Switch to floating" : "Switch to window", selected: false) {
                    showsViewMenu = false
                    onOpenWindow()
                }
            }
        }
        .dockPadding(6)
        .frame(width: 220)
    }

    private var skinMenu: some View {
        VStack(alignment: .trailing, spacing: 0) {
            DockSkinImportActions(store: dockThemeStore, allowsRemoval: false)
                .dockPadding(8)
            skinGrid
        }
        .frame(width: 560, height: 460)
    }

    private var skinGrid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(dockThemeStore.availableThemes) { theme in
                    let selected = dockThemeStore.selectedThemeID == theme
                    Button {
                        withAnimation(.dockEase(duration: 0.16)) { dockThemeStore.selectedThemeID = theme }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            DockSkinSpecimen(theme: theme)
                            HStack(spacing: 4) {
                                Text(theme.title).dockFont(.body, weight: .semibold).lineLimit(1)
                                Spacer(minLength: 0)
                                if selected { DockIcon(.check, color: .dockAccent) }
                            }
                        }
                        .dockPadding(6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.dockHover)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .dockSkinContextMenu(for: theme, store: dockThemeStore)
                }
            }
            .dockPadding(8)
        }
    }

    private var densityMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(
                [(DockWorkspaceScale.defaultTextSize, "Default"), (DockWorkspaceScale.compactTextSize, "Compact")],
                id: \.1
            ) { size, title in
                let selected = DockWorkspaceScale.supportedTextSize(textSize) == size
                Button {
                    textSize = size
                } label: {
                    HStack(spacing: 8) {
                        DockIcon(.check, size: 12, color: .dockPrimaryText).opacity(selected ? 1 : 0)
                        Text(title).dockFont(.body)
                        Spacer(minLength: 0)
                    }
                    .dockPadding(8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .dockPadding(6)
        .frame(width: 160)
    }

    private func viewMenuRow(
        _ title: String, selected: Bool, hasSubmenu: Bool = false, badgeColor: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title).dockFont(.body)
                Spacer(minLength: 0)
                if let badgeColor { Circle().fill(badgeColor).frame(width: 7, height: 7) }
                if hasSubmenu { DockIcon(.caretRight, size: 10, color: Color.dockMetadataText) }
            }
            .dockPadding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityLabel(badgeColor == nil ? title : "\(title), update available")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var destinationMenu: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(menuItems) { item in
                    HStack(spacing: 4) {
                        Button {
                            open(item)
                        } label: {
                            HStack(spacing: 10) {
                                let color: Color = isSelected(item) ? .dockPrimaryText : .dockSecondaryText
                                if let glyph = pluginGlyph(item, size: 16) {
                                    glyph.foregroundStyle(color).frame(width: 16)
                                } else {
                                    DockIcon(
                                        icon(item), size: 16, weight: isSelected(item) ? .fill : .regular,
                                        color: color)
                                }
                                Text(title(item)).dockFont(.body).lineLimit(1)
                                Spacer(minLength: 8)
                                if case .plugin = item {
                                    DesktopPluginBadge()
                                }
                            }
                            .dockPadding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.dockHover)
                        .accessibilityAddTraits(isSelected(item) ? .isSelected : [])
                        Button {
                            togglePin(item)
                        } label: {
                            DockIcon(
                                .pushPin, size: 14, weight: pins.contains(item) ? .fill : .regular,
                                color: pins.contains(item) ? .dockPrimaryText : .dockMetadataText
                            )
                            .frame(width: 32, height: 32)
                            .accessibilityAddTraits(pins.contains(item) ? .isSelected : [])
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.dockHover)
                        .help(pins.contains(item) ? "Unpin from sidebar" : "Pin to sidebar")
                        .accessibilityLabel("\(pins.contains(item) ? "Unpin" : "Pin") \(title(item))")
                        .accessibilityValue(pins.contains(item) ? "Pinned" : "Unpinned")
                    }
                    .dockSelectionBackground(
                        DockThemeShape(cornerRadius: DockLayout.controlRadius), active: isSelected(item),
                        fill: DockThemePalette(theme: DockThemeRuntime.current).selectedFill, allowsInvert: false)
                }
            }.dockPadding(8)
        }
        .frame(width: 260, height: min(440, CGFloat(menuItems.count) * 38 + 16))
        .foregroundStyle(Color.dockPrimaryText)
        .background(Color.dockCanvas)
        .dockThemedRoot()
    }

}

/// Hermes Agent backend status (what every chat depends on), then the
/// separate local messaging gateway.
private struct HermesConnectionButton: View {
    let isConnected: Bool
    let issue: String?
    let endpoint: String
    let version: String?
    @ObservedObject var service: HermesGatewayLifecycleModel
    let style: DockThemePalette
    let onReconnect: () async -> Void
    @State private var showsActions = false
    @State private var isReconnecting = false

    private var title: String {
        if isConnected { return "Connected to Hermes Agent" }
        return isReconnecting ? "Connecting to Hermes Agent…" : "Hermes Agent offline"
    }

    var body: some View {
        Button {
            showsActions.toggle()
        } label: {
            DockIcon(isConnected ? .plugsConnected : .plugs, size: 15, color: style.secondaryText)
                .frame(width: 38, height: 30)
                .overlay(alignment: .topTrailing) {
                    Circle().fill(isConnected ? style.success : style.destructive)
                        .frame(width: 7, height: 7)
                        .dockPadding(.top, 4).dockPadding(.trailing, 7)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .help(issue.map { "\(title) · \($0)" } ?? title)
        .accessibilityLabel("\(title). Connection details")
        .accessibilityIdentifier("hermes-gateway-actions")
        .dockPopover(isPresented: $showsActions, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle().fill(isConnected ? Color.dockSuccess : Color.dockDestructive)
                            .frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(title)
                            .dockFont(.body, weight: .semibold)
                            .foregroundStyle(Color.dockPrimaryText)
                        Spacer(minLength: 0)
                        if !isConnected {
                            Button {
                                Task {
                                    isReconnecting = true
                                    await onReconnect()
                                    isReconnecting = false
                                }
                            } label: {
                                DockActionLabel(
                                    title: "Reconnect", pendingTitle: "Connecting…", isPending: isReconnecting)
                            }
                            .buttonStyle(.dockPrimary)
                            .disabled(isReconnecting)
                        }
                    }
                    Text([endpoint, version].compactMap(\.self).joined(separator: " · "))
                        .dockFont(.body)
                        .foregroundStyle(Color.dockSecondaryText)
                    if !isConnected, let issue {
                        Text(issue)
                            .dockFont(.body)
                            .foregroundStyle(Color.dockWarning)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .dockButtonSize(.compact)
                Divider()
                Text("Messaging gateway · Default profile")
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockSecondaryText)
                HermesGatewaySettingsView(service: service)
            }
            .dockPadding(16)
            .frame(width: 400)
            .background(Color.dockCanvas)
        }
    }
}
