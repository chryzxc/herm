import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct SessionNavConversationSessionRow: View, Equatable {
    let session: HermesSession
    let isSelected: Bool
    let isProjectLinked: Bool
    let projectName: String?
    let attentionDot: SessionAttentionDot?
    let isPinned: Bool
    var style = DockThemePalette(theme: .glass)
    let onSelect: () -> Void
    let onTogglePin: () -> Void

    nonisolated static func controls(
        togglePin: @escaping () -> Void,
        onSelect: @escaping () -> Void
    ) -> PinnedSessionRowControls {
        PinnedSessionRowControls(select: onSelect, togglePin: togglePin)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session == rhs.session
            && lhs.isSelected == rhs.isSelected
            && lhs.isProjectLinked == rhs.isProjectLinked
            && lhs.projectName == rhs.projectName
            && lhs.attentionDot == rhs.attentionDot
            && lhs.isPinned == rhs.isPinned
            && lhs.style.theme == rhs.style.theme
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                sessionDetails
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.dockHover)

            Button(action: onTogglePin) {
                DockIcon(
                    .pushPin, size: 13, weight: isPinned ? .fill : .regular,
                    color: isPinned ? style.primaryText : style.metadataText
                )
                .frame(width: 44, height: 44)
                .accessibilityAddTraits(isPinned ? .isSelected : [])
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .accessibilityLabel(isPinned ? "Unpin \(session.displayTitle)" : "Pin \(session.displayTitle)")
            .help(isPinned ? "Unpin conversation" : "Pin conversation")
        }
        .background(
            RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous).dockSelectionFill(
                isSelected, fallback: isSelected ? style.selectedFill : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
    }

    private var sessionDetails: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(session.displayTitle)
                    .dockFont(.navigation)
                    .foregroundStyle(style.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                SessionActivityGlyph(isWorking: session.isWorking, hasUnreadUpdate: session.hasUnreadUpdate)
                if let attentionDot, !(attentionDot == .failure && session.isWorking) {
                    if let state = attentionDot.activityState {
                        DockActivityIndicator(state: state, size: 10, unreadDot: true)
                    } else {
                        Circle().fill(attentionDot.color).frame(width: 6, height: 6)
                    }
                }
            }
            if let badge = ConversationRepositoryBadgePresentation.make(
                projectName: projectName,
                isProjectLinked: isProjectLinked
            ) {
                DockIconLabel(badge.label, icon: .gitBranch)
                    .dockFont(.metadata, weight: .medium)
                    .foregroundStyle(style.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous).fill(style.selectedFill))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .help(badge.accessibilityLabel)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(badge.accessibilityLabel)
            }
            if let preview = session.displayPreview {
                Text(preview)
                    .dockFont(.body)
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(1)
            }
            if let timestamp = session.lastUpdatedAt {
                Text(timestamp, style: .relative)
                    .dockFont(.metadata)
                    .foregroundStyle(style.metadataText)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 7)
    }
}

/// Project navigation is isolated from DockModel so high-frequency activity
/// updates do not rebuild the project hierarchy.
struct ProjectDisclosureState: Equatable {
    /// Projects the user flipped away from their default (expanded, or collapsed when empty).
    private var toggledProjectIDs: Set<String> = []
    private var expandedSessionProjectIDs: Set<String> = []

    mutating func toggle(projectID: String) {
        if toggledProjectIDs.contains(projectID) {
            toggledProjectIDs.remove(projectID)
        } else {
            toggledProjectIDs.insert(projectID)
        }
    }

    func isCollapsed(projectID: String, isEmpty: Bool = false) -> Bool {
        isEmpty != toggledProjectIDs.contains(projectID)
    }

    mutating func toggleAllSessions(projectID: String) {
        if expandedSessionProjectIDs.contains(projectID) {
            expandedSessionProjectIDs.remove(projectID)
        } else {
            expandedSessionProjectIDs.insert(projectID)
        }
    }

    func showsAllSessions(projectID: String) -> Bool {
        expandedSessionProjectIDs.contains(projectID)
    }

    func visibleSessions(_ sessions: [HermesSession], projectID: String, limit: Int = 10) -> [HermesSession] {
        let newestFirst = sessions.sorted { lhs, rhs in
            let lhsDate = lhs.lastUpdatedAt ?? .distantPast
            let rhsDate = rhs.lastUpdatedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.id < rhs.id
        }
        return showsAllSessions(projectID: projectID)
            ? newestFirst
            : Array(newestFirst.prefix(max(0, limit)))
    }
}

