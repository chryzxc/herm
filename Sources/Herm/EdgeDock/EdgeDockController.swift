import AppKit
import Combine
import CryptoKit
import SwiftUI

/// The passive notch. It is its own window, hidden while the workspace shows,
/// so it never hosts workspace content.
@MainActor
final class EdgeDockController: NSObject {
    let panel = DockPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let model: DockModel
    private let controlCenter: ControlCenterModel
    private let openQuota: () -> Void
    private let openKanban: (KanbanTaskSummary) -> Void
    private let openDock: () -> Void
    let state: EdgeNotchState
    private var petWindow: HermesPetWindow?
    private weak var notchHost: EdgeDockHostingView<EdgeNotchView>?
    private var subscriptions = Set<AnyCancellable>()
    private var interactionMonitors: [Any] = []
    private var previousApplication: NSRunningApplication?
    private var collapseTask: DispatchWorkItem?
    private var expandTask: DispatchWorkItem?
    private lazy var frameTransition = EdgePanelFrameTransition(panel: panel)
    private var hovering = false
    private var dragging = false
    private var petDragging = false
    private var suppressClickUntil = Date.distantPast
    private var workspacePresented = false
    private var quickProfileID: String?
    private var completedTaskIDs: Set<String>?
    private var routineEvents: [String: String] = [:]
    private var observedRoutineProfiles = Set<String>()
    private var latestToolID: String?
    private var latestToolComplete = false
    private var kanbanActivity = EdgeKanbanActivity()
    private var lastBotRead: Date?
    private var loadingBots = false
    private var lastKanbanRead: Date?
    private var lastKanbanPoll: Date?
    private var kanbanStatusCurrent = false
    private var latestSessions: [HermesSession] = []
    private var latestAttention: [String: DockModel.SessionAttention] = [:]
    private var latestAnswers: [AttentionRequest: AttentionAnswerState] = [:]
    private var deliveryQuestions: [EdgeDeliveryQuestion] = []
    private var deliveryQuestionPoll: Task<Void, Never>?
    private var latestActivityLabels: [String: String] = [:]
    private var lastQuotas: [ProviderQuotaSnapshot]?
    /// Quota readers whose usage has moved; these are the services being
    /// spent (by Hermes or any other app), so they are read on every tick.
    private var hotQuotaReaders = Set<String>()
    private var quotaTick = 0
    private var displayID: NSNumber?
    private var fraction: CGFloat = 0.5
    private let defaults: UserDefaults

