import AppKit
import Combine
import SwiftUI
import Foundation
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
              !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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

/// Primary navigation: icon-only destinations, always visible. Chats opens the
/// session lists panel; every other destination renders full-width.
struct MissionControlRail: View {
    let model: DockModel
    let controlCenter: ControlCenterModel
    let workspaceStore: WorkspaceStore
    let isWorkspaceVisible: Bool
    @ObservedObject var agentUpdateService: HermesUpdateService
    @ObservedObject var navigationState: MissionControlNavigationState
    @ObservedObject var dockThemeStore: DockThemeStore
    @AppStorage(SidebarVisibilityKey.kanban) private var showsKanban = true
    @AppStorage(SidebarVisibilityKey.pullRequests) private var showsPullRequests = true
    @AppStorage(SidebarVisibilityKey.issues) private var showsIssues = true
    @AppStorage(SidebarVisibilityKey.office) private var showsOffice = true
    @AppStorage(SidebarVisibilityKey.calendar) private var showsCalendar = true
    let isChatsActive: Bool
    let isIssuesActive: Bool
    let onOpenChats: () -> Void
    let onOpenGlobal: (ControlTab) -> Void
    let onOpenArtifacts: () -> Void
    let onOpenBots: () -> Void
    let onOpenPullRequests: () -> Void
    let onOpenIssues: () -> Void
    let isFullscreen: Bool
    var isHermesConnected = true
    var onReconnect: () -> Void = {}
    let isDockedWindow: Bool
    let onFullscreenToggle: () -> Void
    let onOpenWindow: (() -> Void)?

    var body: some View {
        let style = DockThemePalette(theme: dockThemeStore.selectedThemeID)
        VStack(spacing: 4) {
            VStack(spacing: 4) {
                ChatRailButton(
                    model: model, control: controlCenter, store: workspaceStore,
                    isSelected: isChatsActive, isVisible: isWorkspaceVisible, style: style, action: onOpenChats
                )
            }
            VStack(spacing: 4) {
                if showsKanban { globalDestination(.kanban, style: style) }
                if showsPullRequests { destination("Pull requests", icon: .gitPullRequest, isSelected: navigationState.selection.selection == .pullRequests, style: style, action: onOpenPullRequests) }
                if showsIssues { destination("Issues", icon: .record, isSelected: isIssuesActive, style: style, action: onOpenIssues) }
            }
            VStack(spacing: 4) {
                if showsCalendar { globalDestination(.calendar, style: style) }
                globalDestination(.automations, style: style)
                globalDestination(.capabilities, style: style)
            }
            VStack(spacing: 4) {
                destination("Artifacts", icon: .files, isSelected: navigationState.selection.selection == .artifacts, style: style, action: onOpenArtifacts)
                if showsOffice { globalDestination(.officePreview, style: style) }
            }
            VStack(spacing: 4) {
                destination("Bots", icon: .ghost, isSelected: navigationState.selection.selection == .bots, style: style, action: onOpenBots)
                globalDestination(.messaging, style: style)
                globalDestination(.usage, style: style)
            }
            VStack(spacing: 4) {
                globalDestination(.quota, style: style)
                globalDestination(.core, style: style)
            }
            Spacer(minLength: 0)
            // Global window chrome: applies to the whole workspace, not one chat.
            VStack(spacing: 4) {
                HermesConnectionButton(isConnected: isHermesConnected, style: style, onReconnect: onReconnect)
                if let onOpenWindow {
                    destination(isDockedWindow ? "Switch to floating" : "Switch to window", icon: isDockedWindow ? .pictureInPicture : .appWindow, isSelected: false, style: style, action: onOpenWindow)
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(width: 52)
        .frame(maxHeight: .infinity)
        .background(style.sidebarBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hermes navigation")
    }

    private func destination(_ title: String, icon: Ph, isSelected: Bool, showsUpdateBadge: Bool = false, style: DockThemePalette, action: @escaping () -> Void) -> some View {
        DockRailButton(title: title, icon: icon, isSelected: isSelected, showsUpdateBadge: showsUpdateBadge, style: style, action: action)
    }

    private func globalDestination(_ tab: ControlTab, style: DockThemePalette) -> some View {
        destination(
            tab.globalRailLabel,
            icon: tab.icon,
            isSelected: navigationState.selection.isGlobalSelected(tab),
            showsUpdateBadge: tab == .core && agentUpdateService.phase == .updateAvailable,
            style: style
        ) {
            navigationState.selectGlobal(tab)
            onOpenGlobal(tab)
        }
    }
}

/// Whether Herm's gateway socket to the Hermes backend is up. Offline is a
/// button that retries the connection.
private struct HermesConnectionButton: View {
    let isConnected: Bool
    let style: DockThemePalette
    let onReconnect: () -> Void

    var body: some View {
        let title = isConnected ? "Connected to Hermes" : "Hermes offline · Click to reconnect"
        Button { if !isConnected { onReconnect() } } label: {
            DockIcon(isConnected ? .plugsConnected : .plugs, size: 15, color: style.secondaryText)
                .frame(width: 38, height: 30)
                .overlay(alignment: .topTrailing) {
                    Circle().fill(isConnected ? style.success : style.destructive)
                        .frame(width: 7, height: 7)
                        .padding(.top, 4).padding(.trailing, 7)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}
