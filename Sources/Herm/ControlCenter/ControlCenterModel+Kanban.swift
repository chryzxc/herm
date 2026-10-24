import Combine
import Foundation

extension ControlCenterModel {
    func refreshKanban(filter: KanbanListFilter? = nil) {
        refreshKanban(filter: filter, scope: .visible, trigger: .user)
    }

    func refreshKanban(
        filter: KanbanListFilter?,
        scope: KanbanRefreshScope,
        trigger: KanbanRefreshTrigger
    ) {
        // A capability probe is advisory and can still be in flight when the
        // Kanban tab first appears. The list request itself is authoritative;
        // do not make the initial load (or an explicit retry) silently fail
        // just because that separate probe has not completed yet.
        guard let cli else {
            recordProjectionUnavailable("kanban.board")
            if scope.isAggregate { recordProjectionUnavailable("kanban.global") }
            if scope.isAggregate { globalKanbanIsCurrent = false }
            return
        }
        let actionID = scope.isAggregate ? aggregateKanbanRefreshActionID : visibleKanbanRefreshActionID
        switch trigger {
        case .user:
            guard beginAction(actionID) else {
                if !scope.isAggregate {
                    queuedVisibleKanbanFilter = filter ?? kanbanFilter
                    visibleKanbanRefreshGeneration = UUID()
                }
                return
            }
        case .background:
            // A poll must not replace the generation for an explicit refresh.
            // User refreshes are allowed to supersede a poll, but not vice versa.
            guard !pendingActionIDs.contains(actionID) else { return }
            guard kanbanRefreshInFlight.insert(scope).inserted else { return }
        }
        let hasProjectionState = projectionRefreshStates["kanban.board"] != nil
        let shouldPublishRefreshState = trigger == .user || !hasProjectionState
        if shouldPublishRefreshState {
            beginProjectionRefresh("kanban.board")
        }
        // The notch polls the aggregate every 5s even with the workspace
        // closed. A healthy, unchanged poll must publish nothing, or every
        // view observing this model re-renders mid-scroll.
        let globalState = projectionRefreshStates["kanban.global"]
        let quietAggregate =
            scope.isAggregate && trigger == .background && globalKanbanIsCurrent
            && globalState?.lastSuccess != nil && globalState?.error == nil && globalState?.isStale == false
        if scope.isAggregate, !quietAggregate {
            globalKanbanIsCurrent = false
            beginProjectionRefresh("kanban.global")
        }
        let requestedBoardSlug = scope.isAggregate ? nil : selectedKanbanBoardSlug
        // Global aggregation deliberately omits --board; session activity has
        // its own board-aware projection and never uses this request.
        // loading. Clearing here turns a transient refresh race into the
        // false "This board is clear" state seen in the UI; the published
        // replacement below remains generation-checked.
        if let filter, !scope.isAggregate, kanbanFilter != filter {
            kanbanFilter = filter
        }
        let activeFilter = scope.isAggregate ? (filter ?? KanbanListFilter()) : kanbanFilter
        let generation = UUID()
        if scope.isAggregate {
            aggregateKanbanRefreshGeneration = generation
        } else {
            visibleKanbanRefreshGeneration = generation
        }
        let bindingGeneration = clientBindingGeneration
        Task {
            defer {
                if bindingGeneration == clientBindingGeneration {
                    switch trigger {
                    case .user:
                        finishAction(actionID)
                        if !scope.isAggregate, let filter = queuedVisibleKanbanFilter {
                            queuedVisibleKanbanFilter = nil
                            refreshVisibleKanban(filter: filter)
                        }
                    case .background: kanbanRefreshInFlight.remove(scope)
                    }
                }
            }
            do {
                // `hermes kanban list --json` is the canonical complete board
                // projection. Query it once: splitting an unfiltered board
                // into assumed status lanes delays publication until every
                // request completes and drops any future Hermes status value.
                let result =
                    scope.isAggregate
                    ? try await cli.kanbanListAggregate(filter: activeFilter, background: trigger == .background)
                    : try await cli.kanbanList(
                        boardSlug: requestedBoardSlug, filter: activeFilter, background: trigger == .background)
                let parsed =
                    result.succeeded
                    ? await Self.parseKanbanTasksOffMain(result.stdout, boardSlug: requestedBoardSlug)
                    : nil
                guard result.succeeded else {
                    guard isCurrentKanbanRefresh(generation, scope: scope, boardSlug: requestedBoardSlug) else {
                        return
                    }
                    let message =
                        Self.safeUserDiagnostic(result.stderr).isEmpty
                        ? "Hermes Kanban is unavailable." : Self.safeUserDiagnostic(result.stderr)
                    recordProjectionFailure("kanban.board", error: message)
                    if scope.isAggregate { recordProjectionFailure("kanban.global", error: message) }
                    lastError = message
                    return
                }
                guard isCurrentKanbanRefresh(generation, scope: scope, boardSlug: requestedBoardSlug) else { return }
                guard let parsedTasks = parsed else {
                    let message = "Hermes returned malformed Kanban data."
                    recordProjectionFailure("kanban.board", error: message)
                    if scope.isAggregate { recordProjectionFailure("kanban.global", error: message) }
                    lastError = message
                    return
                }
                var refreshedTasks = parsedTasks
                // A successful `kanban show <id>` in the current session is
                // exact evidence that the card exists even when a stale or
                // filtered list response omitted it. Recover that card by ID;
                // never synthesize cards from titles or assignees.
                if !scope.isAggregate {
                    let knownIDs = Set(refreshedTasks.map(\.id))
                    let observedIDs = dockModel?.observedKanbanTaskIDs ?? []
                    for taskID in observedIDs where !knownIDs.contains(taskID) {
                        let missKey = "\(requestedBoardSlug ?? "")|\(taskID)"
                        guard !unrecoverableKanbanTaskIDs.contains(missKey),
                            let shown = try? await cli.kanbanShow(boardSlug: requestedBoardSlug, taskID: taskID)
                        else { continue }
                        guard shown.succeeded,
                            let task = Self.parseKanbanTaskSummary(shown.stdout, boardSlug: requestedBoardSlug)
                        else {
                            unrecoverableKanbanTaskIDs.insert(missKey)
                            continue
                        }
                        refreshedTasks.append(task)
                    }
                }
                // Automatic polling commonly returns the same board. Avoid
                // publishing an unchanged array: the Kanban surface observes
                // this model, so an unnecessary publish forces SwiftUI to
                // re-diff every visible lane while the user is scrolling.
                // Comparing ~1000 cards took the main thread ~50ms per poll.
                let (published, visible) = (globalKanbanTasks, kanbanTasks)
                let (globalDiffers, visibleDiffers) = await Task.detached(priority: .utility) { [refreshedTasks] in
                    (published != refreshedTasks, visible != refreshedTasks)
                }.value
                guard isCurrentKanbanRefresh(generation, scope: scope, boardSlug: requestedBoardSlug) else { return }
                // An edit landing during the compare fails the identity check
                // below (Array == short-circuits on shared storage) and republishes.
                var taskDataChanged = false
                if scope.isAggregate {
                    if globalDiffers || globalKanbanTasks != published {
                        globalKanbanTasks = refreshedTasks
                        taskDataChanged = true
                    }
                    if !globalKanbanIsCurrent { globalKanbanIsCurrent = true }
                    // Before board inventory has selected a board, the
                    // aggregate is the only valid visible projection.
                    if selectedKanbanBoardSlug == nil, visibleDiffers || kanbanTasks != visible {
                        kanbanTasks = refreshedTasks
                        taskDataChanged = true
                    }
                } else if visibleDiffers || kanbanTasks != visible {
                    kanbanTasks = refreshedTasks
                    taskDataChanged = true
                }
                if shouldPublishRefreshState || taskDataChanged {
                    recordProjectionSuccess("kanban.board")
                }
                if scope.isAggregate, !quietAggregate || taskDataChanged { recordProjectionSuccess("kanban.global") }
                if trigger == .user {
                    refreshKanbanSupportingProjections()
                }
            } catch {
                guard isCurrentKanbanRefresh(generation, scope: scope, boardSlug: requestedBoardSlug) else { return }
                let message = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
                recordProjectionFailure("kanban.board", error: message)
                if scope.isAggregate { recordProjectionFailure("kanban.global", error: message) }
                lastError = message
            }
        }
    }