    init(
        model: DockModel, controlCenter: ControlCenterModel, defaults: UserDefaults = .standard,
        interruptions: HermInterruptionCoordinator? = nil, openQuota: @escaping () -> Void,
        openKanban: @escaping (KanbanTaskSummary) -> Void, openDock: @escaping () -> Void
    ) {
        self.model = model
        state = EdgeNotchState(store: .shared, interruptions: interruptions)
        self.controlCenter = controlCenter
        self.openQuota = openQuota
        self.openKanban = openKanban
        self.defaults = defaults
        self.openDock = openDock
        super.init()
        petWindow = HermesPetWindow(pet: controlCenter.pet, defaults: defaults)
        state.externalPet = true
        state.petAttached = petWindow?.attached ?? true
        petWindow?.onAttachChange = { [weak self] in self?.state.petAttached = $0 }
        petWindow?.onDragProgress = { [weak self] dragging, pull in
            guard let self else { return }
            if dragging && !self.petDragging {
                self.petDragging = true
                self.expandTask?.cancel()
                self.setExpanded(false)
            }
            if !dragging { self.petDragging = false }
            self.state.petDragging = dragging
            self.state.petPull = pull
            if !dragging { self.surfaceDigestIfPossible() }
        }
        quickProfileID = model.profileScopeID
        state.switchQuickProfile(model.profileScopeID)
        state.side = EdgeDockSide(rawValue: defaults.string(forKey: "hermes.notch.side") ?? "") ?? .right
        fraction = defaults.object(forKey: "hermes.notch.position") as? Double ?? 0.5
        displayID = defaults.object(forKey: "hermes.notch.display") as? NSNumber
        panel.acceptsWorkspaceFocus = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        let host = EdgeDockHostingView(
            rootView: EdgeNotchView(
                state: state, controlCenter: controlCenter,
                onQuotaRequested: { [weak self] in self?.loadQuota() },
                onTasksRefresh: { [weak self] in self?.refreshSelectedTasks() },
                onOpenQuota: { [weak self] in self?.openQuota() },
                quickMessageModel: model,
                onQuickMessageFocus: { [weak self] active in self?.setQuickMessageFocus(active) },
                onQuickReply: { [weak self] task in self?.beginQuickReply(task) },
                onResultPeek: { [weak self] task in self?.peekResult(task) },
                onResultReply: { [weak self] target in self?.beginQuickReply(target.task, target: target.session) },
                onOpenDigest: { [weak self] notice in self?.openDigestSource(notice) },
                onAnswer: { [weak self] task, choice in self?.answer(task, choice: choice) },
                openDock: { [weak self] in self?.openWorkspace() },
                onOpenTask: { [weak self] task in self?.openTask(task) },
                onDrag: { [weak self] ended in self?.moveNotch(ended: ended) },
                onCallPetHome: { [weak self] in self?.petWindow?.recall() },
                onSideChange: { [weak self] side in
                    guard let self else { return }
                    self.state.side = side
                    self.persistPlacement()
                    self.position(animated: true)
                }))
        host.onHoverChanged = { [weak self] value in self?.hoverChanged(value) }
        host.sizingOptions = []
        notchHost = host
        panel.contentView = host.panelContainer()
        panel.onCancel = { [weak self] in self?.escapePreview() }
        installInteractionMonitors()
        controlCenter.pet.$info.combineLatest(controlCenter.pet.$sheet)
            .map { $0.enabled && $1 != nil }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak host] visible in
                guard let self else { return }
                self.state.hasPet = visible
                self.position(animated: false)
            }.store(in: &subscriptions)
        controlCenter.pet.$info.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.position(animated: false) }.store(in: &subscriptions)
        Publishers.CombineLatest3(model.$status, model.$hasUnreadResponse, model.$backgroundTasks)
            .receive(on: RunLoop.main)
            .sink { [weak self] status, unread, tasks in
                self?.refresh(status: status, unread: unread, tasks: tasks)
            }.store(in: &subscriptions)
        model.$sessionAttention
            .receive(on: RunLoop.main)
            .sink { [weak self] requests in
                guard let self else { return }
                let hasNewRequest = requests.contains { self.latestAttention[$0.key] != $0.value }
                let changedRequests = requests.filter { self.latestAttention[$0.key] != $0.value }
                self.latestAttention = requests
                self.updateDetail()
                if hasNewRequest {
                    for (owner, request) in changedRequests {
                        self.announce(
                            notice: self.model.interruptionNotice(
                                request.status == .needsApproval ? .approval : .clarification,
                                owner: owner, eventID: request.requestID))
                    }
                }
            }.store(in: &subscriptions)
        model.$attentionAnswers
            .receive(on: RunLoop.main)
            .sink { [weak self] answers in
                guard let self else { return }
                self.latestAnswers = answers
                self.rebuildTasks()
            }.store(in: &subscriptions)
        model.$isLoadingSessions
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.state.refreshingSessions = $0 }
            .store(in: &subscriptions)
        model.$profileScopeID.combineLatest(state.$quickSending)
            .receive(on: RunLoop.main)
            .sink { [weak self] profile, sending in
                guard let self, !sending, profile != self.quickProfileID else { return }
                self.quickProfileID = profile
                self.state.resultTarget = nil
                guard self.state.captureRecord().isEmpty, !self.state.composing, self.state.quickPreparing == 0 else {
                    return
                }
                self.state.switchQuickProfile(profile)
                if !self.workspacePresented { self.setQuickMessageFocus(false) }
            }.store(in: &subscriptions)
        model.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in self?.refreshNoteworthySessions(sessions) }
            .store(in: &subscriptions)
        controlCenter.$cronJobs.combineLatest(controlCenter.$cronRuns)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.routineUpdates()
                self?.rebuildTasks()
            }.store(in: &subscriptions)
        state.preferences.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildTasks() }.store(in: &subscriptions)
        state.$showingAnnouncement.combineLatest(state.$glimpseHeight).removeDuplicates { $0 == $1 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in if self?.state.expanded == true { self?.position(animated: true) } }
            .store(in: &subscriptions)
        state.$side.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] side in
                guard let self else { return }
                EdgeIslandTheme.apply(side: side, store: .shared, defaults: self.defaults)
            }.store(in: &subscriptions)
        state.$composing.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.position(animated: true) }.store(in: &subscriptions)
        Publishers.CombineLatest3(state.interruptions.$pendingDigest, state.$composing, model.$isHermesConnected)
            .receive(on: RunLoop.main)
            .sink { [weak self] pending, composing, connected in
                if pending, !composing, connected { self?.surfaceDigestIfPossible() }
            }.store(in: &subscriptions)
        state.interruptions.$blockingFailure
            .receive(on: RunLoop.main)
            .sink { [weak self] notice in
                self?.rebuildTasks()
                if let notice { self?.announce(notice: notice) }
            }
            .store(in: &subscriptions)
        model.sessionActivityLabelChanges
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] labels in
                self?.latestActivityLabels = labels
                self?.rebuildTasks()
            }
            .store(in: &subscriptions)
        model.$botActivityRevision.map { _ in () }
            .merge(with: model.$botLiveSteps.map { _ in () })
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.rebuildTasks() }
            .store(in: &subscriptions)
        model.$activityPresentationRevision
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.refreshProgress() }
            .store(in: &subscriptions)
        controlCenter.$projectionRefreshStates
            .map { $0["kanban.global"] }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshKanbanActivity() }
            .store(in: &subscriptions)
        // The notch remains alive when the workspace is unmounted. Use the
        // same aggregate projection, without board filters or supporting reads.
        Timer.publish(every: 5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                self?.pollKanban(force: false)
                self?.pollDeliveryQuestions()
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .hermBotActivity)
            .compactMap { $0.userInfo?["events"] as? [BotActivityEvent] }
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.announceBots($0) }
            .store(in: &subscriptions)
        state.observeAgentUpdates(from: .shared) { [weak self] in
            self?.rebuildTasks()
            self?.position(animated: false)
        }.store(in: &subscriptions)
        controlCenter.$providerQuotas
            .receive(on: RunLoop.main)
            .sink { [weak self] quotas in self?.quotaChanged(quotas) }
            .store(in: &subscriptions)
        // The workspace only polls quota while its Quota page is open; keep
        // reading it (Dock open or closed) so drops surface. Quota is spent
        // by other apps too, so this runs whether or not Hermes is working.
        Timer.publish(every: 30, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.pollQuota() }
            .store(in: &subscriptions)
        model.$currentSessionTitle.combineLatest(model.$runtimeConfiguration, model.$defaultBotName)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                guard let self else { return }
                self.state.name = self.model.agentDisplayName
                self.updateDetail()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.position(animated: false) }
            .store(in: &subscriptions)
        // Launch (login item, display not ready yet) can leave the panel unplaced
        // or unordered; re-assert it whenever the screen/app context settles.
        Publishers.Merge3(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification),
            NotificationCenter.default.publisher(
                for: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared),
            Just(Notification(name: .init("herm.notch.launch"))).delay(for: 1, scheduler: RunLoop.main)
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.ensureNotchVisible() }
        .store(in: &subscriptions)
        // Settings writes the side directly; follow it like a context-menu move.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .compactMap { [weak self] _ in
                self.flatMap { EdgeDockSide(rawValue: $0.defaults.string(forKey: "hermes.notch.side") ?? "") }
            }
            .receive(on: RunLoop.main)
            .sink { [weak self] side in
                guard let self, side != self.state.side else { return }
                self.state.side = side
                self.position(animated: true)
            }
            .store(in: &subscriptions)
        controlCenter.bind(to: model)
        ensureNotchVisible()
    }

    private func ensureNotchVisible() {
        guard !workspacePresented else { return }
        position(animated: false)
        panel.orderFrontRegardless()
    }

    var placement: EdgeDockPlacement? {
        // The top island belongs to the primary (menu-bar) display only; side tabs follow the chosen display.
        let screen =
            state.side == .top
            ? NSScreen.screens.first
            : NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == displayID
            } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return nil }
        displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let notch = EdgeNotchMetrics.notchSize(for: screen)
        if state.notchSize != notch { state.notchSize = notch }
        return EdgeDockPlacement(
            side: state.side, fraction: fraction,
            screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    func prepareForWorkspace() {
        frameTransition.cancel()
        collapseTask?.cancel()
        expandTask?.cancel()
        state.composing = false
        state.previewInteraction.mode = .passive
        previousApplication = nil
        state.expanded = false
        hovering = false
        panel.acceptsWorkspaceFocus = false
        panel.resignKey()
        panel.orderOut(nil)
        petWindow?.hide()
        workspacePresented = true
    }

    func restoreNotch() {
        workspacePresented = false
        state.activity.backgroundCompleted = false
        state.activity.responseCompleted = false
        position(animated: false)
        panel.orderFrontRegardless()
        surfaceDigestIfPossible()
    }

    private func peekResult(_ task: EdgeNotchTask) {
        guard !state.quickSending, task.phase == .finished, task.kanbanTask == nil else { return }
        let session =
            task.session
            ?? (task.isCurrent ? model.sessions.first(where: { model.currentSessionIDs.contains($0.id) }) : nil)
            ?? (task.isCurrent
                ? model.navigationSessionID.map {
                    HermesSession(
                        id: $0, profileID: model.sessionProfileID, title: task.title,
                        preview: "", startedAt: nil, messageCount: 0, source: HermesFeatureIDs.sessionSource)
                } : nil)
        guard let session else { return }
        setQuickMessageFocus(false)
        state.resultTarget = EdgeResultTarget(task: task, session: session)
    }

    private func beginQuickReply(_ task: EdgeNotchTask, target: HermesSession? = nil) {
        guard !state.quickSending, state.quickPreparing == 0 else { return }
        let target =
            target ?? task.session
            ?? (task.isCurrent
                ? model.navigationSessionID.map {
                    HermesSession(
                        id: $0, profileID: model.sessionProfileID, title: task.title,
                        preview: task.detail ?? "", startedAt: nil, messageCount: 0,
                        source: HermesFeatureIDs.sessionSource)
                } : nil)
        guard let target else { return }
        state.resultTarget = nil
        state.selectQuickTarget(target, task: task)
        setQuickMessageFocus(true)
    }

    private func setQuickMessageFocus(_ active: Bool) {
        if active { state.showingDigest = false }
        state.composing = active
        collapseTask?.cancel()
        state.showingAnnouncement = false
        panel.acceptsWorkspaceFocus = active || state.previewInteraction.mode == .keyboard
        if active {
            panel.makeKeyAndOrderFront(nil)
        } else {
            if state.previewInteraction.mode == .keyboard { return }
            panel.resignKey()
            if !hovering { scheduleCollapse(after: 0.4) }
        }
    }

    private func openWorkspace() {
        guard !dragging, Date() >= suppressClickUntil else { return }
        DebugLog.write("workflow: workspace.open")
        state.activity.backgroundCompleted = false
        state.activity.responseCompleted = false
        openDock()
    }

    func openTask(_ task: EdgeNotchTask) {
        guard !dragging, Date() >= suppressClickUntil else { return }
        if let routine = task.routine {
            state.routineTarget = routine
            return
        }
        if let card = task.kanbanTask {
            kanbanActivity.acknowledge(card)
            rebuildTasks()
            openKanban(card)
            return
        }
        guard let session = task.session else { return openWorkspace() }
        if task.isFailure { state.interruptions.clearFailure(owner: session.id, profileID: session.profileID) }
        model.resumeSession(session)
        openDock()
    }

    /// `@Published` sinks fire before the property changes, so the latest
    /// session list is cached from the publisher rather than read back.
    private func refreshNoteworthySessions(_ sessions: [HermesSession]) {
        latestSessions = sessions
        let previous = state.tasks
        rebuildTasks()
        state.interruptions.reconcile(
            profileID: model.profileScopeID, sessions: sessions, kanban: controlCenter.globalKanbanTasks)
        if EdgeNotchTask.newlyFinished(from: previous, to: state.tasks) {
            let previousWorking = Set(previous.filter { $0.phase == .working }.map(\.id))
            for task in state.tasks where task.phase == .finished && previousWorking.contains(task.id) {
                announce(notice: model.interruptionNotice(.completion, owner: task.id))
            }
            pollQuota(afterWork: true)
        }
    }

    /// Every session in progress or finished-but-unopened, with the open
    /// session contributing its own live activity instead of the index flag.
    private func rebuildTasks() {
        let activity = state.activity
        var current: EdgeNotchTask?
        let request = model.currentSessionIDs.compactMap { latestAttention[$0] }.first
        let phase: EdgeNotchTask.Phase? =
            (request != nil || activity.attention)
            ? .attention
            : activity.working ? .working : activity.hasUpdate ? .finished : nil
        if let phase {
            let label: String =
                switch phase {
                case .attention: request?.status.title ?? activity.status.title
                case .working: activity.status == .working ? "Working" : activity.title
                case .pending, .finished: activity.title
                }
            current = EdgeNotchTask(
                id: model.navigationSessionID ?? "current", title: state.sessionTitle, phase: phase,
                statusLabel: label, detail: request?.summary ?? state.detail, updatedAt: nil, isCurrent: true,
                isStatusCurrent: activity.status != .offline, session: nil, choices: request?.choices ?? [],
                attentionRequest: request?.responseTarget,
                profileID: model.activeBotProfileID ?? model.sessionProfileID)
        }
        var tasks = EdgeNotchTask.merged(
            EdgeNotchTask.build(
                current: current, sessions: latestSessions,
                activity: latestActivityLabels,
                currentSessionIDs: model.currentSessionIDs,
                isOnline: activity.status != .offline, attention: latestAttention)
                + EdgeNotchTask.botRows(
                    records: model.botActivityBySessionID[model.sessionStorageID ?? model.sessionID ?? "", default: []],
                    steps: model.botLiveSteps, isOnline: activity.status != .offline,
                    listedSessionIDs: Set(latestSessions.filter { $0.isWorking || $0.hasUnreadUpdate }.map(\.id)))
                + kanbanActivity.rows(isCurrent: kanbanStatusCurrent && activity.status != .offline)
                + deliveryQuestions.map(\.row)
                + controlCenter.routineReferences.filter {
                    $0.needsAttention || state.preferences.routinePins.contains($0.id)
                }.map { reference in
                    var row = reference.row
                    row = EdgeNotchTask(
                        id: row.id, title: row.title, phase: row.phase, statusLabel: row.statusLabel,
                        detail: row.detail, updatedAt: row.updatedAt, isCurrent: false,
                        isStatusCurrent: activity.status != .offline
                            && controlCenter.refreshState(for: "cron.jobs")?.isStale != true,
                        session: nil, routine: reference)
                    return row
                }
        ).map { task in
            var task = task
            if let request = task.attentionRequest { task.answerState = latestAnswers[request] }
            if let question = task.deliveryQuestion { task.answerState = state.deliveryAnswers[question] }
            return task
        }
        // Decisions remain global even when their session is outside the current inventory.
        for request in latestAttention.values {
            guard let target = request.responseTarget,
                !tasks.contains(where: { $0.attentionRequest == target })
            else { continue }
            let session = HermesSession(
                id: target.sessionID, profileID: target.profileID, title: target.sessionID,
                preview: "", startedAt: nil, messageCount: 0, source: HermesFeatureIDs.sessionSource)
            var row = EdgeNotchTask(
                id: session.id, title: session.displayTitle, phase: .attention,
                statusLabel: request.status.title, detail: request.summary, updatedAt: nil, isCurrent: false,
                isStatusCurrent: activity.status != .offline, session: session, choices: request.choices,
                attentionRequest: target)
            row.answerState = latestAnswers[target]
            tasks.append(row)
        }
        for failure in state.interruptions.failures {
            guard
                !tasks.contains(where: {
                    $0.id == failure.sourceID && $0.attentionRequest != nil
                        && $0.attentionRequest?.profileID == failure.profileID
                })
            else { continue }
            let session =
                latestSessions.first { $0.id == failure.sourceID && $0.profileID == failure.profileID }
                ?? HermesSession(
                    id: failure.sourceID, profileID: failure.profileID, title: failure.sourceID,
                    preview: "", startedAt: nil, messageCount: 0, source: HermesFeatureIDs.sessionSource)
            tasks.removeAll {
                $0.id == session.id
                    && ($0.session?.profileID == session.profileID
                        || ($0.isCurrent && model.sessionProfileID == session.profileID))
            }
            tasks.append(
                EdgeNotchTask(
                    id: session.id, title: session.displayTitle, phase: .attention,
                    statusLabel: "Failed", detail: "Open the session to inspect the failure",
                    updatedAt: failure.createdAt,
                    isCurrent: model.sessionProfileID == session.profileID
                        && model.currentSessionIDs.contains(session.id), isStatusCurrent: model.status != .offline,
                    session: session, isFailure: true))
            tasks = EdgeNotchTask.merged(tasks)
        }
        tasks = EdgeNotchTask.merged(tasks)
        if tasks != state.tasks {
            state.invalidateNewerResults(tasks)
            state.tasks = tasks
            position(animated: true)
        }
        controlCenter.pet.updateNotchActivity(
            working: state.railActivity.working || tasks.contains { $0.isStatusCurrent && $0.phase == .working },
            attention: state.railActivity.attention || tasks.contains { $0.isStatusCurrent && $0.phase == .attention })
    }

    /// Headless coordinator turns cannot ask; the delivery plugin queues their questions as files.
    private func pollDeliveryQuestions(force: Bool = false) {
        if force {
            deliveryQuestionPoll?.cancel()
            deliveryQuestionPoll = nil
        }
        // Delivery questions are files in this Mac's Hermes home; a remote backend writes its own.
        guard deliveryQuestionPoll == nil, GatewayConnectionStore.isLocalBackend else { return }
        deliveryQuestionPoll = Task { [weak self] in
            let questions = await EdgeDeliveryQuestion.loadOffMain()
            guard !Task.isCancelled, let self else { return }
            self.deliveryQuestionPoll = nil
            guard questions != self.deliveryQuestions else { return }
            let isNew = questions.contains { !self.deliveryQuestions.contains($0) }
            self.deliveryQuestions = questions
            self.state.deliveryAnswers = self.state.deliveryAnswers.filter { questions.contains($0.key) }
            self.rebuildTasks()
            if isNew {
                for question in questions {
                    self.announce(
                        notice: self.model.interruptionNotice(
                            .clarification, owner: question.row.session?.id, eventID: String(question.hashValue)))
                }
            }
        }
    }

    private func answer(_ task: EdgeNotchTask, choice: String) {
        guard task.isStatusCurrent, task.choices.contains(choice) else { return }
        if let question = task.deliveryQuestion {
            guard deliveryQuestions.contains(question), let session = task.session,
                state.deliveryAnswers[question]?.blocksSubmission != true
            else { return }
            if let reason = model.quickMessageUnavailableReason(for: session) {
                state.deliveryAnswers[question] = .failed(choice, reason)
                rebuildTasks()
                return
            }
            state.deliveryAnswers[question] = .sending(choice)
            rebuildTasks()
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.model.submitQuickDraft(question.answerDraft(choice), progress: { _ in })
                } catch {
                    guard await EdgeDeliveryQuestion.loadOffMain().contains(question) else {
                        self.pollDeliveryQuestions(force: true)
                        return
                    }
                    let message = DockModel.safeUserDiagnostic(error.localizedDescription)
                    self.state.deliveryAnswers[question] =
                        (error as? QuickSubmissionFailure)?.uncertain == true
                        ? .uncertain(choice, message) : .failed(choice, message)
                    self.rebuildTasks()
                    return
                }
                do {
                    guard try await question.removeIfCurrent() else {
                        self.pollDeliveryQuestions(force: true)
                        return
                    }
                } catch {
                    self.state.deliveryAnswers[question] = .answered(
                        choice, "Answer sent. The saved question could not be removed; open the session to review it.")
                    self.rebuildTasks()
                    return
                }
                self.pollDeliveryQuestions(force: true)
            }
            return
        }
        guard let request = task.attentionRequest else { return }
        model.answerAttention(request, choice: choice)
    }

    private func refreshSelectedTasks() {
        pollKanban()
        model.loadSessions()
    }

    /// Idle polls are throttled to once a minute: each aggregate read pulls and
    /// re-diffs every board, which kept the CPU (and the Hermes backend) busy
    /// every 5s even with nothing happening. Live work keeps the 5s cadence.
    private func pollKanban(force: Bool = true) {
        guard model.status != .offline else { return }
        if !force, !state.activity.working,
            let last = lastKanbanPoll, Date().timeIntervalSince(last) < 60
        {
            return
        }
        lastKanbanPoll = Date()
        controlCenter.refreshGlobalKanban(trigger: .background)
        guard !loadingBots, lastBotRead.map({ Date().timeIntervalSince($0) >= 15 }) ?? true else { return }
        loadingBots = true
        lastBotRead = Date()
        Task {
            defer { loadingBots = false }
            let service = BotService(client: model.controlRPCClient)
            let inventory = await service.list()
            guard inventory.availability == .ready else { return }
            let events = BotActivityEvent.events(from: state.bots, to: inventory.bots, excluding: model.profileScopeID)
            state.bots = inventory.bots
            announceBots(events)
            for bot in inventory.bots where bot.hasAvatar && state.avatarImages[bot.id] == nil {
                if let data = await service.avatarImageData(profileID: bot.id) { state.avatarImages[bot.id] = data }
            }
        }
    }

    private func refreshKanbanActivity() {
        let previousCards = state.tasks.filter { $0.kanbanTask != nil }
        guard let refresh = controlCenter.refreshState(for: "kanban.global") else {
            kanbanActivity = EdgeKanbanActivity()
            lastKanbanRead = nil
            kanbanStatusCurrent = false
            state.kanbanUnavailable = false
            rebuildTasks()
            return
        }
        // Keep the last status while a read is in flight; only a failed read
        // makes it stale. Visible-board refreshes have a separate freshness key.
        guard !refresh.isRefreshing else { return }
        kanbanStatusCurrent = refresh.lastSuccess != nil && !refresh.isStale && refresh.error == nil
        state.kanbanUnavailable = !kanbanStatusCurrent
        var changed = false
        if kanbanStatusCurrent, refresh.lastSuccess != lastKanbanRead {
            changed = kanbanActivity.ingest(controlCenter.globalKanbanTasks)
            lastKanbanRead = refresh.lastSuccess
        }
        rebuildTasks()
        state.interruptions.reconcile(
            profileID: model.profileScopeID, sessions: latestSessions, kanban: controlCenter.globalKanbanTasks)
        if changed {
            for task in state.tasks where task.kanbanTask != nil && !previousCards.contains(task) {
                guard let card = task.kanbanTask else { continue }
                let kind: HermNotice.Kind = card.status == "blocked" ? .failure : .information
                announce(
                    notice: HermNotice(
                        kind: kind, source: .kanban, profileID: model.profileScopeID,
                        sourceID: card.id, eventID: UUID().uuidString, boardSlug: card.boardSlug))
            }
        }
    }

    private func refresh(status: HermesStatus, unread: Bool, tasks: [HermesBackgroundTask]) {
        let completed = Set(tasks.filter { $0.status == .completed }.map(\.id))
        let newCompletion = completedTaskIDs.map { !completed.subtracting($0).isEmpty } ?? false
        completedTaskIDs = completed
        let previous = state.activity
        let responseFinished =
            previous.status == .working && status == .idle
            && model.messages.last?.role == .hermes
        state.activity = EdgeNotchActivity(
            status: status, unread: unread,
            runningCount: tasks.filter { $0.status == .running }.count,
            backgroundCompleted: newCompletion || (previous.backgroundCompleted && !completed.isEmpty),
            responseCompleted: responseFinished || (previous.responseCompleted && status != .working))
        updateDetail()
        if state.activity.shouldAnnounce(after: previous) || newCompletion || responseFinished {
            announce(
                notice: model.interruptionNotice(
                    model.messages.last?.isError == true
                        ? .failure
                        : state.activity.attention
                            ? (status == .needsApproval ? .approval : .clarification)
                            : responseFinished || newCompletion ? .completion : .information))
        } else {
            position(animated: true)
        }
        if newCompletion || responseFinished { pollQuota(afterWork: true) }
    }

    private func refreshProgress() {
        guard state.activity.working else { return }
        guard let tool = model.activeToolCalls.last else { return }
        let changed = tool.id != latestToolID || tool.isComplete != latestToolComplete
        latestToolID = tool.id
        latestToolComplete = tool.isComplete
        guard changed else { return }
        updateDetail()
        // Tool/activity completions update the detail text in place but must
        // not pop the notch open; only a finished response (or an already
        // expanded preview) should surface. This keeps the quickview from
        // announcing on every tool call within a session.
        if state.expanded {
            position(animated: true)
        }
    }

    private func loadQuota() {
        collapseTask?.cancel()
        controlCenter.bind(to: model)
        guard controlCenter.refreshState(for: "provider.quota")?.isRefreshing != true else { return }
        let lastRead = controlCenter.providerQuotas.map(\.updatedAt).max()
        if lastRead == nil || Date().timeIntervalSince(lastRead!) > 60 {
            controlCenter.refreshProviderQuota()
        }
    }

    /// Every 30s tick reads the providers being spent; every other tick
    /// reads them all, so a provider that starts moving is picked up. Right
    /// after work finishes, the spent providers are read at once so their
    /// final usage joins the completion preview.
    private func pollQuota(afterWork: Bool = false) {
        // Keeps reading while the workspace is open: the chat header shows it too.
        guard controlCenter.refreshState(for: "provider.quota")?.isRefreshing != true else { return }
        controlCenter.bind(to: model)
        quotaTick &+= 1
        let fullRead = hotQuotaReaders.isEmpty || (!afterWork && quotaTick.isMultiple(of: 2))
        controlCenter.refreshProviderQuota(only: fullRead ? nil : hotQuotaReaders, quiet: !afterWork)
    }

    private func quotaChanged(_ quotas: [ProviderQuotaSnapshot]) {
        // An empty list is a reset (rebind or failed read), not a reading.
        guard !quotas.isEmpty else { return }
        defer { lastQuotas = quotas }
        if let previousQuotas = lastQuotas {
            for provider in EdgeQuotaBands.movedProviders(from: previousQuotas, to: quotas) {
                if let reader = controlCenter.quotaReaderID(for: provider) { hotQuotaReaders.insert(reader) }
            }
        }
        guard let previousQuotas = lastQuotas,
            let provider = EdgeQuotaBands.droppedProvider(
                from: EdgeQuotaBands.bands(previousQuotas),
                to: EdgeQuotaBands.bands(quotas)),
            let previous = previousQuotas.first(where: { $0.provider == provider }),
            let current = quotas.first(where: { $0.provider == provider })
        else { return }
        state.quotaChange = EdgeQuotaChange(previous: previous, current: current)
        announce(
            quota: true,
            notice: HermNotice(
                kind: .quota, source: .quota, profileID: nil,
                sourceID: provider, eventID: String(current.updatedAt.timeIntervalSince1970)))
    }

    /// Both the roster poll here and the workspace's post the same events; the
    /// stamp-based notice id lets `admit` drop the duplicate.
    private func announceBots(_ events: [BotActivityEvent]) {
        for event in events {
            _ = state.interruptions.admit(
                HermNotice(
                    kind: .information, source: .activity, profileID: event.botID,
                    sourceID: "bot", eventID: event.id + "/" + event.stamp), channel: .notch)
        }
    }

    private func updateDetail() {
        state.sessionTitle = model.currentSessionTitle ?? (model.sessionID == nil ? "Herm" : "Current session")
        state.updateTitle = state.activity.title
        if state.activity.attention {
            state.detail = "Open this session to review and respond"
        } else if state.activity.working, let tool = model.activeToolCalls.last {
            let step = ToolStep.describe(tool)
            state.detail = [step.title, step.detail].compactMap { $0 }.joined(separator: " · ")
        } else if state.activity.backgroundCompleted {
            state.detail = "Open this session to review its result"
        } else if state.activity.working {
            state.detail = "Working on this session’s request"
        } else if let response = model.messages.last(where: { $0.role == .hermes }),
            !GenerativeUIIntegration.readableText(response).isEmpty
        {
            let summary = replySummaries[response.id]
            state.detail =
                summary.map { "\(OnDeviceAssist.attribution) · \($0)" }
                ?? String(GenerativeUIIntegration.readableText(response).prefix(180))
            summarizeIfEnabled(response)
            if state.activity.quiet {
                state.updateTitle =
                    summary == nil ? "Latest update" : "Latest update · \(OnDeviceAssist.attribution) summary"
            }
        } else {
            state.updateTitle = "No activity yet"
            state.detail =
                model.sessionID == nil
                ? "Choose a session to see its activity." : "Updates will appear as work begins in this session."
        }
        rebuildTasks()
    }

    /// On-device one-liners keyed by reply; computed once per reply, and the plain excerpt shows until one arrives.
    private var replySummaries: [UUID: String] = [:]
    private var summarizing: Set<UUID> = []

    private func summarizeIfEnabled(_ reply: ChatMessage) {
        guard UserDefaults.standard.bool(forKey: OnDeviceAssist.summarizeRepliesKey),
            GenerativeUIIntegration.readableText(reply).count > 200, replySummaries[reply.id] == nil,
            summarizing.insert(reply.id).inserted
        else { return }
        Task { [weak self] in
            let summary = await OnDeviceAssist.summarizeReply(GenerativeUIIntegration.readableText(reply))
            guard let self else { return }
            self.summarizing.remove(reply.id)
            guard let summary else { return }
            self.replySummaries[reply.id] = summary
            self.updateDetail()
        }
    }

    private func routineUpdates() {
        let profile = controlCenter.routineProfileID
        let references = controlCenter.routineReferences
        state.interruptions.reconcileRoutines(profileID: profile, jobIDs: Set(references.map { $0.job.id }))
        let previouslyObserved = observedRoutineProfiles.contains(profile ?? "")
        if !references.isEmpty { observedRoutineProfiles.insert(profile ?? "") }
        for reference in references {
            guard let stamp = reference.run?.id ?? reference.job.lastRunAt else { continue }
            let event =
                stamp + "/" + (reference.run?.status ?? reference.job.lastStatus ?? "") + "/"
                + SHA256.hash(data: Data((reference.job.details.deliveryError ?? "").utf8)).map {
                    String(format: "%02x", $0)
                }.joined()
            let prior = routineEvents.updateValue(event, forKey: reference.id)
            guard previouslyObserved, prior != event, !reference.running else { continue }
            let notice = HermNotice(
                kind: reference.needsAttention ? .failure : .completion, source: .routine,
                profileID: profile, sourceID: reference.job.id, eventID: event)
            model.publishWorkflowNotice(notice, body: reference.job.name)
            announce(notice: notice)
        }
    }

    private func openDigestSource(_ notice: HermNotice) {
        guard !notice.unavailable || notice.canCheckCompletedSession else { return }
        switch notice.source {
        case .quota:
            state.showingDigest = false
            state.interruptions.review(notice.id)
            openQuota()
        case .session:
            guard
                let session = notice.completedSession(in: latestSessions)
                    ?? latestSessions.first(where: { $0.id == notice.sourceID && $0.profileID == notice.profileID })
            else {
                state.interruptions.markUnavailable(notice.id)
                return
            }
            state.showingDigest = false
            let task = EdgeNotchTask(
                id: session.id, title: session.displayTitle, phase: session.isWorking ? .working : .finished,
                statusLabel: session.isWorking ? "Working" : "Finished", detail: session.displayPreview,
                updatedAt: session.lastUpdatedAt,
                isCurrent: model.sessionProfileID == session.profileID && model.currentSessionIDs.contains(session.id),
                isStatusCurrent: model.status != .offline, session: session)
            if notice.kind == .completion, !session.isWorking {
                state.digestResultID = notice.id
                peekResult(task)
            } else {
                state.interruptions.review(notice.id)
                openTask(task)
            }
        case .kanban:
            guard notice.profileID == model.profileScopeID,
                let card = controlCenter.globalKanbanTasks.first(where: {
                    $0.id == notice.sourceID && $0.boardSlug == notice.boardSlug
                })
            else {
                state.interruptions.markUnavailable(notice.id)
                return
            }
            state.showingDigest = false
            state.interruptions.review(notice.id)
            openKanban(card)
        case .routine:
            guard
                let reference = controlCenter.routineReferences.first(where: {
                    $0.profileID == notice.profileID && $0.job.id == notice.sourceID
                })
            else {
                state.interruptions.markUnavailable(notice.id)
                return
            }
            state.showingDigest = false
            state.routineTarget = reference
            state.interruptions.review(notice.id)
        case .repository:
            guard FileManager.default.fileExists(atPath: notice.sourceID) else {
                state.interruptions.markUnavailable(notice.id)
                return
            }
            state.showingDigest = false
            state.interruptions.review(notice.id)
            ExternalOpen.reveal([URL(fileURLWithPath: notice.sourceID)])
        case .activity:
            state.showingDigest = false
            state.interruptions.review(notice.id)
            openWorkspace()
        }
    }

    private func surfaceDigestIfPossible() {
        guard state.interruptions.pendingDigest, !workspacePresented, !dragging, !petDragging,
            !state.composing, !hovering, !state.isReadingDetail, state.previewInteraction.mode == .passive
        else { return }
        state.showingDigest = true
        state.interruptions.consumeDigestAnnouncement()
        announce(
            notice: HermNotice(
                kind: .information, source: .activity, profileID: nil,
                sourceID: "digest", eventID: String(state.interruptions.digestPresentationRevision)))
    }

    private func announce(quota: Bool = false, notice: HermNotice? = nil) {
        let reference =
            notice ?? model.interruptionNotice(state.sessionRailActivity.attention ? .failure : .information)
        guard state.interruptions.admit(reference, channel: .notch) else { return }
        guard !workspacePresented, !dragging, !petDragging, !state.composing, !state.isReadingDetail,
            state.previewInteraction.mode == .passive
        else { return }
        // Every notch announcement, including future sources, reaches the pet here.
        controlCenter.pet.react(.announcement(activity: state.sessionRailActivity, quota: quota))
        DebugLog.write("workflow: notch announcement presented")
        if !hovering {
            // Updates landing while one is showing join it rather than replace it.
            if !state.showingAnnouncement {
                state.announcesTasks = false
                state.announcesQuota = false
                state.glimpseIDs = []
            }
            state.showingAnnouncement = true
            if quota {
                state.announcesQuota = true
            } else {
                state.announcesTasks = true
                if let notice { state.glimpseIDs.append(notice.sourceID) }
            }
        }
        state.expanded = true
        position(animated: true)
        scheduleCollapse(after: 6)
    }

    private func hoverChanged(_ value: Bool) {
        guard !workspacePresented, !dragging, !petDragging else { return }
        hovering = value
        collapseTask?.cancel()
        expandTask?.cancel()
        if value {
            state.showingAnnouncement = false
            // Delay expansion long enough for a drag gesture to register before
            // the view hierarchy changes from rail (with drag gesture) to preview;
            // 80ms was too short for a user to start moving the notch before it
            // expanded out from under the cursor. It also lets a click on the rail
            // open the workspace before the hover preview ever appears.
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.hovering, !self.dragging, !self.petDragging else { return }
                self.setExpanded(true)
            }
            expandTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: task)
        } else {
            surfaceDigestIfPossible()
            if !state.showingAnnouncement { scheduleCollapse(after: 0.4) }
        }
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        collapseTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering, !self.dragging, !self.workspacePresented, !self.state.composing,
                self.state.previewInteraction.mode == .passive,
                !self.panel.frame.contains(NSEvent.mouseLocation)
            else { return }
            guard self.panel.attachedSheet == nil, !self.panel.dockHasInteractiveChildWindow else {
                self.scheduleCollapse(after: 0.4)
                return
            }
            self.state.showingAnnouncement = false
            self.state.activity.backgroundCompleted = false
            self.state.activity.responseCompleted = false
            self.setExpanded(false)
        }
        collapseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    /// Explicit keyboard invocation owns focus until dismissal; hovering remains passive.
    func toggleQuickPreview() {
        guard !workspacePresented, !dragging, !petDragging else { return }
        if state.expanded, state.previewInteraction.mode == .keyboard {
            return dismissKeyboardPreview(returnFocus: true)
        }
        previousApplication = NSWorkspace.shared.frontmostApplication
        if previousApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previousApplication = nil
        }
        expandTask?.cancel()
        state.previewInteraction.mode = .keyboard
        state.previewInteraction.reconcile(
            previous: [], current: state.tasks.map { $0.previewIdentity(currentProfileID: model.sessionProfileID) })
        state.showingAnnouncement = false
        setExpanded(true)
        panel.acceptsWorkspaceFocus = true
        panel.makeKeyAndOrderFront(nil)
    }

    /// Opens the notch with a new-message composer focused, or closes it if it is already composing.
    func toggleQuickCapture() {
        guard !workspacePresented, !dragging, !petDragging else { return }
        if state.composing { return escapePreview() }
        previousApplication = NSWorkspace.shared.frontmostApplication
        if previousApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previousApplication = nil
        }
        expandTask?.cancel()
        state.previewInteraction.mode = .keyboard
        state.previewInteraction.reconcile(
            previous: [], current: state.tasks.map { $0.previewIdentity(currentProfileID: model.sessionProfileID) })
        state.showingAnnouncement = false
        setExpanded(true)
        state.selectQuickTarget(nil)
        setQuickMessageFocus(true)
    }

    func captureWindow() {
        if workspacePresented {
            model.captureDesktopWindow()
            return
        }
        // Capture first, before taking focus away from the originating application.
        if !state.composing { state.selectQuickTarget(nil) }
        state.captureWindow { [weak self] in
            guard let self else { return }
            expandTask?.cancel()
            setExpanded(true)
            setQuickMessageFocus(true)
        }
    }

    private func escapePreview() {
        guard NSApp.modalWindow == nil, panel.attachedSheet == nil, !panel.dockHasInteractiveChildWindow else { return }
        if state.showingResultComparison {
            state.showingResultComparison = false
            return
        }
        if state.composing || state.isReadingDetail || state.showingDigest {
            if !state.quickSending {
                state.draftStore.save(state.captureRecord())
                state.draftStore.flush()
            }
            state.clearPreviewDetails()
            setQuickMessageFocus(false)
        } else {
            dismissKeyboardPreview(returnFocus: true)
        }
    }

    private func dismissKeyboardPreview(returnFocus: Bool) {
        let previous = previousApplication
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        previousApplication = nil
        setExpanded(false)
        if returnFocus, let previous, !previous.isTerminated,
            frontmost == ProcessInfo.processInfo.processIdentifier || frontmost == previous.processIdentifier
        {
            previous.activate(options: [])
        }
    }

    private func installInteractionMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: mask,
            handler: { [weak self] _ in
                Task { @MainActor in self?.outsidePreviewClick() }
            })
        {
            interactionMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(
            matching: mask,
            handler: { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, event.window?.level != .popUpMenu,
                        event.window !== self.panel, event.window?.parent !== self.panel
                    {
                        self.outsidePreviewClick()
                    }
                }
                return event
            })
        {
            interactionMonitors.append(monitor)
        }
    }

    private func outsidePreviewClick() {
        guard state.previewInteraction.mode == .keyboard, NSApp.modalWindow == nil, panel.attachedSheet == nil,
            !panel.dockHasInteractiveChildWindow, !panel.frame.contains(NSEvent.mouseLocation)
        else { return }
        if !state.quickSending {
            state.draftStore.save(state.captureRecord())
            state.draftStore.flush()
        }
        dismissKeyboardPreview(returnFocus: false)
    }

    func shutdown() {
        interactionMonitors.forEach(NSEvent.removeMonitor)
        interactionMonitors = []
    }

    private func setExpanded(_ expanded: Bool) {
        guard !workspacePresented else { return }
        collapseTask?.cancel()
        if !expanded {
            state.previewInteraction.mode = .passive
            state.clearPreviewDetails()
            state.composing = false
            panel.acceptsWorkspaceFocus = false
            panel.resignKey()
        }
        state.expanded = expanded
        updateDetail()
        position(animated: true)
    }

    private func moveNotch(ended: Bool) {
        guard !workspacePresented else { return }
        collapseTask?.cancel()
        expandTask?.cancel()
        dragging = !ended
        hovering = false
        state.expanded = false
        (ended ? NSCursor.arrow : NSCursor.closedHand).set()
        let point = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let location = EdgeDockPlacement.dragged(
                to: point, screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                allowsTop: screen == NSScreen.screens.first)
            displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            state.side = location.side
            fraction = location.fraction
            position(animated: false)
        }
        if ended {
            suppressClickUntil = Date().addingTimeInterval(0.4)
            persistPlacement()
            surfaceDigestIfPossible()
        }
    }

    private func persistPlacement() {
        defaults.set(state.side.rawValue, forKey: "hermes.notch.side")
        defaults.set(fraction, forKey: "hermes.notch.position")
        defaults.set(displayID, forKey: "hermes.notch.display")
    }

    private func position(animated: Bool) {
        guard let placement else { return }
        notchHost?.bottomHoverExclusion = state.side == .top ? 0 : state.petReserve
        let target = placement.frame(width: state.panelSize.width, height: state.panelSize.height).integral
        // On top the pet docks just right of the collapsed island, under the menu bar.
        let home =
            state.side == .top
            ? NSPoint(
                x: placement.screenFrame.midX + state.collapsedSize.width / 2 + 4,
                y: placement.screenFrame.maxY - state.notchSize.height - 44)
            : NSPoint(x: state.side == .right ? target.maxX - 44 : target.minX, y: target.minY)
        petWindow?.update(home: home, screen: placement.visibleFrame, visible: !workspacePresented, side: state.side)
        frameTransition.position(
            to: target, animated: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    static func frame(screenFrame: NSRect, visibleFrame: NSRect, expanded: Bool, railHeight: CGFloat = 136) -> NSRect {
        EdgeDockPlacement(screenFrame: screenFrame, visibleFrame: visibleFrame)
            .frame(
                width: expanded ? EdgeNotchState.expandedSize.width : 72,
                height: expanded ? max(EdgeNotchState.expandedSize.height, railHeight) : railHeight)
    }
}

struct EdgeNotchActivity: Equatable {
    var status: HermesStatus = .idle
    var unread = false
    var runningCount = 0
    var backgroundCompleted = false
    var responseCompleted = false
    var kanbanRunningCount = 0
    /// Every task row currently working (sessions, background, Kanban); the exact number the Count style shows.
    var workingCount = 0
    var sessionNeedsAttention = false
    var kanbanNeedsAttention = false
    var kanbanHasUpdate = false
    var agentUpdatePhase: HermesUpdatePhase = .idle
    /// Marks the status indicator stacks: the primary plus finished/blocked extras.
    var markCount: Int {
        working ? 1 + (hasUpdate ? 1 : 0) + (attention ? 1 : 0) : hasUpdate && attention ? 2 : 1
    }
    var hasUpdate: Bool { unread || backgroundCompleted || responseCompleted || kanbanHasUpdate }
    var quiet: Bool { !working && !attention && !hasUpdate && status == .idle }

    func shouldAnnounce(after previous: Self) -> Bool {
        (working && !previous.working) || runningCount != previous.runningCount
            || (unread && !previous.unread) || (attention && status != previous.status)
    }

    var working: Bool {
        status == .working || runningCount > 0 || workingCount > 0 || kanbanRunningCount > 0
            || agentUpdatePhase.ambientStatus?.isRunning == true
    }
    var attention: Bool {
        status == .needsApproval || status == .needsClarification || kanbanNeedsAttention || sessionNeedsAttention
            || agentUpdatePhase.ambientStatus?.isRunning == false
    }
    var title: String {
        if status == .needsApproval || status == .needsClarification { return status.title }
        if sessionNeedsAttention { return "Needs your attention" }
        if kanbanNeedsAttention { return "Kanban card blocked" }
        if let update = agentUpdatePhase.ambientStatus { return update.title }
        if unread { return "New response" }
        if backgroundCompleted { return "Background task completed" }
        if responseCompleted { return "Response completed" }
        if runningCount > 0 { return "\(runningCount) background \(runningCount == 1 ? "task" : "tasks") running" }
        if status == .working || status == .offline { return status.title }
        if kanbanRunningCount > 0 {
            return "\(kanbanRunningCount) Kanban \(kanbanRunningCount == 1 ? "card" : "cards") running"
        }
        if kanbanHasUpdate { return "Kanban activity updated" }
        return "Open Herm"
    }
    var symbol: Ph {
        if kanbanNeedsAttention || sessionNeedsAttention { return .warningCircle }
        if status == .needsClarification { return DockActivityState.clarification.icon! }
        if status != .needsApproval && agentUpdatePhase.ambientStatus?.isRunning == false { return .warningCircle }
        if attention { return status.icon }
        if unread { return .chat }
        if backgroundCompleted { return .checkCircle }
        if responseCompleted || kanbanHasUpdate { return .dot }
        return status == .offline ? .wifiSlash : .sidebarSimple
    }
}

/// Quota surfaces when a window's remaining share falls into a lower 10-point
/// band (crossing 90%, 80%, … 0%), so steady use announces a handful of times
/// per window rather than on every refresh. Resets only raise the baseline.
enum EdgeQuotaBands {
    static func bands(_ quotas: [ProviderQuotaSnapshot]) -> [String: Int] {
        var bands: [String: Int] = [:]
        for snapshot in quotas {
            for window in snapshot.windows {
                guard let remaining = window.remainingPercent, remaining.isFinite else { continue }
                bands["\(snapshot.provider)/\(window.id)"] = Int((min(100, max(0, remaining)) / 10).rounded(.up))
            }
        }
        return bands
    }

    static func dropped(from previous: [String: Int], to current: [String: Int]) -> Bool {
        droppedProvider(from: previous, to: current) != nil
    }

    /// Providers whose remaining share fell at all since the last reading.
    static func movedProviders(from previous: [ProviderQuotaSnapshot], to current: [ProviderQuotaSnapshot]) -> [String]
    {
        current.filter { snapshot in
            guard let old = previous.first(where: { $0.provider == snapshot.provider }) else { return false }
            return snapshot.windows.contains { window in
                guard let now = window.remainingPercent,
                    let before = old.windows.first(where: { $0.id == window.id })?.remainingPercent
                else { return false }
                return now < before
            }
        }.map(\.provider)
    }

    /// The provider whose window fell the most bands, so an announcement
    /// shows one provider rather than the whole inventory.
    static func droppedProvider(from previous: [String: Int], to current: [String: Int]) -> String? {
        current.compactMap { key, band -> (provider: String, drop: Int)? in
            guard let old = previous[key], band < old else { return nil }
            return (String(key.prefix { $0 != "/" }), old - band)
        }.max { $0.drop < $1.drop }?.provider
    }
}

@MainActor
final class EdgeNotchState: ObservableObject {
    @Published var previewInteraction = EdgePreviewInteraction()
    @Published var showingResultComparison = false
    var isReadingDetail: Bool {
        resultTarget != nil || routineTarget != nil || capacityTarget != nil || steeringTarget != nil || showingRecall
    }
    func clearPreviewDetails() {
        showingResultComparison = false
        resultTarget = nil
        routineTarget = nil
        capacityTarget = nil
        steeringTarget = nil
        showingRecall = false
        showingDigest = false
    }
    @Published var capacitySnapshots: [String: SessionCapacitySnapshot] = [:]
    @Published var steeringTarget: HermesSession?
    @Published var capacityTarget: HermesSession?
    func insertRecall(_ hit: RecallHit) {
        guard !quickSending, !quickNeedsReview else {
            quickResult = "Review the interrupted draft before inserting material."
            return
        }
        quickDraft += (quickDraft.isEmpty ? "" : "\n\n") + hit.snippet
        let reference = "Source conversation: \(hit.session.profileID ?? "Launch profile")/\(hit.session.id)"
        if !quickSources.contains(reference) {
            quickSources.append(reference)
            saveQuickDraft()
        }
        showingRecall = false
        composing = true
    }
    @Published var recallProfileID: String?
    @Published var showingRecall = false
    private var preferenceSubscription: AnyCancellable?
    let preferences: CommandCenterPreferencesStore
    @Published var routineTarget: RoutineReference?
    let interruptions: HermInterruptionCoordinator
    @Published var showingDigest = false
    var digestResultID: String?
    private var interruptionSubscription: AnyCancellable?
    @Published var resultTarget: EdgeResultTarget?
    private var resultCache: [String: EdgeResultContent] = [:]
    private var resultCacheOrder: [String] = []
    private func resultKey(_ target: EdgeResultTarget) -> String {
        target.id + "/" + String(target.session.lastUpdatedAt?.timeIntervalSince1970 ?? 0) + "/"
            + (target.task.detail ?? "")
    }
    func cachedResult(_ target: EdgeResultTarget) -> EdgeResultContent? { resultCache[resultKey(target)] }
    func cacheResult(_ content: EdgeResultContent, for target: EdgeResultTarget) {
        let key = resultKey(target)
        resultCache[key] = content
        resultCacheOrder.removeAll { $0 == key }
        resultCacheOrder.append(key)
        while resultCacheOrder.count > 8 { resultCache.removeValue(forKey: resultCacheOrder.removeFirst()) }
    }
    func clearResult(_ target: EdgeResultTarget) { resultCache.removeValue(forKey: resultKey(target)) }
    func invalidateNewerResults(_ incoming: [EdgeNotchTask]) {
        for task in incoming {
            guard let old = tasks.first(where: { $0.presentationID == task.presentationID }), old != task else {
                continue
            }
            for key in resultCache.keys.filter({ $0.hasPrefix("\(task.session?.profileID ?? "")/\(task.id)/") }) {
                resultCache.removeValue(forKey: key)
            }
        }
    }
    @Published var composing = false
    @Published var quickTarget: HermesSession?
    @Published var quickReplyTask: EdgeNotchTask?
    @Published var quickCreatedSession: HermesSession?
    @Published var quickTranscriptRevision = 0
    let draftStore: QuickDraftStore
    private var draftSubscription: AnyCancellable?
    private var applyingDraft = false
    private var quickRecordID: UUID?
    @Published private(set) var quickProfileID: String?
    @Published var quickFiles: [QuickDraftFile] = []
    @Published var quickPreparing = 0
    @Published var quickSources: [String] = []
    @Published private(set) var quickNeedsReview = false
    @Published private(set) var quickProjectPath: String?

    init(
        store: QuickDraftStore? = nil, interruptions: HermInterruptionCoordinator? = nil,
        preferences: CommandCenterPreferencesStore? = nil
    ) {
        self.preferences = preferences ?? .shared
        draftStore = store ?? QuickDraftStore()
        self.interruptions = interruptions ?? HermInterruptionCoordinator()
        draftSubscription = draftStore.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        interruptionSubscription = self.interruptions.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        preferenceSubscription = self.preferences.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send()
        }
    }

    var recoverableDrafts: [QuickDraftRecord] {
        draftStore.records.filter { $0.savedName == nil && $0.destination.profileID == quickProfileID }.sorted {
            $0.updatedAt > $1.updatedAt
        }
    }

    var savedPrompts: [QuickDraftRecord] {
        draftStore.records.filter { $0.savedName != nil && $0.destination.profileID == quickProfileID }.sorted {
            ($0.savedName ?? "") < ($1.savedName ?? "")
        }
    }

    func captureRecord() -> QuickDraftRecord {
        var record =
            quickRecordID.flatMap { id in draftStore.records.first { $0.id == id } }
            ?? QuickDraftRecord(
                id: quickRecordID ?? UUID(),
                destination: QuickDestination(
                    profileID: quickTarget?.profileID ?? quickProfileID,
                    sessionID: quickTarget?.id, title: quickTarget?.displayTitle ?? "New session",
                    projectPath: quickProjectPath))
        record.text = quickDraft
        record.files = quickFiles
        record.sources = quickSources
        quickRecordID = record.id
        return record
    }

    private func saveQuickDraft() {
        guard !applyingDraft, !quickSending else { return }
        var record = captureRecord()
        record.revision = UUID()
        draftStore.save(record)
    }

    func restoreQuickDraft(_ record: QuickDraftRecord) {
        guard !quickSending, quickPreparing == 0 else { return }
        if record.savedName != nil {
            guard !quickNeedsReview else {
                quickResult = "Review the interrupted draft before inserting a saved prompt."
                return
            }
            guard !record.files.contains(where: { $0.kind == .pdf }) || !quickFiles.contains(where: { $0.kind == .pdf })
            else {
                quickResult = "Keep or remove the existing PDF before inserting this saved prompt."
                return
            }
            quickDraft +=
                (quickDraft.isEmpty ? "" : "\n\n") + ChatContext.prompt(record.text, contexts: record.contexts ?? [])
            for file in record.files
            where !quickFiles.contains(where: { $0.digest == file.digest && $0.name == file.name }) {
                quickFiles.append(file)
            }
            quickSources += record.sources
            saveQuickDraft()
            composing = true
            return
        }
        applyingDraft = true
        quickRecordID = record.id
        quickTarget = record.destination.session
        quickCreatedSession = record.destination.session
        quickReplyTask = nil
        quickProfileID = record.destination.profileID
        quickProjectPath = record.destination.projectPath
        quickDraft = record.text
        quickFiles = record.files
        quickSources = record.sources
        quickNeedsReview = record.delivery == .needsReview
        quickResult =
            quickNeedsReview ? "Interrupted submission. Open the session to review it before sending again." : nil
        applyingDraft = false
    }

    func switchQuickProfile(_ profile: String?) {
        guard !quickSending, quickPreparing == 0 else { return }
        saveQuickDraft()
        applyingDraft = true
        quickProfileID = profile
        quickRecordID = nil
        quickTarget = nil
        quickReplyTask = nil
        quickCreatedSession = nil
        quickDraft = ""
        quickFiles = []
        quickSources = []
        quickNeedsReview = false
        quickProjectPath = nil
        quickResult = nil
        composing = false
        applyingDraft = false
    }

    func setQuickProject(_ path: String?) {
        guard !quickSending, quickPreparing == 0, quickTarget == nil, quickCreatedSession == nil else { return }
        saveQuickDraft()
        applyingDraft = true
        quickRecordID = nil
        quickDraft = ""
        quickFiles = []
        quickSources = []
        quickNeedsReview = false
        quickProjectPath = path
        applyingDraft = false
        if let saved = draftStore.records.first(where: {
            $0.savedName == nil && $0.destination.key == captureRecord().destination.key
        }) {
            restoreQuickDraft(saved)
        }
    }

    func captureWindow(completion: @escaping () -> Void = {}) {
        guard !quickSending, !quickNeedsReview else { return }
        let owner = captureRecord().id
        quickPreparing += 1
        Task { @MainActor in
            defer {
                quickPreparing -= 1
                completion()
            }
            do {
                let captured = try await DesktopCaptureService.shared.capture()
                guard let data = captured.image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                    let png = bitmap.representation(using: .png, properties: [:])
                else { throw QuickDraftError.message("The capture could not be prepared.") }
                let file = try await draftStore.pasteImage(png)
                guard captureRecord().id == owner else {
                    draftStore.removeOwned(file.fallbackURL)
                    return
                }
                quickFiles.append(file)
                quickSources.append(captured.context)
                saveQuickDraft()
            } catch { if captureRecord().id == owner { quickResult = error.localizedDescription } }
        }
    }

    func stageQuickFiles(_ urls: [URL]) {
        guard !quickSending, !quickNeedsReview else { return }
        let recordID = captureRecord().id
        quickPreparing += 1
        Task {
            defer { quickPreparing -= 1 }
            for url in urls {
                do {
                    let file = try await QuickDraftFile.capture(url)
                    guard quickRecordID == recordID, !quickSending else { return }
                    guard file.kind != .pdf || !quickFiles.contains(where: { $0.kind == .pdf }) else {
                        quickResult = "Only one PDF can be staged in a quick draft."
                        continue
                    }
                    if !quickFiles.contains(where: { $0.digest == file.digest && $0.name == file.name }) {
                        quickFiles.append(file)
                    }
                    saveQuickDraft()
                } catch { quickResult = DockModel.safeUserDiagnostic(error.localizedDescription) }
            }
        }
    }

    func stageQuickImage(_ data: Data) {
        guard !quickSending, !quickNeedsReview else { return }
        let recordID = captureRecord().id
        quickPreparing += 1
        Task {
            defer { quickPreparing -= 1 }
            do {
                let file = try await draftStore.pasteImage(data)
                guard quickRecordID == recordID, !quickSending else {
                    draftStore.removeOwned(file.fallbackURL)
                    return
                }
                quickFiles.append(file)
                saveQuickDraft()
            } catch { quickResult = DockModel.safeUserDiagnostic(error.localizedDescription) }
        }
    }

    func removeQuickFile(_ file: QuickDraftFile) {
        guard !quickSending, !quickNeedsReview, !file.uploaded else { return }
        quickFiles.removeAll { $0.id == file.id }
        saveQuickDraft()
        if file.owned { draftStore.removeOwned(file.fallbackURL) }
    }

    func addQuickSource(_ value: String) {
        guard !quickSending, !quickNeedsReview, let url = URL(string: value),
            ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { return }
        if !quickSources.contains(value) {
            quickSources.append(value)
            saveQuickDraft()
        }
    }

    func updateQuickSubmission(_ record: QuickDraftRecord) throws {
        guard quickRecordID == record.id else { return }
        draftStore.save(record)
        draftStore.flush()
        quickCreatedSession = record.destination.session
        quickFiles = record.files
        if let error = draftStore.error { throw QuickDraftError.message(error) }
    }

    func finishQuickSubmission(_ record: QuickDraftRecord, failure: QuickSubmissionFailure?) {
        guard quickRecordID == record.id else { return }
        let latest = draftStore.records.first { $0.id == record.id } ?? record
        quickSending = false
        if let failure {
            var saved = latest
            saved.delivery = failure.uncertain ? .needsReview : .editing
            draftStore.save(saved)
            draftStore.flush()
            quickNeedsReview = failure.uncertain
            quickResult = failure.message
            DebugLog.write("workflow: quick submission failed uncertain=\(failure.uncertain)")
        } else {
            draftStore.remove(latest)
            draftStore.flush()
            applyingDraft = true
            quickDraft = ""
            quickFiles = []
            quickSources = []
            quickRecordID = nil
            quickCreatedSession = nil
            quickTarget = record.destination.session
            quickNeedsReview = false
            quickResult = nil
            quickTranscriptRevision &+= 1
            applyingDraft = false
        }
    }

    func confirmQuickDraftReview() {
        guard !quickSending, quickPreparing == 0, quickNeedsReview else { return }
        var record = captureRecord()
        record.delivery = .editing
        record.revision = UUID()
        draftStore.save(record)
        draftStore.flush()
        restoreQuickDraft(record)
        quickResult = "Review recorded. Send revalidates this destination; no message was resent."
    }
    func discardQuickDraft() {
        guard !quickSending else { return }
        draftStore.remove(captureRecord())
        draftStore.flush()
        applyingDraft = true
        quickRecordID = nil
        quickCreatedSession = nil
        quickDraft = ""
        quickFiles = []
        quickSources = []
        quickNeedsReview = false
        quickResult = nil
        applyingDraft = false
    }

    func selectQuickTarget(_ target: HermesSession?, task: EdgeNotchTask? = nil) {
        guard !quickSending, quickPreparing == 0 else { return }
        saveQuickDraft()
        applyingDraft = true
        quickTarget = target
        quickReplyTask = task
        quickCreatedSession = nil
        quickRecordID = nil
        quickProjectPath = nil
        quickDraft = ""
        quickFiles = []
        quickSources = []
        quickNeedsReview = false
        applyingDraft = false
        let key = captureRecord().destination.key
        if let record = draftStore.records.first(where: { $0.savedName == nil && $0.destination.key == key }) {
            restoreQuickDraft(record)
            quickReplyTask = task
        }
        quickResult = nil
    }

    /// A new-message draft belongs to its profile too. Wait for any captured send
    /// to finish before the controller calls this on a profile change.
    func resetQuickComposition() {
        guard !quickSending else { return }
        switchQuickProfile(quickProfileID)
    }

    var previewTasks: [EdgeNotchTask] {
        guard composing, let quickReplyTask,
            !tasks.contains(where: { $0.presentationID == quickReplyTask.presentationID })
        else { return tasks }
        return tasks + [quickReplyTask]
    }

    @Published var quickDraft = "" { didSet { saveQuickDraft() } }
    @Published var quickSending = false
    @Published var quickResult: String?
    @Published var deliveryAnswers: [EdgeDeliveryQuestion: AttentionAnswerState] = [:]
    @Published var bots: [BotSummary] = []
    @Published var avatarImages: [String: Data] = [:]
    @Published var expanded = false
    @Published var hasPet = false
    var externalPet = false
    @Published var side: EdgeDockSide = .right
    @Published var activity = EdgeNotchActivity()
    @Published var agentUpdatePhase: HermesUpdatePhase = .idle
    @Published var name = "Herm"
    @Published var sessionTitle = "Herm"
    @Published var updateTitle = "No activity yet"
    @Published var showsQuota = false
    @Published var refreshingSessions = false
    @Published var showingAnnouncement = false
    /// Which tab a temporary announcement shows; the user's choice returns after.
    @Published var announcesQuota = false
    @Published var announcesTasks = false
    /// The provider reading behind the latest quota announcement.
    @Published var quotaChange: EdgeQuotaChange?
    var announcedQuotaChange: EdgeQuotaChange? { showingAnnouncement && announcesQuota ? quotaChange : nil }
    /// A task update and a quota drop announced together share one status view.
    var displaysStatus: Bool { showingAnnouncement && announcesTasks && announcedQuotaChange != nil }
    var displaysQuota: Bool { showingAnnouncement ? announcesQuota && !announcesTasks : showsQuota }
    /// Rows the current announcement is about; an update opens as a glimpse of just these.
    @Published var glimpseIDs: [String] = []
    /// The glimpse's measured content height, which sizes the shell around it.
    @Published var glimpseHeight: CGFloat = 64
    var glimpseTasks: [EdgeNotchTask] {
        guard announcesTasks else { return [] }
        let ids = Set(glimpseIDs)
        let hits = tasks.filter {
            ids.contains($0.id) || ids.contains($0.kanbanTask?.id ?? "") || ids.contains($0.routine?.job.id ?? "")
        }
        return Array((hits.isEmpty ? tasks.filter(\.isCurrent) : hits).prefix(3))
    }
    var glimpsing: Bool {
        showingAnnouncement && !showingDigest && !composing && !isReadingDetail
            && (!glimpseTasks.isEmpty || announcedQuotaChange != nil)
    }
    @Published var detail = "Open your conversation"
    /// Sessions in progress or finished with a result not yet opened,
    /// including the current session when it has live activity.
    @Published var tasks: [EdgeNotchTask] = []
    @Published var kanbanUnavailable = false
    /// Fixed so refreshes and task arrivals never resize the preview.
    static let expandedSize = CGSize(width: 368, height: 360)
    static let quickMessageHeight: CGFloat = 560
    /// The island opens landscape: wide and short, like an expanded Dynamic Island.
    static let islandSize = CGSize(width: 560, height: 300)
    var sessionRailActivity: EdgeNotchActivity {
        var result = activity
        result.sessionNeedsAttention = tasks.contains {
            $0.kanbanTask == nil && $0.phase == .attention && $0.isStatusCurrent
        }
        let cards = tasks.filter { $0.kanbanTask != nil && $0.isStatusCurrent }
        result.kanbanRunningCount = cards.filter { $0.phase == .working }.count
        result.kanbanNeedsAttention = cards.contains { $0.phase == .attention }
        result.workingCount = tasks.filter { $0.isStatusCurrent && $0.phase == .working }.count
        result.kanbanHasUpdate = cards.contains { $0.phase == .finished }
        return result
    }
    var showsSeparateWork: Bool { railActivity.working && (railActivity.hasUpdate || railActivity.attention) }
    var isQuiet: Bool { railActivity.quiet && !expanded }
    @Published var petAttached = true
    @Published var petDragging = false
    @Published var petPull = 0.0
    /// The collapsed bar widens to receive a dragged pet and stays a little wider while it is docked.
    var barWidth: CGFloat {
        if petDragging { return 38 + (petAttached ? 10 : 25) * petPull }
        return hasPet && petAttached ? 46 : 38
    }
    /// Accent glow grows as a free pet is dragged toward the notch.
    var barGlow: Double { petDragging && !petAttached ? petPull : 0 }
    var railWidth: CGFloat { expanded ? 80 : 66 }
    var petReserve: CGFloat { hasPet ? Self.petFootprint : 0 }
    static let petFootprint: CGFloat = 48
    /// The collapsed rail grows with the number of stacked marks (24pt each, 6pt apart, room for the shoulders).
    var railHeight: CGFloat { expanded ? 136 : collapsedRailHeight }
    var collapsedRailHeight: CGFloat { max(96, CGFloat(railActivity.markCount) * 30 + 56) }
    var panelHeight: CGFloat { (expanded ? openSize.height : railHeight) + petReserve }
    /// The camera housing the top island wraps (drawn when the screen has none).
    @Published var notchSize = CGSize(width: EdgeNotchMetrics.fallbackWidth, height: 32)
    /// The right ear holds the primary mark, the left the extras; both match the
    /// wider one so the island stays centered on the camera.
    var islandEar: CGFloat { CGFloat(max(1, railActivity.markCount - 1)) * 30 + 20 }
    /// The shell at rest: the rail bar on an edge, the pill around the notch on top.
    var collapsedSize: CGSize {
        side == .top
            ? CGSize(width: notchSize.width + islandEar * 2, height: notchSize.height)
            : CGSize(width: railWidth, height: collapsedRailHeight)
    }
    var openSize: CGSize {
        if isComposingQuickMessage {
            return CGSize(
                width: side == .top ? Self.islandSize.width : Self.expandedSize.width,
                height: Self.quickMessageHeight + (side == .top ? notchSize.height : 0))
        }
        if glimpsing {
            // Matches the preview padding below: 8 + 16 under the notch, 26 + 26 on an edge.
            return side == .top
                ? CGSize(width: 460, height: notchSize.height + glimpseHeight + 24)
                : CGSize(width: Self.expandedSize.width, height: glimpseHeight + 52)
        }
        return side == .top
            ? CGSize(width: Self.islandSize.width, height: Self.islandSize.height + notchSize.height)
            : Self.expandedSize
    }
    var isComposingQuickMessage: Bool {
        composing && !isReadingDetail && !showingDigest && (quickTarget == nil || quickReplyTask == nil)
    }
    /// The window: the pet hangs below an edge rail but beside the top island.
    var panelSize: CGSize {
        side == .top
            ? (expanded ? openSize : collapsedSize)
            : CGSize(width: expanded ? openSize.width : railWidth, height: panelHeight)
    }
}

