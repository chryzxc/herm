import AppKit
import Combine
import SwiftUI

/// The passive notch. It is its own window, hidden while the workspace shows,
/// so it never hosts workspace content.
@MainActor
final class EdgeDockController: NSObject {
    let panel = DockPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let model: DockModel
    private let controlCenter: ControlCenterModel
    private let openQuota: () -> Void
    private let openKanban: (KanbanTaskSummary) -> Void
    private let openDock: () -> Void
    private let state = EdgeNotchState()
    private var petWindow: HermesPetWindow?
    private var subscriptions = Set<AnyCancellable>()
    private var collapseTask: DispatchWorkItem?
    private var expandTask: DispatchWorkItem?
    private var hovering = false
    private var dragging = false
    private var petDragging = false
    private var suppressClickUntil = Date.distantPast
    private var workspacePresented = false
    private var quickProfileID: String?
    private var completedTaskIDs: Set<String>?
    private var latestToolID: String?
    private var latestToolComplete = false
    private var kanbanActivity = EdgeKanbanActivity()
    private var lastBotRead: Date?
    private var loadingBots = false
    private var lastKanbanRead: Date?
    private var kanbanStatusCurrent = false
    private var latestSessions: [HermesSession] = []
    private var latestAttention: [String: DockModel.SessionAttention] = [:]
    private var deliveryQuestions: [EdgeDeliveryQuestion] = []
    private var latestActivityLabels: [String: String] = [:]
    private var lastQuotas: [ProviderQuotaSnapshot]?
    /// Quota readers whose usage has moved; these are the services being
    /// spent (by Hermes or any other app), so they are read on every tick.
    private var hotQuotaReaders = Set<String>()
    private var quotaTick = 0
    private var displayID: NSNumber?
    private var fraction: CGFloat = 0.5
    private let defaults: UserDefaults