struct SessionNavProjectList: View {
    let groups: [SessionNavConversationGroup]
    let selectedSessionID: String?
    let activeSessionID: String?
    let attentionDots: [String: SessionAttentionDot]
    let sessionStatuses: [String: SidebarSessionStatus]
    let isLoadingProjects: Bool
    let isRefreshing: Bool
    let isCreatingChat: Bool
    let style: DockThemePalette
    let isPinned: (HermesSession) -> Bool
    let onTogglePin: (HermesSession) -> Void
    let onRename: (HermesSession, String) async -> Bool
    let onToggleHidden: (HermesSession, Bool) async -> Bool
    let onRequestDelete: (HermesSession) -> Void
    let deletingSessionID: String?
    let updatingSessionVisibilityID: String?
    let renamingSessionID: String?
    let creatingProjectPath: String?
    let onSelectSession: (HermesSession) -> Void
    let onRefresh: () -> Void
    let onAddProject: () -> Void
    let onArchiveProject: (String) -> Void
    let onAddSourceFolder: (String, String) -> Void
    let onNewChatInProject: (String) -> Void
    var pinningSessionID: String?
    @State private var disclosureState = ProjectDisclosureState()
    @State private var isExpanded = true
    @State private var hoveredNewChatProjectID: String?
    @State private var hoveredProjectRowID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let sessionLimit = 10

    /// No container: header, project headers and session rows flatten into
    /// the rail's LazyVStack so only on-screen rows are built.
    @ViewBuilder
    var body: some View {
        DockSectionHeader(title: "Projects", count: groups.count, isExpanded: $isExpanded, style: style) {
            DockIconButton(
                icon: .plus, label: "New project or add folder", size: 24, style: style, action: onAddProject)
            DockIconButton(
                icon: .arrowsClockwise,
                label: isRefreshing ? "Refreshing projects…" : "Refresh projects",
                isBusy: isRefreshing,
                size: 24,
                style: style,
                action: onRefresh
            )
        }
        .padding(.top, style.sectionSpacing)
        .padding(.bottom, isExpanded ? 2 : 0)

        if isExpanded {
            if groups.isEmpty {
                projectStatusRow(isLoadingProjects ? "Loading projects…" : "No projects")
            } else {
                ForEach(groups) { group in projectGroup(group) }
            }
        }
    }