struct EdgeNotchView: View {
    @ObservedObject var state: EdgeNotchState
    @ObservedObject var controlCenter: ControlCenterModel
    var onQuotaRequested: () -> Void = {}
    var onTasksRefresh: () -> Void = {}
    var onOpenQuota: () -> Void = {}
    var quickMessageModel: DockModel? = nil
    var onQuickMessageFocus: (Bool) -> Void = { _ in }
    var onQuickReply: (EdgeNotchTask) -> Void = { _ in }
    var onResultPeek: (EdgeNotchTask) -> Void = { _ in }
    var onResultReply: (EdgeResultTarget) -> Void = { _ in }
    var onOpenDigest: (HermNotice) -> Void = { _ in }
    var onAnswer: (EdgeNotchTask, String) -> Void = { _, _ in }
    @ObservedObject private var theme = DockThemeStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Visual open state. It trails `state.expanded` by one run-loop turn so the
    /// spring starts after the window has grown; changes applied inside the
    /// window-resize layout pass are not animated.
    @State private var open = false
    private var morph: Animation? {
        reduceMotion ? nil : state.side == .top ? EdgeDockMotion.islandMorph : EdgeDockMotion.morph
    }
    let openDock: () -> Void
    var onOpenTask: (EdgeNotchTask) -> Void = { _ in }
    var onDrag: (Bool) -> Void = { _ in }
    var onCallPetHome: () -> Void = {}
    var onSideChange: (EdgeDockSide) -> Void = { _ in }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 4) {
                HStack(spacing: 0) {
                    if open {
                        // The outer contour already supplies visual breathing room.
                        // Keep the preview close to it so its content does not float
                        // in the middle of the expanded notch.
                        preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.horizontal, state.side == .top ? 34 : 8)
                            .padding(.top, state.side == .top ? 8 : 26)
                            .padding(.bottom, state.side == .top ? 16 : 26)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .asymmetric(
                                        insertion: .islandContent(side: state.side).animation(
                                            .easeOut(duration: 0.24).delay(0.1)),
                                        removal: .opacity.animation(.easeIn(duration: 0.1))))
                    } else if state.side == .top {
                        EdgeIslandRail(
                            activity: state.railActivity, notchWidth: state.notchSize.width, ear: state.islandEar,
                            height: state.notchSize.height, action: openDock
                        )
                        .contextMenu { railMenu }
                        .accessibilityLabel("\(state.name), \(state.railActivity.title). Open Herm")
                        .accessibilityHint("Drag to a screen edge to dock it there")
                        .transition(.opacity.animation(.easeOut(duration: 0.16)))
                    } else {
                        rail.transition(.opacity.animation(.easeOut(duration: 0.16)))
                    }
                }
                // Sized from state only, never the window: the window grows ahead of
                // the shape (non-animated), and tying the shape to it made the
                // preview pop to full size instead of growing with the spring.
                .frame(
                    width: open ? state.openSize.width : state.collapsedSize.width,
                    height: open ? state.openSize.height : state.collapsedSize.height,
                    alignment: state.side.alignment
                )
                // The content is revealed through the growing shell rather than
                // appearing at full size beside it.
                .mask { shell(EdgeNotchShape(side: state.side).fill(.black)) }
                // One persistent shell: the rail bar itself stretches into the preview
                // panel and back, so the two states read as a single growing notch.
                .background {
                    // Side previews retain a contour even when Glass blends into the desktop.
                    shell(
                        DockWindowBackground(shape: AnyShape(EdgeNotchShape(side: state.side)))
                            .overlay {
                                // Doubled stroke clipped to the shape leaves a uniform inner 1pt line;
                                // a centered 1pt stroke loses its outer half to the clip on every edge.
                                if state.side != .top {
                                    EdgeNotchShape(side: state.side).stroke(Color.dockBorderStrong, lineWidth: 2)
                                }
                            }
                            .clipShape(EdgeNotchShape(side: state.side)))
                }
                // Attach drag gesture to parent so it works in both collapsed and expanded states
                .simultaneousGesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { _ in onDrag(false) }
                        .onEnded { _ in onDrag(true) })
                if state.hasPet && !state.externalPet {
                    HermesNotchPetButton(pet: controlCenter.pet, mirrored: state.side == .left)
                        .frame(maxWidth: .infinity, alignment: state.side == .left ? .leading : .trailing)
                } else if state.hasPet && state.side != .top {
                    Color.clear.frame(height: max(44, state.petReserve - 4)).allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: state.side.alignment)
        }
        .clipped()
        // Rail growth (more stacked marks) uses the same spring as the open/close morph.
        .animation(morph, value: state.collapsedSize)
        .animation(morph, value: state.openSize)
        .onAppear { open = state.expanded }
        .onChange(of: state.expanded) { _, expanded in
            DispatchQueue.main.async {
                guard state.expanded == expanded else { return }
                withAnimation(!expanded && state.side == .top && !reduceMotion ? EdgeDockMotion.islandCollapse : morph)
                { open = expanded }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.isQuiet)
        .dockThemedRoot().dockPreferredTextSize()
        .id(theme.selectedThemeID)
    }

    /// The notch outline at its current size: the rail bar when closed, the whole panel when open.
    private func shell(_ surface: some View) -> some View {
        GeometryReader { shell in
            surface
                .frame(
                    width: open || state.side == .top ? shell.size.width : min(shell.size.width, state.barWidth),
                    height: shell.size.height
                )
                .frame(maxWidth: .infinity, alignment: state.side.alignment)
        }
        .animation(
            reduceMotion ? nil : .interactiveSpring(response: 0.28, dampingFraction: 0.68), value: state.barWidth)
    }

    private var rail: some View {
        Button(action: openDock) {
            EdgePetRail(
                activity: state.railActivity, side: state.side, width: state.barWidth,
                height: state.collapsedRailHeight, glow: state.barGlow, docked: state.petAttached && state.hasPet
            )
            .frame(width: state.railWidth, height: state.collapsedRailHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .contextMenu { railMenu }
        .accessibilityLabel("\(state.name), \(state.railActivity.title). Open Herm")
        .accessibilityHint("Drag to move along either screen edge")
    }

    @ViewBuilder private var railMenu: some View {
        if state.hasPet { Button("Attach pet to notch", action: onCallPetHome).disabled(state.petAttached) }
        Button("Move to left edge") { onSideChange(.left) }.disabled(state.side == .left)
        Button("Move to right edge") { onSideChange(.right) }.disabled(state.side == .right)
        Button("Move to top") { onSideChange(.top) }.disabled(state.side == .top)
        Divider()
        Button("Quit Herm") { NSApp.terminate(nil) }
    }

    private var isIsland: Bool { state.side == .top }
    private var showsQuickMessage: Bool {
        state.isComposingQuickMessage && quickMessageModel != nil
    }

    private var preview: some View {
        VStack(spacing: isIsland ? 6 : 0) {
            // A glimpse is just the update: no tabs or toolbar until the user hovers.
            if !state.glimpsing && !showsQuickMessage {
                HStack(spacing: 4) {
                    HStack(spacing: 2) {
                        tabButton("Tasks", isSelected: !state.displaysQuota && !state.displaysStatus) {
                            state.clearPreviewDetails()
                            onQuickMessageFocus(false)
                            state.showingAnnouncement = false
                            state.showsQuota = false
                        }
                        tabButton("Quota", isSelected: state.displaysQuota) {
                            state.clearPreviewDetails()
                            onQuickMessageFocus(false)
                            state.showingAnnouncement = false
                            state.showsQuota = true
                            onQuotaRequested()
                        }
                    }
                    .padding(2)
                    .background(DockThemeShape(cornerRadius: 14).dockSurfaceFill(Color.dockSurface4.opacity(0.6)))
                    if isIsland {
                        // Leave the camera housing clear; the controls sit in the ears either side.
                        Spacer(minLength: state.notchSize.width + 12)
                    } else {
                        Spacer()
                    }
                    if state.displaysQuota {
                        EdgeQuotaToolbar(control: controlCenter)
                    } else {
                        HStack(spacing: 8) {
                            EdgeQuietMenu(coordinator: state.interruptions) {
                                onQuickMessageFocus(false)
                                state.showingDigest = true
                            }
                            taskToolbar
                        }
                    }
                }
                .frame(height: isIsland ? max(state.notchSize.height, 34) : 40)
                .padding(.horizontal, isIsland ? 0 : 6)
                if !isIsland { Divider().overlay(Color.dockBorderLight) }
            }
            if let target = state.steeringTarget, let model = quickMessageModel {
                EdgeSubagentSteering(
                    origin: target,
                    service: HermesWorkflowRPC(client: model.quickWorkflowClient, profileID: target.profileID),
                    back: {
                        state.steeringTarget = nil
                        onQuickMessageFocus(false)
                    },
                    open: {
                        model.resumeSession(target)
                        openDock()
                    })
            } else if let target = state.capacityTarget, let model = quickMessageModel {
                EdgeSessionCapacity(
                    destination: target, control: controlCenter,
                    service: HermesWorkflowRPC(client: model.controlRPCClient, profileID: target.profileID),
                    back: { state.capacityTarget = nil },
                    loaded: { snapshot in
                        let key = QuickDestination(profileID: target.profileID, sessionID: target.id).sessionKey
                        state.capacitySnapshots[key] = snapshot
                    },
                    open: {
                        model.resumeSession(target)
                        openDock()
                    })
            } else if state.showingRecall, let model = quickMessageModel {
                EdgeRecallView(
                    profileID: state.recallProfileID, client: model.controlRPCClient,
                    back: {
                        state.showingRecall = false
                        onQuickMessageFocus(false)
                    },
                    open: { session in
                        model.resumeSession(session)
                        openDock()
                    },
                    insert: { hit in state.insertRecall(hit) })
            } else if let routine = state.routineTarget {
                EdgeRoutinePreview(
                    reference: controlCenter.routineReferences.first { $0.id == routine.id } ?? routine,
                    control: controlCenter, preferences: state.preferences,
                    back: { state.routineTarget = nil },
                    openAutomation: {
                        controlCenter.requestAutomation(routine)
                        state.routineTarget = nil
                        openDock()
                    }
                ).id(routine.id)
            } else if state.showingDigest {
                EdgeDigestView(
                    coordinator: state.interruptions, back: { state.showingDigest = false },
                    open: onOpenDigest, openActivity: openDock)
            } else if let target = state.resultTarget, let quickMessageModel {
                resultPreview(target, model: quickMessageModel)
            } else if showsQuickMessage, let quickMessageModel {
                EdgeQuickMessageView(
                    model: quickMessageModel, control: controlCenter, state: state,
                    close: { onQuickMessageFocus(false) }, openDock: openDock)
            } else if state.displaysQuota, !state.glimpsing {
                EdgeQuotaPreview(
                    control: controlCenter, openQuota: onOpenQuota, change: state.announcedQuotaChange,
                    sessionActions: state.captureRecord().destination.session.map { session in
                        { state.capacityTarget = session }
                    })
            } else {
                EdgeTaskPreview(
                    tasks: state.glimpsing ? state.glimpseTasks : state.previewTasks,
                    isOffline: state.activity.status == .offline,
                    quotaChange: state.displaysStatus || state.glimpsing ? state.announcedQuotaChange : nil,
                    kanbanUnavailable: state.kanbanUnavailable,
                    bots: state.bots, avatarImages: state.avatarImages,
                    quickMessage: quickMessageModel == nil
                        ? nil
                        : {
                            guard !state.quickSending else { return }
                            state.selectQuickTarget(nil)
                            onQuickMessageFocus(true)
                        },
                    reply: quickMessageModel == nil ? nil : onQuickReply,
                    quickState: state, quickModel: quickMessageModel, quotaControl: controlCenter,
                    closeReply: { onQuickMessageFocus(false) },
                    answer: onAnswer,
                    peek: quickMessageModel == nil ? nil : onResultPeek,
                    recall: quickMessageModel == nil
                        ? nil
                        : {
                            guard !state.quickSending else { return }
                            state.recallProfileID = state.quickProfileID
                            onQuickMessageFocus(true)
                            state.showingRecall = true
                        },
                    steer: { task in
                        guard !state.quickSending else { return }
                        let session = task.session ?? (task.isCurrent ? quickMessageModel?.workflowSession : nil)
                        if let session {
                            onQuickMessageFocus(true)
                            state.steeringTarget = session
                        }
                    }, beginEditing: { onQuickMessageFocus(true) }, compactFooter: isIsland, glimpse: state.glimpsing,
                    openDock: openDock, openTask: onOpenTask)
            }
        }
        // Presentations without the tab row still leave the camera housing clear.
        .padding(.top, (state.glimpsing || showsQuickMessage) && isIsland ? state.notchSize.height : 0)
    }

    private func resultPreview(_ target: EdgeResultTarget, model quickMessageModel: DockModel) -> some View {
        EdgeResultPeek(
            target: target,
            load: { session in
                if let cached = state.cachedResult(target) { return cached }
                let loaded = try await quickMessageModel.resultPeek(for: session)
                guard !Task.isCancelled else { return nil }
                if let loaded { state.cacheResult(loaded, for: target) }
                return loaded
            },
            back: { state.resultTarget = nil },
            reply: { onResultReply(target) },
            openSession: {
                quickMessageModel.resumeSession(target.session)
                state.resultTarget = nil
                openDock()
            },
            reviewed: {
                quickMessageModel.markQuickResultReviewed(target.session)
                if let id = state.digestResultID {
                    state.interruptions.review(id)
                    state.digestResultID = nil
                }
            },
            refresh: {
                state.clearResult(target)
                if let newer = state.tasks.first(where: {
                    $0.id == target.task.id && $0.session?.profileID == target.session.profileID
                        && $0.phase == .finished
                }), let session = newer.session {
                    state.resultTarget = EdgeResultTarget(task: newer, session: session)
                }
            },
            hasNewerResult: state.tasks.contains {
                $0.id == target.task.id && $0.session?.profileID == target.session.profileID && $0.phase == .finished
                    && $0 != target.task
            },
            showingComparison: $state.showingResultComparison,
            reviewInWorkspace: { comparison in
                let key = QuickDestination(profileID: target.session.profileID, sessionID: target.session.id).sessionKey
                guard let path = comparison?.path ?? DeveloperWorkflowModel.shared.turnBaselines[key]?.path else {
                    return
                }
                quickMessageModel.resumeSession(target.session)
                state.resultTarget = nil
                openDock()
                ObservedRequestChanges.shared.requestedReview = ObservedReviewRequest(
                    session: target.session, path: path, comparison: comparison)
            }
        )
        .id(target.id)
    }

    private var taskToolbar: some View {
        let refreshing =
            state.refreshingSessions
            || controlCenter.refreshState(for: "kanban.global")?.isRefreshing == true
        let unavailable = state.activity.status == .offline || state.kanbanUnavailable
        return Button(action: onTasksRefresh) {
            Group {
                if refreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    DockIcon(
                        unavailable ? .warningCircle : .arrowClockwise, size: 13,
                        color: unavailable ? .dockWarning : .dockSecondaryText)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .disabled(refreshing || state.activity.status == .offline)
        .help(unavailable ? "Status unavailable. Refresh tasks" : "Refresh tasks")
        .accessibilityLabel(unavailable ? "Status unavailable. Refresh tasks" : "Refresh tasks")
    }

    private func tabButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .dockFont(.body, weight: isSelected ? .semibold : .medium)
                .foregroundStyle(isSelected ? Color.dockPrimaryText : Color.dockSecondaryText)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    DockThemeShape(cornerRadius: 12).dockSelectionFill(
                        isSelected, fallback: isSelected ? Color.dockSurface : .clear)
                )
                .overlay(
                    DockThemeShape(cornerRadius: 12).stroke(
                        isSelected && DockThemeStyle.current.material != .glass
                            ? Color.dockBorderLight : .clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Dots told apart by motion and fill as well as color: breathing = working
/// or attention, held = done, hollow = offline. Work keeps its own dot
/// beneath attention or done so a blocked card never hides a running task.
private struct EdgePetRail: View {
    @AppStorage(NotchDisplayStyle.defaultsKey) private var displayStyle: NotchDisplayStyle = .defaultStyle
    let activity: EdgeNotchActivity
    let side: EdgeDockSide
    var width: CGFloat = 28
    var height: CGFloat = 60
    var glow = 0.0
    var docked = false
    @State private var flash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                if side == .right { Spacer(minLength: 0) }
                EdgeNotchStatusIndicator(activity: activity, style: displayStyle)
                    .frame(width: width, height: height)
                    // The shell fill lives in EdgeNotchView so it can grow into the preview.
                    .overlay {
                        EdgeNotchShape(side: side).stroke(
                            DockThemePalette(theme: DockThemeRuntime.current).accent, lineWidth: 2
                        ).opacity(flash ? 1 : glow * 0.8)
                    }
                    .animation(
                        reduceMotion ? nil : .interactiveSpring(response: 0.28, dampingFraction: 0.68), value: width)
                if side == .left { Spacer(minLength: 0) }
            }
        }
        // A brief accent flash marks the moment the pet docks.
        .onChange(of: docked) { _, isDocked in
            guard isDocked, !reduceMotion else { return }
            flash = true
            withAnimation(.easeOut(duration: 0.7)) { flash = false }
        }
    }
}

/// Content settles in from the anchored edge once the shell has opened.
private struct IslandContentModifier: ViewModifier {
    let shown: Bool
    let side: EdgeDockSide

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : 0.94, anchor: side.anchor)
            .opacity(shown ? 1 : 0)
    }
}

