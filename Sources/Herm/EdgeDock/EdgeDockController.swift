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
    private var deferredCompletionDetail: DispatchWorkItem?
    private var expandTask: DispatchWorkItem?
    private lazy var frameTransition = EdgePanelFrameTransition(panel: panel)
    private var hovering = false
    private var dragging = false
    private var petDragging = false
    private var suppressClickUntil = Date.distantPast
    private var workspacePresented = false
    private var runtimeStarted = false
    private let voiceConversation = EdgeQuickConversationModel()
    private lazy var notchVoiceModel: DockModel = {
        let voice = voiceConversation.prepareVoice(runtime: model)
        voice.voiceAssistant.control = controlCenter
        return voice
    }()
    private lazy var voiceIsland = EdgeVoiceIsland(model: model)
    private lazy var notchVoiceIsland = EdgeVoiceIsland(model: notchVoiceModel)
    private var quickProfileID: String?
    private var completedTaskIDs: Set<String>?
    private var finishedBots = EdgeFinishedBotAcknowledgements()
    private var finishedBotsOwner: String?
    private var routineEvents: [String: String] = [:]
    private var observedRoutineProfiles = Set<String>()
    private var latestToolID: String?
    private var latestToolComplete = false
    private var kanbanActivity = EdgeKanbanActivity()
    private var lastKanbanRead: Date?
    private var lastKanbanPoll: Date?
    private var kanbanStatusCurrent = false
    private var latestSessions: [HermesSession] = []
    private var latestAttention: [String: DockModel.SessionAttention] = [:]
    private var latestAnswers: [AttentionRequest: AttentionAnswerState] = [:]
    private var deliveryQuestions: [EdgeDeliveryQuestion] = []
    private var deliveryQuestionWatch: EdgeDeliveryQuestionWatch?
    private var deliveryQuestionPoll: Task<Void, Never>?
    private var deliveryQuestionRefreshPending = false
    private var latestActivityLabels: [String: String] = [:]
    private var lastQuotas: [ProviderQuotaSnapshot]?
    /// Quota readers whose usage has moved; these are the services being
    /// spent (by Hermes or any other app), so they are read on every tick.
    private var hotQuotaReaders: [String: Date] = [:]
    private var quotaTick = 0
    private var lastQuotaPoll: Date?
    private var displayID: NSNumber?
    private var fraction: CGFloat = 0.5
    private let defaults: UserDefaults

    init(
        model: DockModel, controlCenter: ControlCenterModel, defaults: UserDefaults = .standard,
        interruptions: HermInterruptionCoordinator? = nil, openQuota: @escaping () -> Void,
        openKanban: @escaping (KanbanTaskSummary) -> Void, openDock: @escaping () -> Void,
        startsRuntime: Bool = true
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
            if self.state.petDragging != dragging { self.state.petDragging = dragging }
            // The contour travels at most a few points per step. Keep raw mouse samples
            // out of the notch state, especially when the pet is outside its reach.
            let step = (pull * 64).rounded() / 64
            if self.state.petPull != step { self.state.petPull = step }
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
                quickMessageModel: model, notchVoiceModel: notchVoiceModel,
                onToggleVoice: { [weak self] in self?.toggleVoiceFromPreview() },
                onMinimizeVoice: { [weak self] in self?.minimizeVoiceStage() },
                onQuickMessageFocus: { [weak self] active in self?.setQuickMessageFocus(active) },
                onQuickReply: { [weak self] task in self?.beginQuickReply(task) },
                onResultPeek: { [weak self] task in self?.peekResult(task) },
                onMarkFinishedRead: { [weak self] targets in self?.markFinishedRead(targets) },
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
        NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: panel)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel))
            .compactMap { ($0.object as? NSWindow)?.frame.maxY }
            .removeDuplicates()
            .sink { [weak self] top in self?.state.windowTop = top }
            .store(in: &subscriptions)
        panel.onCancel = { [weak self] in self?.escapePreview() }
        installInteractionMonitors()
        model.notchVoiceNoticeTarget = notchVoiceModel
        model.voiceCapture.standby = notchVoiceModel
        Publishers.CombineLatest4(
            model.$voiceState.map(\.isNativeConversationActive).removeDuplicates(),
            notchVoiceModel.$voiceState.map(\.isNativeConversationActive).removeDuplicates(),
            model.voiceStage.$mountedTalkStages.map { $0 > 0 }.removeDuplicates(), state.$side.removeDuplicates()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.updateVoiceStage() }
        .store(in: &subscriptions)
        // The collapsed dot follows actual microphone startup and shutdown.
        notchVoiceModel.$voiceState.map { _ in () }
            .merge(with: notchVoiceModel.voiceMic.$isRunning.removeDuplicates().map { _ in () })
            .merge(with: notchVoiceModel.voiceMic.$isPreparingSpeech.removeDuplicates().map { _ in () })
            .merge(with: notchVoiceModel.voiceMic.$errorMessage.removeDuplicates().map { _ in () })
            .merge(with: model.botMode.$inventory.map { _ in () })
            .merge(with: NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshVoiceWake() }
            .store(in: &subscriptions)
        model.voiceTimers.$soonest
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] soonest in
                guard let self, self.state.countdown != soonest else { return }
                self.state.countdown = soonest
                self.position(animated: true)
            }
            .store(in: &subscriptions)
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
        state.interruptions.sessionCompletions.receive(on: RunLoop.main)
            .sink { [weak self] notice in
                guard let self else { return }
                let current =
                    self.model.currentSessionIDs.contains {
                        self.model.rowSessionID($0) == notice.sourceID
                    }
                    && notice.profileID == (self.model.sessionProfileID ?? self.model.profileScopeID)
                if current, self.model.status != .working {
                    self.state.activity.responseCompleted = true
                    self.updateDetail()
                }
                self.announce(notice: notice)
                self.pollQuota(afterWork: true)
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
        model.$allBotSessionsState.dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildTasks() }
            .store(in: &subscriptions)
        controlCenter.$cronJobs.combineLatest(controlCenter.$cronRuns)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.routineUpdates()
                self?.rebuildTasks()
            }.store(in: &subscriptions)
        state.preferences.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildTasks() }.store(in: &subscriptions)
        // The widget's unfold changes its height every frame; resize the window once it settles,
        // not per frame (each resize re-lays out the whole notch and drops frames).
        state.$voiceHeight.removeDuplicates().debounce(for: .milliseconds(90), scheduler: RunLoop.main)
            .sink { [weak self] _ in if self?.state.voiceLive == true { self?.position(animated: true) } }
            .store(in: &subscriptions)
        state.$showingAnnouncement.combineLatest(state.$glimpseHeight)
            .removeDuplicates { $0 == $1 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in if self?.state.expanded == true { self?.position(animated: true) } }
            .store(in: &subscriptions)
        state.$side.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] side in
                guard let self else { return }
                self.panel.appearance = EdgeNotchState.themeSurface(for: side).windowAppearance
            }.store(in: &subscriptions)
        state.$composing.combineLatest(state.$quickTarget, state.$quickCreatedSession, state.$quickDraftHeight)
            .map { composing, target, created, height in
                composing ? (target == nil && created == nil ? height : EdgeNotchState.quickMessageHeight) : 0
            }
            .removeDuplicates().receive(on: RunLoop.main)
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
        model.sessionActivityLabelUpdates
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in
                guard let self else { return }
                latestActivityLabels = self.model.sessionActivityLabels
                rebuildTasks()
            }
            .store(in: &subscriptions)
        model.$botActivityRevision.map { _ in () }
            .merge(with: model.$botLiveSteps.map { _ in () })
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.rebuildTasks() }
            .store(in: &subscriptions)
        model.activityPresentation.$revision
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.refreshProgress() }
            .store(in: &subscriptions)
        controlCenter.$projectionRefreshStates
            .map { $0["kanban.global"] }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshKanbanActivity() }
            .store(in: &subscriptions)
        Timer.publish(every: EdgeNotchPolling.kanbanInterval, tolerance: 3, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                self?.pollKanban(force: false)
                self?.pollBots()
            }
            .store(in: &subscriptions)
        model.botMode.$inventory.combineLatest(model.botMode.$avatarImages)
            .receive(on: RunLoop.main)
            .sink { [weak self] inventory, avatars in
                guard let self, inventory.availability == .ready else { return }
                if self.state.bots != inventory.bots { self.state.bots = inventory.bots }
                if self.state.avatarImages != avatars { self.state.avatarImages = avatars }
            }.store(in: &subscriptions)
        model.botMode.$activity
            .receive(on: RunLoop.main)
            .sink { [weak self] board in
                guard let self, self.state.botActivity != board else { return }
                self.state.botActivity = board
            }.store(in: &subscriptions)
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
        model.presentationDemand.$hasVisibleHost.combineLatest(state.$expanded)
            .map { EdgeNotchPolling.quotaInterval(workspaceVisible: $0, previewExpanded: $1) }
            .removeDuplicates()
            .map { interval in
                Timer.publish(every: interval, tolerance: interval / 5, on: .main, in: .common).autoconnect()
            }
            .switchToLatest()
            .sink { [weak self] _ in self?.pollQuota() }
            .store(in: &subscriptions)
        model.presentationDemand.$hasVisibleHost.removeDuplicates()
            .dropFirst()
            .sink { [weak self] visible in
                if visible { self?.pollQuota(force: true) }
            }.store(in: &subscriptions)
        model.$currentSessionTitle
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateDetail() }
            .store(in: &subscriptions)
        model.$messages
            .map { $0.last(where: { $0.role == .hermes }) }
            .removeDuplicates { $0?.id == $1?.id && $0?.contentRevision == $1?.contentRevision }
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateDetail() }.store(in: &subscriptions)
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
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .compactMap { [weak self] _ in self?.notchEnabled }
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.ensureNotchVisible() }
            .store(in: &subscriptions)
        model.voiceCapture.onStartNotchVoice = { [weak self] in self?.startVoice() }
        ensureNotchVisible()
        if startsRuntime { startRuntime() }
    }

    func startRuntime() {
        guard !runtimeStarted else { return }
        runtimeStarted = true
        controlCenter.bind(to: model)
        refreshVoiceWake()
        Just(()).delay(for: .seconds(30), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self, self.lastQuotaPoll == nil else { return }
                self.pollQuota()
            }.store(in: &subscriptions)
        // Delivery questions are files in this Mac's Hermes home. A remote backend writes its own.
        if GatewayConnectionStore.isLocalBackend {
            deliveryQuestionWatch = EdgeDeliveryQuestionWatch(directory: EdgeDeliveryQuestion.directory) {
                [weak self] in
                self?.pollDeliveryQuestions()
            }
            refreshDeliveryQuestionWatch()
            // Recover from a replaced ancestor or a filesystem that missed a notification.
            Timer.publish(
                every: EdgeNotchPolling.deliveryQuestionRecoveryInterval, tolerance: 12, on: .main, in: .common
            )
            .autoconnect()
            .sink { [weak self] _ in self?.refreshDeliveryQuestionWatch() }
            .store(in: &subscriptions)
        }
    }

    private var notchEnabled: Bool { defaults.object(forKey: NotchDisplayStyle.enabledKey) as? Bool ?? true }

    private func ensureNotchVisible() {
        guard !workspacePresented else { return }
        guard notchEnabled else {
            panel.orderOut(nil)
            petWindow?.hide()
            return
        }
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
        updateVoiceStage()
    }

    func restoreNotch() {
        workspacePresented = false
        state.activity.backgroundCompleted = false
        state.activity.responseCompleted = false
        ensureNotchVisible()
        surfaceDigestIfPossible()
        updateVoiceStage()
    }

    private func startVoice() {
        if let owner = model.voiceCapture.owner, owner.voiceState.isNativeConversationActive {
            if owner.voiceState == .paused { owner.resumeVoiceListening(force: true) }
            return
        }
        model.stopVoiceAnnouncement()
        notchVoiceModel.startLocalVoiceAssistant()
    }

    func toggleVoice() {
        let target = model.voiceCapture.owner ?? notchVoiceModel
        if target === notchVoiceModel { model.stopVoiceAnnouncement() }
        target.toggleVoiceFromShortcut()
    }

    func minimizeVoiceStage() {
        guard let visible = state.voicePreviewModel else { return }
        state.minimizedVoiceModel = visible
        hovering = false
        notchHost?.resetNotchHover()
        updateVoiceStage()
    }

    func toggleVoiceFromPreview() {
        if state.minimizedVoiceModel != nil {
            state.minimizedVoiceModel = nil
            updateVoiceStage()
        } else {
            toggleVoice()
        }
    }

    private func refreshVoiceWake() {
        guard runtimeStarted else { return }
        notchVoiceModel.refreshIdleWake()
        let mic = notchVoiceModel.voiceMic
        let enabled = VoiceWakeShortcut.wakeWordEnabled
        let paused =
            notchVoiceModel.voiceState == .paused
            && !notchVoiceModel.isVoiceMicMuted && notchVoiceModel.voiceWakesByVoice
        let listening =
            (notchVoiceModel.listensForIdleWake || paused) && mic.isRunning && mic.errorMessage == nil
            && !mic.isPreparingSpeech && mic.utteranceTranscript != nil
        let error = enabled ? mic.errorMessage : nil
        if state.wakeError != error { state.wakeError = error }
        let hadIndicator = state.showsWakeIndicator
        if state.wakeEnabled != enabled { state.wakeEnabled = enabled }
        if state.wakeListening != listening { state.wakeListening = listening }
        if state.showsWakeIndicator != hadIndicator { position(animated: true) }
    }

    /// Shows a live voice conversation, unless a Talk tab already does: inside Herm's own
    /// notch (top or side) when it is on screen, else in the standalone voice widget.
    private func updateVoiceStage() {
        let notchVoiceActive = notchVoiceModel.voiceState.isNativeConversationActive
        let workspaceVoice = EdgeVoiceStagePlacement.resolve(
            voiceActive: model.voiceState.isNativeConversationActive, talkTabShowing: model.mountedTalkStages > 0)
        let active = notchVoiceActive ? notchVoiceModel : model.voiceState.isNativeConversationActive ? model : nil
        if let minimized = state.minimizedVoiceModel, minimized !== active { state.minimizedVoiceModel = nil }
        let showVoice = state.minimizedVoiceModel == nil
        let inNotch =
            showVoice && (notchVoiceActive || workspaceVoice == .island) && notchEnabled && !workspacePresented
        let visibleModel = inNotch ? (notchVoiceActive ? notchVoiceModel : model) : nil
        let wasInNotch = state.voiceLive
        if state.voicePreviewModel !== visibleModel { state.voicePreviewModel = visibleModel }
        if wasInNotch != inNotch {
            collapseTask?.cancel()
            expandTask?.cancel()
            if inNotch {
                state.previewInteraction.mode = .passive
                state.clearPreviewDetails()
                state.composing = false
                state.showingAnnouncement = false
                setExpanded(true)
            } else {
                setExpanded(hovering)
            }
        }
        let attachment = inNotch ? placement.map(attachedVoicePreview) : nil
        voiceIsland.show(
            showVoice && workspaceVoice == .island && !notchVoiceActive,
            attachedTo: visibleModel === model ? attachment : nil)
        notchVoiceIsland.show(
            showVoice && notchVoiceActive, attachedTo: visibleModel === notchVoiceModel ? attachment : nil)
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

    private func markFinishedRead(_ targets: EdgeFinishedReadTargets) {
        finishedBots.acknowledge(targets.bots)
        var sessions = targets.sessions
        if targets.includesCurrent {
            sessions += latestSessions.filter {
                model.currentSessionIDs.contains($0.id) && $0.profileID == model.sessionProfileID
            }
            state.activity.backgroundCompleted = false
            state.activity.responseCompleted = false
            model.markResponseRead()
        }
        model.markSessionsRead(sessions, at: .now)
        for card in targets.kanban { kanbanActivity.acknowledge(card) }
        let notices = state.interruptions.entries.filter { notice in
            notice.kind == .completion && notice.source == .session
                && sessions.contains { $0.id == notice.sourceID && $0.profileID == notice.profileID }
        }
        for notice in notices { state.interruptions.review(notice.id) }
        rebuildTasks()
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
            let currentIDs = Set(model.currentSessionIDs.map { model.rowSessionID($0) })
            let previousWorking = previous.filter {
                !$0.isCurrent && $0.session != nil && $0.isStatusCurrent && $0.phase == .working
                    && !currentIDs.contains(model.rowSessionID($0.id))
            }
            for task in state.tasks
            where !task.isCurrent && task.session != nil && task.isStatusCurrent && task.phase == .finished
                && !currentIDs.contains(model.rowSessionID(task.id))
                && previousWorking.contains(where: {
                    $0.id == task.id && $0.session?.profileID == task.session?.profileID
                })
            {
                announce(notice: model.interruptionNotice(.completion, owner: task.id))
            }
            pollQuota(afterWork: true)
        }
    }

    /// Every session in progress or finished-but-unopened, with the open
    /// session contributing its own live activity instead of the index flag.
    private func rebuildTasks() {
        if finishedBotsOwner != model.profileScopeID {
            finishedBots = EdgeFinishedBotAcknowledgements()
            finishedBotsOwner = model.profileScopeID
        }
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
                profileID: model.activeBotProfileID ?? model.sessionProfileID,
                attentionState: request.map { $0.status == .needsClarification ? .clarification : .approval })
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
                attentionRequest: target,
                attentionState: request.status == .needsClarification ? .clarification : .approval)
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
        tasks.removeAll { finishedBots.isAcknowledged($0) }
        tasks = EdgeNotchTask.merged(tasks)
        publishLiveBotWork(tasks, hasCurrentRequest: request != nil)
        if tasks != state.tasks {
            state.invalidateNewerResults(tasks)
            state.tasks = tasks
            position(animated: true)
        }
        controlCenter.pet.updateNotchActivity(
            working: state.railActivity.working || tasks.contains { $0.isStatusCurrent && $0.phase == .working },
            attention: state.railActivity.attention || tasks.contains { $0.isStatusCurrent && $0.phase == .attention })
    }

    private func publishLiveBotWork(_ tasks: [EdgeNotchTask], hasCurrentRequest: Bool) {
        let status = state.activity.status
        guard status != .offline else {
            model.updateLiveBotWork([])
            return
        }
        let hasCurrentTurn = hasCurrentRequest || [.working, .needsApproval, .needsClarification].contains(status)
        let scope = model.profileScopeID ?? model.botMode.bots.first(where: \.isDefault)?.id
        var work = tasks.compactMap { task -> BotLiveWork? in
            guard !task.isCurrent || hasCurrentTurn else { return nil }
            return task.liveBotWork(scopeProfileID: scope, currentSessionID: model.sessionID)
        }
        // The office also has desks for profiles outside the notch's session list.
        if case .ready(let sessions) = model.allBotSessionsState {
            let represented = Set(tasks.compactMap { $0.session?.id })
                .union(model.currentSessionIDs.map { model.rowSessionID($0) })
            let background = sessions.filter {
                $0.profileID != nil && $0.isWorking && model.recentIndexByID[$0.id] == nil
                    && !represented.contains($0.id)
            }
            let rows = EdgeNotchTask.build(
                current: nil, sessions: background, activity: latestActivityLabels,
                currentSessionIDs: [], isOnline: true, attention: latestAttention)
            work += EdgeNotchTask.merged(rows).compactMap {
                $0.liveBotWork(scopeProfileID: nil, currentSessionID: nil)
            }
        }
        let origin = model.sessionStorageID ?? model.sessionID ?? ""
        let handoffs = Dictionary(
            model.botActivityBySessionID[origin, default: []].compactMap { record -> (ProfileScopedID, String)? in
                guard record.isLive, !record.isKanbanReference, let id = record.botChatSessionID else { return nil }
                return (ProfileScopedID(profileID: record.botID, resourceID: id), record.originSessionID)
            }, uniquingKeysWith: { _, newest in newest })
        for index in work.indices {
            guard work[index].originSessionID == nil, let id = work[index].sessionID else { continue }
            work[index].originSessionID = handoffs[ProfileScopedID(profileID: work[index].profileID, resourceID: id)]
        }
        model.updateLiveBotWork(work)
    }

    private func refreshDeliveryQuestionWatch() {
        deliveryQuestionWatch?.restart()
        pollDeliveryQuestions()
    }

    /// Headless coordinator turns cannot ask; the delivery plugin queues their questions as files.
    private func pollDeliveryQuestions() {
        guard deliveryQuestionWatch != nil else { return }
        guard deliveryQuestionPoll == nil else {
            deliveryQuestionRefreshPending = true
            return
        }
        deliveryQuestionPoll = Task { [weak self] in
            let questions = await EdgeDeliveryQuestion.loadOffMain()
            guard !Task.isCancelled, let self else { return }
            self.deliveryQuestionPoll = nil
            if self.deliveryQuestionRefreshPending {
                self.deliveryQuestionRefreshPending = false
                self.pollDeliveryQuestions()
                return
            }
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
                        self.pollDeliveryQuestions()
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
                        self.pollDeliveryQuestions()
                        return
                    }
                } catch {
                    self.state.deliveryAnswers[question] = .answered(
                        choice, "Answer sent. The saved question could not be removed; open the session to review it.")
                    self.rebuildTasks()
                    return
                }
                self.pollDeliveryQuestions()
            }
            return
        }
        guard let request = task.attentionRequest else { return }
        model.answerAttention(request, choice: choice)
    }

    private func refreshSelectedTasks() {
        guard runtimeStarted else { return }
        pollKanban()
        pollBots(interactive: true)
        model.loadSessions()
    }

    private func pollKanban(force: Bool = true) {
        guard runtimeStarted else { return }
        let now = Date()
        let shouldPoll = EdgeNotchPolling.shouldPollKanban(
            now: now, lastPoll: lastKanbanPoll, isWorking: state.activity.working,
            isOffline: model.status == .offline, force: force)
        guard shouldPoll else { return }
        lastKanbanPoll = now
        controlCenter.refreshGlobalKanban(trigger: .background)
    }

    private func pollBots(interactive: Bool = false) {
        guard runtimeStarted, model.status != .offline else { return }
        let active =
            interactive || model.presentationDemand.hasVisibleHost || state.expanded
            || state.railActivity.working || state.railActivity.attention
        let interval = active ? EdgeNotchPolling.kanbanInterval : EdgeNotchPolling.idleInventoryInterval
        Task { [weak self] in
            await self?.model.botMode.refreshNow(
                probeCapability: true, minimumInterval: interval)
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
        state.activity = EdgeNotchActivity(
            status: status, unread: unread,
            runningCount: tasks.filter { $0.status == .running }.count,
            backgroundCompleted: newCompletion || (previous.backgroundCompleted && !completed.isEmpty),
            responseCompleted: previous.responseCompleted && status != .working)
        updateDetail()
        if state.activity.shouldAnnounce(after: previous) {
            announce(
                notice: model.interruptionNotice(
                    status == .needsApproval ? .approval : .clarification))
        } else {
            position(animated: true)
        }
        if newCompletion { pollQuota(afterWork: true) }
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
        guard runtimeStarted else { return }
        collapseTask?.cancel()
        controlCenter.bind(to: model)
        guard controlCenter.refreshState(for: "provider.quota")?.isRefreshing != true else { return }
        let lastRead = controlCenter.providerQuotaFreshness.checkedAt.values.max()
        if lastRead == nil || Date().timeIntervalSince(lastRead!) > 60 {
            controlCenter.refreshProviderQuota()
        }
    }

    /// Every 30s tick reads the providers being spent; every other tick
    /// reads them all, so a provider that starts moving is picked up. Right
    /// after work finishes, the spent providers are read at once so their
    /// final usage joins the completion preview.
    private func pollQuota(afterWork: Bool = false, force: Bool = false) {
        // Keeps reading while the workspace is open: the chat header shows it too.
        guard runtimeStarted, controlCenter.refreshState(for: "provider.quota")?.isRefreshing != true else { return }
        let now = Date()
        let interval = EdgeNotchPolling.quotaInterval(
            workspaceVisible: model.presentationDemand.hasVisibleHost, previewExpanded: state.expanded)
        guard force || afterWork || (lastQuotaPoll.map { now.timeIntervalSince($0) >= interval } ?? true) else {
            return
        }
        lastQuotaPoll = now
        hotQuotaReaders = hotQuotaReaders.filter { now.timeIntervalSince($0.value) < 120 }
        quotaTick &+= 1
        let fullRead = hotQuotaReaders.isEmpty || (!afterWork && quotaTick.isMultiple(of: 2))
        controlCenter.refreshProviderQuota(only: fullRead ? nil : Set(hotQuotaReaders.keys), quiet: !afterWork)
    }

    private func quotaChanged(_ quotas: [ProviderQuotaSnapshot]) {
        // An empty list is a reset (rebind or failed read), not a reading.
        guard !quotas.isEmpty else { return }
        defer { lastQuotas = quotas }
        if let previousQuotas = lastQuotas {
            for provider in EdgeQuotaBands.movedProviders(from: previousQuotas, to: quotas) {
                if let reader = controlCenter.quotaReaderID(for: provider) { hotQuotaReaders[reader] = Date() }
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

    /// The shared roster publishes activity notifications with stable stamps.
    private func announceBots(_ events: [BotActivityEvent]) {
        for event in events {
            _ = state.interruptions.admit(
                HermNotice(
                    kind: .information, source: .activity, profileID: event.botID,
                    sourceID: "bot", eventID: event.id + "/" + event.stamp), channel: .notch)
        }
    }

    private func updateDetail() {
        deferredCompletionDetail?.cancel()
        deferredCompletionDetail = nil
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
        if reference.source == .kanban || reference.source == .quota {
            model.publishWorkflowNotice(
                reference,
                body: reference.source == .kanban
                    ? "A Kanban card changed. Open Herm to review its current state."
                    : "Provider quota dropped to a lower band. Open Herm to review usage.")
        }
        guard state.interruptions.admit(reference, channel: .notch) else { return }
        guard !workspacePresented, !dragging, !petDragging, !state.composing, !state.isReadingDetail,
            !state.voiceLive, state.previewInteraction.mode == .passive
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
        setExpanded(true)
        scheduleCollapse(after: 6)
    }

    private func hoverChanged(_ value: Bool) {
        guard runtimeStarted, !workspacePresented, !dragging, !petDragging else { return }
        // Voice holds the notch open; hovering neither swaps nor collapses it.
        if state.voiceLive {
            hovering = value
            return
        }
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
                !self.state.voiceLive, self.state.previewInteraction.mode == .passive,
                !self.panel.frame.contains(NSEvent.mouseLocation)
            else { return }
            guard self.panel.attachedSheet == nil, !self.panel.dockHasInteractiveChildWindow else {
                self.scheduleCollapse(after: 0.4)
                return
            }
            self.state.showingAnnouncement = false
            var activity = self.state.activity
            let clearsCompletion = activity.backgroundCompleted || activity.responseCompleted
            if clearsCompletion {
                activity.backgroundCompleted = false
                activity.responseCompleted = false
                self.state.activity = activity
            }
            self.setExpanded(false)
            if clearsCompletion { self.scheduleCompletionDetailRefresh() }
        }
        collapseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func scheduleCompletionDetailRefresh() {
        deferredCompletionDetail?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.updateDetail() }
        deferredCompletionDetail = task
        let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : EdgeDockMotion.morphSettle
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    /// Explicit keyboard invocation owns focus until dismissal; hovering remains passive.
    func toggleQuickPreview() {
        guard runtimeStarted, !workspacePresented, !dragging, !petDragging else { return }
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
        guard runtimeStarted, !workspacePresented, !dragging, !petDragging else { return }
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
        if state.voiceLive {
            minimizeVoiceStage()
        } else {
            setExpanded(false)
        }
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
        runtimeStarted = false
        voiceIsland.show(false)
        notchVoiceIsland.show(false)
        notchVoiceModel.refreshIdleWake(suspended: true)
        voiceConversation.shutdown()
        deferredCompletionDetail?.cancel()
        deliveryQuestionWatch = nil
        deliveryQuestionPoll?.cancel()
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
        let changed = state.expanded != expanded
        if changed { state.expanded = expanded }
        position(animated: true)
        if changed, deferredCompletionDetail != nil { scheduleCompletionDetailRefresh() }
    }

    private func moveNotch(ended: Bool) {
        guard !workspacePresented else { return }
        collapseTask?.cancel()
        expandTask?.cancel()
        if dragging != !ended {
            (ended ? NSCursor.arrow : NSCursor.closedHand).set()
        }
        dragging = !ended
        hovering = false
        if state.expanded { state.expanded = false }
        let point = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let location = EdgeDockPlacement.dragged(
                to: point, screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                allowsTop: screen == NSScreen.screens.first)
            displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            if state.side != location.side { state.side = location.side }
            fraction = location.fraction
            position(animated: false)
        }
        if ended {
            suppressClickUntil = Date().addingTimeInterval(0.4)
            if state.voiceLive { setExpanded(true) }
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
        let collapsedTop = placement.frame(width: 1, height: state.collapsedRailHeight + state.petReserve).integral.maxY
        let openTop = placement.frame(width: 1, height: state.openSize.height + state.petReserve).integral.maxY
        if state.collapsedTop != collapsedTop { state.collapsedTop = collapsedTop }
        if state.openTop != openTop { state.openTop = openTop }
        // On top the pet docks just right of the collapsed island, under the menu bar.
        let home =
            state.side == .top
            ? NSPoint(
                x: placement.screenFrame.midX + state.islandShellOffset + state.islandShellWidth / 2 + 4,
                y: placement.screenFrame.maxY - state.notchSize.height - 44)
            : NSPoint(x: state.side == .right ? target.maxX - 44 : target.minX, y: target.minY)
        petWindow?.update(home: home, screen: placement.visibleFrame, visible: !workspacePresented, side: state.side)
        frameTransition.position(
            to: target, animated: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if let voice = state.voicePreviewModel {
            (voice === model ? voiceIsland : notchVoiceIsland).moveAttachedPreview(
                to: attachedVoicePreview(in: placement))
        }
    }

    private func attachedVoicePreview(in placement: EdgeDockPlacement) -> EdgeVoicePreviewPlacement {
        let panelSize = state.panelSize
        let frame = placement.frame(width: panelSize.width, height: panelSize.height).integral
        let height = min(frame.height, state.openSize.height)
        let widget = NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
        return EdgeVoicePreviewPlacement(widget: widget, side: placement.side, visibleFrame: placement.visibleFrame)
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
    var sessionAttentionState: DockActivityState?
    var kanbanNeedsAttention = false
    var kanbanHasUpdate = false
    var agentUpdatePhase: HermesUpdatePhase = .idle
    /// The Bots style's faces. Working lists every Bot at work, up to three:
    /// working task rows first, then the roster Bots the Bot picker counts as
    /// running. Blocked and finished name the first live task's Bot. Empty
    /// means the task's Bot is not known.
    var workingBotIDs: [String] = []
    var blockedBotID: String?
    var finishedBotID: String?
    /// Live tasks finished with a result not yet opened; the Bots badge number.
    var finishedCount = 0
    /// Marks the status indicator stacks: the primary plus finished/blocked extras.
    var markCount: Int {
        working ? 1 + (hasUpdate ? 1 : 0) + (attention ? 1 : 0) : hasUpdate && attention ? 2 : 1
    }
    /// Stacked slots for `style`: the Bots style gives each working Bot its own face.
    func slots(for style: NotchDisplayStyle) -> (primary: Int, extras: Int) {
        let primary = working && style == .bots ? max(1, workingBotIDs.count) : 1
        return (primary, markCount - 1)
    }
    var hasUpdate: Bool { unread || backgroundCompleted || responseCompleted || kanbanHasUpdate }
    var quiet: Bool { !working && !attention && !hasUpdate && status == .idle }

    func shouldAnnounce(after previous: Self) -> Bool {
        status != previous.status && (status == .needsApproval || status == .needsClarification)
    }

    var attentionState: DockActivityState {
        if status == .needsApproval { return .approval }
        if status == .needsClarification { return .clarification }
        return sessionAttentionState ?? .approval
    }

    var working: Bool {
        status == .working || runningCount > 0 || workingCount > 0 || kanbanRunningCount > 0
            || !workingBotIDs.isEmpty
            || agentUpdatePhase.ambientStatus?.isRunning == true
    }
    var attention: Bool {
        status == .needsApproval || status == .needsClarification || kanbanNeedsAttention || sessionNeedsAttention
            || agentUpdatePhase.ambientStatus?.isRunning == false
    }
    var title: String {
        if status == .needsApproval || status == .needsClarification { return status.title }
        if sessionNeedsAttention { return attentionState.label }
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
        if status == .needsApproval || status == .needsClarification { return attentionState.icon ?? .warningCircle }
        if sessionNeedsAttention { return attentionState.icon ?? .warningCircle }
        if kanbanNeedsAttention { return .warningCircle }
        if status != .needsApproval && agentUpdatePhase.ambientStatus?.isRunning == false { return .warningCircle }
        if attention { return status.icon }
        if unread { return .chat }
        if backgroundCompleted { return .checkCircle }
        if responseCompleted || kanbanHasUpdate { return .dot }
        return status == .offline ? .wifiSlash : .sidebarSimple
    }
    /// Fills the Bots style's faces from the notch's task rows, then the
    /// shared Bot activity board the Bot picker reads too.
    mutating func applyBots(from tasks: [EdgeNotchTask], board: BotActivityBoard = BotActivityBoard()) {
        let live = tasks.filter(\.isStatusCurrent)
        func profile(_ task: EdgeNotchTask) -> String {
            task.botProfileID ?? ""
        }
        func bot(_ phase: EdgeNotchTask.Phase) -> String? {
            live.first { $0.phase == phase }.map(profile)
        }
        var working: [String] = []
        for id in live.filter({ $0.phase == .working }).map(profile) + board.working where !working.contains(id) {
            working.append(id)
        }
        workingBotIDs = Array(working.prefix(3))
        blockedBotID =
            live.first {
                $0.phase == .attention && $0.resolvedAttentionState == attentionState
            }.map(profile)
            ?? bot(.attention) ?? board.blocked.first
        finishedBotID = bot(.finished) ?? board.finished.first
        finishedCount = live.filter { $0.phase == .finished }.count
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
        else { return taskPreviewRows }
        return taskPreviewRows + [quickReplyTask]
    }

    private var taskPreviewRows: [EdgeNotchTask] = []

    private func rebuildTaskPreviewRows() {
        taskPreviewRows = EdgeNotchTask.previewRows(
            tasks: tasks, bots: bots, board: botActivity, isOnline: activity.status != .offline)
    }

    @Published var quickDraft = "" { didSet { saveQuickDraft() } }
    @Published var quickSending = false
    @Published var quickResult: String?
    @Published var deliveryAnswers: [EdgeDeliveryQuestion: AttentionAnswerState] = [:]
    @Published var bots: [BotSummary] = [] { didSet { rebuildTaskPreviewRows() } }
    /// Who is working, blocked or done; shared with the Bot picker.
    @Published var botActivity = BotActivityBoard() { didSet { rebuildTaskPreviewRows() } }
    @Published var avatarImages: [String: Data] = [:]
    @Published var expanded = false
    @Published var hasPet = false
    var externalPet = false
    @Published var side: EdgeDockSide = .right
    @Published var activity = EdgeNotchActivity() {
        didSet {
            if (oldValue.status == .offline) != (activity.status == .offline) { rebuildTaskPreviewRows() }
        }
    }
    @Published var agentUpdatePhase: HermesUpdatePhase = .idle
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
    /// The visible stage owns the open notch. A minimized call releases the preview until restored.
    @Published var voicePreviewModel: DockModel?
    @Published var minimizedVoiceModel: DockModel?
    var voiceLive: Bool { voicePreviewModel != nil }
    /// Listening for "Hey <name>" with no call open (Settings → Voice → Wake word, or the notch's ear).
    @Published var wakeEnabled = false
    @Published var wakeListening = false
    var wakeIndicatorStatus: EdgeWakeIndicator.Status? {
        if wakeListening { return .listening }
        guard wakeEnabled else { return nil }
        return wakeError == nil ? .standby : .unavailable
    }
    var showsWakeIndicator: Bool { wakeIndicatorStatus != nil }
    var wakeAccessibilityValue: String {
        switch wakeIndicatorStatus {
        case .listening: EdgeWakeIndicator.accessibilityStatus
        case .standby: "Wake word on, microphone not listening"
        case .unavailable: wakeError ?? "Wake microphone unavailable"
        case nil: ""
        }
    }
    @Published var wakeError: String?
    /// The soonest voice reminder within the hour, counting down in the island's right ear.
    @Published var countdown: VoiceTimer?
    /// The voice widget's measured height, which sizes the shell around it.
    @Published var voiceHeight: CGFloat = 96
    /// Voice is wider than the task preview on an edge so the spoken line has room.
    static let voiceSideWidth: CGFloat = 420
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
    @Published var tasks: [EdgeNotchTask] = [] { didSet { rebuildTaskPreviewRows() } }
    @Published var kanbanUnavailable = false
    /// Fixed so refreshes and task arrivals never resize the preview.
    static let expandedSize = CGSize(width: 368, height: 360)
    @Published var quickDraftHeight: CGFloat = 160
    var startsNewQuickSession: Bool { quickTarget == nil && quickCreatedSession == nil }
    static let quickMessageHeight: CGFloat = 560
    /// The island opens landscape: wide and short, like an expanded Dynamic Island.
    static let islandSize = CGSize(width: 560, height: 300)
    var sessionRailActivity: EdgeNotchActivity {
        var result = activity
        result.sessionNeedsAttention = tasks.contains {
            $0.kanbanTask == nil && $0.phase == .attention && $0.isStatusCurrent
        }
        result.sessionAttentionState = tasks.filter {
            $0.kanbanTask == nil && $0.phase == .attention && $0.isStatusCurrent
        }.map(\.resolvedAttentionState).min()
        let cards = tasks.filter { $0.kanbanTask != nil && $0.isStatusCurrent }
        result.kanbanRunningCount = cards.filter { $0.phase == .working }.count
        result.kanbanNeedsAttention = cards.contains { $0.phase == .attention }
        result.workingCount = tasks.filter { $0.isStatusCurrent && $0.phase == .working }.count
        result.kanbanHasUpdate = cards.contains { $0.phase == .finished }
        result.applyBots(from: tasks, board: botActivity)
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
    var collapsedRailHeight: CGFloat {
        let slots = railActivity.slots(for: .stored)
        let height = max(96, CGFloat(slots.primary + slots.extras) * 30 + 56)
        // The faces are centered. Reserve the bottom inset on both sides of
        // that center so extra space below the mic doesn't crowd the stack.
        let wakeFooter = Self.sideWakeClearance * 2 + sideWakeTopMargin + Self.wakeSlot - Self.wakeGlyphSize
        return height + (showsWakeIndicator ? wakeFooter : 0)
    }
    var sideWakeTopMargin: CGFloat { showsWakeIndicator ? DockSpacing.section : 0 }
    var panelHeight: CGFloat { (expanded ? openSize.height : railHeight) + petReserve }
    /// The camera housing the top island wraps (drawn when the screen has none).
    @Published var notchSize = CGSize(width: EdgeNotchMetrics.fallbackWidth, height: 32)
    /// The right ear holds the primary mark, the left the extras. Each fits its
    /// own marks, so a lone badge never sits beside an empty slot.
    var islandEars: (left: CGFloat, right: CGFloat) {
        let slots = railActivity.slots(for: .stored)
        func ear(_ count: Int) -> CGFloat { CGFloat(max(1, count)) * 30 + 20 }
        return (
            ear(slots.extras) + Self.islandBadgeInset,
            ear(slots.primary) + (countdown == nil ? 0 : Self.countdownSlot)
                + (showsWakeIndicator ? Self.wakeSlot + Self.wakeEdgeInset : 0)
        )
    }
    /// Room for a timer glyph and "59:59" beside the primary mark.
    static let countdownSlot: CGFloat = 52
    /// The listening indicator's slot after the faces, so it never touches a badge.
    static let wakeSlot: CGFloat = 20
    static let wakeGlyphSize: CGFloat = 14
    static let sideWakeClearance = DockSpacing.section
    /// Clears the island's rounded end, which curves in well before its frame edge.
    static let wakeEdgeInset: CGFloat = 16
    /// Badged faces sit bottom-leading in their box, so the left ear pads its
    /// outer edge to keep them off the shell's shoulder.
    static let islandBadgeInset: CGFloat = 6
    /// The top notch wraps the camera housing, so its chrome wears Onyx; side notches wear the skin.
    static func themeSurface(for side: EdgeDockSide) -> DockThemeSurface { side == .top ? .cameraNotch : .app }
    /// The window stays centered on the camera at the wider ear on both sides;
    /// the drawn island uses the real ears and shifts by this to keep the gap on the camera.
    var islandEar: CGFloat { max(islandEars.left, islandEars.right) }
    var islandShellOffset: CGFloat { (islandEars.right - islandEars.left) / 2 }
    var islandShellWidth: CGFloat { notchSize.width + islandEars.left + islandEars.right }
    /// The shell at rest: the rail bar on an edge, the pill around the notch on top.
    var collapsedSize: CGSize {
        side == .top
            ? CGSize(width: notchSize.width + islandEar * 2, height: notchSize.height)
            : CGSize(width: railWidth, height: collapsedRailHeight)
    }
    var openSize: CGSize {
        if voiceLive {
            // Matches the preview padding: 8 + 16 under the notch, 26 + 26 on an edge.
            return side == .top
                ? CGSize(width: EdgeVoiceIsland.width, height: notchSize.height + voiceHeight + 24)
                : CGSize(width: Self.voiceSideWidth, height: voiceHeight + 52)
        }
        if isComposingQuickMessage {
            let verticalInsets: CGFloat = side == .top ? 24 : 52
            let height = startsNewQuickSession ? quickDraftHeight + verticalInsets : Self.quickMessageHeight
            return CGSize(
                width: side == .top ? Self.islandSize.width : Self.expandedSize.width,
                height: height + (side == .top ? notchSize.height : 0))
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
    /// Screen tops (AppKit) of the collapsed and open windows and of the live window. Both
    /// clamp to the screen separately, so the view pins the shell to these tops: the
    /// preview grows out of, and folds back into, the rail where it actually sits.
    @Published var collapsedTop: CGFloat = 0
    @Published var openTop: CGFloat = 0
    @Published var windowTop: CGFloat = 0
    /// The window: the pet hangs below an edge rail but beside the top island.
    var panelSize: CGSize {
        side == .top
            ? (expanded ? openSize : collapsedSize)
            : CGSize(width: expanded ? openSize.width : railWidth, height: panelHeight)
    }
}

struct EdgeNotchView: View {
    @ObservedObject var state: EdgeNotchState
    let controlCenter: ControlCenterModel
    #if DEBUG
        var onPreviewEvaluation: (() -> Void)?
    #endif
    @State private var controlPresentationRevision = 0
    @AppStorage(VoiceWakeShortcut.wakeWordKey) private var wakeWordEnabled = false
    @ObservedObject private var wakeActivation = VoiceWakeActivation.shared
    var onQuotaRequested: () -> Void = {}
    var onTasksRefresh: () -> Void = {}
    var onOpenQuota: () -> Void = {}
    var quickMessageModel: DockModel? = nil
    var notchVoiceModel: DockModel? = nil
    var onToggleVoice: () -> Void = {}
    var onMinimizeVoice: () -> Void = {}
    var onQuickMessageFocus: (Bool) -> Void = { _ in }
    var onQuickReply: (EdgeNotchTask) -> Void = { _ in }
    var onResultPeek: (EdgeNotchTask) -> Void = { _ in }
    var onMarkFinishedRead: (EdgeFinishedReadTargets) -> Void = { _ in }
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
        let _ = controlPresentationRevision
        // Pin the shell to its edge: the window stays expanded-wide while it collapses,
        // and default center alignment made the shrinking notch drift to the middle.
        VStack(alignment: state.side.alignment.horizontal, spacing: 4) {
            HStack(spacing: 0) {
                if open {
                    // The outer contour already supplies visual breathing room.
                    // Keep the preview close to it so its content does not float
                    // in the middle of the expanded notch.
                    preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .dockPadding(.horizontal, state.side == .top ? 34 : 8)
                        .dockPadding(.top, previewTopInset)
                        .dockPadding(.bottom, state.side == .top ? 16 : 26)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .islandContent(side: state.side).animation(
                                        .easeOut(duration: 0.24).delay(0.1)),
                                    removal: .opacity.animation(.easeIn(duration: 0.1))))
                } else if state.side == .top {
                    EdgeIslandRail(
                        activity: state.railActivity, notchWidth: state.notchSize.width, ears: state.islandEars,
                        height: state.notchSize.height, wakeStatus: state.wakeIndicatorStatus,
                        countdown: state.countdown, action: openDock
                    )
                    .contextMenu { railMenu }
                    .accessibilityLabel("Herm, \(state.railActivity.title). Open Herm")
                    .accessibilityValue(state.wakeAccessibilityValue)
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
                width: open
                    ? state.openSize.width
                    : state.side == .top ? state.islandShellWidth : state.collapsedSize.width,
                height: open ? state.openSize.height : state.collapsedSize.height,
                alignment: state.side.alignment
            )
            // The content is revealed through the growing shell rather than
            // appearing at full size beside it.
            .mask { shell(outline.fill(.black)) }
            // One persistent shell: the rail bar itself stretches into the preview
            // panel and back, so the two states read as a single growing notch.
            .background {
                if open && state.voiceLive {
                    shell(EdgeVoiceGlass(shape: AnyShape(outline), housing: isIsland ? state.notchSize.height : 0))
                } else if isIsland {
                    // The quick island stays black to match the camera housing.
                    shell(EdgeNotchShape(side: .top).fill(.black))
                } else {
                    // Side previews retain a contour even when Glass blends into the desktop.
                    shell(
                        DockWindowBackground(shape: AnyShape(outline))
                            .overlay {
                                // Doubled stroke clipped to the shape leaves a uniform inner 1pt line;
                                // a centered 1pt stroke loses its outer half to the clip on every edge.
                                if state.side != .top {
                                    outline.stroke(Color.dockBorderStrong, lineWidth: 2)
                                }
                            }
                            .clipShape(outline))
                }
            }
            // Attach drag gesture to parent so it works in both collapsed and expanded states
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { _ in onDrag(false) }
                    .onEnded { _ in onDrag(true) }
            )
            .offset(x: !open && state.side == .top ? state.islandShellOffset : 0)
            if state.hasPet && !state.externalPet {
                HermesNotchPetButton(pet: controlCenter.pet, mirrored: state.side == .left)
                    .frame(maxWidth: .infinity, alignment: state.side == .left ? .leading : .trailing)
            } else if state.hasPet && state.side != .top {
                Color.clear.frame(height: max(44, state.petReserve - 4)).allowsHitTesting(false)
            }
        }
        // Fills the window without reading its size: a GeometryReader here rebuilt the whole
        // preview on every step of the window's resize, a 5ms layout per frame of the open.
        .frame(
            minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
            alignment: state.side == .top ? .top : state.side == .left ? .topLeading : .topTrailing
        )
        .offset(y: state.side == .top ? 0 : state.windowTop - (open ? state.openTop : state.collapsedTop))
        .clipped()
        .environment(\.botActivity, state.botActivity)
        .onReceive(controlCenter.notchPresentationChanges) { _ in controlPresentationRevision &+= 1 }
        // Rail growth (more stacked marks) uses the same spring as the open/close morph.
        .animation(morph, value: state.collapsedSize)
        .animation(morph, value: state.islandShellWidth)
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
        .dockThemedRoot(surface: EdgeNotchState.themeSurface(for: state.side)).dockPreferredTextSize()
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
            state.petDragging ? nil : DockMotion.animation(reduceMotion: reduceMotion), value: state.barWidth)
    }

    private var dockingReach: CGFloat {
        guard !open, state.side != .top, DockMotion.isEnabled(reduceMotion: reduceMotion) else { return 0 }
        return state.petPull
    }

    private var outline: EdgeNotchShape { EdgeNotchShape(side: state.side, dockingReach: dockingReach) }

    private var rail: some View {
        Button(action: openDock) {
            EdgePetRail(
                activity: state.railActivity, side: state.side, width: state.barWidth,
                height: state.collapsedRailHeight, statusBottomInset: state.sideWakeTopMargin,
                glow: state.barGlow, dockingReach: dockingReach,
                tracking: state.petDragging, docked: state.petAttached && state.hasPet
            )
            .frame(width: state.railWidth, height: state.collapsedRailHeight)
            // The mic sits at the bar's foot, centered on the bar (which hugs the screen
            // edge inside the wider rail frame); the top island lays it out beside its faces.
            .overlay(alignment: state.side == .left ? .bottomLeading : .bottomTrailing) {
                if let status = state.wakeIndicatorStatus {
                    EdgeWakeIndicator(status: status)
                        .frame(width: state.barWidth)
                        .dockPadding(.bottom, 10)
                        .padding(.bottom, EdgeNotchState.sideWakeClearance)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .contextMenu { railMenu }
        .accessibilityLabel("Herm, \(state.railActivity.title). Open Herm")
        .accessibilityValue(state.wakeAccessibilityValue)
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

    private var showsPreviewToolbar: Bool { !state.glimpsing && !showsQuickMessage }

    private var previewTopInset: CGFloat {
        if !isIsland { return 26 }
        return state.voiceLive || !showsPreviewToolbar ? DockSpacing.control : 0
    }

    private var preview: some View {
        #if DEBUG
            let _ = onPreviewEvaluation?()
        #endif
        return previewContent
    }

    @ViewBuilder private var previewContent: some View {
        if state.voiceLive, let model = state.voicePreviewModel {
            EdgeVoiceWidget(
                model: model, mic: model.voiceMic, bots: model.botMode, shown: open, inNotch: true,
                onMinimize: onMinimizeVoice
            )
            .id(ObjectIdentifier(model))
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: { height in
                // 8pt steps: caption reflows of a line or less don't move the window.
                let stepped = (height / 8).rounded(.up) * 8
                if state.voiceHeight != stepped { state.voiceHeight = stepped }
            }
            .dockPadding(.top, isIsland ? state.notchSize.height : 0)
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            dockPreview
        }
    }

    private var dockPreview: some View {
        VStack(spacing: isIsland ? 6 : 0) {
            if showsPreviewToolbar { previewToolbar }
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
                    workingBotCount: state.activity.status == .offline ? 0 : state.botActivity.working.count,
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
                    markFinishedRead: quickMessageModel == nil ? nil : onMarkFinishedRead,
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
        // Camera housing is measured in screen points and does not scale with density.
        .padding(.top, isIsland && !showsPreviewToolbar ? state.notchSize.height : 0)
    }

    @ViewBuilder private var previewToolbar: some View {
        if isIsland {
            ViewThatFits(in: .horizontal) {
                EdgeIslandToolbarLayout(cameraWidth: state.notchSize.width) {
                    HStack(spacing: DockSpacing.micro) {
                        previewTabs
                        talkButton
                    }
                    HStack(spacing: DockSpacing.micro) {
                        wakeWordButton
                        previewToolbarActions
                    }
                }
                .frame(height: max(state.notchSize.height, DockControlMetrics.compactHeight))
                // The controls can use the shoulder inset while the scrolling body keeps its gutter.
                .dockPadding(.horizontal, -DockSpacing.control)

                previewToolbarRow
                    .frame(height: max(state.notchSize.height, 34))
                    .padding(.top, state.notchSize.height)
                    .dockPadding(.top, DockSpacing.control)
            }
        } else {
            previewToolbarRow
                .frame(height: 40)
                .dockPadding(.horizontal, DockSpacing.tight)
            Divider().overlay(Color.dockBorderLight)
        }
    }

    private var previewToolbarRow: some View {
        HStack(spacing: DockSpacing.micro) {
            previewTabs
            talkButton
            wakeWordButton
            Spacer()
            previewToolbarActions
        }
    }

    private var previewTabs: some View {
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
        .dockPadding(2)
        .dockWell(.sunken, radius: 14)
    }

    @ViewBuilder private var previewToolbarActions: some View {
        if state.displaysQuota {
            EdgeQuotaToolbar(control: controlCenter)
        } else {
            HStack(spacing: DockSpacing.control) {
                EdgeQuietMenu(coordinator: state.interruptions) {
                    onQuickMessageFocus(false)
                    state.showingDigest = true
                }
                taskToolbar
            }
        }
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
                    DockLoadingIndicator().controlSize(.small).scaleEffect(0.7)
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

    /// Voice is an action, not a view: its own mic, beside the toolbar, whichever tab is open.
    @ViewBuilder private var talkButton: some View {
        if let model = notchVoiceModel ?? quickMessageModel {
            let minimized = state.minimizedVoiceModel != nil
            let live = minimized || model.voiceState != .inactive
            let actionLabel = minimized ? "Show voice" : live ? "End voice" : "Talk"
            let label =
                live
                ? actionLabel
                : VoiceWakeShortcut.talkHelp(
                    chord: VoiceWakeShortcut.stored,
                    wakeName: VoiceWakeShortcut.wakeWordEnabled && MicLevelMeter.canDetectWakePhrase
                        ? model.voiceWakeName : nil)
            Button {
                state.clearPreviewDetails()
                onQuickMessageFocus(false)
                onToggleVoice()
            } label: {
                DockIcon(.microphone, size: 13, color: live ? .dockAccent : .dockSecondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .help(label)
            .accessibilityLabel(actionLabel)
            .accessibilityHint(live ? "" : label)
        }
    }

    /// Always-on wake word: the same preference as Settings → Voice → Wake word.
    @ViewBuilder private var wakeWordButton: some View {
        if let model = notchVoiceModel ?? quickMessageModel {
            let on = wakeWordEnabled
            let available = MicLevelMeter.canDetectWakePhrase
            let error = wakeActivation.error ?? state.wakeError
            let help =
                error ?? VoiceWakeShortcut.wakeWordHelp(on: on, available: available, wakeName: model.voiceWakeName)
            let active = on && available && error == nil
            let tint: Color = error != nil ? .dockWarning : active ? .dockAccent : .dockSecondaryText
            Button {
                Task { await wakeActivation.setEnabled(!on) }
            } label: {
                DockIcon(active ? .ear : .earSlash, size: 13, color: tint)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .disabled(wakeActivation.isRequesting)
            .help(help)
            .accessibilityLabel("Always listen for wake word")
            .accessibilityValue(
                wakeActivation.isRequesting
                    ? "Requesting permission" : error != nil ? "Unavailable" : active ? "On" : "Off"
            )
            .accessibilityHint(help)
        }
    }

    private func tabButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        DockTabButton(title: title, isSelected: isSelected, height: 24, action: action)
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
    var statusBottomInset: CGFloat = 0
    var glow = 0.0
    var dockingReach: CGFloat = 0
    var tracking = false
    var docked = false
    @State private var flash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @DockChromeTheme private var chrome

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                if side == .right { Spacer(minLength: 0) }
                EdgeNotchStatusIndicator(activity: activity, style: displayStyle)
                    .padding(.bottom, statusBottomInset)
                    .frame(width: width, height: height)
                    // The shell fill lives in EdgeNotchView so it can grow into the preview.
                    .overlay {
                        EdgeNotchShape(side: side, dockingReach: dockingReach).stroke(
                            DockThemePalette(theme: chrome).accent, lineWidth: 2
                        ).opacity(flash ? 1 : glow * 0.8)
                    }
                    .animation(
                        tracking ? nil : DockMotion.animation(reduceMotion: reduceMotion), value: width)
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
    var dockingReach: CGFloat = 0

    var animatableData: CGFloat {
        get { dockingReach }
        set { dockingReach = newValue }
    }

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
        // Pull the lower lip toward the companion. Both ends of the returning
        // curve have horizontal tangents, so the crest joins the shoulder smoothly.
        let baseline = rect.maxY - shoulder
        let depth = min(1, max(0, dockingReach)) * shoulder * 0.9
        let crest = CGPoint(x: rect.minX + radius, y: baseline + depth)
        path.addQuadCurve(to: crest, control: CGPoint(x: rect.minX, y: crest.y))
        let end = CGPoint(x: rect.maxX - shoulder, y: baseline)
        let middle = (crest.x + end.x) / 2
        path.addCurve(to: end, control1: CGPoint(x: middle, y: crest.y), control2: CGPoint(x: middle, y: end.y))
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
    var bottomHoverExclusion: CGFloat = 0
    private var lastNotchHover: Bool?
    func resetNotchHover() { lastNotchHover = nil }
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
    private let scrollHits = DockScrollHitCache()
    override func hitTest(_ point: NSPoint) -> NSView? {
        scrollHits.hitTest(point, in: self) { super.hitTest($0) }
    }
    override func mouseMoved(with event: NSEvent) {
        // The notch hover is cheap and must never wait out a scroll.
        updateNotchHover(event)
        guard DockHoverGate.admit(event, in: self, replay: { [weak self] in self?.replayHover($0) }) else { return }
        super.mouseMoved(with: event)
    }
    private func replayHover(_ event: NSEvent) {
        super.mouseMoved(with: event)
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // Leaving via the pet must still schedule collapse after leaving the panel.
        resetNotchHover()
        onHoverChanged?(false)
    }
}
