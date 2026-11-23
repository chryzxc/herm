import Foundation
import Testing

@testable import Herm

@MainActor
struct StatusBarLayoutTests {
    private func task(
        _ id: String, _ phase: EdgeNotchTask.Phase, failure: Bool = false, current: Bool = true
    ) -> EdgeNotchTask {
        EdgeNotchTask(
            id: id, title: id, phase: phase, statusLabel: "", detail: nil, updatedAt: nil,
            isCurrent: false, isStatusCurrent: current, session: nil, isFailure: failure)
    }

    @Test func visibilityUsesPersistedPreferencesAcrossHostModes() throws {
        let domain = "StatusBarVisibilityTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = StatusBarPreferences(defaults: defaults)
        #expect(!preferences.isVisible(inFloatingPanel: false))
        #expect(!preferences.isVisible(inFloatingPanel: true))

        preferences.isEnabled = true
        #expect(preferences.isVisible(inFloatingPanel: false))
        #expect(preferences.isVisible(inFloatingPanel: true))

        preferences.showsInFloating = false
        let restored = StatusBarPreferences(defaults: defaults)
        #expect(restored.isVisible(inFloatingPanel: false))
        #expect(!restored.isVisible(inFloatingPanel: true))

        restored.isEnabled = false
        let disabled = StatusBarPreferences(defaults: defaults)
        #expect(!disabled.isVisible(inFloatingPanel: false))
        #expect(!disabled.isVisible(inFloatingPanel: true))
    }

    @Test func aNewRunWithTheSameStatusStartsAFreshStalledClock() throws {
        let domain = "StatusBarStalledTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = StatusBarPreferences(defaults: defaults)
        preferences.set(.stalled, on: true)
        preferences.set(.nextMeeting, on: false)
        let status = WorkspaceStatusModel(preferences: preferences)
        let edge = EdgeNotchState()
        let model = DockModel()
        let control = ControlCenterModel(capabilities: [])
        let pullRequests = PullRequestCenterModel()
        let working = EdgeNotchTask(
            id: "run", title: "Build", phase: .working, statusLabel: "Working", detail: nil,
            updatedAt: Date().addingTimeInterval(-600), isCurrent: false, isStatusCurrent: true, session: nil)
        edge.tasks = [working]
        status.attach(edge: edge, model: model, control: control, pullRequests: pullRequests)
        #expect(status.layout.trailing.contains { $0.item == .stalled })

        edge.tasks = [task("run", .finished)]
        edge.tasks = [working]
        #expect(!status.layout.trailing.contains { $0.item == .stalled })
    }

    @Test func reconnectOnlyCountsActualActivityTransitions() throws {
        let domain = "StatusBarReconnectTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = StatusBarPreferences(defaults: defaults)
        preferences.set(.nextMeeting, on: false)
        var now = Date.now
        let status = WorkspaceStatusModel(preferences: preferences, now: { now })
        let edge = EdgeNotchState()
        let model = DockModel()
        let control = ControlCenterModel(capabilities: [])
        let pullRequests = PullRequestCenterModel()
        let current = [task("result", .finished), task("request", .attention), task("run", .working)]
        edge.tasks = current
        status.attach(edge: edge, model: model, control: control, pullRequests: pullRequests)

        now = now.addingTimeInterval(30)
        edge.tasks = [task("result", .finished, current: false)] + Array(current.dropFirst())
        edge.tasks = current
        #expect(status.events.isEmpty)

        model.status = .offline
        edge.tasks = []
        model.status = .idle
        edge.tasks = [current[0], current[1], task("run", .finished)]

        #expect(status.events.map(\.kind) == [.finished])
    }

    @Test func reachKeepsLocalOnlyResourcesOffRemoteGateways() {
        #expect(BackendReach.access(.hermes, mode: .cloud) == .viaHermes)
        #expect(BackendReach.access(.macCalendar, mode: .ssh) == .thisMac)
        #expect(BackendReach.access(.repositoryFiles, mode: .local) == .direct)
        #expect(!BackendReach.access(.repositoryFiles, mode: .remote).isAvailable)
        #expect(!BackendReach.access(.simulator, mode: .cloud).isAvailable)
        let link = BackendReach.access(.processLinks, mode: .ssh)
        #expect(link.isAvailable && link.reason != nil)
    }

