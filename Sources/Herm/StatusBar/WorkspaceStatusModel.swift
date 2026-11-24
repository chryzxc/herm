import AppKit
import Combine
import CoreGraphics
import Foundation

/// A change counted in the status bar's return summary.
struct StatusBarEvent {
    enum Kind { case finished, asked, failed }
    let time: Date
    let kind: Kind
}

/// Gathers the bar's inputs from their owners without observing the whole
/// DockModel or ControlCenterModel, and records what Herm sees change.
@MainActor
final class WorkspaceStatusModel: ObservableObject {
    struct TerminalScope: Equatable {
        let identity: String
        let directory: String
        let repositoryID: String?
        let fingerprint: String?
    }

    @Published private(set) var layout = StatusBarLayout()
    /// When Hermes went offline, for the stale slot.
    @Published private(set) var staleSince: Date?
    /// After an idle stretch: what changed while you were away.
    @Published private(set) var returnSummary: (since: Date, text: String)?
    /// The Activity tray, shared so the ⌘J registry command and the bar button agree.
    @Published var isTrayPresented = false
    private(set) var terminalScope: TerminalScope?
    private let startedAt: Date
    private let now: () -> Date
    private(set) var events: [StatusBarEvent] = []
    private var input = StatusBarInput()
    private var signatures: [String: String] = [:]
    private var phases: [String: EdgeNotchTask.Phase] = [:]
    private var awaySince: Date?
    private var subscriptions = Set<AnyCancellable>()
    private var simulatorTask: Task<Void, Never>?
    private var calendar: SystemCalendarService?
    private var calendarSubscription: AnyCancellable?
    private let preferences: StatusBarPreferences
    private weak var edge: EdgeNotchState?
    private weak var model: DockModel?

    init(preferences: StatusBarPreferences = .shared, now: @escaping () -> Date = Date.init) {
        self.preferences = preferences
        self.now = now
        startedAt = now()
    }