    @ViewBuilder
    private func projectGroup(_ group: SessionNavConversationGroup) -> some View {
        let sessionCount = max(group.declaredSessionCount, group.sessions.count)
        let isCollapsed = disclosureState.isCollapsed(
            projectID: group.id, isEmpty: sessionCount == 0 && group.sessions.isEmpty)
        let sessions = disclosureState.visibleSessions(group.sessions, projectID: group.id, limit: sessionLimit)
        let isActiveProject = group.sessions.contains { $0.id == selectedSessionID }
        let isCreatingHere = creatingProjectPath != nil && creatingProjectPath == group.projectPath
        HStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .dockEase(duration: 0.18)) {
                    disclosureState.toggle(projectID: group.id)
                }
            } label: {
                HStack(spacing: 7) {
                    DockIcon(isCollapsed ? .caretRight : .caretDown, size: 11, color: style.metadataText)
                        .frame(width: 12)
                    DockIcon(.folder, size: 15, color: isActiveProject ? style.primaryText : style.metadataText)
                        .frame(width: 16)
                    Text(group.title)
                        .dockFont(.navigation)
                        .foregroundStyle(style.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .accessibilityLabel(isCollapsed ? "Expand project \(group.title)" : "Collapse project \(group.title)")
            .layoutPriority(1)

            // Count at rest; actions replace it while the row is hovered.
            let showsActions = hoveredProjectRowID == group.id || isCreatingHere
            ZStack(alignment: .trailing) {
                if sessionCount > 0 {
                    Text(compactCount(sessionCount))
                        .dockFont(.metadata).monospacedDigit()
                        .foregroundStyle(style.metadataText)
                        .padding(.trailing, 14)
                        .opacity(showsActions ? 0 : 1)
                }
                if let projectPath = group.projectPath, !projectPath.isEmpty {
                    HStack(spacing: 0) {
                        Button {
                            onNewChatInProject(projectPath)
                        } label: {
                            Group {
                                if isCreatingHere {
                                    ProgressView().controlSize(.small)
                                } else {
                                    DockIcon(
                                        .chatTeardropText, size: 15,
                                        color: hoveredNewChatProjectID == group.id ? style.accent : style.secondaryText)
                                }
                            }
                            .frame(width: 32, height: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.dockHover)
                        .disabled(isCreatingChat || creatingProjectPath != nil)
                        .help("New chat in \(group.title)")
                        .accessibilityLabel("New chat in \(group.title)")
                        .onHover { isHovered in
                            hoveredNewChatProjectID =
                                isHovered
                                ? group.id
                                : (hoveredNewChatProjectID == group.id ? nil : hoveredNewChatProjectID)
                        }

                        DockMenu {
                            projectActions(group, projectPath: projectPath)
                        } label: {
                            Ph.dotsThree.image(size: 15, color: NSColor(style.secondaryText))
                                .frame(width: 32, height: 44)
                                .contentShape(Rectangle())
                        }
                        .fixedSize()
                        .help("More options for \(group.title)")
                        .accessibilityLabel("More options for \(group.title)")
                    }
                    .opacity(showsActions ? 1 : 0)
                    .allowsHitTesting(showsActions)
                }
            }
            .frame(width: 64)
        }
        .onHover { isHovered in
            hoveredProjectRowID =
                isHovered
                ? group.id
                : (hoveredProjectRowID == group.id ? nil : hoveredProjectRowID)
        }
        .background(Color.clear)
        .dockContextMenu {
            if let projectPath = group.projectPath, !projectPath.isEmpty {
                projectActions(group, projectPath: projectPath)
            }
        }
        if !isCollapsed {
            if group.sessions.isEmpty {
                projectStatusRow(sessionCount == 0 ? "No conversations yet" : "Loading linked sessions…", leading: 0)
                    .padding(.leading, 12)
            } else {
                ForEach(sessions, id: \.[sidebarSection: group.id]) { session in
                    sessionRow(session).padding(.leading, 12)
                }
                if group.sessions.count > sessionLimit {
                    Button {
                        withAnimation(reduceMotion ? nil : .dockEase(duration: 0.18)) {
                            disclosureState.toggleAllSessions(projectID: group.id)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(
                                disclosureState.showsAllSessions(projectID: group.id)
                                    ? "Show recent"
                                    : "Show \(group.sessions.count - sessionLimit) more")
                            DockIcon(
                                disclosureState.showsAllSessions(projectID: group.id) ? .caretUp : .caretDown, size: 10,
                                color: style.metadataText)
                        }
                        .dockFont(.control)
                        .foregroundStyle(style.secondaryText)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.dockLink)
                    .accessibilityLabel(
                        disclosureState.showsAllSessions(projectID: group.id)
                            ? "Show recent sessions for \(group.title)"
                            : "Show \(group.sessions.count - sessionLimit) more sessions for \(group.title)"
                    )
                    .padding(.leading, 12)
                }
            }
        }
    }

    private func projectStatusRow(_ text: String, leading: CGFloat = 34) -> some View {
        Text(text)
            .dockFont(.body)
            .foregroundStyle(style.metadataText)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.leading, leading)
    }

    private func sessionRow(_ session: HermesSession) -> some View {
        SessionNavSidebarSessionRow(
            session: session,
            selectedSessionID: selectedSessionID,
            sessionStatus: sessionStatuses[session.id] ?? .none,
            style: style,
            repositoryName: nil,
            isPinned: isPinned(session),
            isActive: session.id == activeSessionID,
            isDeleting: deletingSessionID == session.id,
            isUpdatingVisibility: updatingSessionVisibilityID == session.id,
            isRenaming: renamingSessionID == session.id,
            onSelect: onSelectSession,
            onTogglePin: onTogglePin,
            onRename: onRename,
            onToggleHidden: onToggleHidden,
            onRequestDelete: onRequestDelete,
            isPinning: pinningSessionID == session.id
        )
        .equatable()
    }

    @ViewBuilder
    private func projectActions(_ group: SessionNavConversationGroup, projectPath: String) -> some View {
        Button("Reveal in Finder", icon: .folderOpen) {
            ExternalOpen.reveal([URL(fileURLWithPath: projectPath)])
        }
        if let projectID = group.projectID {
            Button("Add Source Folder…", icon: .folderPlus) { chooseSourceFolder(projectID: projectID) }
            Divider()
            Button("Archive Project", icon: .archive) { onArchiveProject(projectID) }
        }
    }

    private func chooseSourceFolder(projectID: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        guard panel.runAboveHerm() == .OK, let url = panel.url else { return }
        onAddSourceFolder(projectID, url.path)
    }

    private func compactCount(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }
}