    @Test func attentionBadgeOpensThePreview() {
        var input = StatusBarInput()
        input.tasks = [task("w", .working), task("ask", .attention), task("bad", .attention, failure: true)]
        let layout = StatusBarLayout.make(input)
        #expect(layout.summary.running.map(\.id) == ["w"])
        #expect(layout.summary.attention.map(\.id) == ["ask", "bad"])
        #expect(layout.chips.map(\.item) == [.needsYou])
        #expect(layout.chips.map(\.text) == ["2 need attention"])
        #expect(layout.chips.allSatisfy { $0.action == .tray })
        #expect(layout.trailing.isEmpty)
    }

    @Test func runningCountIsOptInWhileRunningWorkRemainsInActivity() {
        var input = StatusBarInput()
        input.tasks = [task("w", .working)]
        let defaultLayout = StatusBarLayout.make(input)
        #expect(defaultLayout.chips.isEmpty)
        #expect(defaultLayout.summary.running.map(\.id) == ["w"])

        input.enabled.insert(.agentActivity)
        let optedIn = StatusBarLayout.make(input)
        #expect(optedIn.trailing.first?.text == "1 running")
        #expect(optedIn.trailing.first?.action == .tray)
    }

    @Test func needsYouShowsEvenWhenEverythingIsOff() {
        var input = StatusBarInput()
        input.enabled = []
        input.tasks = [task("w", .working), task("ask", .attention)]
        let layout = StatusBarLayout.make(input)
        #expect(layout.chips.map(\.text) == ["1 needs attention"])
    }

    @Test func stalledNeedsQuietTimePastTheThreshold() {
        var input = StatusBarInput()
        input.enabled = [.stalled]
        let working = task("w", .working)
        input.tasks = [working]
        input.lastChange = [working.presentationID: input.now.addingTimeInterval(-60)]
        #expect(!StatusBarLayout.make(input).trailing.contains { $0.item == .stalled })
        input.lastChange = [working.presentationID: input.now.addingTimeInterval(-6 * 60)]
        #expect(StatusBarLayout.make(input).trailing.map(\.text) == ["w stalled 6m"])
    }

    @Test func repositoryItemsHideOnRemoteGateways() {
        var input = StatusBarInput()
        input.enabled.insert(.unpushed)
        var repository = RepositorySnapshot(
            path: "/work/app", branch: "main", changedFiles: 0, latestCommit: "abc", isGitRepository: true)
        repository.aheadCount = 2
        input.repository = repository
        #expect(StatusBarLayout.make(input).trailing.contains { $0.item == .unpushed })
        input.mode = .cloud
        #expect(!StatusBarLayout.make(input).trailing.contains { $0.item == .unpushed })
    }

    @Test func trailingDropsBeforeChipsFold() {
        let folds = WorkspaceStatusBar.folds(chips: 2, trailing: 2)
        #expect(folds.map(\.trailing) == [2, 1, 0, 0, 0])
        #expect(folds.map(\.chips) == [2, 2, 2, 1, 0])
    }

    @Test func previewShowsAtMostTwoAttentionItems() {
        var input = StatusBarInput()
        input.tasks = [
            task("running", .working), task("first", .attention), task("second", .attention),
            task("third", .attention), task("finished", .finished),
        ]
        let preview = StatusBarLayout.make(input).preview

        #expect(preview.headline == "3 need attention")
        #expect(preview.rows.map(\.title) == ["first", "second"])
        #expect(preview.rows.allSatisfy { $0.action == .none })
    }