    func attach(
        edge: EdgeNotchState, model: DockModel, control: ControlCenterModel, pullRequests: PullRequestCenterModel
    ) {
        guard self.edge !== edge || self.model !== model else { return }
        subscriptions.removeAll()
        self.edge = edge
        self.model = model
        model.$status.map { $0 == .offline }.removeDuplicates()
            .sink { [weak self] in self?.update(\.isOffline, $0) }.store(in: &subscriptions)
        edge.$tasks.sink { [weak self] in self?.observe($0) }
            .store(in: &subscriptions)
        edge.$botActivity.combineLatest(edge.$bots)
            .map { board, roster in board.working.compactMap { id in roster.first { $0.id == id } } }
            .removeDuplicates()
            .sink { [weak self] in self?.update(\.workingBots, $0) }
            .store(in: &subscriptions)
        control.$cronJobs.combineLatest(
            control.$routineProfileID,
            control.$projectionRefreshStates.map { $0["cron.jobs"]?.isStale == true }.removeDuplicates()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak control] _, _, _ in
            guard let control else { return }
            let routines = control.refreshState(for: "cron.jobs")?.isStale == true ? [] : control.cronJobs
            let references = routines.map { job in
                RoutineReference(profileID: control.profileForRoutine(job), job: job, run: nil)
            }
            guard let self, input.routines != references else { return }
            update(\.routines, references)
        }.store(in: &subscriptions)
        control.$developmentContext.sink { [weak self] in self?.update(\.repository, $0) }.store(in: &subscriptions)
        model.$todoPlan.combineLatest(model.$sessionID).sink { [weak self] plan, session in
            self?.update(\.plan, plan?.sessionID == session ? plan : nil)
        }.store(in: &subscriptions)
        model.$queuedPrompts.combineLatest(model.$sessionID).sink { [weak self] queue, session in
            self?.update(\.queuedCount, queue.filter { $0.sessionID == session }.count)
        }.store(in: &subscriptions)
        pullRequests.recordUpdates.combineLatest(pullRequests.$viewerLogin).sink {
            [weak self] records, login in
            self?.input.viewerLogin = login
            self?.update(\.pullRequests, records)
        }.store(in: &subscriptions)
        preferences.objectWillChange.sink { [weak self] in
            // Fires before the change lands.
            DispatchQueue.main.async { self?.preferencesChanged() }
        }.store(in: &subscriptions)
        GatewayConnectionStore.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.refreshSimulator()
                self?.rebuild()
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in
            self?.loadCalendar(refreshAccess: true)
        }.store(in: &subscriptions)
        Timer.publish(every: 30, tolerance: 5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tickFired() }.store(in: &subscriptions)
        preferencesChanged()
    }

    func openActivity() {
        isTrayPresented = true
    }

    func toggleActivity() {
        if isTrayPresented {
            isTrayPresented = false
        } else {
            openActivity()
        }
    }

    func dismissReturnSummary() { returnSummary = nil }

    func monitorTerminals(in scope: TerminalScope?, servers: Bool, tests: Bool) async {
        terminalScope = scope
        input.localServer = nil
        input.failedTest = nil
        rebuild()
        guard let scope, servers || tests else { return }
        while !Task.isCancelled {
            let workspaces = TerminalWorkspaceStore.shared.tabs(identity: scope.identity, directory: scope.directory)
            if tests {
                let runs = workspaces.flatMap { workspace in
                    workspace.tabs.sessions.compactMap { shell in
                        shell.lastVerificationRun.map { ($0, workspace.extraID, shell.id) }
                    }
                }
                input.failedTest = Self.failedTest(in: runs, scope: scope)
            }
            if servers {
                let roots = workspaces.flatMap { $0.tabs.sessions.map(\.shellProcessID) }.filter { $0 > 0 }
                let reachable = try? await LocalServerDiscovery.discover(roots: roots)
                guard !Task.isCancelled, terminalScope == scope else { return }
                input.localServer = reachable?.first
            }
            rebuild()
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
        }
    }

    static func failedTest(
        in runs: [(run: VerificationRun, tabID: UUID?, shellID: UUID)], scope: TerminalScope
    ) -> StatusBarEntry.Action? {
        guard let repositoryID = scope.repositoryID, let fingerprint = scope.fingerprint else { return nil }
        let currentTests = runs.filter { item in
            item.run.recipeID.hasPrefix("test:")
                && item.run.isCurrent(repositoryFingerprint: fingerprint, repositoryID: repositoryID)
        }
        guard let (run, tabID, shellID) = currentTests.max(by: { $0.run.startedAt < $1.run.startedAt }),
            run.isComplete, let code = run.exitCode, code > 0, code < 128
        else { return nil }
        return .terminal(identity: scope.identity, tabID: tabID, shellID: shellID)
    }

    // MARK: - Observation

    private func update<Value>(_ path: WritableKeyPath<StatusBarInput, Value>, _ value: Value) {
        input[keyPath: path] = value
        rebuild()
    }

    private func observe(_ tasks: [EdgeNotchTask]) {
        let now = now()
        for task in tasks where task.isStatusCurrent {
            let id = task.presentationID
            let previous = phases[id]
            let phase = task.isQueued ? EdgeNotchTask.Phase.pending : task.phase
            phases[id] = phase
            if phase == .working {
                let signature = "\(task.statusLabel)\u{1F}\(task.detail ?? "")"
                if previous != .working || signatures[id] != signature {
                    signatures[id] = signature
                    input.lastChange[id] = previous == nil ? task.updatedAt.map { min($0, now) } ?? now : now
                }
            } else if previous != phase, previous != nil || now.timeIntervalSince(startedAt) > 10 {
                let isFailure = task.isFailure || task.resolvedAttentionState == .failed
                switch phase {
                case .attention:
                    record(isFailure ? .failed : .asked, at: now)
                case .finished:
                    record(isFailure ? .failed : .finished, at: now)
                default: break
                }
            }
        }
        // Stale rows still carry identities. An offline inventory can also be temporarily empty.
        if !input.isOffline {
            let seen = Set(tasks.map(\.presentationID))
            for id in Set(phases.keys).subtracting(seen) {
                phases[id] = nil
                signatures[id] = nil
                input.lastChange[id] = nil
            }
        }
        input.tasks = tasks
        rebuild()
    }

    private func record(_ kind: StatusBarEvent.Kind, at time: Date) {
        events.insert(StatusBarEvent(time: time, kind: kind), at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
    }

    private func preferencesChanged() {
        input.enabled = preferences.enabledItems
        input.stalledAfter = TimeInterval(preferences.stalledMinutes * 60)
        loadCalendar()
        refreshSimulator()
        rebuild()
    }

    private func rebuild() {
        input.mode = GatewayConnectionStore.shared.selected.mode
        input.now = now()
        input.nextMeeting = nextMeeting(after: input.now)
        let next = StatusBarLayout.make(input)
        if next.isStale, staleSince == nil {
            staleSince = input.now
        } else if !next.isStale, staleSince != nil {
            staleSince = nil
        }
        if next != layout { layout = next }
    }

    private func tickFired() {
        checkIdle()
        loadCalendar()
        rebuild()
    }

    /// Idle comes from the system's last input time, so nothing is tracked per keystroke.
    private func checkIdle() {
        let minutes = preferences.returnSummaryMinutes
        guard minutes > 0 else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle >= TimeInterval(minutes * 60) {
            if awaySince == nil { awaySince = now().addingTimeInterval(-idle) }
        } else if idle < 60, let since = awaySince {
            awaySince = nil
            returnSummary = Self.summary(events.filter { $0.time >= since }).map { (since, $0) }
        }
    }

    /// "3 finished · 1 needs you · 1 failed", or nil when nothing changed.
    static func summary(_ events: [StatusBarEvent]) -> String? {
        let parts: [(StatusBarEvent.Kind, String)] = [
            (.finished, "finished"), (.asked, "need you"), (.failed, "failed"),
        ]
        let text = parts.compactMap { kind, label -> String? in
            let count = events.filter { $0.kind == kind }.count
            guard count > 0 else { return nil }
            return "\(count) \(kind == .asked && count == 1 ? "needs you" : label)"
        }
        return text.isEmpty ? nil : text.joined(separator: " · ")
    }

    // MARK: - Calendar and simulator

    private func calendarService() -> SystemCalendarService {
        if let calendar { return calendar }
        let service = SystemCalendarService(includesReminders: false)
        calendar = service
        calendarSubscription = service.$items.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.rebuild() }
        return service
    }

    private var showsMacCalendar: Bool {
        preferences.isEnabled && preferences.isOn(.nextMeeting)
            && (UserDefaults.standard.object(forKey: SystemCalendarService.enabledKey) as? Bool ?? true)
    }

    private func nextMeeting(after now: Date) -> CalendarItem? {
        guard showsMacCalendar, let calendar, calendar.eventAccess == .granted else { return nil }
        let hidden = Set(
            (UserDefaults.standard.string(forKey: SystemCalendarService.hiddenSourcesKey) ?? "")
                .split(separator: "\n"))
        return calendar.items.filter { item in
            item.isEvent && !item.isAllDay && item.start > now
                && (item.sourceID.map { !hidden.contains(Substring($0)) } ?? true)
        }.min { $0.start < $1.start }
    }

    private func loadCalendar(refreshAccess: Bool = false) {
        guard showsMacCalendar else {
            calendar?.setEnabled(false)
            return
        }
        let service = calendarService()
        service.setEnabled(true)
        if refreshAccess { service.refresh() }
        guard service.eventAccess == .granted else { return }
        service.load(DateInterval(start: Calendar.current.startOfDay(for: .now), duration: 2 * 86_400))
    }

    private func refreshSimulator() {
        guard preferences.isEnabled, preferences.isOn(.simulator), BackendReach.access(.simulator) == .direct else {
            simulatorTask?.cancel()
            simulatorTask = nil
            if input.bootedSimulator != nil { update(\.bootedSimulator, nil) }
            return
        }
        guard simulatorTask == nil else { return }
        simulatorTask = Task { [weak self] in
            while !Task.isCancelled {
                let name = await HermesLocalSimulator.bootedName()
                guard !Task.isCancelled, self != nil else { return }
                self?.update(\.bootedSimulator, name)
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    deinit { simulatorTask?.cancel() }
}
