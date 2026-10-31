import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Fullscreen navigation stays visible as a quiet operational queue. It is
/// intentionally list-led rather than another dashboard: selecting an item
/// always changes the central work surface.
enum SessionAttentionDot: Equatable {
    case warning, clarification, failure, success, activity

    var color: Color {
        switch self {
        case .warning: .dockWarning
        case .clarification: .dockAccent
        case .failure: .dockDestructive
        case .success: .dockSuccess
        case .activity: .dockAccent
        }
    }
}

/// A session's live working/unread state, shown alongside `SessionAttentionDot`
/// wherever a session row is rendered. Working takes priority over unread; both
/// stay silent when the session is idle and read.
struct SessionActivityGlyph: View {
    let isWorking: Bool
    let hasUnreadUpdate: Bool

    var body: some View {
        if isWorking {
            DockActivityIndicator(state: .running, size: 10)
        } else if hasUnreadUpdate {
            DockActivityIndicator(state: .done, size: 10, unreadDot: true)
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
    let isWorkspaceVisible: Bool
    @ObservedObject var agentUpdateService: HermesUpdateService
    @ObservedObject var navigationState: SessionNavigationState
    @ObservedObject var dockThemeStore: DockThemeStore
    @AppStorage(DockRailDestination.pinsKey) private var pinnedDestinations = DockRailDestination.defaultPins
    @State private var showsDestinations = false
    @State private var dragOrder: [DockRailDestination]?
    @State private var draggingItem: DockRailDestination?
    @State private var dragOffset: CGFloat = 0
    @State private var dragStartIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isChatsActive: Bool
    let isGitHubActive: Bool
    let onOpenChats: () -> Void
    let onOpenGlobal: (ControlTab) -> Void
    let onOpenArtifacts: () -> Void
    let onOpenGitHub: (GitHubWorkspaceSection) -> Void
    let isFullscreen: Bool
    var isHermesConnected = true
    var hermesConnectionIssue: String?
    var onReconnect: () async -> Void = {}
    let isDockedWindow: Bool
    let onFullscreenToggle: () -> Void
    let onOpenWindow: (() -> Void)?

    var body: some View {
        let style = DockThemePalette(theme: dockThemeStore.selectedThemeID)
        VStack(spacing: 4) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    VStack(spacing: 4) {
                        ChatRailButton(
                            model: model, control: controlCenter, store: workspaceStore,
                            isSelected: isChatsActive, isVisible: isWorkspaceVisible, style: style, action: onOpenChats
                        )
                    }
                    ForEach(dragOrder ?? orderedPins) { item in
                        let isDragging = draggingItem == item
                        destination(
                            item.title, icon: item.icon, isSelected: isSelected(item),
                            showsUpdateBadge: hasUpdate(item), style: style
                        ) { open(item) }
                        .contextMenu {
                            Button("Unpin \(item.title) from sidebar", icon: .pushPinSlash) { togglePin(item) }
                        }
                        .scaleEffect(isDragging ? 1.12 : 1)
                        .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: 8, y: 3)
                        .offset(y: isDragging ? dragOffset : 0)
                        .zIndex(isDragging ? 1 : 0)
                        .simultaneousGesture(reorderGesture(for: item))
                    }
                    destination(
                        "More destinations", icon: .dotsThree,
                        isSelected: DockRailDestination.allCases.contains { !pins.contains($0) && isSelected($0) },
                        showsUpdateBadge: !pins.contains(.settings) && hasUpdate(.settings), style: style
                    ) { showsDestinations.toggle() }
                    .dockPopover(isPresented: $showsDestinations, arrowEdge: .trailing) {
                        destinationMenu
                    }
                }
            }
            // Global window chrome: applies to the whole workspace, not one chat.
            VStack(spacing: 4) {
                HermesConnectionButton(
                    isConnected: isHermesConnected, issue: hermesConnectionIssue,
                    endpoint: model.gateway.endpointDescription,
                    // The installed CLI only describes a local backend.
                    version: GatewayConnectionStore.isLocalBackend
                        ? agentUpdateService.installed.map { "Hermes \($0.displayVersion)" } : nil,
                    service: controlCenter.gatewayService, style: style, onReconnect: onReconnect)
                if let onOpenWindow {
                    destination(
                        isDockedWindow ? "Switch to floating" : "Switch to window",
                        icon: isDockedWindow ? .pictureInPicture : .appWindow, isSelected: false, style: style,
                        action: onOpenWindow)
                }
            }
        }
        .dockPadding(.horizontal, 7)
        .dockPadding(.top, 12)
        .dockPadding(.bottom, 8)
        .frame(width: 52)
        .frame(maxHeight: .infinity)
        .dockShellChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Herm navigation")
    }

    private func destination(
        _ title: String, icon: Ph, isSelected: Bool, showsUpdateBadge: Bool = false, style: DockThemePalette,
        action: @escaping () -> Void
    ) -> some View {
        DockRailButton(
            title: title, icon: icon, isSelected: isSelected, showsUpdateBadge: showsUpdateBadge, style: style,
            action: action)
    }

    private var pins: Set<DockRailDestination> { DockRailDestination.pins(pinnedDestinations) }
    private var orderedPins: [DockRailDestination] { DockRailDestination.ordered(pinnedDestinations) }

    /// One rail slot: button height plus the stack spacing.
    private static let slotHeight: CGFloat = 42

    /// The lifted button follows the pointer while its neighbours spring aside.
    private func reorderGesture(for item: DockRailDestination) -> some Gesture {
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
                    order = DockRailDestination.moving(item, to: target, in: order)
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.78)) {
                        dragOrder = order
                    }
                }
                // Keep the button under the pointer even though its slot moved.
                dragOffset = value.translation.height - CGFloat(target - dragStartIndex) * Self.slotHeight
            }
            .onEnded { _ in
                let order = dragOrder ?? orderedPins
                withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                    dragOffset = 0
                    draggingItem = nil
                    pinnedDestinations = DockRailDestination.raw(order)
                }
                dragOrder = nil
            }
    }

    private func isSelected(_ item: DockRailDestination) -> Bool {
        switch item {
        case .github: isGitHubActive
        case .artifacts: navigationState.selection.selection == .artifacts
        default: item.tab.map { navigationState.selection.isGlobalSelected($0) } ?? false
        }
    }

    private func hasUpdate(_ item: DockRailDestination) -> Bool {
        item == .settings && agentUpdateService.phase == .updateAvailable
    }

    private func togglePin(_ item: DockRailDestination) {
        pinnedDestinations = DockRailDestination.toggling(item, in: pinnedDestinations)
    }

    private func open(_ item: DockRailDestination) {
        showsDestinations = false
        switch item {
        case .github:
            onOpenGitHub(navigationState.selectedGitHubSection)
        case .artifacts: onOpenArtifacts()
        default:
            if let tab = item.tab {
                onOpenGlobal(tab)
            }
        }
    }

    private var destinationMenu: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(DockRailDestination.allCases) { item in
                    HStack(spacing: 4) {
                        Button {
                            open(item)
                        } label: {
                            HStack(spacing: 10) {
                                DockIcon(
                                    item.icon, size: 16, weight: isSelected(item) ? .fill : .regular,
                                    color: isSelected(item) ? .dockPrimaryText : .dockSecondaryText)
                                Text(item.title).dockFont(.body)
                                Spacer(minLength: 8)
                                if hasUpdate(item) {
                                    DockIcon(.arrowCircleUp, size: 14, color: .dockWarning)
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
                        .accessibilityLabel("\(pins.contains(item) ? "Unpin" : "Pin") \(item.title)")
                        .accessibilityValue(pins.contains(item) ? "Pinned" : "Unpinned")
                    }
                    .dockSelectionBackground(
                        DockThemeShape(cornerRadius: DockLayout.controlRadius), active: isSelected(item),
                        fill: DockThemePalette(theme: DockThemeRuntime.current).selectedFill, allowsInvert: false)
                }
            }.dockPadding(8)
        }
        .frame(width: 260, height: min(440, CGFloat(DockRailDestination.allCases.count) * 38 + 16))
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
