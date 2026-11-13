import Combine
import Foundation
import SwiftUI

/// One group of conversations in the left navigation rail: a project-backed
/// bucket or the shared unlinked bucket.
struct SessionNavConversationGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let sessions: [HermesSession]
    let declaredSessionCount: Int
    let projectID: String?
    /// The gateway project name is the repository path used as `cwd` when
    /// creating a project-scoped chat.
    let projectPath: String?
    let isLinked: Bool
    /// The project folder is a git checkout (`.git` dir, or file for worktrees).
    var hasGit = false
}

/// Immutable row input for future native and SwiftUI rail renderers. Keeping
/// presentation text in a value type makes row equality independent from the
/// live model graph and prevents formatters from running in every body pass.
struct SidebarSessionRowDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let preview: String
    let repositoryLabel: String?
    let statusLabel: String
    let relativeTime: String?
    let isPinned: Bool
    let isSelected: Bool
    let actionState: String?
}

/// A deduplicated projection of everything the left navigation rail renders.
///
/// The rail previously re-derived conversation groups several times per body
/// evaluation, so every high-frequency `DockModel` publication (streaming
/// transcript flushes, activity revisions) repeated that whole pass. This
/// snapshot splits the work: cheap-to-compare `Inputs` are diffed against the
/// live models first, and the derived collections are rebuilt only when an
/// input the rail renders actually changed.
struct SessionNavSidebarSnapshot: Equatable {
    struct Inputs: Equatable {
        var activeSessionID: String?
        var activeStatus: HermesStatus?
        var profileScopeID: String?
        var agentDisplayName: String
        var isLoadingSessions: Bool
        var isCreatingSession: Bool
        var deletingSessionID: String?
        var renamingSessionID: String?
        var updatingSessionVisibilityID: String?
        var sessions: [HermesSession]
        var sessionProjectionState: HermesProjectionState<[HermesSession]>
        var activeSessions: [SessionSummary]
        var projects: [ProjectSummary]
        var projectIDBySessionID: [String: String]
        var projectSessionsByProjectID: [String: [SessionSummary]]
        var projectProfileID: String?
        /// Only the rendered "loading with nothing yet" bit; the raw refresh
        /// flag flipped on every background refresh and rebuilt the rail.
        var isLoadingProjects: Bool
        var isRefreshingProjectNavigation: Bool
        var attention: [AttentionItem]
        var latestActivities: [LatestActivityItem]
        var pinnedSessions: [HermesSession] = []
        var pinningSessionID: String?
        /// Dock-local session → project folder links for conversations Hermes
        /// has no project for (its cwd-based membership can't be edited from here).
        var localProjectPathBySessionID: [String: String] = [:]
        /// Every bot's recent sessions, for the multi-bot groupings.
        var allBotSessionsState: HermesProjectionState<[HermesSession]> = .loading

        /// Every input `conversationGroups` and `SidebarAgentGrouping.merged` read.
        func hasSameConversations(as other: Inputs) -> Bool {
            sessions == other.sessions && projects == other.projects
                && projectIDBySessionID == other.projectIDBySessionID
                && projectSessionsByProjectID == other.projectSessionsByProjectID
                && projectProfileID == other.projectProfileID
                && localProjectPathBySessionID == other.localProjectPathBySessionID
                && allBotSessionsState == other.allBotSessionsState
                && profileScopeID == other.profileScopeID
        }
    }

    let inputs: Inputs
    let linkedProjectGroups: [SessionNavConversationGroup]
    let conversations: [HermesSession]
    let attentionDots: [String: SessionAttentionDot]
    let linkedSessionIDs: Set<String>
    let projectNameBySessionID: [String: String]
    /// Every bot's recent chats merged with the selected bot's fresher rows,
    /// newest first. Equals `conversations` until the all-bot scan loads.
    let allBotConversations: [HermesSession]
    /// Real projects an unlinked conversation can be added to.
    var projectTargets: [SidebarProjectTarget] {
        linkedProjectGroups.compactMap { group in
            group.projectPath.map { SidebarProjectTarget(title: group.title, path: $0) }
        }
    }