enum ProjectSessionPendingAction: Equatable {
    case rename, visibility, deletion
}

struct ProjectSessionActionPresentation: Equatable {
    let isPinned: Bool
    let isActive: Bool
    let isHidden: Bool
    let pendingAction: ProjectSessionPendingAction?

    var canDelete: Bool { !isActive && pendingAction != .deletion }
    var visibilityTitle: String { isHidden ? "Show" : "Hide" }
}

enum SidebarSessionTime {
    /// Compact rail timestamp: "now", "9m", "3h", "5d", then "Sep 2".
    static func short(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

/// The rail is one flat LazyVStack, and a session can appear in Pinned,
/// Conversations and a project at once. Lazy stacks conflate rows that share
/// an id across sibling ForEach blocks and leave one blank until re-render.
extension HermesSession {
    subscript(sidebarSection section: String) -> String { "\(section):\(id)" }
}

struct SidebarProjectTarget: Identifiable, Equatable {
    let title: String
    let path: String
    var id: String { path }
}

/// A conversation that belongs to a Bot: avatar on the left and a tinted card
/// so it reads differently from the selected Bot's own conversations.
struct SessionNavBotSessionRow: View, Equatable {
    let session: HermesSession
    let bot: BotSummary
    let imageData: Data?
    let isSelected: Bool
    /// Approval or clarify from the sidebar status; nil keeps the busy face.
    var mood: BotMood? = nil
    let style: DockThemePalette
    let onOpen: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session == rhs.session && lhs.bot == rhs.bot && lhs.imageData == rhs.imageData
            && lhs.mood == rhs.mood && lhs.isSelected == rhs.isSelected && lhs.style.theme == rhs.style.theme
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            BotAvatarView(bot: bot, imageData: imageData, size: 30, mood: mood, orbits: session.isWorking)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(bot.name)
                        .dockFont(.navigation)
                        .foregroundStyle(style.primaryText)
                        .lineLimit(1)
                    Text("BOT")
                        .dockFont(.metadata, weight: .bold)
                        .foregroundStyle(style.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(style.selectedFill))
                    Spacer(minLength: 4)
                    SessionActivityGlyph(isWorking: session.isWorking, hasUnreadUpdate: session.hasUnreadUpdate)
                    if let date = session.lastUpdatedAt {
                        Text(SidebarSessionTime.short(date))
                            .dockFont(.metadata).monospacedDigit()
                            .foregroundStyle(style.metadataText)
                            .fixedSize()
                    }
                }
                if let preview = session.displayPreview {
                    Text(preview)
                        .dockFont(.body)
                        .foregroundStyle(style.metadataText)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                .fill(isSelected ? style.selectedFill : style.selectedFill.opacity(0.35))
        )
        .contentShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
        .dockHoverable().onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bot.name) bot chat")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

struct SessionNavSidebarSessionRow: View, Equatable {
    let session: HermesSession
    let selectedSessionID: String?
    let sessionStatus: SidebarSessionStatus
    let style: DockThemePalette
    let repositoryName: String?
    let isPinned: Bool
    let isActive: Bool
    let isDeleting: Bool
    let isUpdatingVisibility: Bool
    let isRenaming: Bool
    let onSelect: (HermesSession) -> Void
    let onTogglePin: (HermesSession) -> Void
    let onRename: (HermesSession, String) async -> Bool
    let onToggleHidden: (HermesSession, Bool) async -> Bool
    let onRequestDelete: (HermesSession) -> Void
    var isPinning = false
    var projectTargets: [SidebarProjectTarget] = []
    var onAddToProject: (HermesSession, SidebarProjectTarget) -> Void = { _, _ in }
    @State private var isHovered = false
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var renameError: String?
    @State private var titleFieldDidFocus = false
    @FocusState private var titleFieldFocused: Bool
    @FocusState private var rowFocused: Bool

    private static let rowHeight: CGFloat = 30

    private var isSelected: Bool { session.id == selectedSessionID }

    private var pendingAction: ProjectSessionPendingAction? {
        if isDeleting { return .deletion }
        if isUpdatingVisibility { return .visibility }
        if isRenaming { return .rename }
        return nil
    }

