import Foundation
import Testing

@testable import Herm

@MainActor
struct SessionProcessIsolationTests {
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
                    id: "rpc-activity", title: "Activity", detail: "Available", isAvailable: true, recovery: nil)
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
                    id: "rpc-activity", title: "Activity", detail: "Available", isAvailable: true, recovery: nil)
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
                    id: "rpc-activity", title: "Activity", detail: "Available", isAvailable: true, recovery: nil)
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
        // Do not launch a second focused read while installing the new projection.
        control.capabilities = []
        if transition == 0 {
            dock.sessionID = nil
            control.focus(sessionID: nil)
        } else if transition == 1 {
            dock.sessionID = "session-b"
            control.focus(sessionID: "session-b")
        } else if transition == 2 {
            let otherDock = DockModel(defaults: defaults, rpcClient: client)
            otherDock.sessionID = "session-a"
            control.bind(to: otherDock)
        } else {
            dock.sessionID = "session-b"
            control.focus(sessionID: "session-b")
            dock.sessionID = "session-a"
            control.focus(sessionID: "session-a")
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
        // A broad refresh that finishes derives lastError from projection
        // states (all clean here); a rebind cancels it. The stale failure must never leak.
        #expect(control.lastError == expectedError || (broad && control.lastError == nil))
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
                    id: "rpc-activity", title: "Activity", detail: "Available", isAvailable: true, recovery: nil)
            ])
        control.dockModel = dock
        control.focus(sessionID: "session-a")
        client.deferNextProcess = true
        let oldPoll = Task { await control.pollProcesses() }
        await client.waitForDeferredProcess()

        let otherDock = DockModel(defaults: defaults, rpcClient: client)
        otherDock.sessionID = "session-a"
        if rebind {
            control.bind(to: otherDock)
            control.capabilities = [
                CapabilityState(
                    id: "rpc-activity", title: "Activity", detail: "Available", isAvailable: true, recovery: nil)
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
                    id: "rpc-activity", title: "Activity", detail: "Available", isAvailable: true, recovery: nil)
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
}

@MainActor
private final class SessionProcessIsolationClient: HermesRPCClientProtocol {
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
            deferredProcess?.resume(throwing: HermesGateway.GatewayError.malformedResponse)
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