extension AnyTransition {
    static func islandContent(side: EdgeDockSide) -> AnyTransition {
        .modifier(
            active: IslandContentModifier(shown: false, side: side),
            identity: IslandContentModifier(shown: true, side: side))
    }
}

/// Small concave shoulders meet the physical screen edge; the inner face is rounded.
struct EdgeNotchShape: Shape {
    var side: EdgeDockSide = .right

    func path(in rect: CGRect) -> Path {
        if side == .top {
            // The right-edge outline turned so its screen edge faces up.
            let turned = CGRect(x: 0, y: 0, width: rect.height, height: rect.width)
            return EdgeNotchShape(side: .right).path(in: turned)
                .applying(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: rect.minX, ty: rect.minY + rect.height))
        }
        let shoulder: CGFloat = min(18, rect.width / 4)
        let radius: CGFloat = min(26, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - shoulder, y: rect.minY + shoulder),
            control: CGPoint(x: rect.maxX, y: rect.minY + shoulder))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY + shoulder))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + shoulder + radius),
            control: CGPoint(x: rect.minX, y: rect.minY + shoulder))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - shoulder - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.maxY - shoulder),
            control: CGPoint(x: rect.minX, y: rect.maxY - shoulder))
        path.addLine(to: CGPoint(x: rect.maxX - shoulder, y: rect.maxY - shoulder))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY - shoulder))
        // Left open: fills close implicitly, but strokes skip the screen-edge side.
        if side == .left {
            return path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0))
        }
        return path
    }
}