    @Test func hoverPreviewsKeepTheRequestedWorkAndBotIdentity() throws {
        var input = StatusBarInput()
        var running = task("working", .working)
        running.profileID = "build-bot"
        input.tasks = [task("attention", .attention), running, task("result", .finished)]
        input.enabled.formUnion([.agentActivity, .readyToReview])
        let layout = StatusBarLayout.make(input)
        let active = try #require(layout.trailing.first { $0.item == .agentActivity })
        let review = try #require(layout.trailing.first { $0.item == .readyToReview })

        #expect(layout.preview(for: active).rows.map(\.title) == ["working"])
        #expect(layout.preview(for: active).rows.first?.task?.profileID == "build-bot")
        #expect(layout.preview(for: review).rows.map(\.title) == ["result"])
    }

    @Test func previewUsesOneFallbackItemAndExplainsOfflineState() {
        var input = StatusBarInput()
        #expect(StatusBarLayout.make(input).preview.headline == "No current activity")

        input.tasks = [task("finished", .finished)]
        #expect(StatusBarLayout.make(input).preview.rows.map(\.title) == ["finished"])

        input.tasks += [task("running", .working), task("other", .working)]
        #expect(StatusBarLayout.make(input).preview.rows.map(\.title) == ["running"])

        input.tasks = [
            EdgeNotchTask(
                id: "old", title: "Stale", phase: .attention, statusLabel: "Blocked", detail: nil, updatedAt: nil,
                isCurrent: false, isStatusCurrent: false, session: nil)
        ]
        let stale = StatusBarLayout.make(input).preview
        #expect(stale.headline == "Activity status unavailable")
        #expect(stale.rows.isEmpty)

        input.tasks = []
        input.isOffline = true
        let offline = StatusBarLayout.make(input).preview
        #expect(offline.headline == "Hermes Agent is offline")
        #expect(offline.rows.isEmpty)
    }

    @Test func activityShortcutTogglesThePreview() {
        let status = WorkspaceStatusModel()
        status.toggleActivity()
        #expect(status.isTrayPresented)
        status.toggleActivity()
        #expect(!status.isTrayPresented)
        status.openActivity()
        #expect(status.isTrayPresented)
    }

    @Test func nearestScheduleHasPriorityAndLinksToTheExactItem() {
        var input = StatusBarInput()
        let job = CronSummary(
            id: "daily", name: "Session hygiene", schedule: "Daily", enabled: true,
            nextRun: input.now.addingTimeInterval(9 * 60 + 40).ISO8601Format())
        let routine = RoutineReference(profileID: "work", job: job, run: nil)
        input.routines = [routine]
        let meeting = CalendarItem(
            id: "event:standup", kind: .event(calendar: "Work", location: nil, attendees: [], url: nil),
            title: "Standup", start: input.now.addingTimeInterval(5 * 60))
        input.nextMeeting = meeting

        let first = StatusBarLayout.make(input).trailing
        #expect(first.map(\.text) == ["Standup in 5m"])
        #expect(first.first?.compactText == "Meeting in 5m")
        #expect(first.first?.action == .calendar(meeting))
        input.enabled.remove(.nextMeeting)
        let second = StatusBarLayout.make(input).trailing
        #expect(second.map(\.text) == ["Session hygiene in 10m"])
        #expect(second.first?.compactText == "Routine in 10m")
        #expect(second.first?.action == .routine(routine))

        input.enabled.insert(.processes)
        input.localServer = LocalPreviewServer(pid: 21, port: 5173)
        #expect(StatusBarLayout.make(input).trailing.map(\.item) == [.nextSchedule, .processes])
    }

    @Test func distantAndExpiredSchedulesLeaveTheSlotEmpty() {
        var input = StatusBarInput()
        input.nextMeeting = CalendarItem(
            id: "event:standup", kind: .event(calendar: "Work", location: nil, attendees: [], url: nil),
            title: "Standup", start: input.now.addingTimeInterval(1_801))
        #expect(StatusBarLayout.make(input).trailing.isEmpty)
        input.now = input.now.addingTimeInterval(1_802)
        #expect(StatusBarLayout.make(input).trailing.isEmpty)
    }