    private var presentation: ProjectSessionActionPresentation {
        ProjectSessionActionPresentation(
            isPinned: isPinned,
            isActive: isActive,
            isHidden: session.isHidden,
            pendingAction: pendingAction
        )
    }

    private var showsActions: Bool {
        isHovered || rowFocused || pendingAction != nil || isPinning
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session == rhs.session
            && lhs.selectedSessionID == rhs.selectedSessionID
            && lhs.sessionStatus == rhs.sessionStatus
            && lhs.style.theme == rhs.style.theme
            && lhs.repositoryName == rhs.repositoryName
            && lhs.isPinned == rhs.isPinned
            && lhs.isActive == rhs.isActive
            && lhs.isDeleting == rhs.isDeleting
            && lhs.isUpdatingVisibility == rhs.isUpdatingVisibility
            && lhs.isRenaming == rhs.isRenaming
            && lhs.isPinning == rhs.isPinning
            && lhs.projectTargets == rhs.projectTargets
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            statusIndicator
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                if !isEditingTitle, session.sourceBadgeTitle != nil || repository != nil || preview != nil {
                    HStack(spacing: 6) {
                        if let source = session.sourceBadgeTitle {
                            HStack(spacing: 4) {
                                DockIcon(.discordLogo, size: 12)
                                Text(source)
                                    .dockFont(.metadata, weight: .medium)
                            }
                            .foregroundStyle(Color.dockDiscord)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.dockDiscord.opacity(0.16)))
                            .fixedSize()
                            .accessibilityLabel("Source: \(source)")
                            .help("Session from \(source)")
                        }
                        if let repository { repositoryPill(repository) }
                        if let preview {
                            Text(preview)
                                .dockFont(.body)
                                .foregroundStyle(style.metadataText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .frame(minHeight: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous).fill(rowFill)
        )
        .contentShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
        // rowFill already tracks hover; a second hover tracker doubled the work per row while scrolling.
        .onTapGesture { if !isEditingTitle { onSelect(session) } }
        .focusable(!isEditingTitle)
        .focusEffectDisabled()
        .focused($rowFocused)
        .onKeyPress(.return) {
            guard !isEditingTitle else { return .ignored }
            onSelect(session)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(accessibilityLabel)
        .help(tooltip)
        .disabled(isDeleting)
        .opacity(isDeleting ? 0.5 : 1)
        .onHover { isHovered = $0 }
        .dockContextMenu { contextActions }
        .onChange(of: isEditingTitle) { _, editing in
            if editing {
                titleDraft = session.displayTitle
                renameError = nil
                titleFieldDidFocus = false
                // The context menu is still dismissing and reclaims focus; wait for it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { titleFieldFocused = true }
            }
        }
        .onChange(of: titleFieldFocused) { _, focused in
            if focused {
                titleFieldDidFocus = true
            }
            // Only treat blur as cancel once the field actually had focus.
            else if titleFieldDidFocus, isEditingTitle, pendingAction == nil {
                cancelRename()
            }
        }
    }

    @ViewBuilder
    private var titleLine: some View {
        HStack(spacing: 6) {
            if isEditingTitle {
                DockTextField("Session title", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .dockFont(.navigation, weight: .medium)
                    .foregroundStyle(style.primaryText)
                    .focused($titleFieldFocused)
                    .onSubmit { submitRename() }
                    .onExitCommand { cancelRename() }
                    .help(renameError ?? "Press Return to save, Esc to cancel")
                if renameError != nil {
                    DockIcon(.warningCircle, size: 11, color: .dockWarning)
                        .help(renameError ?? "")
                }
            } else {
                Text(session.displayTitle)
                    .dockFont(.navigation, weight: isSelected ? .medium : .regular)
                    .foregroundStyle(isSelected ? style.primaryText : style.primaryText.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .modifier(WorkingTitleShimmer(isActive: sessionStatus == .working, color: style.accent))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showsActions {
                    actionSurface
                } else {
                    trailingDetail
                }
            }
        }
        .frame(height: 24)
    }

    private var repository: String? { Self.nonEmpty(repositoryName) }
    private var preview: String? { Self.nonEmpty(session.displayPreview) }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// Wired repo shown as a pill ahead of the last-message preview.
    private func repositoryPill(_ name: String) -> some View {
        HStack(spacing: 4) {
            DockIcon(.folder, size: 11)
            Text(name)
                .dockFont(.metadata, weight: .medium)
                .lineLimit(1)
        }
        .foregroundStyle(style.accent)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(style.accent.opacity(0.14)))
        .fixedSize()
        .accessibilityLabel("Project: \(name)")
        .help("Wired to \(name)")
    }

    private var rowFill: Color {
        if isSelected { return style.selectedFill }
        return isHovered ? style.selectedFill.opacity(0.4) : .clear
    }

    private var tooltip: String {
        [session.displayTitle, session.sourceBadgeTitle, repositoryName, session.displayPreview]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private var accessibilityLabel: String {
        var parts = [session.displayTitle]
        if let source = session.sourceBadgeTitle { parts.append("Source: \(source)") }
        if sessionStatus != .none { parts.append(sessionStatus.label) }
        if let repositoryName, !repositoryName.isEmpty { parts.append(repositoryName) }
        if let date = session.lastUpdatedAt { parts.append(SidebarSessionTime.short(date)) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var trailingDetail: some View {
        if let date = session.lastUpdatedAt {
            Text(SidebarSessionTime.short(date))
                .dockFont(.metadata)
                .monospacedDigit()
                .foregroundStyle(style.metadataText)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// Leading status slot. Fixed width keeps titles aligned whether or not a
    /// row has status. Only working rows spin, so scrolling stays cheap.
    private var statusIndicator: some View {
        Group {
            if let state = sessionStatus.activityState {
                DockActivityIndicator(state: state, size: 12, unreadDot: true)
            } else {
                Color.clear
            }
        }
        .frame(width: 14, height: 14)
        // Shapes and spinners have no text baseline; center on the title's x-height so every state lines up.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
    }

    private var actionSurface: some View {
        HStack(spacing: 0) {
            Button {
                onTogglePin(session)
            } label: {
                DockIcon(
                    .pushPin, size: 12, weight: isPinned ? .fill : .regular,
                    color: isPinned ? style.primaryText : style.metadataText
                )
                .opacity(isPinning ? 0 : 1)
                .overlay { if isPinning { ProgressView().controlSize(.mini) } }
                .frame(width: 24, height: 24)
                .accessibilityAddTraits(isPinned ? .isSelected : [])
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .disabled(isPinning)
            .help(isPinned ? "Unpin session" : "Pin session")
            .accessibilityLabel(isPinned ? "Unpin \(session.displayTitle)" : "Pin \(session.displayTitle)")

            if pendingAction != nil {
                ProgressView().controlSize(.mini).frame(width: 24, height: 24)
            } else {
                // Menu labels on macOS only reliably render Text/Image.
                DockMenu {
                    contextActions
                } label: {
                    Ph.dotsThree.image(size: 13, color: NSColor(Color.dockSecondaryText))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .fixedSize()
                .help("More session actions")
                .accessibilityLabel("More actions for \(session.displayTitle)")
            }
        }
    }

    @ViewBuilder
    private var contextActions: some View {
        Button(isPinned ? "Unpin" : "Pin", icon: isPinned ? .pushPinSlash : .pushPin) {
            onTogglePin(session)
        }
        .disabled(isPinning)
        Button("Rename…", icon: .pencilSimple) {
            isEditingTitle = true
        }
        Button(presentation.visibilityTitle, icon: session.isHidden ? .eye : .eyeSlash) {
            Task { @MainActor in
                _ = await onToggleHidden(session, !session.isHidden)
            }
        }
        .disabled(isUpdatingVisibility || isDeleting)
        if !projectTargets.isEmpty {
            DockMenu("Add to project", icon: .folderPlus) {
                ForEach(projectTargets) { target in
                    Button(target.title) { onAddToProject(session, target) }
                }
            }
        }
        Divider()
        Button("Delete", icon: .trash, role: .destructive) {
            onRequestDelete(session)
        }
        .disabled(!presentation.canDelete || isDeleting)
        .help(isActive ? "The active session cannot be deleted" : "Permanently delete this session")
    }

    private func submitRename() {
        let clean = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            renameError = "Title can’t be empty."
            return
        }
        guard clean != session.title else {
            isEditingTitle = false
            return
        }
        renameError = nil
        Task { @MainActor in
            let succeeded = await onRename(session, clean)
            if succeeded {
                isEditingTitle = false
            } else {
                renameError = "Could not rename. Try again."
                titleFieldFocused = true
            }
        }
    }

    private func cancelRename() {
        isEditingTitle = false
        renameError = nil
        titleDraft = session.displayTitle
    }
}