final class EdgeDockHostingView<Content: View>: NSHostingView<Content> {
    func panelContainer() -> NSView {
        // A root NSHostingView can animate the window size even with sizingOptions empty.
        // Keep panel sizing in AppKit so SwiftUI animation cannot reenter window layout.
        let container = NSView(frame: frame)
        autoresizingMask = [.width, .height]
        container.addSubview(self)
        return container
    }

    var onHoverChanged: ((Bool) -> Void)?
    var bottomHoverExclusion: CGFloat = 0 { didSet { updateTrackingAreas() } }
    private var lastNotchHover: Bool?
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        hoverArea = area
        addTrackingArea(area)
    }
    func notchHoverContains(_ point: NSPoint) -> Bool {
        bounds.contains(point) && (isFlipped ? bounds.maxY - point.y : point.y - bounds.minY) >= bottomHoverExclusion
    }
    private func updateNotchHover(_ event: NSEvent) {
        let inside = notchHoverContains(convert(event.locationInWindow, from: nil))
        guard lastNotchHover != inside else { return }
        lastNotchHover = inside
        onHoverChanged?(inside)
    }
    // super must run: SwiftUI's own hover tracking is delivered through these.
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateNotchHover(event)
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateNotchHover(event)
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // Leaving via the pet must still schedule collapse after leaving the panel.
        lastNotchHover = nil
        onHoverChanged?(false)
    }
}