    func isCurrentKanbanRefresh(_ generation: UUID, scope: KanbanRefreshScope, boardSlug: String?) -> Bool {
        let currentGeneration = scope.isAggregate ? aggregateKanbanRefreshGeneration : visibleKanbanRefreshGeneration
        return generation == currentGeneration && (scope.isAggregate || boardSlug == selectedKanbanBoardSlug)
    }

    func refreshKanbanSupportingProjections() {
        refreshKanbanStats()
        refreshKanbanAssignees()
        refreshKanbanBoards()
        refreshKanbanDiagnostics()
    }

    /// The global Kanban surface must never inherit a hidden session scope
    /// left behind by the session-activity shortcut. Keep the user's ordinary
    /// status, assignee, mine, archive, and sort choices, but make ownership
    /// explicit at this boundary.
    static func globalKanbanFilter(_ filter: KanbanListFilter) -> KanbanListFilter {
        var global = filter
        global.sessionID = nil
        return global
    }

    static func reconcileProjectRefresh(current: [ProjectSummary], incoming: [ProjectSummary]) -> [ProjectSummary] {
        var seen = Set<String>()
        let deduplicated = incoming.filter { seen.insert($0.id).inserted }
        guard !current.isEmpty else { return deduplicated.sorted { $0.id < $1.id } }

        let currentIDs = current.map(\.id)
        let incomingIDs = deduplicated.map(\.id)
        let incomingByID = Dictionary(deduplicated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rowsUnchanged =
            current.count == deduplicated.count
            && current.allSatisfy { incomingByID[$0.id] == $0 }
        if rowsUnchanged {
            return current
        }
        if Set(currentIDs) == Set(incomingIDs) {
            return incomingIDs == currentIDs
                ? currentIDs.compactMap { incomingByID[$0] }
                : deduplicated
        }
        let currentIDSet = Set(currentIDs)
        let retained = currentIDs.compactMap { incomingByID[$0] }
        let newProjects =
            deduplicated
            .filter { !currentIDSet.contains($0.id) }
            .sorted { $0.id < $1.id }
        return retained + newProjects
    }

    /// Refreshes the global Kanban projection. Board inventory and board
    /// selection are global controls, so they must never resurrect a session
    /// filter retained from an Activity shortcut.
    func refreshGlobalKanban(filter: KanbanListFilter? = nil, trigger: KanbanRefreshTrigger = .user) {
        refreshKanban(
            filter: Self.globalKanbanFilter(filter ?? KanbanListFilter()),
            scope: .aggregate,
            trigger: trigger
        )
    }

    /// Refreshes the user-visible Kanban list using the selected board and
    /// explicit UI filters. Unlike aggregate hydration, this preserves a
    /// deliberate session-only filter.
    func refreshVisibleKanban(
        filter: KanbanListFilter? = nil,
        trigger: KanbanRefreshTrigger = .user
    ) {
        refreshKanban(filter: filter ?? kanbanFilter, scope: .visible, trigger: trigger)
    }

    /// Refreshes the Kanban projection for the currently focused session without
    /// mutating the global board projection used by the Kanban tab.
    /// `quiet` is the chat's background poll: it publishes only when the
    /// session's cards changed, since every publish re-renders the whole
    /// chat view and stutters a transcript being scrolled.
    func refreshSessionKanban(for sessionID: String? = nil, quiet: Bool = false) {
        let candidateSessionID = sessionID ?? dockModel?.sessionID
        let requestedSessionID =
            candidateSessionID == dockModel?.sessionID
            ? dockModel?.kanbanSessionID
            : candidateSessionID
        // Session activity spans boards, independently of the global selector.
        let requestedBoardSlug: String? = nil
        let requested = SessionKanbanProjectionRequest(
            sessionID: requestedSessionID,
            boardSlug: requestedBoardSlug
        )
        if Self.shouldCoalesceSessionKanbanRefresh(
            activeRequest: sessionKanbanRequest,
            hasInFlightTask: sessionKanbanTask != nil,
            requested: requested
        ) {
            sessionKanbanRefreshPending = true
            return
        }
        let generation = UUID()
        let isNewProjection =
            sessionKanbanSessionID != requestedSessionID || sessionKanbanBoardSlug != requestedBoardSlug
        sessionKanbanTask?.cancel()
        sessionKanbanTask = nil
        sessionKanbanRefreshPending = false
        sessionKanbanRefreshGeneration = generation
        sessionKanbanRequest = requested
        if isNewProjection {
            sessionKanbanTasks = sessionKanbanTasksByRequest[requested] ?? []
        }
        if sessionKanbanSessionID != requestedSessionID { sessionKanbanSessionID = requestedSessionID }
        sessionKanbanBoardSlug = requestedBoardSlug
        if !quiet { beginProjectionRefresh("kanban.session") }

        guard
            Self.shouldAttemptSessionKanbanQuery(
                sessionID: requestedSessionID,
                hasCLI: cli != nil
            ),
            let requestedSessionID,
            let cli
        else {
            if !quiet {
                recordProjectionFailure("kanban.session", error: "Kanban is unavailable for the current session.")
            }
            return
        }

        // Capture attribution before suspension; another session may become active
        // while list/show requests are in flight.
        let activeAliases = Set((dockModel?.botActivitySessionIDs ?? []).compactMap { $0 })
        let isActiveSession = activeAliases.contains(requestedSessionID)
        let aliases = (isActiveSession ? activeAliases : []).union([requestedSessionID])
        let observedIDs = isActiveSession ? (dockModel?.observedKanbanTaskIDs ?? []) : []
        sessionKanbanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == self.sessionKanbanRefreshGeneration {
                    self.sessionKanbanTask = nil
                    self.sessionKanbanRequest = nil
                    if self.sessionKanbanRefreshPending {
                        self.sessionKanbanRefreshPending = false
                        self.refreshSessionKanban(for: requestedSessionID)
                    }
                }
            }
            do {
                let result = try await cli.kanbanList(
                    boardSlug: requestedBoardSlug,
                    // Finished session cards get archived; keep them in Recent.
                    filter: KanbanListFilter(includeArchived: true, sort: "updated"),
                    background: quiet
                )
                let parsed =
                    result.succeeded
                    ? await Self.parseKanbanTasksOffMain(result.stdout, boardSlug: requestedBoardSlug)
                    : nil
                guard
                    Self.isCurrentSessionKanbanResult(
                        generationMatches: generation == self.sessionKanbanRefreshGeneration,
                        publishedSessionID: self.sessionKanbanSessionID,
                        requestedSessionID: requestedSessionID,
                        publishedBoardSlug: self.sessionKanbanBoardSlug,
                        requestedBoardSlug: requestedBoardSlug
                    )
                else { return }
                guard result.succeeded else {
                    if quiet { return }
                    self.recordProjectionFailure(
                        "kanban.session",
                        error: Self.safeUserDiagnostic(result.stderr).isEmpty
                            ? "Hermes Kanban is unavailable." : Self.safeUserDiagnostic(result.stderr)
                    )
                    return
                }
                // A card may carry any of the session's aliases (runtime,
                // storage or attribution ID), so match them all.
                guard let parsed else {
                    if quiet { return }
                    self.recordProjectionFailure("kanban.session", error: "Hermes returned malformed Kanban data.")
                    return
                }
                var sessionTasks = Self.filterSessionKanbanTasks(
                    parsed,
                    sessionID: requestedSessionID,
                    aliases: aliases,
                    observedIDs: Set(observedIDs)
                )

                // Hermes agents can create a card through the kanban toolset
                // without persisting the originating chat session on the
                // task row. If this session explicitly ran `kanban show
                // <task-id>`, that exact command is stronger attribution
                // evidence than the missing database field. Enrich only
                // those exact IDs; never match by assignee or title.
                // Cards already in the list were judged above; only look up the
                // missing ones, or rehydrating a busy session takes minutes.
                let knownIDs = Set(parsed.map(\.id))
                for taskID in observedIDs where !knownIDs.contains(taskID) {
                    let missKey = "\(requestedBoardSlug ?? "")|\(taskID)"
                    guard !self.unrecoverableKanbanTaskIDs.contains(missKey),
                        let shown = try? await cli.kanbanShow(boardSlug: requestedBoardSlug, taskID: taskID)
                    else { continue }
                    guard shown.succeeded,
                        // A card owned by another session (e.g. an id that
                        // merely appeared in `kanban list` output) is not ours.
                        Self.parseKanbanTaskSummary(shown.stdout, boardSlug: requestedBoardSlug)
                            .map({ $0.sessionID.map(aliases.contains) ?? true }) ?? false,
                        let task = Self.parseKanbanTaskSummary(
                            shown.stdout,
                            boardSlug: requestedBoardSlug,
                            sessionID: requestedSessionID
                        )
                    else {
                        self.unrecoverableKanbanTaskIDs.insert(missKey)
                        continue
                    }
                    sessionTasks.append(task)
                }
                guard !Task.isCancelled,
                    Self.isCurrentSessionKanbanResult(
                        generationMatches: generation == self.sessionKanbanRefreshGeneration,
                        publishedSessionID: self.sessionKanbanSessionID,
                        requestedSessionID: requestedSessionID,
                        publishedBoardSlug: self.sessionKanbanBoardSlug,
                        requestedBoardSlug: requestedBoardSlug
                    )
                else { return }
                self.sessionKanbanTasksByRequest[requested] = sessionTasks
                let changed = self.sessionKanbanTasks != sessionTasks
                if changed { self.sessionKanbanTasks = sessionTasks }
                // Quiet polls still bump lastSuccess on real changes so card details refresh.
                if !quiet || changed { self.recordProjectionSuccess("kanban.session") }
                if requestedSessionID == self.dockModel?.kanbanSessionID {
                    await self.syncKanbanEventsIntoChat(sessionTasks, cli: cli)
                }
            } catch {
                guard generation == self.sessionKanbanRefreshGeneration,
                    self.sessionKanbanSessionID == requestedSessionID, !quiet
                else { return }
                self.recordProjectionFailure(
                    "kanban.session", error: Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    static func shouldCoalesceSessionKanbanRefresh(
        activeRequest: SessionKanbanProjectionRequest?,
        hasInFlightTask: Bool,
        requested: SessionKanbanProjectionRequest
    ) -> Bool {
        hasInFlightTask && activeRequest == requested
    }

    /// A session Activity result belongs to the request that created its
    /// projection. The global board selector is populated asynchronously and
    /// must not invalidate an otherwise current session-scoped list response.
    static func isCurrentSessionKanbanResult(
        generationMatches: Bool,
        publishedSessionID: String?,
        requestedSessionID: String,
        publishedBoardSlug: String?,
        requestedBoardSlug: String?
    ) -> Bool {
        generationMatches
            && publishedSessionID == requestedSessionID
            && publishedBoardSlug == requestedBoardSlug
    }

    /// The read-only list request is authoritative. Capability probes can be
    /// delayed or stale and must not suppress a session-scoped Activity query.
    static func shouldAttemptSessionKanbanQuery(sessionID: String?, hasCLI: Bool) -> Bool {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return hasCLI && !sessionID.isEmpty
    }

    func refreshKanbanBoards() {
        guard let cli, capabilityAvailable("kanban.boards") else { return }
        guard beginAction(refreshKanbanBoardsActionID) else { return }
        let generation = UUID()
        kanbanBoardsGeneration = generation
        Task {
            defer { finishAction(refreshKanbanBoardsActionID) }
            do {
                let result = try await cli.kanbanBoards()
                guard generation == kanbanBoardsGeneration else { return }
                guard result.succeeded else {
                    lastError =
                        Self.safeUserDiagnostic(result.stderr).isEmpty
                        ? "Hermes Kanban boards are unavailable." : Self.safeUserDiagnostic(result.stderr)
                    return
                }
                let boards = Self.parseKanbanBoards(result.stdout)
                if kanbanBoards != boards {
                    kanbanBoards = boards
                }
                let previousSelection = selectedKanbanBoardSlug
                if let selected = selectedKanbanBoardSlug,
                    boards.contains(where: { $0.slug == selected && !$0.archived })
                {
                    // Preserve an explicitly selected Dock board even when the
                    // shared Hermes default changes elsewhere.
                } else {
                    selectedKanbanBoardSlug =
                        boards.first(where: { $0.isCurrent && !$0.archived })?.slug
                        ?? boards.first(where: { !$0.archived })?.slug
                }
                let inventoryRefreshPlan = Self.boardInventoryRefreshPlan(
                    previousSelection: previousSelection,
                    resolvedSelection: selectedKanbanBoardSlug
                )
                if inventoryRefreshPlan.refreshBoard {
                    // Keep eager aggregate hydration separate from the
                    // visible board-scoped list.
                    refreshVisibleKanban(trigger: .background)
                }
                if inventoryRefreshPlan.refreshSession {
                    refreshSessionKanban(for: dockModel?.kanbanSessionID)
                }
            } catch {
                guard generation == kanbanBoardsGeneration else { return }
                lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    func selectKanbanBoard(_ board: KanbanBoardSummary) {
        guard !board.archived else { return }
        selectKanbanBoard(slug: board.slug)
    }

    func selectKanbanBoard(slug: String) {
        guard selectedKanbanBoardSlug != slug else { return }
        selectedKanbanBoardSlug = slug
        visibleKanbanRefreshGeneration = UUID()
        kanbanStatsGeneration = UUID()
        kanbanAssigneesGeneration = UUID()
        kanbanDetailGeneration = UUID()
        kanbanDiagnosticsGeneration = UUID()
        kanbanAttachmentsGeneration = UUID()
        kanbanTasks = []
        kanbanDetail = nil
        kanbanDetailTaskIdentity = nil
        kanbanDetailError = nil
        kanbanStats = nil
        kanbanAssignees = []
        kanbanDiagnostics = []
        kanbanAttachments = []
        loadingKanbanDetailTaskID = nil
        refreshVisibleKanban()
        refreshSessionKanban(for: dockModel?.kanbanSessionID)
        refreshKanbanDiagnostics()
    }

    func revealKanbanTask(_ task: KanbanTaskSummary) {
        kanbanFilter = KanbanListFilter()
        if let slug = task.boardSlug, selectedKanbanBoardSlug != slug {
            selectKanbanBoard(slug: slug)
        }
        refreshVisibleKanban(filter: KanbanListFilter())
        requestedKanbanTask = task
    }

    /// Board inventory establishes the global board selector. It must not
    /// restart the independently scoped session Activity request; explicit
    /// user board selection is handled by `selectKanbanBoard(_:)` instead.
    static func boardInventoryRefreshPlan(
        previousSelection: String?,
        resolvedSelection: String?
    ) -> (refreshBoard: Bool, refreshSession: Bool) {
        let selectionChanged = previousSelection != resolvedSelection && resolvedSelection != nil
        return (refreshBoard: selectionChanged, refreshSession: false)
    }

    func refreshKanbanAssignees() {
        guard let cli, capabilityAvailable("kanban.assignees") else { return }
        let generation = UUID()
        let requestedBoardSlug = selectedKanbanBoardSlug
        kanbanAssigneesGeneration = generation
        Task {
            guard let result = try? await cli.kanbanAssignees(boardSlug: requestedBoardSlug),
                result.succeeded,
                generation == kanbanAssigneesGeneration,
                requestedBoardSlug == selectedKanbanBoardSlug
            else { return }
            let assignees = Self.parseKanbanAssignees(result.stdout)
            if kanbanAssignees != assignees {
                kanbanAssignees = assignees
            }
        }
    }

    func refreshKanbanDiagnostics(severity: String? = nil) {
        guard let cli, capabilityAvailable("kanban") else { return }
        let generation = UUID()
        let requestedBoardSlug = selectedKanbanBoardSlug
        kanbanDiagnosticsGeneration = generation
        beginProjectionRefresh("kanban.diagnostics")
        Task {
            do {
                let result = try await cli.kanbanDiagnostics(boardSlug: requestedBoardSlug, severity: severity)
                guard generation == kanbanDiagnosticsGeneration,
                    requestedBoardSlug == selectedKanbanBoardSlug
                else { return }
                guard result.succeeded else {
                    recordProjectionFailure("kanban.diagnostics", error: Self.safeUserDiagnostic(result.stderr))
                    return
                }
                let diagnostics = Self.parseKanbanDiagnostics(
                    result.stdout, boardSlug: requestedBoardSlug, severity: severity)
                if kanbanDiagnostics != diagnostics {
                    kanbanDiagnostics = diagnostics
                }
                recordProjectionSuccess("kanban.diagnostics")
            } catch {
                guard generation == kanbanDiagnosticsGeneration else { return }
                recordProjectionFailure(
                    "kanban.diagnostics", error: Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    func refreshKanbanAttachments(for taskID: String, boardSlug: String? = nil) {
        guard let cli else { return }
        let generation = UUID()
        let requestedBoardSlug = boardSlug ?? selectedKanbanBoardSlug
        kanbanAttachmentsGeneration = generation
        beginProjectionRefresh("kanban.attachments")
        Task {
            do {
                let result = try await cli.kanbanAttachments(boardSlug: requestedBoardSlug, taskID: taskID)
                guard generation == kanbanAttachmentsGeneration,
                    kanbanDetailTaskIdentity == KanbanTaskIdentity(boardSlug: requestedBoardSlug, taskID: taskID)
                else { return }
                guard result.succeeded,
                    let data = result.stdout.data(using: .utf8),
                    let value = try? JSONSerialization.jsonObject(with: data)
                else {
                    recordProjectionFailure("kanban.attachments", error: Self.safeUserDiagnostic(result.stderr))
                    return
                }
                kanbanAttachments = Self.parseKanbanAttachments(value, boardSlug: requestedBoardSlug, taskID: taskID)
                recordProjectionSuccess("kanban.attachments")
            } catch {
                guard generation == kanbanAttachmentsGeneration else { return }
                recordProjectionFailure(
                    "kanban.attachments", error: Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    func loadKanbanTask(_ task: KanbanTaskSummary) {
        let generation = UUID()
        let requestedBoardSlug = task.boardSlug ?? selectedKanbanBoardSlug
        let identity = KanbanTaskIdentity(boardSlug: requestedBoardSlug, taskID: task.id)
        kanbanDetailGeneration = generation
        kanbanDetailTaskIdentity = identity
        loadingKanbanDetailTaskID = task.id
        kanbanDetail = Self.fallbackKanbanTaskDetail(task, boardSlug: requestedBoardSlug)
        kanbanDetailError = nil
        kanbanAttachmentsGeneration = UUID()
        kanbanAttachments = []
        refreshKanbanAttachments(for: task.id, boardSlug: requestedBoardSlug)
        guard let cli else {
            loadingKanbanDetailTaskID = nil
            kanbanDetailError = "Hermes task details are unavailable. Showing the board summary."
            return
        }
        Task {
            defer {
                if generation == kanbanDetailGeneration {
                    loadingKanbanDetailTaskID = nil
                }
            }
            do {
                let fetched = try await fetchKanbanTaskDetail(task, boardSlug: requestedBoardSlug, cli: cli)
                guard generation == kanbanDetailGeneration else { return }
                if let error = fetched.error {
                    kanbanDetailError = error
                    return
                }
                guard kanbanDetailTaskIdentity == identity, let detail = fetched.detail else { return }
                kanbanDetail = detail
            } catch {
                guard generation == kanbanDetailGeneration,
                    kanbanDetailTaskIdentity == identity
                else { return }
                kanbanDetailError = HermesDiagnosticsService.safeSummary(
                    Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    /// Silent re-read of the open card for the live Activity tab: unlike
    /// `loadKanbanTask` it keeps the current detail on screen and drops errors.
    func refreshKanbanTaskQuietly(_ task: KanbanTaskSummary) async {
        guard let cli else { return }
        let boardSlug = task.boardSlug ?? selectedKanbanBoardSlug
        let identity = KanbanTaskIdentity(boardSlug: boardSlug, taskID: task.id)
        guard kanbanDetailTaskIdentity == identity,
            let detail = try? await fetchKanbanTaskDetail(task, boardSlug: boardSlug, cli: cli).detail,
            kanbanDetailTaskIdentity == identity, detail != kanbanDetail
        else { return }
        kanbanDetail = detail
    }

    /// Hermes posts only terminal kanban events to chat, so handoffs (picked
    /// up, review requested, changes requested…) are read from each session
    /// card's history and inserted as the same notice cards. A card is
    /// re-read only when its latest event moved; reloading the transcript
    /// (new first message) starts over.
    func syncKanbanEventsIntoChat(_ tasks: [KanbanTaskSummary], cli: HermesCLIAdapter) async {
        guard let dockModel, let floor = dockModel.messages.first else { return }
        if kanbanChatSyncAnchor != floor.id {
            kanbanChatSyncAnchor = floor.id
            kanbanChatSyncedEventAt = [:]
            // A reload of the same chat keeps its discovered feeds; cached
            // cards skip discovery, so only a new chat starts over.
            if kanbanChatSyncSessionID != dockModel.kanbanSessionID {
                kanbanChatSyncSessionID = dockModel.kanbanSessionID
                kanbanChatFeeds = [:]
                kanbanChatCheckedSessionIDs = []
            }
        }
        for task in tasks
        where (task.latestEventAt ?? .distantFuture) >= floor.timestamp
            && kanbanChatSyncedEventAt[task.id] != task.latestEventAt
        {
            // A live external turn reloads the transcript every few seconds,
            // minting a new anchor each time. Re-insert from the last read of
            // an unchanged card instead of spawning `kanban show` again.
            if let cached = kanbanChatDetailCache[task.id], cached.eventAt == task.latestEventAt {
                kanbanChatSyncedEventAt[task.id] = task.latestEventAt
                dockModel.insertKanbanBoardNotices(KanbanNotice.boardEventNotices(for: cached.detail))
                continue
            }
            guard let detail = try? await fetchKanbanTaskDetail(task, boardSlug: task.boardSlug, cli: cli).detail else {
                continue
            }
            kanbanChatDetailCache[task.id] = (task.latestEventAt, detail)
            guard kanbanChatSyncAnchor == floor.id else { continue }
            kanbanChatSyncedEventAt[task.id] = task.latestEventAt
            dockModel.insertKanbanBoardNotices(KanbanNotice.boardEventNotices(for: detail))
            await discoverFeedSessions(mentioning: task.id, anchor: floor.id)
        }
        await syncFeedSessionsIntoChat(anchor: floor.id)
    }

    /// Plugins (workflow runners, supervisors…) may narrate a card's progress
    /// into a session of their own. Such a feed is a session with no user
    /// turns that names this chat's card; any session with a prompt is a
    /// conversation or worker run, not a feed.
    func discoverFeedSessions(mentioning taskID: String, anchor: UUID) async {
        guard let rpc, let dockModel,
            let hits = try? await rpc.searchSessions(query: taskID)
        else { return }
        let own = Set(dockModel.botActivitySessionIDs.compactMap { $0 })
        for hit in hits {
            guard let id = hit["session_id"] as? String, !own.contains(id),
                kanbanChatCheckedSessionIDs.insert(id).inserted,
                let rows = try? await rpc.sessionMessages(sessionID: id, latest: true)["data"] as? [[String: Any]],
                Self.isFeedSession(rows), kanbanChatSyncAnchor == anchor
            else { continue }
            kanbanChatFeeds[id] = (hit["source"] as? String).flatMap(Self.nonEmpty) ?? "feed"
        }
    }

    static func isFeedSession(_ rows: [[String: Any]]) -> Bool {
        !rows.isEmpty && !rows.contains { ($0["role"] as? String) == "user" }
    }

    /// Merges each feed into this chat by timestamp, so a run reads where it
    /// was started instead of only in a side session.
    func syncFeedSessionsIntoChat(anchor: UUID) async {
        guard let rpc else { return }
        for (feedID, source) in kanbanChatFeeds.sorted(by: { $0.key < $1.key }) {
            guard let rows = try? await rpc.sessionMessages(sessionID: feedID, latest: true)["data"] as? [[String: Any]]
            else { continue }
            guard kanbanChatSyncAnchor == anchor, let dockModel else { return }
            let feed = DockModel.parseMessages(
                TranscriptHistoryPaging.displayRows(fromStoredRows: rows),
                defaultBotProfileID: source,
                defaultBotDisplayName: source
            ).messages.map {
                ChatMessage(
                    role: .hermes, text: $0.text, timestamp: $0.timestamp,
                    systemEvent: .feed(source: source, text: $0.text))
            }
            dockModel.insertTimelineMessages(feed)
        }
    }

    /// Card detail for the session Activity panel and chat kanban notices;
    /// leaves the board's selected `kanbanDetail` untouched.
    func sessionKanbanTaskDetail(_ task: KanbanTaskSummary) async -> KanbanTaskDetail? {
        guard let cli else { return nil }
        return try? await fetchKanbanTaskDetail(task, boardSlug: task.boardSlug ?? selectedKanbanBoardSlug, cli: cli)
            .detail
    }

    /// One `show` round trip, plus `runs` only for Hermes versions whose
    /// `show` omits run history. Returns `error` when `show` itself failed.
    func fetchKanbanTaskDetail(
        _ task: KanbanTaskSummary,
        boardSlug: String?,
        cli: HermesCLIAdapter
    ) async throws -> (detail: KanbanTaskDetail?, error: String?) {
        let taskResult = try await cli.kanbanShow(boardSlug: boardSlug, taskID: task.id)
        guard taskResult.succeeded else {
            let safeError = HermesDiagnosticsService.safeSummary(taskResult.stderr)
            return (
                nil, safeError.isEmpty ? "Hermes task details are unavailable. Showing the board summary." : safeError
            )
        }
        // A successful Hermes version may return a human-readable `show`
        // response instead of structured JSON. The selected card already
        // contains authoritative summary data, so keep Details usable and use
        // the structured response only to enrich it when available.
        var detail =
            Self.parseKanbanTaskDetail(taskResult.stdout, fallback: task, boardSlug: boardSlug)
            ?? Self.fallbackKanbanTaskDetail(task, boardSlug: boardSlug)
        if detail.runs.isEmpty, capabilityAvailable("kanban.taskRuns") {
            let runsResult = try await cli.kanbanRuns(boardSlug: boardSlug, taskID: task.id)
            if runsResult.succeeded {
                detail =
                    Self.enrichedKanbanTaskDetail(
                        detail,
                        runs: Self.parseKanbanRuns(runsResult.stdout, boardSlug: boardSlug),
                        boardSlug: boardSlug
                    ) ?? detail
            }
        }
        return (detail, nil)
    }

    /// Loads detail and attachments for an inspector outside the Kanban page.
    /// The cached entry (or the card summary) stays visible while refreshing.
    func inspectKanbanTask(_ task: KanbanTaskSummary) {
        let identity = KanbanTaskIdentity(boardSlug: task.boardSlug, taskID: task.id)
        var entry =
            kanbanTaskInspections[identity]
            ?? KanbanTaskInspection(detail: Self.fallbackKanbanTaskDetail(task, boardSlug: task.boardSlug))
        guard let cli else {
            entry.error = "Hermes task details are unavailable. Showing the board summary."
            storeKanbanTaskInspection(entry, for: identity)
            return
        }
        entry.isLoading = true
        entry.error = nil
        storeKanbanTaskInspection(entry, for: identity)
        let generation = UUID()
        kanbanTaskInspectionGenerations[identity] = generation
        Task {
            async let attachmentsResult = try? cli.kanbanAttachments(boardSlug: task.boardSlug, taskID: task.id)
            var next = kanbanTaskInspections[identity] ?? entry
            do {
                let fetched = try await fetchKanbanTaskDetail(task, boardSlug: task.boardSlug, cli: cli)
                if let detail = fetched.detail { next.detail = detail }
                next.error = fetched.error
            } catch {
                next.error = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            }
            if let result = await attachmentsResult, result.succeeded,
                let data = result.stdout.data(using: .utf8),
                let value = try? JSONSerialization.jsonObject(with: data)
            {
                next.attachments = Self.parseKanbanAttachments(value, boardSlug: task.boardSlug, taskID: task.id)
                next.attachmentsAvailable = true
            } else {
                next.attachmentsAvailable = false
            }
            guard kanbanTaskInspectionGenerations[identity] == generation else { return }
            kanbanTaskInspectionGenerations[identity] = nil
            next.isLoading = false
            next.loadedAt = Date()
            storeKanbanTaskInspection(next, for: identity)
        }
    }

    func storeKanbanTaskInspection(_ entry: KanbanTaskInspection, for identity: KanbanTaskIdentity) {
        kanbanTaskInspectionOrder.removeAll { $0 == identity }
        kanbanTaskInspectionOrder.append(identity)
        var next = kanbanTaskInspections
        next[identity] = entry
        // Bounded LRU. In-flight entries are never evicted.
        while kanbanTaskInspectionOrder.count > Self.kanbanTaskInspectionLimit,
            let index = kanbanTaskInspectionOrder.firstIndex(where: { kanbanTaskInspectionGenerations[$0] == nil })
        {
            next[kanbanTaskInspectionOrder.remove(at: index)] = nil
        }
        if next != kanbanTaskInspections { kanbanTaskInspections = next }
    }

    func refreshKanbanStats() {
        guard let cli, capabilityAvailable("kanban.stats") else { return }
        let generation = UUID()
        let requestedBoardSlug = selectedKanbanBoardSlug
        kanbanStatsGeneration = generation
        Task {
            guard let result = try? await cli.kanbanStats(boardSlug: requestedBoardSlug),
                result.succeeded,
                generation == kanbanStatsGeneration,
                requestedBoardSlug == selectedKanbanBoardSlug
            else { return }
            let stats = Self.parseKanbanStats(result.stdout)
            if kanbanStats != stats {
                kanbanStats = stats
            }
        }
    }

    func createKanbanTask(title: String, body: String) async -> Bool {
        guard let cli, capabilityAvailable("kanban.create") else {
            reportActionError(
                "Could not create task", message: "Kanban is unavailable because Hermes Control is not connected.")
            return false
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            reportActionError("Could not create task", message: "Enter a Kanban task title before creating it.")
            return false
        }
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = nil
        isCreatingKanbanTask = true
        defer { isCreatingKanbanTask = false }
        do {
            let result = try await cli.kanbanCreate(
                boardSlug: selectedKanbanBoardSlug,
                title: cleanTitle,
                body: cleanBody.isEmpty ? nil : cleanBody
            )
            guard result.succeeded else {
                reportActionError(
                    "Could not create task",
                    message:
                        Self.safeUserDiagnostic(result.stderr).isEmpty
                        ? "Hermes Kanban could not create the task." : Self.safeUserDiagnostic(result.stderr))
                return false
            }
            if let sessionID = dockModel?.kanbanSessionID, !sessionID.isEmpty,
                (selectedKanbanBoardSlug ?? "").isEmpty,
                let taskID = Self.kanbanTaskID(fromCreateOutput: result.stdout)
            {
                try? await cli.kanbanAttributeSession(taskID: taskID, sessionID: sessionID)
            }
            refreshKanban()
            refreshGlobalKanban()
            return true
        } catch {
            reportActionError(
                "Could not create task",
                message: HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription)))
            return false
        }
    }

    static func kanbanTaskID(fromCreateOutput output: String) -> String? {
        if let data = output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["id"] as? String
        {
            return id
        }
        return output.range(of: #""id"\s*:\s*"(t_[A-Za-z0-9_-]+)""#, options: .regularExpression)
            .flatMap { range in
                String(output[range]).components(separatedBy: "\"").last { !$0.isEmpty && !$0.contains(":") }
            }
    }

    func updateKanbanTask(_ task: KanbanTaskSummary, action: KanbanTaskAction) {
        guard let cli, canMutateKanbanTask(action) else { return }
        let actionID = kanbanActionID(action, task: task)
        guard beginAction(actionID) else { return }
        Task {
            defer { finishAction(actionID) }
            do {
                let result: HermesCLIResult
                switch action {
                case .complete:
                    result = try await cli.kanbanComplete(
                        boardSlug: task.boardSlug ?? selectedKanbanBoardSlug, taskID: task.id)
                case .block:
                    result = try await cli.kanbanBlock(
                        boardSlug: task.boardSlug ?? selectedKanbanBoardSlug, taskID: task.id)
                case .unblock:
                    result = try await cli.kanbanUnblock(
                        boardSlug: task.boardSlug ?? selectedKanbanBoardSlug, taskID: task.id)
                case .archive:
                    result = try await cli.kanbanArchive(
                        boardSlug: task.boardSlug ?? selectedKanbanBoardSlug, taskID: task.id)
                }
                guard result.succeeded else {
                    reportActionError(
                        "Could not update task",
                        message:
                            Self.safeUserDiagnostic(result.stderr).isEmpty
                            ? "Hermes Kanban could not update the task." : Self.safeUserDiagnostic(result.stderr))
                    return
                }
                refreshKanban()
                refreshGlobalKanban()
            } catch {
                reportActionError(
                    "Could not update task",
                    message: HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription)))
            }
        }
    }

    func mutateKanban(_ request: KanbanMutationRequest) {
        guard let cli, capabilityAvailable(request.kind.capabilityID) else {
            reportActionError(
                "Could not update task",
                message: "\(request.kind.title.capitalized) is unavailable through the installed Hermes CLI.")
            return
        }
        let value = request.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            reportActionError("Could not update task", message: "Enter a value before updating this Kanban task.")
            return
        }
        let actionID = kanbanActionID(request.kind, task: request.task)
        guard beginAction(actionID) else { return }
        Task {
            defer { finishAction(actionID) }
            do {
                let result: HermesCLIResult
                switch request.kind {
                case .comment:
                    result = try await cli.kanbanComment(
                        boardSlug: request.task.boardSlug ?? selectedKanbanBoardSlug, taskID: request.task.id,
                        text: value)
                case .schedule:
                    result = try await cli.kanbanSchedule(
                        boardSlug: request.task.boardSlug ?? selectedKanbanBoardSlug, taskID: request.task.id,
                        reason: value)
                case .assign:
                    result = try await cli.kanbanAssign(
                        boardSlug: request.task.boardSlug ?? selectedKanbanBoardSlug, taskID: request.task.id,
                        profile: value, reassign: false, reclaim: false)
                case .reassign:
                    result = try await cli.kanbanAssign(
                        boardSlug: request.task.boardSlug ?? selectedKanbanBoardSlug, taskID: request.task.id,
                        profile: value, reassign: true, reclaim: request.reclaimFirst)
                case .promote:
                    result = try await cli.kanbanPromote(
                        boardSlug: request.task.boardSlug ?? selectedKanbanBoardSlug, taskID: request.task.id,
                        reason: value)
                case .reclaim:
                    result = try await cli.kanbanReclaim(
                        boardSlug: request.task.boardSlug ?? selectedKanbanBoardSlug, taskID: request.task.id,
                        reason: value)
                }
                guard result.succeeded else {
                    reportActionError(
                        "Could not update task",
                        message:
                            Self.safeUserDiagnostic(result.stderr).isEmpty
                            ? "Hermes Kanban could not update the task." : Self.safeUserDiagnostic(result.stderr))
                    return
                }
                refreshKanban()
                loadKanbanTask(request.task)
                refreshGlobalKanban()
            } catch {
                reportActionError(
                    "Could not update task",
                    message: HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription)))
            }
        }
    }

    func kanbanMoveActionID(_ task: KanbanTaskSummary) -> String { "kanban.move:\(task.id)" }

    /// Lane drops PATCH the same plugin route the board is read from, so the
    /// board being loaded is the capability.
    /// The capability probe runs through the gateway's shell, which can miss a
    /// `hermes` the CLI adapter does reach. A loaded board proves the adapter works.
    func canMutateKanbanTask(_ action: KanbanTaskAction) -> Bool {
        capabilityAvailable("kanban.\(action.rawValue)") || canMoveKanbanTasks
    }

    var canMoveKanbanTasks: Bool {
        guard cli != nil, let state = refreshState(for: "kanban.board") else { return false }
        return state.lastSuccess != nil && !state.isStale
    }

    /// Drag-to-move for Triage/Todo/Ready. Keep the current card in place until
    /// Hermes accepts the transition, then refresh the authoritative board.
    func moveKanbanTask(_ task: KanbanTaskSummary, to lane: KanbanLane) {
        guard let cli, canMoveKanbanTasks else {
            reportActionError(
                "Could not move task", message: "Moving Kanban tasks is unavailable through the installed Hermes.")
            return
        }
        guard case .move = KanbanBoardPresentation.dropOutcome(taskStatus: task.status, target: lane) else { return }
        let actionID = kanbanMoveActionID(task)
        guard beginAction(actionID) else { return }
        Task {
            defer { finishAction(actionID) }
            do {
                _ = try await cli.kanbanMove(
                    boardSlug: task.boardSlug ?? selectedKanbanBoardSlug, taskID: task.id, status: lane.status)
            } catch {
                reportActionError(
                    "Could not move task",
                    message: HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription)))
            }
            refreshKanban()
            refreshGlobalKanban()
        }
    }

    /// One-step assignment, as in the Hermes desktop assignee menu: reassign
    /// and reclaim a live worker first so a running card can change hands.
    /// `nil` unassigns.
    func assignKanbanTask(_ task: KanbanTaskSummary, to profile: String?) {
        guard let cli, capabilityAvailable(HermesFeatureIDs.ID.kanbanReassign.rawValue) else {
            reportActionError(
                "Could not assign task",
                message: "Assigning Kanban tasks is unavailable through the installed Hermes CLI.")
            return
        }
        guard task.assignee != profile else { return }
        let actionID = kanbanActionID(.reassign, task: task)
        guard beginAction(actionID) else { return }
        setKanbanTask(task.id) { $0.assignee = profile }
        Task {
            defer { finishAction(actionID) }
            do {
                let result = try await cli.kanbanAssign(
                    boardSlug: task.boardSlug ?? selectedKanbanBoardSlug,
                    taskID: task.id,
                    profile: profile ?? "none",
                    reassign: true,
                    reclaim: true
                )
                if !result.succeeded {
                    let message = Self.safeUserDiagnostic(result.stderr)
                    reportActionError(
                        "Could not assign task",
                        message: message.isEmpty ? "Hermes Kanban could not assign the task." : message)
                }
            } catch {
                reportActionError(
                    "Could not assign task",
                    message: HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription)))
            }
            refreshKanban()
            refreshGlobalKanban()
        }
    }

    func setKanbanTask(_ id: String, _ change: (inout KanbanTaskSummary) -> Void) {
        guard let index = kanbanTasks.firstIndex(where: { $0.id == id }) else { return }
        change(&kanbanTasks[index])
    }
}
