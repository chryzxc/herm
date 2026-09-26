import AppKit
import Combine
import SwiftUI

/// One native window morphs from the passive notch into the interactive workspace.
@MainActor
final class EdgeDockController: NSObject {
    let panel = DockPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let model: DockModel
    private let controlCenter: ControlCenterModel
    private let openQuota: () -> Void
    private let openDock: () -> Void
    private let state = EdgeNotchState()
    private var notchHost: NSView?
    private var subscriptions = Set<AnyCancellable>()
    private var collapseTask: DispatchWorkItem?
    private var expandTask: DispatchWorkItem?
    private var hovering = false
    private var dragging = false
    private var suppressClickUntil = Date.distantPast
    private var workspacePresented = false
    private var completedTaskIDs: Set<String>?
    private var latestToolID: String?
    private var latestToolComplete = false
    private var latestSessions: [HermesSession] = []
    private var latestActivityLabels: [String: String] = [:]
    private var lastQuotas: [ProviderQuotaSnapshot]?
    /// Quota readers whose usage has moved; these are the services being
    /// spent (by Hermes or any other app), so they are read on every tick.
    private var hotQuotaReaders = Set<String>()
    private var quotaTick = 0
    private var displayID: NSNumber?
    private var fraction: CGFloat = 0.5
    private let defaults: UserDefaults

