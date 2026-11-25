import Combine
import Foundation
import SwiftUI

struct SidebarUnreadSession: Hashable, Sendable {
    let profileID: String?
    let id: String
    let updatedAt: Date?
    let isHidden: Bool
    let isAutomation: Bool
}

/// One group of conversations in the left navigation rail: a project-backed
/// bucket or the shared unlinked bucket.
struct SessionNavConversationGroup: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let sessions: [HermesSession]
    let declaredSessionCount: Int
    let projectID: String?
    /// The gateway project name is the repository path used as `cwd` when
    /// creating a project-scoped chat.
    let projectPath: String?
    let isLinked: Bool
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
struct SessionNavSidebarSnapshot: Equatable, Sendable {
    struct Inputs: Equatable, Sendable {
        var activeSessionID: String?
        var activeStatus: HermesStatus?
        var profileScopeID: String?
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
        /// The model reconciles bounded scan and complete scoped pin evidence.
        var resolvedAllProfilePins: [HermesSession]? = nil
        var failedProjectSessionIDs: Set<String> = []
        var seenAtByKey: [String: Date] = [:]
        var baselinedProfiles: Set<String> = []

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

    private(set) var inputs: Inputs
    let linkedProjectGroups: [SessionNavConversationGroup]
    let conversations: [HermesSession]
    let attentionDots: [String: SessionAttentionDot]
    let linkedSessionIDs: Set<String>
    let projectNameBySessionID: [String: String]
    let projectPathBySessionID: [String: String]
    /// Every bot's recent chats merged with the selected bot's fresher rows,
    /// newest first. Equals `conversations` until the all-bot scan loads.
    let allBotConversations: [HermesSession]
    let scopedRecents: SessionRecentsPresentation
    let allBotRecents: SessionRecentsPresentation
    /// Every profile's pins for the "All profiles" scope (`AllProfilesSessions.pinned`).
    let allProfilePinned: [HermesSession]
    let scopedPinPresentation: PinnedSessionPresentation
    let allProfilePinPresentation: PinnedSessionPresentation
    private(set) var sessionStatuses: [String: SidebarSessionStatus]
    private let statusSessionsByID: [String: HermesSession]
    private let activeSummariesByID: [String: SessionSummary]
    struct UnreadInventory: Equatable, Sendable {
        let sessions: [HermesSession]
        let rows: Set<SidebarUnreadSession>

        init(sessions: [HermesSession]) {
            self.sessions = sessions
            self.rows = Set(
                sessions.map {
                    SidebarUnreadSession(
                        profileID: $0.profileID, id: $0.id, updatedAt: $0.updatedAt,
                        isHidden: $0.isHidden, isAutomation: $0.isAutomationSession)
                })
        }
    }
    let unreadInventory: UnreadInventory
    /// Real projects an unlinked conversation can be added to.
    var projectTargets: [SidebarProjectTarget] {
        linkedProjectGroups.compactMap { group in
            group.projectPath.map { SidebarProjectTarget(title: group.title, path: $0) }
        }
    }

    /// Projects a conversation can move to: every real project except the
    /// ones that already list it.
    func projectTargets(forSessionID sessionID: String) -> [SidebarProjectTarget] {
        linkedProjectGroups.compactMap { group in
            guard let path = group.projectPath, !group.sessions.contains(where: { $0.id == sessionID })
            else { return nil }
            return SidebarProjectTarget(title: group.title, path: path)
        }
    }

