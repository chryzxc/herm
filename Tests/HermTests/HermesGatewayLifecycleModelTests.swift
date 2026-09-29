import Foundation
import Testing
@testable import Herm

@Suite("Messaging gateway service")
struct HermesGatewayLifecycleModelTests {
    private static let managed = "Launchd plist: /Users/test/Library/LaunchAgents/ai.hermes.gateway.plist\n"
    private static let running = managed + "✓ Gateway is supervised by launchd (PID 9623)\n"

    @Test("Status needs positive process evidence, not a service definition or successful exit")
    func parsesStatus() {
        #expect(HermesGatewayProcessStatus.parse(Self.running) == .init(state: .running, isManaged: true, processID: 9623))
        #expect(HermesGatewayProcessStatus.parse(Self.managed + "✓ Gateway service is registered with launchd").state == .unavailable)
        #expect(HermesGatewayProcessStatus.parse("unrecognized output").state == .unavailable)
        #expect(HermesGatewayProcessStatus.parse("✓ Gateway is running (PID: 42)") == .init(state: .running, isManaged: false, processID: 42))
        #expect(HermesGatewayProcessStatus.parse("✗ Gateway is not running").state == .stopped)
        #expect(HermesGatewayProcessStatus.parse("✓ Gateway is running (PID: 0)").state == .unavailable)
        #expect(HermesGatewayProcessStatus.parse("\u{1B}[32m" + Self.running + "\u{1B}[0m").state == .running)
    }

    @Test("Detached fallback counts as running even when the service is not loaded")
    func fallbackAndOtherProfiles() {
        let unloaded = Self.managed + "✗ Gateway service is not loaded\n"
        #expect(HermesGatewayProcessStatus.parse(unloaded).state == .stopped)
        #expect(HermesGatewayProcessStatus.parse(unloaded + "  Note: a detached gateway process is running (PID 55)").state == .running)
        #expect(HermesGatewayProcessStatus.parse("✗ Gateway is not running\nOther profiles:\n✓ Gateway is running (PID: 44)").state == .stopped)
    }

    @Test("Status and restart target the same explicit default profile")
    func commands() {
        #expect(HermesGatewayCommand.status.arguments == ["hermes", "-p", "default", "gateway", "status"])
        #expect(HermesGatewayCommand.restart.arguments == ["hermes", "-p", "default", "gateway", "restart"])
    }

    @Test("Restart rechecks service ownership and refreshes authoritative status")
    @MainActor
    func restart() async {
        var calls: [HermesGatewayCommand] = []
        let service = HermesGatewayLifecycleModel(pause: {}) { command in
            calls.append(command)
            let output = calls.contains(.restart) ? Self.running.replacingOccurrences(of: "9623", with: "9624") : Self.running
            return .init(succeeded: true, output: command == .status ? output : "")
        }
        await service.refresh()
        #expect(service.canRestart)
        await service.restart()
        #expect(calls == [.status, .status, .restart, .status])
        #expect(service.status.state == .running)
        #expect(!service.isRestarting)
        #expect(service.error == nil)
    }

    @Test("Manual processes and lost service ownership cannot launch a foreground restart")
    @MainActor
    func unmanaged() async {
        var output = Self.running
        var restarts = 0
        let service = HermesGatewayLifecycleModel(pause: {}) { command in
            if command == .restart { restarts += 1 }
            return .init(succeeded: true, output: output)
        }
        await service.refresh()
        output = "✓ Gateway is running (PID: 42)"
        await service.restart()
        #expect(restarts == 0)
        #expect(!service.canRestart)
        #expect(service.error != nil)
    }

    @Test("Failed reads invalidate previously running status")
    @MainActor
    func readFailure() async {
        var succeeds = true
        let service = HermesGatewayLifecycleModel(pause: {}) { _ in .init(succeeded: succeeds, output: Self.running) }
        await service.refresh()
        succeeds = false
        await service.refresh()
        #expect(service.status.state == .unavailable)
        #expect(!service.canRestart)
        #expect(service.error != nil)
        succeeds = true
        await service.refresh()
        #expect(service.error == nil)
    }

    @Test("Command failure stays visible even when the subsequent status is running")
    @MainActor
    func restartFailure() async {
        let service = HermesGatewayLifecycleModel(pause: {}) { command in
            .init(succeeded: command == .status, output: Self.running)
        }
        await service.refresh()
        await service.restart()
        #expect(service.status.state == .running)
        #expect(service.error?.contains("restart failed") == true)
        await service.refresh()
        #expect(service.error?.contains("restart failed") == true)
    }

    @Test("A zero exit code does not imply the gateway recovered")
    @MainActor
    func unconfirmedRestart() async {
        let service = HermesGatewayLifecycleModel(pause: {}) { _ in
            .init(succeeded: true, output: Self.managed + "✗ Gateway service is not loaded")
        }
        await service.refresh()
        await service.restart()
        #expect(service.status.state == .stopped)
        #expect(service.error?.contains("not confirmed running") == true)
    }

    @Test("Refresh and duplicate restart calls are suppressed while restarting")
    @MainActor
    func duplicateActions() async {
        var continuation: CheckedContinuation<HermesGatewayCommandResult, Never>?
        var calls: [HermesGatewayCommand] = []
        let service = HermesGatewayLifecycleModel(pause: {}) { command in
            calls.append(command)
            if command == .restart {
                return await withCheckedContinuation { continuation = $0 }
            }
            let output = calls.contains(.restart) ? Self.running.replacingOccurrences(of: "9623", with: "9624") : Self.running
            return .init(succeeded: true, output: output)
        }
        await service.refresh()
        let restart = Task { await service.restart() }
        while continuation == nil { await Task.yield() }
        #expect(service.label == "Restarting…")
        #expect(!service.canRestart)
        await service.restart()
        await service.refresh()
        #expect(calls == [.status, .status, .restart])
        continuation?.resume(returning: .init(succeeded: true))
        await restart.value
        #expect(calls == [.status, .status, .restart, .status])
    }

    @Test("An asynchronous restart waits for a replacement process")
    @MainActor
    func replacementProcess() async {
        var restarting = false
        var polls = 0
        let service = HermesGatewayLifecycleModel(pause: {}) { command in
            if command == .restart { restarting = true }
            if restarting && command == .status { polls += 1 }
            let output = polls >= 3 ? Self.running.replacingOccurrences(of: "9623", with: "9624") : Self.running
            return .init(succeeded: true, output: output)
        }
        await service.refresh()
        await service.restart()
        #expect(polls == 3)
        #expect(service.status.processID == 9624)
        #expect(service.error == nil)
    }

    @Test("An unchanged PID is not proof of a completed restart")
    @MainActor
    func unchangedProcess() async {
        let service = HermesGatewayLifecycleModel(pause: {}) { _ in .init(succeeded: true, output: Self.running) }
        await service.refresh()
        await service.restart()
        #expect(service.error?.contains("not confirmed running") == true)
        #expect(!service.isRestarting)
    }
}
