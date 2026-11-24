import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct SessionProcessIsolationTests {
    @Test func composerProjectionsKeepProcessesAndStopsInTheirOwnSession() async throws {
        let client = SessionProcessIsolationClient()
        client.processState = "running"
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        control.capabilities = [
            CapabilityState(
                id: "rpc-sessions", title: "Sessions", detail: "Available", isAvailable: true, recovery: nil)
        ]
        let first = DockModel(initialSessionID: "session-a", rpcClient: client)
        let second = DockModel(initialSessionID: "session-b", rpcClient: client)
        let a = SessionProcessProjection(control: control, model: first)
        let b = SessionProcessProjection(control: control, model: second)
        a.reset(for: first.sessionID)
        b.reset(for: second.sessionID)
        client.processID = "process-a"
        await a.poll()
        client.processID = "process-b"
        await b.poll()
        #expect(a.processes.map(\.id) == ["process-a"])
        #expect(b.processes.map(\.id) == ["process-b"])
        let stale = a.confirmation(for: try #require(a.processes.first))
        let target = b.confirmation(for: try #require(b.processes.first))
        first.sessionID = "session-c"
        a.reset(for: first.sessionID)
        #expect(a.processes.isEmpty)
        #expect(!(await a.stop(stale)))
        #expect(await b.stop(target))
        #expect(client.killedSessionIDs == ["session-b"])
        #expect(client.killedProcessIDs == ["process-b"])
    }

    @Test func idlePaneRetriesProcessReadWhenConnectionBecomesReady() async throws {
        let client = SessionProcessIsolationClient()
        let model = DockModel(initialSessionID: "session-a", rpcClient: client)
        let control = ControlCenterModel()
        let host = NSHostingView(
            rootView: RunningProcessesStrip(control: control, model: model, isTurnActive: false))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        control.bind(to: model)
        model.isHermesConnected = true
        try await Task.sleep(for: .milliseconds(500))
        #expect(client.processSessionIDs.contains("session-a"))
    }

    @Test func processEventRefreshesIdleProjection() async throws {
        let client = SessionProcessIsolationClient()
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let model = DockModel(initialSessionID: "session-a", rpcClient: client)
        let projection = SessionProcessProjection(control: control, model: model)
        projection.reset(for: model.sessionID)
        projection.startObserving()
        model.eventRouter.route(type: "process.changed", params: ["session_id": "session-a"])
        try await Task.sleep(for: .milliseconds(200))
        #expect(client.processSessionIDs == ["session-a"])
        projection.stopObserving()
        model.eventRouter.route(type: "process.changed", params: ["session_id": "session-a"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.processSessionIDs == ["session-a"])
    }

    @Test func aBurstDuringAProcessReadSharesOneFollowUp() async throws {
        let client = SessionProcessIsolationClient()
        client.deferNextProcess = true
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let model = DockModel(initialSessionID: "session-a", rpcClient: client)
        defer { model.shutdown() }
        let projection = SessionProcessProjection(control: control, model: model)
        projection.reset(for: model.sessionID)
        projection.startObserving()
        defer { projection.stopObserving() }
        let firstRead = Task { await projection.poll() }
        await client.waitForDeferredProcess()
        for _ in 0..<40 {
            model.eventRouter.route(type: "process.changed", params: ["session_id": "session-a"])
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(client.processSessionIDs == ["session-a"])
        client.completeDeferredProcess(fails: false)
        await firstRead.value
        #expect(client.processSessionIDs == ["session-a", "session-a"])
        #expect(projection.processes.map(\.id) == [client.processID])
    }

    @Test func oldProcessCannotBeStoppedAfterBackendRebind() async throws {
        let client = SessionProcessIsolationClient()
        client.processState = "running"
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let model = DockModel(initialSessionID: "session-a", rpcClient: client)
        let projection = SessionProcessProjection(control: control, model: model)
        projection.reset(for: model.sessionID)
        await projection.poll()
        let process = try #require(projection.processes.first)
        control.clientBindingGeneration += 1
        let confirmation = projection.confirmation(for: process)
        #expect(!(await projection.stop(confirmation)))
        #expect(client.killedProcessIDs.isEmpty)
    }

    @Test func productionSplitRowUsesOneRefreshSubscription() async throws {
        let client = SessionProcessIsolationClient()
        let primary = DockModel(initialSessionID: "primary", rpcClient: client)
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        control.bind(to: primary)
        let store = SessionPaneStore()
        store.runtime = primary
        store.open(QuickDestination(profileID: nil, sessionID: "pane-a", title: "A"), target: .newPanel(1))
        try await Task.sleep(for: .milliseconds(300))
        let pane = try #require(store.panels.last?.chat.conversation)
        let host = NSHostingView(
            rootView: SessionPaneRow(
                store: store, control: control, bots: BotModeModel(), isEnabled: true,
                headerHeight: 40, usesWindowChrome: false, leadingControls: nil
            ) { _ in Color.clear })
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        await control.refreshTask?.value
        let before = client.activeSessionRequests
        primary.receiveGatewayEvent("message.complete", params: ["session_id": pane.sessionID ?? ""])
        await control.eventRefreshTask?.value
        await control.refreshTask?.value
        #expect(client.activeSessionRequests - before == 1)
        #expect(control.dockModel === primary)
    }

    @Test func messageCompleteRefreshCountDoesNotGrowWithPanesOrSessionSwitch() async throws {
        let one = try await refreshCounts(panes: 1)
        let four = try await refreshCounts(panes: 4)
        // Each event refresh reads active sessions once without a capability probe.
        #expect(one == [1, 1])
        #expect(four == one)
    }

    private func refreshCounts(panes: Int) async throws -> [Int] {
        let client = SessionProcessIsolationClient()
        let defaults = try #require(UserDefaults(suiteName: "pane-refresh-\(UUID().uuidString)"))
        let primary = DockModel(defaults: defaults, initialSessionID: "primary", rpcClient: client)
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        control.bind(to: primary)
        let bots = BotModeModel()
        var models = [primary]
        for index in 1..<panes {
            models.append(DockModel(defaults: defaults, initialSessionID: "pane-\(index)", rpcClient: client))
        }
        let host = NSHostingView(
            rootView: HStack {
                ForEach(Array(models.enumerated()), id: \.offset) { _, model in
                    SessionPaneChat(model: model, control: control, bots: bots, metrics: .resolve(isFullscreen: false))
                }
            })
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        await control.refreshTask?.value
        #expect(control.dockModel === primary)
        var counts: [Int] = []
        for sessionID in ["primary", "switched"] {
            primary.sessionID = sessionID
            control.focus(sessionID: sessionID)
            await control.refreshTask?.value
            let before = client.activeSessionRequests
            for model in models {
                model.eventRouter.route(type: "message.complete", params: ["session_id": model.sessionID ?? ""])
            }
            await control.eventRefreshTask?.value
            await control.refreshTask?.value
            counts.append(client.activeSessionRequests - before)
        }
        return counts
    }

    @Test(arguments: [false, true])
    func listedProcessCanStopWithoutActivityProbe(includeUnavailableProbe: Bool) async throws {
        let client = SessionProcessIsolationClient()
        client.processState = "running"
        let defaults = try #require(UserDefaults(suiteName: "session-process-\(UUID().uuidString)"))
        let dock = DockModel(defaults: defaults, rpcClient: client)
        dock.sessionID = "session-a"
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        control.dockModel = dock
        control.focus(sessionID: "session-a")
        control.capabilities = [
            CapabilityState(
                id: "rpc-sessions", title: "Sessions", detail: "Available", isAvailable: true, recovery: nil)
        ]
        if includeUnavailableProbe {
            control.capabilities.append(
                CapabilityState(
                    id: "rpc-activity", title: "Activity", detail: "Unavailable", isAvailable: false, recovery: nil))
        }
        let refresh = try #require(
            control.refreshFocusedProcesses(for: "session-a", generation: control.sessionProcessesGeneration))
        await refresh.value
        let process = try #require(control.processes.first)
        let confirmation = control.processStopConfirmation(process)

        client.output = "New output while the stop confirmation is open"
        await control.pollProcesses()
        #expect(control.processes.first?.latestOutput == client.output)
        client.processState = "completed"
        await control.pollProcesses()
        #expect(!control.canStopCurrentProcess(confirmation))
        client.processState = "running"
        await control.pollProcesses()
        #expect(await control.killProcess(confirmation))
        #expect(client.killedSessionIDs == ["session-a"])
        #expect(client.killedProcessIDs == [process.id])
        await control.refreshTask?.value
    }

    @Test
    func pollingDiscoversProcessesWithoutActivityProbe() async throws {
        let client = SessionProcessIsolationClient()
        let defaults = try #require(UserDefaults(suiteName: "session-process-\(UUID().uuidString)"))
        let dock = DockModel(defaults: defaults, rpcClient: client)
        dock.sessionID = "session-a"
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        control.dockModel = dock
        control.focus(sessionID: "session-a")
        control.capabilities = [
            CapabilityState(
                id: "rpc-sessions", title: "Sessions", detail: "Available", isAvailable: true, recovery: nil)
        ]

        await control.pollProcesses()
        #expect(client.processSessionIDs == ["session-a"])
        #expect(control.processControlAvailable)

        dock.sessionID = nil
        control.focus(sessionID: nil)
        #expect(!control.processControlAvailable)
    }

    @Test(arguments: [Optional<String>.none, .some("")])
    func newChatClearsPreviousSessionProcesses(clearedSessionID: String?) async throws {
        let client = SessionProcessIsolationClient()
        let defaults = try #require(UserDefaults(suiteName: "session-process-\(UUID().uuidString)"))
        let dock = DockModel(defaults: defaults, rpcClient: client)
        dock.sessionID = "session-a"
        let control = ControlCenterModel(
            rpc: HermesControlRPC(client: client),
            capabilities: [
                CapabilityState(
                    id: "rpc-sessions", title: "Sessions", detail: "Available", isAvailable: true, recovery: nil)
            ])
        control.dockModel = dock
        control.focus(sessionID: dock.sessionID)
        await control.pollProcesses()
        #expect(client.processSessionIDs == ["session-a"])
        #expect(control.processes.map(\.id) == ["finished-in-a"])

        dock.newChat()
        control.focus(sessionID: clearedSessionID)

        #expect(dock.sessionID == nil)
        #expect(control.processes.isEmpty)
        #expect(control.currentFocus == nil)
    }

    @Test
    func staleStopDoesNotTargetNewSession() async throws {
        let client = SessionProcessIsolationClient()
        let defaults = try #require(UserDefaults(suiteName: "session-process-\(UUID().uuidString)"))
        let dock = DockModel(defaults: defaults, rpcClient: client)
        let control = ControlCenterModel(
            rpc: HermesControlRPC(client: client),
            capabilities: [
                CapabilityState(
                    id: "rpc-sessions", title: "Sessions", detail: "Available", isAvailable: true, recovery: nil)
            ])
        control.dockModel = dock
        dock.sessionID = "session-a"
        control.focus(sessionID: dock.sessionID)
        await control.pollProcesses()
        let oldProcess = try #require(control.processes.first)
        let oldConfirmation = control.processStopConfirmation(oldProcess)

        dock.sessionID = "session-b"
        control.focus(sessionID: dock.sessionID)
        await control.pollProcesses()
        #expect(await control.killProcess(oldConfirmation) == false)
        #expect(client.killedSessionIDs.isEmpty)

        await control.pollProcesses()
        let currentProcess = try #require(control.processes.first)
        #expect(await control.killProcess(control.processStopConfirmation(currentProcess)))
        #expect(client.killedSessionIDs == ["session-b"])
    }

    @Test
    func projectNavigationKeepsComposerProcessControl() async throws {
        let client = SessionProcessIsolationClient()
        let defaults = try #require(UserDefaults(suiteName: "session-process-\(UUID().uuidString)"))
        let dock = DockModel(defaults: defaults, rpcClient: client)
        dock.sessionID = "session-a"
        let control = ControlCenterModel(
            rpc: HermesControlRPC(client: client),
            capabilities: [
                CapabilityState(
                    id: "rpc-sessions", title: "Sessions", detail: "Available", isAvailable: true, recovery: nil)
            ])
        control.dockModel = dock
        control.focus(sessionID: "session-a")
        await control.pollProcesses()
        control.openProject(
            ProjectSummary(
                id: "project", name: "Project", repoCount: 0, sessionCount: 0, sessionIDs: [], preview: nil,
                isActive: false))
        client.processID = "updated"
        await control.pollProcesses()
        #expect(control.processes.map(\.id) == ["updated"])
        let process = try #require(control.processes.first)
        #expect(await control.killProcess(control.processStopConfirmation(process)))
        #expect(client.killedSessionIDs == ["session-a"])
    }

    @Test(arguments: [false, true], [0, 1, 2, 3, 4, 5, 6, 7])
    func delayedFocusedAndBroadReadsPreserveNewProjection(broad: Bool, scenario: Int) async throws {
        let fails = scenario >= 4
        let transition = scenario % 4
        let client = SessionProcessIsolationClient()
        let defaults = try #require(UserDefaults(suiteName: "session-process-\(UUID().uuidString)"))
        let dock = DockModel(defaults: defaults, rpcClient: client)
        dock.sessionID = "session-a"
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        control.dockModel = dock
        control.focus(sessionID: "session-a")
        control.capabilities = [
            CapabilityState(
                id: "rpc-sessions", title: "Sessions", detail: "Available", isAvailable: true, recovery: nil)
        ]
        try await waitForFocusedProcessRead(control, sessionID: "session-a")
        client.deferNextProcess = true
        let oldTask: Task<Void, Never>
        if broad {
            control.refresh()
            oldTask = try #require(control.refreshTask)
        } else {
            oldTask = try #require(
                control.refreshFocusedProcesses(
                    for: "session-a", generation: control.sessionProcessesGeneration))
        }
        await client.waitForDeferredProcess()
        defer { client.completeDeferredProcess(fails: fails) }
        let otherDock = transition == 2 ? DockModel(defaults: defaults, rpcClient: client) : nil
        defer { withExtendedLifetime(otherDock) {} }
        if transition == 0 {
            dock.sessionID = nil
            control.focus(sessionID: nil)
        } else if transition == 1 {
            dock.sessionID = "session-b"
            control.focus(sessionID: "session-b")
        } else if let otherDock {
            otherDock.sessionID = "session-a"
            control.bind(to: otherDock)
        } else {
            dock.sessionID = "session-b"
            control.focus(sessionID: "session-b")
            dock.sessionID = "session-a"
            control.focus(sessionID: "session-a")
        }
        if let focusedSessionID = control.processSessionID {
            try await waitForFocusedProcessRead(control, sessionID: focusedSessionID)
        }
        // Keep the broad refresh's unrelated CLI history read from changing lastError.
        control.cli = nil
        control.processes = [ProcessSummary(id: "new", name: "New", state: "running", detail: nil)]
        control.recordProjectionSuccess("processes")
        let expectedState = control.refreshState(for: "processes")
        control.lastError = "Current session error"
        let expectedError = control.lastError
        client.completeDeferredProcess(fails: fails)
        await oldTask.value
        #expect(control.processes.map(\.id) == ["new"])
        #expect(control.refreshState(for: "processes") == expectedState)
        if broad {
            // Other projections can publish their own diagnostics during a broad refresh.
            #expect(control.lastError != SessionProcessIsolationClient.deferredReadFailure)
        } else {
            #expect(control.lastError == expectedError)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func delayedPollCannotReplaceSwitchedOrReboundSession(rebind: Bool, fails: Bool) async throws {
        let client = SessionProcessIsolationClient()
        let defaults = try #require(UserDefaults(suiteName: "session-process-\(UUID().uuidString)"))
        let dock = DockModel(defaults: defaults, rpcClient: client)
        dock.sessionID = "session-a"
        let control = ControlCenterModel(
            rpc: HermesControlRPC(client: client),
            capabilities: [
                CapabilityState(
                    id: "rpc-sessions", title: "Sessions", detail: "Available", isAvailable: true, recovery: nil)
            ])
        control.dockModel = dock
        control.focus(sessionID: "session-a")
        try await waitForFocusedProcessRead(control, sessionID: "session-a")
        client.deferNextProcess = true
        let oldPoll = Task { await control.pollProcesses() }
        await client.waitForDeferredProcess()

        let otherDock = DockModel(defaults: defaults, rpcClient: client)
        defer { withExtendedLifetime(otherDock) {} }
        otherDock.sessionID = "session-a"
        if rebind {
            control.bind(to: otherDock)
            control.capabilities = [
                CapabilityState(
                    id: "rpc-sessions", title: "Sessions", detail: "Available", isAvailable: true, recovery: nil)
            ]
        } else {
            dock.sessionID = "session-b"
            control.focus(sessionID: "session-b")
            dock.sessionID = "session-a"
            control.focus(sessionID: "session-a")
        }
        await control.pollProcesses()
        #expect(control.processes.map(\.id) == ["finished-in-a"])
        control.lastError = "Current session error"
        let expectedError = control.lastError
        client.completeDeferredProcess(fails: fails)
        await oldPoll.value
        #expect(control.processes.map(\.id) == ["finished-in-a"])
        #expect(control.lastError == expectedError)
    }

    @Test
    func boundBlankAndUnboundFallbackChooseCorrectFocus() throws {
        let client = SessionProcessIsolationClient()
        let defaults = try #require(UserDefaults(suiteName: "session-process-\(UUID().uuidString)"))
        let dock = DockModel(defaults: defaults, rpcClient: client)
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client), capabilities: [])
        control.activeSessions = [SessionSummary(id: "foreign", title: "Foreign", state: "running", preview: nil)]
        control.dockModel = dock
        control.establishFocusIfNeeded()
        #expect(control.currentFocus == nil)
        control.dockModel = nil
        control.establishFocusIfNeeded()
        #expect(control.currentFocus?.sessionID == "foreign")
    }

    @Test
    func foreignProcessEventDoesNotFocusBlankComposer() async throws {
        let client = SessionProcessIsolationClient()
        let defaults = try #require(UserDefaults(suiteName: "session-process-\(UUID().uuidString)"))
        let dock = DockModel(defaults: defaults, rpcClient: client)
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client), capabilities: [])
        control.bind(to: dock)
        dock.receiveGatewayEvent("process.changed", params: ["session_id": "foreign"])
        let eventTask = try #require(control.eventRefreshTask)
        await eventTask.value
        if let refreshTask = control.refreshTask { await refreshTask.value }
        #expect(control.activeSessions.map(\.id) == ["foreign"])
        #expect(control.currentFocus == nil)
        #expect(control.processes.isEmpty)
    }

    @Test
    func reopeningOwnerRefetchesRuntimeProcesses() async throws {
        let client = SessionProcessIsolationClient()
        let defaults = try #require(UserDefaults(suiteName: "session-process-\(UUID().uuidString)"))
        let dock = DockModel(defaults: defaults, rpcClient: client)
        let control = ControlCenterModel(
            rpc: HermesControlRPC(client: client),
            capabilities: [
                CapabilityState(
                    id: "rpc-sessions", title: "Sessions", detail: "Available", isAvailable: true, recovery: nil)
            ])
        control.dockModel = dock
        let owner = HermesSession(
            id: "owner", profileID: "default", title: "Owner", preview: "", startedAt: nil, messageCount: 0,
            source: "test")
        #expect(await dock.resumeSession(owner, reportFailure: true))
        #expect(dock.sessionID == "runtime-owner")
        control.focus(sessionID: dock.sessionID)
        await control.pollProcesses()
        #expect(client.processSessionIDs == ["runtime-owner"])
        #expect(control.processes.map(\.id) == ["finished-in-a"])
    }

    private func waitForFocusedProcessRead(_ control: ControlCenterModel, sessionID: String) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while control.verifiedProcessSessionID != sessionID, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(control.verifiedProcessSessionID == sessionID)
    }
}