    @Test func allAvailableOptedInDeveloperShortcutsAppear() {
        var input = StatusBarInput()
        let server = LocalPreviewServer(pid: 21, port: 5173, processName: "Vite")
        input.localServer = server
        input.repository = RepositorySnapshot(
            path: "/work", branch: "main", changedFiles: 0, latestCommit: "abc", isGitRepository: true, aheadCount: 2)
        let result = StatusBarEntry.Action.terminal(identity: "session", tabID: UUID(), shellID: UUID())
        input.failedTest = result
        #expect(StatusBarLayout.make(input).trailing.isEmpty)

        input.enabled.formUnion([.verification, .processes, .unpushed])
        #expect(StatusBarLayout.make(input).trailing.map(\.action) == [result, .tab(.changes), .url(server.url)])
        input.failedTest = nil
        #expect(StatusBarLayout.make(input).trailing.map(\.action) == [.tab(.changes), .url(server.url)])
        input.repository?.isStale = true
        #expect(StatusBarLayout.make(input).trailing.map(\.action) == [.url(server.url)])
        input.mode = .ssh
        #expect(StatusBarLayout.make(input).trailing.isEmpty)
    }

    @Test func terminalLookupUsesTheExactSessionAndDirectory() {
        let store = TerminalWorkspaceStore()
        let id = UUID()
        let base = store.workspace(key: "session:/work:app")
        let extra = store.workspace(key: "session:extra:\(id.uuidString):/work:app")
        _ = store.workspace(key: "other:session:/work:app")
        _ = store.workspace(key: "session:extra:\(UUID().uuidString):/elsewhere:/work:app")

        let found = store.tabs(identity: "session", directory: "/work:app")
        #expect(found.count == 2)
        #expect(found.contains { $0.extraID == nil && $0.tabs === base })
        #expect(found.contains { $0.extraID == id && $0.tabs === extra })
    }

    @Test func terminalFailureRequiresCurrentEvidenceAndOpensTheRecordedShell() {
        let now = Date()
        let shell = UUID()
        let tab = UUID()
        let scope = WorkspaceStatusModel.TerminalScope(
            identity: "session", directory: "/work", repositoryID: "repo", fingerprint: "current")
        func run(_ code: Int, fingerprint: String = "current", at date: Date = .now) -> VerificationRun {
            VerificationRun(
                id: UUID(), recipeID: "test:swift test", repositoryID: "repo", repositoryFingerprint: fingerprint,
                command: "swift test", startedAt: date, finishedAt: date, exitCode: code, outputSummary: nil)
        }
        let failed = (run(1, at: now), Optional(tab), shell)
        #expect(
            WorkspaceStatusModel.failedTest(in: [failed], scope: scope)
                == .terminal(identity: "session", tabID: tab, shellID: shell))
        #expect(WorkspaceStatusModel.failedTest(in: [(run(1, fingerprint: "old"), nil, shell)], scope: scope) == nil)
        #expect(WorkspaceStatusModel.failedTest(in: [(run(130), nil, shell)], scope: scope) == nil)
        #expect(
            WorkspaceStatusModel.failedTest(
                in: [failed, (run(0, at: now.addingTimeInterval(1)), nil, UUID())], scope: scope) == nil)
    }

    @Test func durationsReadShort() {
        #expect(StatusBarLayout.minutes(20) == "now")
        #expect(StatusBarLayout.minutes(42 * 60) == "42m")
        #expect(StatusBarLayout.minutes(65 * 60) == "1h 5m")
        #expect(StatusBarLayout.minutes(24 * 3600) == "1d")
        #expect(StatusBarLayout.minutes(191 * 3600 + 47 * 60) == "7d 23h")
    }

    @Test func returnSummaryCountsWhatChanged() {
        func event(_ kind: StatusBarEvent.Kind) -> StatusBarEvent {
            StatusBarEvent(time: .now, kind: kind)
        }
        #expect(WorkspaceStatusModel.summary([]) == nil)
        #expect(
            WorkspaceStatusModel.summary([event(.finished), event(.finished), event(.asked)])
                == "2 finished · 1 needs you")
    }
}