    /// Activity, attention and status tick on every tool event from every
    /// running session but only feed `attentionDots`; reusing `previous`'s
    /// groups keeps those ticks from rescanning every project × session.
    init(inputs: Inputs, reusing previous: SessionNavSidebarSnapshot? = nil) {
        self.inputs = inputs
        self.attentionDots = Self.attentionDots(inputs: inputs)
        if let previous, previous.inputs.hasSameConversations(as: inputs) {
            self.linkedProjectGroups = previous.linkedProjectGroups
            self.conversations = previous.conversations
            self.linkedSessionIDs = previous.linkedSessionIDs
            self.projectNameBySessionID = previous.projectNameBySessionID
            self.allBotConversations = previous.allBotConversations
            return
        }
        let groups = Self.conversationGroups(inputs: inputs)
        self.linkedProjectGroups = groups.filter(\.isLinked)
        self.conversations = Self.deduplicatedConversations(groups: groups)
        var linkedSessionIDs = Set<String>()
        var projectNameBySessionID: [String: String] = [:]
        for group in self.linkedProjectGroups {
            for session in group.sessions {
                linkedSessionIDs.insert(session.id)
                if projectNameBySessionID[session.id] == nil {
                    projectNameBySessionID[session.id] = group.title
                }
            }
        }
        self.linkedSessionIDs = linkedSessionIDs
        self.projectNameBySessionID = projectNameBySessionID
        let scanned: [HermesSession] =
            switch inputs.allBotSessionsState {
            case .ready(let sessions), .stale(let sessions, _): sessions
            case .loading, .empty, .unavailable, .failed: []
            }
        self.allBotConversations = SidebarAgentGrouping.merged(
            all: scanned, scoped: self.conversations, scopeProfileID: inputs.profileScopeID)
    }

    @MainActor
    static func inputs(model: DockModel, control: ControlCenterModel, localProjectPaths: [String: String] = [:])
        -> Inputs
    {
        Inputs(
            activeSessionID: model.navigationSessionID,
            activeStatus: model.isSending && model.status == .idle ? .working : model.status,
            profileScopeID: model.profileScopeID,
            agentDisplayName: model.agentDisplayName,
            isLoadingSessions: model.isLoadingSessions,
            isCreatingSession: model.isCreatingSession,
            deletingSessionID: model.deletingSessionID,
            renamingSessionID: model.renamingSessionID,
            updatingSessionVisibilityID: model.updatingSessionVisibilityID,
            sessions: model.sessions,
            sessionProjectionState: model.sessionProjectionState,
            activeSessions: control.activeSessions,
            projects: control.projects,
            projectIDBySessionID: control.projectIDBySessionID,
            projectSessionsByProjectID: control.projectSessionsByProjectID,
            projectProfileID: control.projectProfileID,
            isLoadingProjects: control.isRefreshing && control.projects.isEmpty,
            isRefreshingProjectNavigation: control.isRefreshingProjectNavigation,
            // Attention is keyed by the event's runtime sid; rows use the durable id.
            attention: control.attention.map { item in
                var item = item
                item.reference.sessionID = item.reference.sessionID.map(model.rowSessionID)
                return item
            },
            latestActivities: control.latestActivities,
            pinnedSessions: model.pinnedSessions,
            pinningSessionID: model.pinningSessionID,
            localProjectPathBySessionID: localProjectPaths,
            allBotSessionsState: model.allBotSessionsState
        )
    }

    static func projectDisplayName(_ rawName: String) -> String {
        let name = URL(fileURLWithPath: rawName).lastPathComponent
        return name.isEmpty ? rawName : name
    }

    private static func sessionDate(_ session: HermesSession) -> Date {
        session.lastUpdatedAt ?? .distantPast
    }