@MainActor
private final class SessionProcessIsolationClient: HermesRPCClientProtocol {
    nonisolated static let deferredReadFailure = "Deferred process read failed"

    private struct DeferredReadError: LocalizedError {
        var errorDescription: String? { SessionProcessIsolationClient.deferredReadFailure }
    }

    var activeSessionRequests = 0
    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var processSessionIDs: [String] = []
    private(set) var killedSessionIDs: [String] = []
    private(set) var killedProcessIDs: [String] = []
    var processID = "finished-in-a"
    var processState = "completed"
    var output = ""
    var deferNextProcess = false
    private var deferredProcess: CheckedContinuation<[String: Any], Error>?
    private var processStarted: CheckedContinuation<Void, Never>?

    func waitForDeferredProcess() async {
        if deferredProcess != nil { return }
        await withCheckedContinuation { processStarted = $0 }
    }

    func completeDeferredProcess(fails: Bool) {
        if fails {
            deferredProcess?.resume(throwing: DeferredReadError())
        } else {
            deferredProcess?.resume(returning: ["processes": [["id": "stale", "state": "running"]]])
        }
        deferredProcess = nil
    }

    func connect() async throws {}
    func close() {}

    func fetchHTTP(_ path: String) async throws -> [String: Any] { [:] }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "session.resume" {
            return ["session_id": "runtime-owner", "session_key": "owner", "messages": []]
        }
        if method == "session.active_list" {
            activeSessionRequests += 1
            return ["sessions": [["id": "foreign", "state": "running"]]]
        }
        // A valid empty inventory keeps the broad refresh's unrelated cron read
        // from replacing lastError.
        if method == HermesFeatureIDs.ID.cronManage.rawValue { return ["jobs": []] }
        if method == "process.kill" {
            killedSessionIDs.append(params["session_id"] as? String ?? "")
            killedProcessIDs.append(params["process_id"] as? String ?? "")
            return [:]
        }
        guard method == "process.list" else { return [:] }
        processSessionIDs.append(params["session_id"] as? String ?? "")
        if deferNextProcess {
            deferNextProcess = false
            return try await withCheckedThrowingContinuation { continuation in
                deferredProcess = continuation
                processStarted?.resume()
                processStarted = nil
            }
        }
        return [
            "processes": [
                ["id": processID, "command": "completed job from A", "state": processState, "output_tail": output]
            ]
        ]
    }
}