    init(model: DockModel, controlCenter: ControlCenterModel, defaults: UserDefaults = .standard, openQuota: @escaping () -> Void, openKanban: @escaping (KanbanTaskSummary) -> Void, openDock: @escaping () -> Void) {
        self.model = model
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
            if dragging && !self.petDragging { self.petDragging = true; self.expandTask?.cancel(); self.setExpanded(false) }
            if !dragging { self.petDragging = false }
            self.state.petDragging = dragging; self.state.petPull = pull
        }
        quickProfileID = model.profileScopeID
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
        let host = EdgeDockHostingView(rootView: EdgeNotchView(state: state, controlCenter: controlCenter,
            onQuotaRequested: { [weak self] in self?.loadQuota() },
            onTasksRefresh: { [weak self] in self?.refreshSelectedTasks() },
            onOpenQuota: { [weak self] in self?.openQuota() },
            quickMessageModel: model,
            onQuickMessageFocus: { [weak self] active in self?.setQuickMessageFocus(active) },
            onQuickReply: { [weak self] task in self?.beginQuickReply(task) },
            onAnswer: { [weak self] task, choice in self?.answer(task, choice: choice) },
            openDock: { [weak self] in self?.openWorkspace() },
            onOpenTask: { [weak self] task in self?.openTask(task) },
            onDrag: { [weak self] ended in self?.moveNotch(ended: ended) },
            onCallPetHome: { [weak self] in self?.petWindow?.recall() }, onSideChange: { [weak self] side in
                guard let self else { return }
                self.state.side = side
                self.persistPlacement()
                self.position(animated: true)
            }))
        host.onHoverChanged = { [weak self] value in self?.hoverChanged(value) }
        host.sizingOptions = []
        panel.contentView = host
        panel.onCancel = { [weak self] in self?.setExpanded(false) }
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
                self.latestAttention = requests
                self.updateDetail()
                if hasNewRequest { self.announce() }
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
                self.state.resetQuickComposition()
                if !self.workspacePresented { self.setQuickMessageFocus(false) }
            }.store(in: &subscriptions)
        model.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in self?.refreshNoteworthySessions(sessions) }
            .store(in: &subscriptions)
        model.$sessionActivityLabels
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] labels in
                self?.latestActivityLabels = labels
                self?.rebuildTasks()
            }
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
            .sink { [weak self] _ in self?.pollKanban(); self?.pollDeliveryQuestions() }
            .store(in: &subscriptions)
        controlCenter.$providerQuotas
            .receive(on: RunLoop.main)
            .sink { [weak self] quotas in self?.quotaChanged(quotas) }
            .store(in: &subscriptions)
        // The workspace only polls quota while its Quota page is open; keep
        // reading it with the Dock closed so drops surface here. Quota is spent
        // by other apps too, so this runs whether or not Hermes is working.
        Timer.publish(every: 30, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.pollQuota() }
            .store(in: &subscriptions)
        model.$currentSessionTitle.combineLatest(model.$runtimeConfiguration)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
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
            NotificationCenter.default.publisher(for: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared),
            Just(Notification(name: .init("herm.notch.launch"))).delay(for: 1, scheduler: RunLoop.main))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.ensureNotchVisible() }
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
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == displayID
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return nil }
        displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return EdgeDockPlacement(side: state.side, fraction: fraction,
                                 screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    func prepareForWorkspace() {
        collapseTask?.cancel()
        expandTask?.cancel()
        state.composing = false
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
    }

    private func beginQuickReply(_ task: EdgeNotchTask) {
        guard !state.quickSending else { return }
        let target = task.session ?? (task.isCurrent ? model.navigationSessionID.map {
            HermesSession(id: $0, profileID: model.sessionProfileID, title: task.title,
                          preview: task.detail ?? "", startedAt: nil, messageCount: 0, source: "herm")
        } : nil)
        guard let target else { return }
        state.selectQuickTarget(target, task: task)
        setQuickMessageFocus(true)
    }

    private func setQuickMessageFocus(_ active: Bool) {
        state.composing = active
        collapseTask?.cancel()
        state.showingAnnouncement = false
        panel.acceptsWorkspaceFocus = active
        if active {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.resignKey()
            if !hovering { scheduleCollapse(after: 0.4) }
        }
    }

    private func openWorkspace() {
        guard !dragging, Date() >= suppressClickUntil else { return }
        state.activity.backgroundCompleted = false
        state.activity.responseCompleted = false
        openDock()
    }

    private func openTask(_ task: EdgeNotchTask) {
        guard !dragging, Date() >= suppressClickUntil else { return }
        if let card = task.kanbanTask {
            kanbanActivity.acknowledge(card)
            rebuildTasks()
            openKanban(card)
            return
        }
        guard let session = task.session else { return openWorkspace() }
        model.resumeSession(session)
        openDock()
    }

    /// `@Published` sinks fire before the property changes, so the latest
    /// session list is cached from the publisher rather than read back.
    private func refreshNoteworthySessions(_ sessions: [HermesSession]) {
        latestSessions = sessions
        let previous = state.tasks
        rebuildTasks()
        if EdgeNotchTask.newlyFinished(from: previous, to: state.tasks) {
            announce()
            pollQuota(afterWork: true)
        }
    }

    /// Every session in progress or finished-but-unopened, with the open
    /// session contributing its own live activity instead of the index flag.
    private func rebuildTasks() {
        let activity = state.activity
        var current: EdgeNotchTask?
        let request = model.currentSessionIDs.compactMap { latestAttention[$0] }.first
        let phase: EdgeNotchTask.Phase? = (request != nil || activity.attention) ? .attention
            : activity.working ? .working : activity.hasUpdate ? .finished : nil
        if let phase {
            let label: String = switch phase {
            case .attention: request?.status.title ?? activity.status.title
            case .working: activity.status == .working ? "Working" : activity.title
            case .pending, .finished: activity.title
            }
            current = EdgeNotchTask(
                id: model.navigationSessionID ?? "current", title: state.sessionTitle, phase: phase,
                statusLabel: label, detail: request?.summary ?? state.detail, updatedAt: nil, isCurrent: true,
                isStatusCurrent: activity.status != .offline, session: nil, choices: request?.choices ?? [])
        }
        let tasks = EdgeNotchTask.merged(EdgeNotchTask.build(current: current, sessions: latestSessions,
                                        activity: latestActivityLabels,
                                        currentSessionIDs: model.currentSessionIDs,
                                        isOnline: activity.status != .offline, attention: latestAttention)
            + kanbanActivity.rows(isCurrent: kanbanStatusCurrent && activity.status != .offline)
            + deliveryQuestions.map(\.row))
        if tasks != state.tasks { state.tasks = tasks }
        controlCenter.pet.updateNotchActivity(
            working: state.railActivity.working || tasks.contains { $0.isStatusCurrent && $0.phase == .working },
            attention: state.railActivity.attention || tasks.contains { $0.isStatusCurrent && $0.phase == .attention })
    }

    /// Headless coordinator turns cannot ask; the delivery plugin queues their questions as files.
    private func pollDeliveryQuestions() {
        let questions = EdgeDeliveryQuestion.load()
        guard questions != deliveryQuestions else { return }
        let isNew = questions.contains { !deliveryQuestions.contains($0) }
        deliveryQuestions = questions
        rebuildTasks()
        if isNew { announce() }
    }

    private func answer(_ task: EdgeNotchTask, choice: String) {
        if let question = task.deliveryQuestion {
            guard let session = task.session else { return }
            model.sendQuickMessage(question.answerText(choice), to: session) { [weak self] error in
                guard let self else { return }
                // ponytail: a busy Bot Chat keeps the question; tapping again retries.
                if let error { return DebugLog.write("notch: question answer failed: \(error)") }
                try? FileManager.default.removeItem(at: question.file)
                self.pollDeliveryQuestions()
            }
            return
        }
        guard let sessionID = task.isCurrent
                ? model.currentSessionIDs.first(where: { latestAttention[$0] != nil })
                : task.session?.id else { return }
        model.answerAttention(sessionID: sessionID, choice: choice)
    }

    private func refreshSelectedTasks() {
        pollKanban()
        model.loadSessions()
    }

    private func pollKanban() {
        guard model.status != .offline else { return }
        controlCenter.refreshGlobalKanban(trigger: .background)
        guard !loadingBots, lastBotRead.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        loadingBots = true
        lastBotRead = Date()
        Task {
            defer { loadingBots = false }
            let service = BotService(client: model.controlRPCClient)
            let inventory = await service.list()
            guard inventory.availability == .ready else { return }
            state.bots = inventory.bots
            for bot in inventory.bots where bot.hasAvatar && state.avatarImages[bot.id] == nil {
                if let data = await service.avatarImageData(profileID: bot.id) { state.avatarImages[bot.id] = data }
            }
        }
    }

    private func refreshKanbanActivity() {
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
        if changed { announce() }
    }

    private func refresh(status: HermesStatus, unread: Bool, tasks: [HermesBackgroundTask]) {
        let completed = Set(tasks.filter { $0.status == .completed }.map(\.id))
        let newCompletion = completedTaskIDs.map { !completed.subtracting($0).isEmpty } ?? false
        completedTaskIDs = completed
        let previous = state.activity
        let responseFinished = previous.status == .working && status == .idle
            && model.messages.last?.role == .hermes
        state.activity = EdgeNotchActivity(status: status, unread: unread,
            runningCount: tasks.filter { $0.status == .running }.count,
            backgroundCompleted: newCompletion || (previous.backgroundCompleted && !completed.isEmpty),
            responseCompleted: responseFinished || (previous.responseCompleted && status != .working))
        updateDetail()
        if state.activity.shouldAnnounce(after: previous) || newCompletion || responseFinished {
            announce()
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
        guard !workspacePresented,
              controlCenter.refreshState(for: "provider.quota")?.isRefreshing != true else { return }
        controlCenter.bind(to: model)
        quotaTick &+= 1
        let fullRead = hotQuotaReaders.isEmpty || (!afterWork && quotaTick.isMultiple(of: 2))
        controlCenter.refreshProviderQuota(only: fullRead ? nil : hotQuotaReaders)
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
              let provider = EdgeQuotaBands.droppedProvider(from: EdgeQuotaBands.bands(previousQuotas),
                                                            to: EdgeQuotaBands.bands(quotas)),
              let previous = previousQuotas.first(where: { $0.provider == provider }),
              let current = quotas.first(where: { $0.provider == provider }) else { return }
        state.quotaChange = EdgeQuotaChange(previous: previous, current: current)
        announce(quota: true)
    }

    private func updateDetail() {
        state.sessionTitle = model.currentSessionTitle ?? (model.sessionID == nil ? "Herm" : "Current session")
        state.updateTitle = state.activity.title
        if state.activity.attention {
            state.detail = "Open this session to review and respond"
        } else if state.activity.working, let tool = model.activeToolCalls.last {
            state.detail = "\(tool.isComplete ? "Completed" : "Running") \(tool.name)"
        } else if state.activity.backgroundCompleted {
            state.detail = "Open this session to review its result"
        } else if state.activity.working {
            state.detail = "Working on this session’s request"
        } else if let response = model.messages.last(where: { $0.role == .hermes }), !response.text.isEmpty {
            state.detail = String(response.text.prefix(180))
            if state.activity.quiet { state.updateTitle = "Latest update" }
        } else {
            state.updateTitle = "No activity yet"
            state.detail = model.sessionID == nil ? "Choose a session to see its activity." : "Updates will appear as work begins in this session."
        }
        rebuildTasks()
    }

    private func announce(quota: Bool = false) {
        guard !workspacePresented, !dragging, !petDragging, !state.composing else { return }
        // Every notch announcement, including future sources, reaches the pet here.
        controlCenter.pet.react(.announcement(activity: state.railActivity, quota: quota))
        if !hovering {
            // Updates landing while one is showing join it rather than replace it.
            if !state.showingAnnouncement {
                state.announcesTasks = false
                state.announcesQuota = false
            }
            state.showingAnnouncement = true
            if quota {
                state.announcesQuota = true
            } else {
                state.announcesTasks = true
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
            // expanded out from under the cursor.
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.hovering, !self.dragging, !self.petDragging else { return }
                self.setExpanded(true)
            }
            expandTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
        }
        else { scheduleCollapse(after: 0.4) }
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        collapseTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering, !self.dragging, !self.workspacePresented, !self.state.composing,
                  !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            guard self.panel.attachedSheet == nil, self.panel.childWindows?.isEmpty != false else {
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

    /// Keyboard counterpart to hovering the notch: stays open while the
    /// pointer is over it, otherwise folds back after a few seconds.
    func toggleQuickPreview() {
        guard !workspacePresented, !dragging, !petDragging else { return }
        if state.expanded { return setExpanded(false) }
        state.showingAnnouncement = false
        setExpanded(true)
        scheduleCollapse(after: 5)
    }

    private func setExpanded(_ expanded: Bool) {
        guard !workspacePresented else { return }
        collapseTask?.cancel()
        if !expanded {
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
        let point = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let location = EdgeDockPlacement.dragged(to: point, screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
            displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            state.side = location.side
            fraction = location.fraction
            position(animated: false)
        }
        if ended {
            suppressClickUntil = Date().addingTimeInterval(0.4)
            persistPlacement()
        }
    }

    private func persistPlacement() {
        defaults.set(state.side.rawValue, forKey: "hermes.notch.side")
        defaults.set(fraction, forKey: "hermes.notch.position")
        defaults.set(displayID, forKey: "hermes.notch.display")
    }

    private func position(animated: Bool) {
        guard let placement else { return }
        (panel.contentView as? EdgeDockHostingView<EdgeNotchView>)?.bottomHoverExclusion = state.petReserve
        let target = placement.frame(width: state.expanded ? EdgeNotchState.expandedSize.width : state.railWidth,
                                     height: state.panelHeight)
        petWindow?.update(home: NSPoint(x: state.side == .right ? target.maxX - 44 : target.minX, y: target.minY),
                          screen: placement.visibleFrame, visible: !workspacePresented, side: state.side)
        guard !panel.frame.equalTo(target) else { return }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                let expanding = target.width > panel.frame.width
                context.duration = expanding ? EdgeDockMotion.revealDuration : EdgeDockMotion.collapseDuration
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    static func frame(screenFrame: NSRect, visibleFrame: NSRect, expanded: Bool, railHeight: CGFloat = 136) -> NSRect {
        EdgeDockPlacement(screenFrame: screenFrame, visibleFrame: visibleFrame)
            .frame(width: expanded ? EdgeNotchState.expandedSize.width : 72,
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
    var sessionNeedsAttention = false
    var kanbanNeedsAttention = false
    var kanbanHasUpdate = false
    var hasUpdate: Bool { unread || backgroundCompleted || responseCompleted || kanbanHasUpdate }
    var quiet: Bool { !working && !attention && !hasUpdate && status == .idle }

    func shouldAnnounce(after previous: Self) -> Bool {
        (working && !previous.working) || runningCount != previous.runningCount
            || (unread && !previous.unread) || (attention && status != previous.status)
    }

    var working: Bool { status == .working || runningCount > 0 || kanbanRunningCount > 0 }
    var attention: Bool { status == .needsApproval || status == .needsClarification || kanbanNeedsAttention || sessionNeedsAttention }
    var title: String {
        if status == .needsApproval || status == .needsClarification { return status.title }
        if sessionNeedsAttention { return "Needs your attention" }
        if kanbanNeedsAttention { return "Kanban card blocked" }
        if unread { return "New response" }
        if backgroundCompleted { return "Background task completed" }
        if responseCompleted { return "Response completed" }
        if runningCount > 0 { return "\(runningCount) background \(runningCount == 1 ? "task" : "tasks") running" }
        if status == .working || status == .offline { return status.title }
        if kanbanRunningCount > 0 { return "\(kanbanRunningCount) Kanban \(kanbanRunningCount == 1 ? "card" : "cards") running" }
        if kanbanHasUpdate { return "Kanban activity updated" }
        return "Open Herm"
    }
    var symbol: Ph {
        if kanbanNeedsAttention || sessionNeedsAttention { return .warningCircle }
        if attention { return status.icon }
        if unread { return .chat }
        if backgroundCompleted || responseCompleted || kanbanHasUpdate { return .check }
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
    static func movedProviders(from previous: [ProviderQuotaSnapshot], to current: [ProviderQuotaSnapshot]) -> [String] {
        current.filter { snapshot in
            guard let old = previous.first(where: { $0.provider == snapshot.provider }) else { return false }
            return snapshot.windows.contains { window in
                guard let now = window.remainingPercent,
                      let before = old.windows.first(where: { $0.id == window.id })?.remainingPercent else { return false }
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
    @Published var composing = false
    @Published var quickTarget: HermesSession?
    @Published var quickReplyTask: EdgeNotchTask?
    @Published var quickCreatedSession: HermesSession?
    private var quickDrafts: [String: String] = [:]
    private var quickDraftKey: String { quickTarget.map { "\($0.profileID ?? "")/\($0.id)" } ?? "new" }

    func selectQuickTarget(_ target: HermesSession?, task: EdgeNotchTask? = nil) {
        guard !quickSending else { return }
        quickDrafts[quickDraftKey] = quickDraft
        quickTarget = target
        quickReplyTask = task
        quickDraft = quickDrafts[quickDraftKey] ?? ""
        quickResult = nil
    }

    /// A new-message draft belongs to its profile too. Wait for any captured send
    /// to finish before the controller calls this on a profile change.
    func resetQuickComposition() {
        guard !quickSending else { return }
        quickDrafts.removeAll()
        quickTarget = nil; quickReplyTask = nil; quickCreatedSession = nil
        quickDraft = ""; quickResult = nil; composing = false
    }

    var previewTasks: [EdgeNotchTask] {
        guard composing, let quickReplyTask, !tasks.contains(where: { $0.id == quickReplyTask.id }) else { return tasks }
        return tasks + [quickReplyTask]
    }

    @Published var quickDraft = ""
    @Published var quickSending = false
    @Published var quickResult: String?
    @Published var bots: [BotSummary] = []
    @Published var avatarImages: [String: Data] = [:]
    @Published var expanded = false
    @Published var hasPet = false
    var externalPet = false
    @Published var side: EdgeDockSide = .right
    @Published var activity = EdgeNotchActivity()
    @Published var name = "Hermes"
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
    @Published var detail = "Open your conversation"
    /// Sessions in progress or finished with a result not yet opened,
    /// including the current session when it has live activity.
    @Published var tasks: [EdgeNotchTask] = []
    @Published var kanbanUnavailable = false
    /// Fixed so refreshes and task arrivals never resize the preview.
    static let expandedSize = CGSize(width: 368, height: 360)
    static let previewSize = CGSize(width: 352, height: 312)
    var railActivity: EdgeNotchActivity {
        var result = activity
        result.sessionNeedsAttention = tasks.contains { $0.kanbanTask == nil && $0.phase == .attention && $0.isStatusCurrent }
        let cards = tasks.filter { $0.kanbanTask != nil && $0.isStatusCurrent }
        result.kanbanRunningCount = cards.filter { $0.phase == .working }.count
        result.kanbanNeedsAttention = cards.contains { $0.phase == .attention }
        result.kanbanHasUpdate = cards.contains { $0.phase != .working }
        return result
    }
    var showsSeparateWork: Bool { railActivity.working && (railActivity.hasUpdate || railActivity.attention) }
    var isQuiet: Bool { railActivity.quiet && !expanded }
    @Published var petAttached = true
    @Published var petDragging = false
    @Published var petPull = 0.0
    /// The collapsed bar widens to receive a dragged pet and stays a little wider while it is docked.
    var barWidth: CGFloat {
        if petDragging { return 22 + (petAttached ? 8 : 20) * petPull }
        return hasPet && petAttached ? 30 : 22
    }
    /// Accent glow grows as a free pet is dragged toward the notch.
    var barGlow: Double { petDragging && !petAttached ? petPull : 0 }
    var railWidth: CGFloat { expanded ? 72 : 44 }
    var petReserve: CGFloat { hasPet ? Self.petFootprint : 0 }
    static let petFootprint: CGFloat = 48
    var railHeight: CGFloat { expanded ? 136 : 72 }
    var panelHeight: CGFloat { (expanded ? Self.expandedSize.height : railHeight) + petReserve }
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
    var onAnswer: (EdgeNotchTask, String) -> Void = { _, _ in }
    @ObservedObject private var theme = DockThemeStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let openDock: () -> Void
    var onOpenTask: (EdgeNotchTask) -> Void = { _ in }
    var onDrag: (Bool) -> Void = { _ in }
    var onCallPetHome: () -> Void = {}
    var onSideChange: (EdgeDockSide) -> Void = { _ in }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 4) {
            HStack(spacing: 0) {
                if state.expanded {
                    // The outer contour already supplies visual breathing room.
                    // Keep the preview close to it so its content does not float
                    // in the middle of the expanded notch.
                    preview.frame(width: EdgeNotchState.previewSize.width, height: EdgeNotchState.previewSize.height)
                        .padding(.horizontal, 8)
                        .transition(.opacity)
                } else {
                    rail
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height - state.petReserve,
                   alignment: state.side == .right ? .trailing : .leading)
            .background {
                if state.expanded {
                    DockWindowBackground().clipShape(EdgeNotchShape(side: state.side))
                        .overlay { EdgeNotchShape(side: state.side).stroke(Color.dockBorderStrong, lineWidth: 1) }
                }
            }
            // Attach drag gesture to parent so it works in both collapsed and expanded states
            .simultaneousGesture(DragGesture(minimumDistance: 6)
                .onChanged { _ in onDrag(false) }
                .onEnded { _ in onDrag(true) })
                if state.hasPet && !state.externalPet {
                    HermesNotchPetButton(pet: controlCenter.pet, mirrored: state.side == .left)
                        .frame(maxWidth: .infinity, alignment: state.side == .right ? .trailing : .leading)
                } else if state.hasPet {
                    Color.clear.frame(height: max(44, state.petReserve - 4)).allowsHitTesting(false)
                }
            }
        }
        .clipped()
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: state.expanded)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.isQuiet)
        .dockThemedRoot()
        .preferredColorScheme(theme.selectedThemeID.appearance == .light ? .light : theme.selectedThemeID.appearance == .dark ? .dark : nil)
        .id(theme.selectedThemeID)
    }

    private var rail: some View {
        Button(action: openDock) {
            EdgePetRail(activity: state.railActivity, side: state.side, width: state.barWidth, glow: state.barGlow, docked: state.petAttached && state.hasPet)
            .frame(width: state.railWidth, height: state.railHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if state.hasPet { Button("Attach pet to notch", action: onCallPetHome).disabled(state.petAttached) }
            Button("Move to left edge") { onSideChange(.left) }
            Button("Move to right edge") { onSideChange(.right) }
            Divider()
            Button("Quit Herm") { NSApp.terminate(nil) }
        }
        .accessibilityLabel("\(state.name), \(state.railActivity.title). Open Herm")
        .accessibilityHint("Drag to move along either screen edge")
        .help("\(state.railActivity.title). Hover for details; drag to reposition.")
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                HStack(spacing: 2) {
                    tabButton("Tasks", isSelected: !state.displaysQuota && !state.displaysStatus) {
                        onQuickMessageFocus(false); state.showingAnnouncement = false; state.showsQuota = false
                    }
                    tabButton("Quota", isSelected: state.displaysQuota) {
                        onQuickMessageFocus(false); state.showingAnnouncement = false; state.showsQuota = true; onQuotaRequested()
                    }
                }
                .padding(2)
                .background(Capsule().fill(Color.dockSurface4.opacity(0.6)))
                Spacer()
                if state.displaysQuota {
                    EdgeQuotaToolbar(control: controlCenter)
                } else {
                    taskToolbar
                }
            }
            .frame(height: 40)
            .padding(.horizontal, 6)
            Divider().overlay(Color.dockBorderLight)
            if state.composing, state.quickTarget == nil, let quickMessageModel {
                EdgeQuickMessageView(model: quickMessageModel, state: state,
                                     close: { onQuickMessageFocus(false) }, openDock: openDock)
            } else if state.displaysQuota {
                EdgeQuotaPreview(control: controlCenter, openQuota: onOpenQuota, change: state.announcedQuotaChange)
            } else {
                EdgeTaskPreview(tasks: state.previewTasks, isOffline: state.activity.status == .offline,
                                quotaChange: state.displaysStatus ? state.announcedQuotaChange : nil,
                                kanbanUnavailable: state.kanbanUnavailable,
                                bots: state.bots, avatarImages: state.avatarImages,
                                quickMessage: quickMessageModel == nil ? nil : {
                                    guard !state.quickSending else { return }
                                    state.selectQuickTarget(nil)
                                    onQuickMessageFocus(true)
                                },
                                reply: quickMessageModel == nil ? nil : onQuickReply,
                                quickState: state, quickModel: quickMessageModel,
                                closeReply: { onQuickMessageFocus(false) },
                                answer: onAnswer,
                                openDock: openDock, openTask: onOpenTask)
            }
        }
    }

    private var taskToolbar: some View {
        let refreshing = state.refreshingSessions
            || controlCenter.refreshState(for: "kanban.global")?.isRefreshing == true
        let unavailable = state.activity.status == .offline || state.kanbanUnavailable
        return Button(action: onTasksRefresh) {
            Group {
                if refreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    DockIcon(unavailable ? .warningCircle : .arrowClockwise, size: 13,
                             color: unavailable ? .dockWarning : .dockSecondaryText)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(refreshing || state.activity.status == .offline)
        .help(unavailable ? "Status unavailable. Refresh tasks" : "Refresh tasks")
        .accessibilityLabel(unavailable ? "Status unavailable. Refresh tasks" : "Refresh tasks")
    }

    private func tabButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.dockAccent : Color.dockSecondaryText)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Capsule().fill(isSelected ? Color.dockAccentMuted : .clear))
                .overlay(Capsule().strokeBorder(isSelected ? Color.dockAccent.opacity(0.45) : .clear, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Dots told apart by motion and fill as well as color: breathing = working
/// or attention, held = done, hollow = offline. Work keeps its own dot
/// beneath attention or done so a blocked card never hides a running task.
private struct EdgePetRail: View {
    @AppStorage(NotchDisplayStyle.defaultsKey) private var displayStyle: NotchDisplayStyle = .dots
    let activity: EdgeNotchActivity
    let side: EdgeDockSide
    var width: CGFloat = 22
    var glow = 0.0
    var docked = false
    @State private var flash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                if side == .right { Spacer(minLength: 0) }
                EdgeNotchStatusIndicator(activity: activity, style: displayStyle)
                    .frame(width: width, height: 72)
                    .background {
                        DockWindowBackground().clipShape(EdgeNotchShape(side: side))
                            .overlay { EdgeNotchShape(side: side).stroke(Color.dockBorderStrong, lineWidth: 1) }
                            .overlay { EdgeNotchShape(side: side).stroke(Color.accentColor, lineWidth: 2).opacity(flash ? 1 : glow * 0.8) }
                    }
                    .animation(reduceMotion ? nil : .interactiveSpring(response: 0.28, dampingFraction: 0.68), value: width)
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

/// Concave shoulders meet the physical screen edge; the inner face is rounded.
struct EdgeNotchShape: Shape {
    var side: EdgeDockSide = .right

    func path(in rect: CGRect) -> Path {
        let shoulder: CGFloat = min(24, rect.width / 3)
        let radius: CGFloat = min(30, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - shoulder, y: rect.minY + shoulder),
                          control: CGPoint(x: rect.maxX, y: rect.minY + shoulder))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY + shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + shoulder + radius),
                          control: CGPoint(x: rect.minX, y: rect.minY + shoulder))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - shoulder - radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY - shoulder),
                          control: CGPoint(x: rect.minX, y: rect.maxY - shoulder))
        path.addLine(to: CGPoint(x: rect.maxX - shoulder, y: rect.maxY - shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY - shoulder))
        path.closeSubpath()
        if side == .left {
            return path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0))
        }
        return path
    }
}

final class EdgeDockHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChanged: ((Bool) -> Void)?
    var bottomHoverExclusion: CGFloat = 0 { didSet { updateTrackingAreas() } }
    private var lastNotchHover: Bool?
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        hoverArea = area
        addTrackingArea(area)
    }
    func notchHoverContains(_ point: NSPoint) -> Bool {
        bounds.contains(point) && (isFlipped ? bounds.maxY - point.y : point.y - bounds.minY) >= bottomHoverExclusion
    }
    private func updateNotchHover(_ event: NSEvent) {
        let inside = notchHoverContains(convert(event.locationInWindow, from: nil))
        guard lastNotchHover != inside else { return }
        lastNotchHover = inside; onHoverChanged?(inside)
    }
    override func mouseEntered(with event: NSEvent) { updateNotchHover(event) }
    override func mouseMoved(with event: NSEvent) { updateNotchHover(event) }
    override func mouseExited(with event: NSEvent) {
        // Leaving via the pet must still schedule collapse after leaving the panel.
        lastNotchHover = nil; onHoverChanged?(false)
    }
}
