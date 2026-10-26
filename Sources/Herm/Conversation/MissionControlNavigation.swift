import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Native panel placement is owned by AppKit, while this state lets the
/// SwiftUI surface match its silhouette without resetting conversation state.
final class DockPanelPresentation: ObservableObject {
    @Published var quotaRequest = 0
    @Published var kanbanRequest = 0
    @Published var isEdgeAttached = false
    /// Drives the notch-style grow/shrink of the edge-attached panel: false is the collapsed notch shape.
    @Published var isRevealed = true
    var collapsedSize = CGSize(width: 66, height: 96)
    @Published var edgeSide: EdgeDockSide = .right
    /// Clearance inside the edge silhouette; the top drop-down clears the menu bar and its shoulders.
    @Published var edgeInsets = EdgeDockLayout.insets(for: .right)
    @Published var compactHeight: CGFloat = 720
    @Published var compactWidth: CGFloat = .greatestFiniteMagnitude
    @Published var availableWidth: CGFloat = .greatestFiniteMagnitude
    /// Owned by the panel controller; the view mirrors it so the layout always
    /// matches the window, including when the panel reopens in fullscreen.
    @Published var isFullscreen = false
    /// The notch's state, which the top drop-down shows in its menu-bar band.
    var islandStatus: EdgeNotchState?
    var openIslandTask: (EdgeNotchTask) -> Void = { _ in }
}

/// UserDefaults keys for optional sidebar destinations; all default to visible.
enum SidebarVisibilityKey {
    static let kanban = "hermes.sidebar.shows-kanban"
    static let pullRequests = "hermes.sidebar.shows-pull-requests"
    static let issues = "hermes.sidebar.shows-issues"
    static let office = "hermes.sidebar.shows-office"
    static let calendar = "hermes.sidebar.shows-calendar"
}

enum MissionControlNavigationSelection: Equatable {
    case session(String)
    case task(UUID)
    case global(ControlTab)
    case artifacts
    case bots
    case groupChat(String)
    case pullRequests
    case issues
}

@MainActor
final class MissionControlNavigationSelectionState: ObservableObject {
    @Published private(set) var selection: MissionControlNavigationSelection?

    func clear() { selection = nil }
    func selectSession(_ id: String) { selection = .session(id) }
    func selectTask(_ id: UUID) { selection = .task(id) }
    func selectGlobal(_ tab: ControlTab) { selection = .global(tab) }
    func selectArtifacts() { selection = .artifacts }
    func selectBots() { selection = .bots }
    func selectGroupChat(_ roomID: String) { selection = .groupChat(roomID) }
    func selectPullRequests() { selection = .pullRequests }
    func selectIssues() { selection = .issues }

    func isTaskSelected(_ id: UUID, sessionID: String? = nil) -> Bool {
        if case .task(id) = selection { return true }
        return false
    }

    func isSessionSelected(_ id: String) -> Bool {
        if case .session(id) = selection { return true }
        return false
    }

    func isGlobalSelected(_ tab: ControlTab) -> Bool {
        if case .global(tab) = selection { return true }
        return false
    }
}

/// Presentation state owned by the left navigation rail, rather than a
/// particular split-view host. Global destinations replace their trailing
/// content host, so keeping this state here lets the rail retain its expanded
/// sections and local selection while the user moves between pages.
@MainActor
final class MissionControlNavigationState: ObservableObject {
    let selection = MissionControlNavigationSelectionState()
    @Published var showsAllConversations = false
    @Published var selectedTaskID: UUID?
    @Published var selectedSessionID: String?
    @Published var areConversationsExpanded = true
    @Published var arePinnedExpanded = true
    @Published private(set) var selectedGitHubSection: GitHubWorkspaceSection = .pullRequests
    var hasRequestedSessionIndex = false

    var selectedProjectSessionID: String? {
        guard case .session = selection.selection else { return nil }
        return selectedSessionID
    }

    func selectSession(_ id: String) {
        selection.selectSession(id)
        selectedTaskID = nil
        selectedSessionID = id
    }

    /// Route every callback that opens an existing or newly resolved session
    /// through the same owner so the prior task/global destination cannot
    /// remain selected alongside the conversation.
    func openSession(_ id: String) {
        selectSession(id)
    }

    func openBotChat(sessionID: String) {
        openSession(sessionID)
    }

    func openProjectSession(sessionID: String) {
        openSession(sessionID)
    }

    func openPullRequestChat(sessionID: String?) {
        if let sessionID {
            openSession(sessionID)
        } else {
            clearSelection()
        }
    }

    func synchronizeActiveSession(_ sessionID: String?) {
        if let sessionID, !sessionID.isEmpty {
            openSession(sessionID)
        }
    }

    func openIssueChat(sessionID: String?) {
        openPullRequestChat(sessionID: sessionID)
    }

    func beginProjectChat(sessionID: String? = nil) {
        if let sessionID {
            openSession(sessionID)
        } else {
            beginNewConversation()
        }
    }

    func beginNewConversation() {
        clearSelection()
    }

    func clearSelection() {
        selection.clear()
        selectedTaskID = nil
        selectedSessionID = nil
    }

    func selectTask(_ id: UUID) {
        selection.selectTask(id)
        selectedSessionID = nil
        selectedTaskID = id
    }

    func selectGlobal(_ tab: ControlTab) {
        selection.selectGlobal(tab)
        selectedTaskID = nil
        selectedSessionID = nil
    }

    func selectArtifacts() {
        selection.selectArtifacts()
        selectedTaskID = nil
        selectedSessionID = nil
    }

    func selectBots() {
        selection.selectBots()
        selectedTaskID = nil
        selectedSessionID = nil
    }

    func selectPullRequests() {
        selectedGitHubSection = .pullRequests
        selection.selectPullRequests()
        selectedTaskID = nil
        selectedSessionID = nil
    }

    func selectGitHubRepositories() {
        selectPullRequests()
        selectedGitHubSection = .repositories
    }

    func selectGitHubProjects() {
        selectPullRequests()
        selectedGitHubSection = .projects
    }

    func selectIssues() {
        selectedGitHubSection = .issues
        selection.selectIssues()
        selectedTaskID = nil
        selectedSessionID = nil
    }
}