    init(model: DockModel, controlCenter: ControlCenterModel, defaults: UserDefaults = .standard, openQuota: @escaping () -> Void, openDock: @escaping () -> Void) {
        self.model = model
        self.controlCenter = controlCenter
        self.openQuota = openQuota
        self.defaults = defaults
        self.openDock = openDock
        super.init()
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
            onOpenQuota: { [weak self] in self?.openQuota() },
            openDock: { [weak self] in self?.openWorkspace() },
            onOpenTask: { [weak self] task in self?.openTask(task) },
            onDrag: { [weak self] ended in self?.moveNotch(ended: ended) },
            onSideChange: { [weak self] side in
                guard let self else { return }
                self.state.side = side
                self.persistPlacement()
                self.position(animated: true)
            }))
        host.onHoverChanged = { [weak self] value in self?.hoverChanged(value) }
        host.sizingOptions = []
        notchHost = host
        panel.contentView = host
        panel.onCancel = { [weak self] in self?.setExpanded(false) }
        Publishers.CombineLatest3(model.$status, model.$hasUnreadResponse, model.$backgroundTasks)
            .receive(on: RunLoop.main)
            .sink { [weak self] status, unread, tasks in
                self?.refresh(status: status, unread: unread, tasks: tasks)
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
        workspacePresented = true
        hovering = false
        panel.acceptsWorkspaceFocus = true
    }

    func restoreNotch() {
        workspacePresented = false
        panel.acceptsWorkspaceFocus = false
        panel.resignKey()
        state.expanded = false
        state.activity.backgroundCompleted = false
        state.activity.responseCompleted = false
        panel.contentView = notchHost
        notchHost?.alphaValue = 1
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            notchHost?.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                notchHost?.animator().alphaValue = 1
            }
        }
        panel.hasShadow = false
        panel.onCancel = { [weak self] in self?.setExpanded(false) }
        position(animated: true)
        panel.orderFrontRegardless()
    }

    private func openWorkspace() {
        guard !dragging, Date() >= suppressClickUntil else { return }
        state.activity.backgroundCompleted = false
        state.activity.responseCompleted = false
        openDock()
    }

    private func openTask(_ task: EdgeNotchTask) {
        guard let session = task.session else { return openWorkspace() }
        guard !dragging, Date() >= suppressClickUntil else { return }
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
        let phase: EdgeNotchTask.Phase? = activity.attention ? .attention
            : activity.working ? .working : activity.hasUpdate ? .finished : nil
        if let phase {
            let label: String = switch phase {
            case .attention: activity.status.title
            case .working: activity.status == .working ? "Working" : activity.title
            case .finished: activity.title
            }
            current = EdgeNotchTask(
                id: model.navigationSessionID ?? "current", title: state.sessionTitle, phase: phase,
                statusLabel: label, detail: state.detail, updatedAt: nil, isCurrent: true,
                isStatusCurrent: activity.status != .offline, session: nil)
        }
        let tasks = EdgeNotchTask.build(current: current, sessions: latestSessions,
                                        activity: latestActivityLabels,
                                        currentSessionIDs: model.currentSessionIDs,
                                        isOnline: activity.status != .offline)
        if tasks != state.tasks { state.tasks = tasks }
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
        guard !workspacePresented, !dragging else { return }
        if !hovering {
            // Updates landing while one is showing join it rather than replace it.
            if !state.showingAnnouncement {
                state.announcesTasks = false
                state.announcesQuota = false
            }
            state.showingAnnouncement = true
            if quota { state.announcesQuota = true } else { state.announcesTasks = true }
        }
        state.expanded = true
        position(animated: true)
        scheduleCollapse(after: 6)
    }

    private func hoverChanged(_ value: Bool) {
        guard !workspacePresented, !dragging else { return }
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
                guard let self, self.hovering, !self.dragging else { return }
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
            guard let self, !self.hovering, !self.dragging, !self.workspacePresented,
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
        guard !workspacePresented, !dragging else { return }
        if state.expanded { return setExpanded(false) }
        state.showingAnnouncement = false
        setExpanded(true)
        scheduleCollapse(after: 5)
    }

    private func setExpanded(_ expanded: Bool) {
        guard !workspacePresented else { return }
        collapseTask?.cancel()
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
        guard !workspacePresented, let placement else { return }
        let target = placement.frame(width: state.expanded ? EdgeNotchState.expandedSize.width : state.railWidth,
                                     height: state.expanded ? max(EdgeNotchState.expandedSize.height, state.railHeight) : state.railHeight)
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
    var hasUpdate: Bool { unread || backgroundCompleted || responseCompleted }
    var quiet: Bool { !working && !attention && !hasUpdate && status == .idle }

    func shouldAnnounce(after previous: Self) -> Bool {
        (working && !previous.working) || runningCount != previous.runningCount
            || (unread && !previous.unread) || (attention && status != previous.status)
    }

    var working: Bool { status == .working || runningCount > 0 }
    var attention: Bool { status == .needsApproval || status == .needsClarification }
    var title: String {
        if attention { return status.title }
        if unread { return "New response" }
        if backgroundCompleted { return "Background task completed" }
        if responseCompleted { return "Response completed" }
        if runningCount > 0 { return "\(runningCount) background \(runningCount == 1 ? "task" : "tasks") running" }
        if status == .working || status == .offline { return status.title }
        return "Open Dock"
    }
    var symbol: Ph {
        if attention { return status.icon }
        if unread { return .chat }
        if backgroundCompleted || responseCompleted { return .check }
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
    @Published var expanded = false
    @Published var side: EdgeDockSide = .right
    @Published var activity = EdgeNotchActivity()
    @Published var name = "Hermes"
    @Published var sessionTitle = "Herm"
    @Published var updateTitle = "No activity yet"
    @Published var showsQuota = false
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
    /// Fixed so refreshes and task arrivals never resize the preview.
    static let expandedSize = CGSize(width: 368, height: 360)
    static let previewSize = CGSize(width: 352, height: 312)
    var showsSeparateWork: Bool { activity.working && (activity.hasUpdate || activity.attention) }
    var isQuiet: Bool { activity.quiet && !expanded }
    var railWidth: CGFloat { expanded ? 72 : 44 }
    var railHeight: CGFloat { expanded ? 136 : 72 }
}

struct EdgeNotchView: View {
    @ObservedObject var state: EdgeNotchState
    let controlCenter: ControlCenterModel
    var onQuotaRequested: () -> Void = {}
    var onOpenQuota: () -> Void = {}
    @ObservedObject private var theme = DockThemeStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let openDock: () -> Void
    var onOpenTask: (EdgeNotchTask) -> Void = { _ in }
    var onDrag: (Bool) -> Void = { _ in }
    var onSideChange: (EdgeDockSide) -> Void = { _ in }

    var body: some View {
        GeometryReader { geometry in
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
            .frame(width: geometry.size.width, height: geometry.size.height,
                   alignment: state.side == .right ? .trailing : .leading)
            .background {
                if state.expanded {
                    EdgeNotchShape(side: state.side).fill(Color.dockNotchCanvas)
                        .overlay { EdgeNotchShape(side: state.side).stroke(Color.dockBorderStrong, lineWidth: 1) }
                }
            }
            // Attach drag gesture to parent so it works in both collapsed and expanded states
            .simultaneousGesture(DragGesture(minimumDistance: 6)
                .onChanged { _ in onDrag(false) }
                .onEnded { _ in onDrag(true) })
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
            HStack(spacing: 0) {
                if state.side == .right { Spacer(minLength: 0) }
                EdgeNotchStatusIndicator(activity: state.activity)
                    .frame(width: 22, height: 72)
                    .background {
                        EdgeNotchShape(side: state.side).fill(Color.dockNotchCanvas)
                            .overlay { EdgeNotchShape(side: state.side).stroke(Color.dockBorderStrong, lineWidth: 1) }
                    }
                if state.side == .left { Spacer(minLength: 0) }
            }
            .frame(width: state.railWidth, height: state.railHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Move to left edge") { onSideChange(.left) }
            Button("Move to right edge") { onSideChange(.right) }
            Divider()
            Button("Quit Herm") { NSApp.terminate(nil) }
        }
        .accessibilityLabel("\(state.name), \(state.activity.title). Open Dock")
        .accessibilityHint("Drag to move along either screen edge")
        .help("\(state.activity.title). Hover for details; drag to reposition.")
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    tabButton("Tasks", isSelected: !state.displaysQuota && !state.displaysStatus) {
                        state.showingAnnouncement = false; state.showsQuota = false
                    }
                    tabButton("Quota", isSelected: state.displaysQuota) {
                        state.showingAnnouncement = false; state.showsQuota = true; onQuotaRequested()
                    }
                }
                .padding(2)
                .background(Capsule().fill(Color.dockSurface4.opacity(0.6)))
                Spacer()
                if state.displaysQuota {
                    EdgeQuotaToolbar(control: controlCenter)
                } else if state.activity.status == .offline {
                    DockStatusPill(tone: .inactive, text: "Offline", symbol: .wifiSlash)
                        .accessibilityLabel("Hermes is offline. Task status is not current.")
                }
            }
            .frame(height: 40)
            .padding(.horizontal, 12)
            Divider().overlay(Color.dockBorderLight)
            if state.displaysQuota {
                EdgeQuotaPreview(control: controlCenter, openQuota: onOpenQuota, change: state.announcedQuotaChange)
            } else {
                EdgeTaskPreview(tasks: state.tasks, isOffline: state.activity.status == .offline,
                                quotaChange: state.displaysStatus ? state.announcedQuotaChange : nil,
                                openDock: openDock, openTask: onOpenTask)
            }
        }
    }

    private func tabButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.dockAccent : Color.dockSecondaryText)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(Capsule().fill(isSelected ? Color.dockAccentMuted : .clear))
                .overlay(Capsule().strokeBorder(isSelected ? Color.dockAccent.opacity(0.45) : .clear, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Indeterminate motion conveys work without inventing a percentage.
private struct EdgeNotchStatusIndicator: View {
    let activity: EdgeNotchActivity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color {
        if activity.attention { return .dockWarning }
        if activity.hasUpdate { return .dockSuccess }
        if activity.status == .offline { return .dockSecondaryText }
        return .dockAccent
    }

    var body: some View {
        VStack(spacing: 7) {
            if activity.attention {
                DockIcon(.warningCircle).font(.system(size: 10, weight: .bold))
            } else if activity.status == .offline {
                DockIcon(.prohibit).font(.system(size: 10))
            }
            if activity.working {
                EdgeNotchWorkingBar(color: color, reduceMotion: reduceMotion)
            } else if activity.quiet {
                Capsule().fill(Color.dockSecondaryText.opacity(0.45))
                    .frame(width: 3, height: 16)
            } else if activity.hasUpdate {
                EdgeNotchCompletedBar(color: color, reduceMotion: reduceMotion)
            }
        }
        .foregroundStyle(color)
        .accessibilityHidden(true)
    }
}

/// Driven by the clock rather than a state flip, so the segment keeps
/// traveling however the notch was shown, hidden or rebuilt around it.
private struct EdgeNotchWorkingBar: View {
    let color: Color
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate / 0.85
            // Eased ping-pong between the track's ends.
            let travel = reduceMotion ? 0 : -cos(phase * .pi) * 9
            ZStack {
                Capsule().fill(color.opacity(0.18)).frame(width: 3, height: 28)
                Capsule().fill(color).frame(width: 3, height: 10).offset(y: travel)
            }
        }
    }
}

/// Completion resolves the working track: the traveling segment fills it solid.
private struct EdgeNotchCompletedBar: View {
    let color: Color
    let reduceMotion: Bool
    @State private var filled = false

    var body: some View {
        ZStack {
            Capsule().fill(color.opacity(0.18))
            Capsule().fill(color)
                .scaleEffect(y: filled || reduceMotion ? 1 : 10.0 / 28.0)
                .shadow(color: color.opacity(filled ? 0.55 : 0), radius: 4)
        }
        .frame(width: 3, height: 28)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { filled = true }
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
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        hoverArea = area
        addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}