    /// Activity, attention and status tick on every tool event from every
    /// running session but only feed `attentionDots`; reusing `previous`'s
    /// groups keeps those ticks from rescanning every project × session.
    init(inputs: Inputs, reusing previous: SessionNavSidebarSnapshot? = nil) {
        self.inputs = inputs
        self.attentionDots = Self.attentionDots(inputs: inputs)
        let scanned: [HermesSession] =
            switch inputs.allBotSessionsState {
            case .ready(let sessions), .stale(let sessions, _): sessions
            case .loading, .empty, .unavailable, .failed: []
            }
        if let resolved = inputs.resolvedAllProfilePins {
            self.allProfilePinned = resolved
        } else if let previous, previous.inputs.resolvedAllProfilePins == nil,
            previous.inputs.pinnedSessions == inputs.pinnedSessions,
            previous.inputs.allBotSessionsState == inputs.allBotSessionsState,
            previous.inputs.profileScopeID == inputs.profileScopeID
        {
            self.allProfilePinned = previous.allProfilePinned
        } else {
            self.allProfilePinned = AllProfilesSessions.pinned(
                scopePinned: inputs.pinnedSessions, scanned: scanned, scopeProfileID: inputs.profileScopeID)
        }
        let reusesConversations = previous?.inputs.hasSameConversations(as: inputs) == true
        if let previous, reusesConversations {
            self.linkedProjectGroups = previous.linkedProjectGroups
            self.conversations = previous.conversations
            self.linkedSessionIDs = previous.linkedSessionIDs
            self.projectNameBySessionID = previous.projectNameBySessionID
            self.projectPathBySessionID = previous.projectPathBySessionID
            self.allBotConversations = previous.allBotConversations
            self.scopedRecents = previous.scopedRecents
            self.allBotRecents = previous.allBotRecents
        } else {
            let groups = Self.conversationGroups(inputs: inputs)
            self.linkedProjectGroups = groups.filter(\.isLinked)
            self.conversations = Self.deduplicatedConversations(groups: groups)
            var linkedSessionIDs = Set<String>()
            var projectNameBySessionID: [String: String] = [:]
            var projectPathBySessionID: [String: String] = [:]
            for group in self.linkedProjectGroups {
                for session in group.sessions {
                    linkedSessionIDs.insert(session.id)
                    if projectNameBySessionID[session.id] == nil {
                        projectNameBySessionID[session.id] = group.title
                        projectPathBySessionID[session.id] = group.projectPath
                    }
                }
            }
            self.linkedSessionIDs = linkedSessionIDs
            self.projectNameBySessionID = projectNameBySessionID
            self.projectPathBySessionID = projectPathBySessionID
            self.allBotConversations = SidebarAgentGrouping.merged(
                all: scanned, scoped: self.conversations, scopeProfileID: inputs.profileScopeID)
            self.scopedRecents = SessionRecentsPresentation(self.conversations)
            // Both inventories have the same rows and order until the all-profile scan arrives.
            self.allBotRecents =
                scanned.isEmpty ? self.scopedRecents : SessionRecentsPresentation(self.allBotConversations)
        }
        let reusesPins = reusesConversations && previous?.inputs.pinnedSessions == inputs.pinnedSessions
        let reusesPinPresentation =
            reusesPins && previous?.inputs.sessionProjectionState == inputs.sessionProjectionState
        if let previous, reusesPinPresentation {
            self.scopedPinPresentation = previous.scopedPinPresentation
        } else {
            self.scopedPinPresentation = PinnedSessionPresentation(
                pinned: inputs.pinnedSessions, live: conversations, projection: inputs.sessionProjectionState)
        }
        if let previous, reusesPinPresentation, previous.allProfilePinned == allProfilePinned {
            self.allProfilePinPresentation = previous.allProfilePinPresentation
        } else {
            self.allProfilePinPresentation = PinnedSessionPresentation(
                pinned: allProfilePinned, live: allBotConversations, projection: inputs.sessionProjectionState,
                matchesProfile: true, scopeProfileID: inputs.profileScopeID)
        }
        let reusesStatusSessions = reusesPins && previous?.allProfilePinned == allProfilePinned
        if let previous, reusesStatusSessions {
            statusSessionsByID = previous.statusSessionsByID
        } else {
            statusSessionsByID = Dictionary(
                (allBotConversations + inputs.pinnedSessions + allProfilePinned).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first })
        }
        if let previous, previous.inputs.activeSessions == inputs.activeSessions {
            activeSummariesByID = previous.activeSummariesByID
        } else {
            activeSummariesByID = Dictionary(
                inputs.activeSessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        if let previous, reusesStatusSessions,
            previous.inputs.activeSessions == inputs.activeSessions,
            previous.inputs.activeSessionID == inputs.activeSessionID,
            previous.inputs.activeStatus == inputs.activeStatus,
            previous.inputs.seenAtByKey == inputs.seenAtByKey,
            previous.inputs.baselinedProfiles == inputs.baselinedProfiles,
            previous.attentionDots == attentionDots
        {
            self.sessionStatuses = previous.sessionStatuses
        } else {
            let attention = attentionDots
            let summaries = activeSummariesByID
            self.sessionStatuses = statusSessionsByID.mapValues { session in
                SidebarSessionStatusResolver.status(
                    for: session, summary: summaries[session.id], inputs: inputs,
                    attention: attention[session.id], seenAtByKey: inputs.seenAtByKey,
                    baselinedProfiles: inputs.baselinedProfiles)
            }
        }
        if let previous, reusesPins, previous.inputs.activeSessions == inputs.activeSessions {
            unreadInventory = previous.unreadInventory
        } else {
            unreadInventory = UnreadInventory(
                sessions: SessionDashboardProjection.sessions(in: inputs, allBotConversations: allBotConversations))
        }
    }

    /// The selection affects at most two status marks. Share every inventory projection.
    func selecting(_ id: String?, status: HermesStatus?) -> Self {
        guard inputs.activeSessionID != id || inputs.activeStatus != status else { return self }
        var next = self
        next.inputs.activeSessionID = id
        next.inputs.activeStatus = status
        for id in Set([inputs.activeSessionID, id].compactMap { $0 }) {
            guard let session = statusSessionsByID[id] else { continue }
            let resolved = SidebarSessionStatusResolver.status(
                for: session, summary: activeSummariesByID[id], inputs: next.inputs,
                attention: attentionDots[id], seenAtByKey: inputs.seenAtByKey,
                baselinedProfiles: inputs.baselinedProfiles)
            if next.sessionStatuses[id] != resolved { next.sessionStatuses[id] = resolved }
        }
        return next
    }

    @MainActor
    static func inputs(
        model: DockModel, control: ControlCenterModel, localProjectPaths: [String: String] = [:],
        seenStore: SidebarSessionSeenStore = .shared
    ) -> Inputs {
        Inputs(
            activeSessionID: model.navigationSessionID,
            activeStatus: model.isSending && model.status == .idle ? .working : model.status,
            profileScopeID: model.profileScopeID,
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
            allBotSessionsState: model.allBotSessionsState,
            resolvedAllProfilePins: model.allProfilePins(),
            failedProjectSessionIDs: Set(
                control.projects.compactMap { project in
                    control.refreshState(for: control.projectSessionsProjectionKey(for: project.id))?.error == nil
                        ? nil : project.id
                }),
            seenAtByKey: seenStore.seenAtByKey, baselinedProfiles: seenStore.baselinedProfiles
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
        let recentSessions = SidebarAgentGrouping.sortedNewestFirst(inputs.sessions, tieBreakByID: false)
        var groups: [SessionNavConversationGroup] = []
        var assigned = Set<String>()

        // One pass over sessions through reverse indexes; the old per-project
        // scan was projects × sessions and reran on every running-session tick.
        let renderable = inputs.projects.filter(\.isRenderableProject)
        var projectsBySessionID: [String: [Int]] = [:]
        var projectsByID: [String: [Int]] = [:]
        var projectsByName: [String: [Int]] = [:]
        for (index, project) in renderable.enumerated() {
            projectsByID[project.id, default: []].append(index)
            projectsByName[project.name, default: []].append(index)
            for sessionID in project.sessionIDs { projectsBySessionID[sessionID, default: []].append(index) }
        }
        var members = Array(repeating: [HermesSession](), count: renderable.count)
        for session in recentSessions {
            var hits = projectsBySessionID[session.id] ?? []
            if let projectID = inputs.projectIDBySessionID[session.id] { hits += projectsByID[projectID] ?? [] }
            if let path = inputs.localProjectPathBySessionID[session.id] { hits += projectsByName[path] ?? [] }
            guard !hits.isEmpty else { continue }
            assigned.insert(session.id)
            for index in hits where members[index].last?.id != session.id { members[index].append(session) }
        }

        for (index, project) in renderable.enumerated() {
            var sessionsByID = Dictionary(
                members[index].map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for summary in inputs.projectSessionsByProjectID[project.id] ?? project.previewSessions ?? [] {
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
                    isHidden: savedSession?.isHidden ?? false,
                    isWorking: savedSession?.isWorking ?? false,
                    hasUnreadUpdate: savedSession?.hasUnreadUpdate ?? false,
                    isPinned: savedSession?.isPinned ?? false, modelName: savedSession?.modelName
                )
                assigned.insert(summary.id)
            }
            let sessions = SidebarAgentGrouping.sortedNewestFirst(sessionsByID.values, tieBreakByID: true)
            groups.append(
                SessionNavConversationGroup(
                    id: "project:\(project.id)",
                    title: projectDisplayName(project.name),
                    sessions: sessions,
                    declaredSessionCount: project.sessionCount,
                    projectID: project.id,
                    projectPath: project.name,
                    isLinked: true
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
                    isHidden: savedSession?.isHidden ?? false,
                    isWorking: savedSession?.isWorking ?? false,
                    hasUnreadUpdate: savedSession?.hasUnreadUpdate ?? false,
                    isPinned: savedSession?.isPinned ?? false, modelName: savedSession?.modelName
                )
            }
        }
        let unlinked = SidebarAgentGrouping.sortedNewestFirst(
            unlinkedByID.values.filter { !assigned.contains($0.id) }, tieBreakByID: true)
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
        SidebarAgentGrouping.sortedNewestFirst(
            Dictionary(groups.flatMap(\.sessions).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values,
            tieBreakByID: true)
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
    private struct Key: Hashable {
        let model: ObjectIdentifier
        let control: ObjectIdentifier
        let store: ObjectIdentifier
    }

    private final class WeakBox {
        weak var value: SessionNavSidebarModel?
        init(_ value: SessionNavSidebarModel) { self.value = value }
    }

    private static var registry: [Key: WeakBox] = [:]

    static func shared(model: DockModel, control: ControlCenterModel, store: WorkspaceStore) -> SessionNavSidebarModel {
        let key = Key(
            model: ObjectIdentifier(model), control: ObjectIdentifier(control), store: ObjectIdentifier(store))
        if let existing = registry[key]?.value { return existing }
        registry = registry.filter { $0.value.value != nil }
        let sidebar = SessionNavSidebarModel(model: model, control: control, store: store)
        registry[key] = WeakBox(sidebar)
        return sidebar
    }

    @Published private(set) var snapshot: SessionNavSidebarSnapshot
    var unreadSessions: SessionNavSidebarSnapshot.UnreadInventory { snapshot.unreadInventory }
    let instanceID = UUID().uuidString.prefix(8).description
    private let mountedAt = ProcessInfo.processInfo.systemUptime

    private let model: DockModel
    private let control: ControlCenterModel
    private let store: WorkspaceStore
    private let seenStore: SidebarSessionSeenStore
    private var cancellables: Set<AnyCancellable> = []
    private var coalescedRefreshTask: Task<Void, Never>?
    private var refreshRequested = false

    init(
        model: DockModel, control: ControlCenterModel, store: WorkspaceStore,
        seenStore: SidebarSessionSeenStore = .shared
    ) {
        self.model = model
        self.control = control
        self.store = store
        self.seenStore = seenStore
        self.snapshot = SessionNavSidebarSnapshot(
            inputs: SessionNavSidebarSnapshot.inputs(
                model: model, control: control, localProjectPaths: store.projectPathsBySessionID, seenStore: seenStore))

        Publishers.Merge4(
            model.sidebarPresentationChanges, control.sidebarPresentationChanges, store.objectWillChange.map { _ in },
            seenStore.objectWillChange.map { _ in }
        )
        // objectWillChange fires before the mutation lands; one main-queue
        // hop reads the settled values and coalesces same-tick bursts.
        .receive(on: DispatchQueue.main)
        .debounce(for: .milliseconds(1), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.scheduleRefresh() }
        .store(in: &cancellables)
    }

    private func requiresImmediateRefresh(from inputs: SessionNavSidebarSnapshot.Inputs) -> Bool {
        if model.profileScopeID != inputs.profileScopeID
            || (inputs.pinnedSessions.isEmpty && !model.pinnedSessions.isEmpty)
            || (inputs.sessions.isEmpty && !model.sessions.isEmpty)
        {
            return true
        }
        // A refresh can replace the ready inventory without changing its availability.
        if case .ready = model.sessionProjectionState, case .ready = inputs.sessionProjectionState { return false }
        return model.sessionProjectionState != inputs.sessionProjectionState
    }

    /// Coalesce activity before projecting the inventory away from the UI thread.
    private func scheduleRefresh() {
        if requiresImmediateRefresh(from: snapshot.inputs) { return refresh() }
        applySelection()
        guard coalescedRefreshTask == nil else {
            refreshRequested = true
            return
        }
        coalescedRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            await self.refreshInBackground()
        }
    }

    private var activeStatus: HermesStatus {
        model.isSending && model.status == .idle ? .working : model.status
    }

    private func applySelection() {
        let id = model.navigationSessionID
        let status = activeStatus
        if snapshot.inputs.activeSessionID != id || snapshot.inputs.activeStatus != status {
            publish(snapshot.selecting(id, status: status))
        }
    }

    private var currentInputs: SessionNavSidebarSnapshot.Inputs {
        SessionNavSidebarSnapshot.inputs(
            model: model, control: control, localProjectPaths: store.projectPathsBySessionID, seenStore: seenStore)
    }

    private func refreshInBackground() async {
        refreshRequested = false
        let inputs = currentInputs
        let previous = snapshot
        let projection = Task.detached(priority: .utility) { () -> SessionNavSidebarSnapshot? in
            guard !Task.isCancelled, inputs != previous.inputs else { return nil }
            return SessionNavSidebarSnapshot(inputs: inputs, reusing: previous)
        }
        let next = await withTaskCancellationHandler {
            await projection.value
        } onCancel: {
            projection.cancel()
        }
        guard !Task.isCancelled else { return }
        if requiresImmediateRefresh(from: inputs) { return refresh() }
        coalescedRefreshTask = nil
        if let next { publish(next.selecting(model.navigationSessionID, status: activeStatus)) }
        if refreshRequested { scheduleRefresh() }
    }

    func refresh() {
        coalescedRefreshTask?.cancel()
        coalescedRefreshTask = nil
        refreshRequested = false
        let performanceStart = ProcessInfo.processInfo.systemUptime
        defer { HermPerformanceRecorder.recordWork("sidebarRefresh", since: performanceStart) }
        let inputs = currentInputs
        guard inputs != snapshot.inputs else { return }
        publish(SessionNavSidebarSnapshot(inputs: inputs, reusing: snapshot))
    }

    private func publish(_ next: SessionNavSidebarSnapshot) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        defer { HermPerformanceRecorder.recordWork("sidebarPublish", since: startedAt) }
        let previous = snapshot
        snapshot = next
        if previous.conversations.isEmpty && previous.inputs.pinnedSessions.isEmpty,
            !next.conversations.isEmpty || !next.inputs.pinnedSessions.isEmpty
        {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - mountedAt) * 1000)
            DebugLog.writePerformance("session_index stage=sidebar_rows rows=\(next.conversations.count) ms=\(elapsed)")
        }
        DebugLog.writePerformance(
            "sidebar instance=\(instanceID) snapshot_publish_ms=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))"
        )
    }
}