    private static func sessionDate(_ session: HermesSession?) -> Date {
        session.map(sessionDate) ?? .distantPast
    }

    private static func conversationGroups(inputs: Inputs) -> [SessionNavConversationGroup] {
        let recentSessions = inputs.sessions.sorted { sessionDate($0) > sessionDate($1) }
        var groups: [SessionNavConversationGroup] = []
        var assigned = Set<String>()

        for project in inputs.projects where project.isRenderableProject {
            var sessionsByID = Dictionary(
                recentSessions.compactMap { session -> (String, HermesSession)? in
                    let isMember =
                        project.sessionIDs.contains(session.id)
                        || inputs.projectIDBySessionID[session.id] == project.id
                        || inputs.localProjectPathBySessionID[session.id] == project.name
                    guard isMember else { return nil }
                    assigned.insert(session.id)
                    return (session.id, session)
                }, uniquingKeysWith: { first, _ in first })
            for summary in inputs.projectSessionsByProjectID[project.id] ?? [] {
                let savedSession = sessionsByID[summary.id]
                let updatedAt = [summary.updatedAt, savedSession?.updatedAt].compactMap { $0 }.max()
                let savedSessionIsNewer = sessionDate(savedSession) > (summary.updatedAt ?? .distantPast)
                sessionsByID[summary.id] = HermesSession(
                    id: summary.id,
                    profileID: inputs.projectProfileID,
                    title: savedSessionIsNewer ? savedSession?.title ?? summary.title : summary.title,
                    preview: savedSessionIsNewer
                        ? savedSession?.preview ?? summary.preview ?? ""
                        : summary.preview ?? savedSession?.preview ?? "",
                    startedAt: savedSession?.startedAt,
                    updatedAt: updatedAt,
                    messageCount: savedSession?.messageCount ?? 0,
                    source: savedSession?.source ?? "project",
                    isHidden: savedSession?.isHidden ?? false
                )
                assigned.insert(summary.id)
            }
            let sessions = sessionsByID.values.sorted { sessionDate($0) > sessionDate($1) }
            groups.append(
                SessionNavConversationGroup(
                    id: "project:\(project.id)",
                    title: projectDisplayName(project.name),
                    sessions: sessions,
                    declaredSessionCount: project.sessionCount,
                    projectID: project.id,
                    projectPath: project.name,
                    isLinked: true,
                    hasGit: FileManager.default.fileExists(
                        atPath: (project.name as NSString).appendingPathComponent(".git"))
                )
            )
        }

        // session.list may repeat a row; keep the first occurrence.
        var unlinkedByID = Dictionary(recentSessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Synthetic gateway buckets are not projects, but their session rows
        // are still valid conversations. Move those rows into the unlinked
        // group instead of dropping them with the bucket.
        for project in inputs.projects where !project.isRenderableProject && project.name != "__no_project__" {
            for summary in inputs.projectSessionsByProjectID[project.id] ?? [] {
                let savedSession = unlinkedByID[summary.id]
                let updatedAt = [summary.updatedAt, savedSession?.updatedAt].compactMap { $0 }.max()
                let savedSessionIsNewer = sessionDate(savedSession) > (summary.updatedAt ?? .distantPast)
                unlinkedByID[summary.id] = HermesSession(
                    id: summary.id,
                    profileID: inputs.projectProfileID,
                    title: savedSessionIsNewer ? savedSession?.title ?? summary.title : summary.title,
                    preview: savedSessionIsNewer
                        ? savedSession?.preview ?? summary.preview ?? ""
                        : summary.preview ?? savedSession?.preview ?? "",
                    startedAt: savedSession?.startedAt,
                    updatedAt: updatedAt,
                    messageCount: savedSession?.messageCount ?? 0,
                    source: savedSession?.source ?? "conversation",
                    isHidden: savedSession?.isHidden ?? false
                )
            }
        }
        let unlinked = unlinkedByID.values
            .filter { !assigned.contains($0.id) }
            .sorted { lhs, rhs in
                let lhsDate = sessionDate(lhs)
                let rhsDate = sessionDate(rhs)
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.id < rhs.id
            }
        if !unlinked.isEmpty {
            groups.append(
                SessionNavConversationGroup(
                    id: "unlinked",
                    title: "Unlinked conversations",
                    sessions: Array(unlinked),
                    declaredSessionCount: unlinked.count,
                    projectID: nil,
                    projectPath: nil,
                    isLinked: false
                )
            )
        }
        // Most recently active project first; projects still loading their
        // rows keep tree order after them so a refresh does not reshuffle.
        return groups.enumerated().sorted { lhs, rhs in
            let lhsDate = sessionDate(lhs.element.sessions.first)
            let rhsDate = sessionDate(rhs.element.sessions.first)
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func deduplicatedConversations(groups: [SessionNavConversationGroup]) -> [HermesSession] {
        Dictionary(
            groups.flatMap(\.sessions).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        .values
        .sorted { lhs, rhs in
            let lhsDate = sessionDate(lhs)
            let rhsDate = sessionDate(rhs)
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.id < rhs.id
        }
    }

    private static func attentionDots(inputs: Inputs) -> [String: SessionAttentionDot] {
        var dots: [String: SessionAttentionDot] = [:]
        for item in inputs.attention {
            guard let sessionID = item.reference.sessionID else { continue }
            dots[sessionID] =
                item.kind == .approval
                ? .warning
                : item.kind == .clarification
                    ? .clarification
                    : item.kind == .failure ? .failure : .activity
        }
        for activity in inputs.latestActivities where dots[activity.sessionID] == nil {
            let state = activity.state.lowercased()
            let name = activity.activityName.lowercased()
            if state.contains("fail") || state.contains("error") {
                dots[activity.sessionID] = .failure
            } else if state.contains("complete") || state.contains("success") || state == "done" {
                dots[activity.sessionID] = .success
            } else if name.contains("clarif") {
                dots[activity.sessionID] = .clarification
            } else if name.contains("permission") || name.contains("approval") {
                dots[activity.sessionID] = .warning
            }
        }
        return dots
    }
}

/// Owns the navigation-rail projection so streaming transcript churn and other
/// high-frequency publications cannot rebuild the rail. Publications are
/// diffed against the cheap `Inputs` first; the snapshot is republished only
/// when an input the rail renders actually changed.
@MainActor
final class SessionNavSidebarModel: ObservableObject {
    @Published private(set) var snapshot: SessionNavSidebarSnapshot
    let instanceID = UUID().uuidString.prefix(8).description

    private let model: DockModel
    private let control: ControlCenterModel
    private let store: WorkspaceStore
    private var cancellables: Set<AnyCancellable> = []

    init(model: DockModel, control: ControlCenterModel, store: WorkspaceStore) {
        self.model = model
        self.control = control
        self.store = store
        self.snapshot = SessionNavSidebarSnapshot(
            inputs: SessionNavSidebarSnapshot.inputs(
                model: model, control: control, localProjectPaths: store.projectPathsBySessionID))

        Publishers.Merge3(
            model.sidebarPresentationChanges, control.sidebarPresentationChanges, store.objectWillChange.map { _ in }
        )
        // objectWillChange fires before the mutation lands; one main-queue
        // hop reads the settled values and coalesces same-tick bursts.
        .receive(on: DispatchQueue.main)
        .debounce(for: .milliseconds(1), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.refresh() }
        .store(in: &cancellables)
    }

    func refresh() {
        let startedAt = Date()
        let inputs = SessionNavSidebarSnapshot.inputs(
            model: model, control: control, localProjectPaths: store.projectPathsBySessionID)
        guard inputs != snapshot.inputs else { return }
        snapshot = SessionNavSidebarSnapshot(inputs: inputs, reusing: snapshot)
        DebugLog.writePerformance(
            "sidebar instance=\(instanceID) snapshot_refresh_ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
        )
    }
}
