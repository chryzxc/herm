import Foundation
import Testing
@testable import Herm

extension AgentUpdateVisibilityTests {
    @MainActor @Test func productionNotificationsShareOwnerAndClearAmbientState() async throws {
        enum LaunchFailure: Error { case mocked }
        let gate = UpdateVersionGate()
        var launches = 0
        var owner: HermesUpdateService!
        owner = HermesUpdateService(
            readVersion: {
                await gate.wait()
                return (true, "Hermes Agent v0.20.5 (2026.8.19)")
            },
            readRelease: {
                .success(HermesLatestRelease(tag: "v2026.8.19", marketing: "0.20.5",
                    name: nil, publishedAt: nil, pageURL: nil))
            },
            launchUpdate: { process in
                launches += 1
                #expect(process.arguments == HermesUpdateService.updateCommandArguments)
                // Both workspace callers must hit the same busy guard.
                owner.checkForUpdates()
                owner.performUpdate()
                #expect(owner.phase == .updating)
                throw LaunchFailure.mocked
            })
        let first = EdgeNotchState()
        let second = EdgeNotchState()
        var projections: [EdgeNotchActivity] = []
        let firstObservation = first.observeAgentUpdates(from: owner) {
            projections.append(first.railActivity)
        }
        let secondObservation = second.observeAgentUpdates(from: owner) {}
        defer { firstObservation.cancel(); secondObservation.cancel() }
        owner.performUpdate()
        try await waitUntil { projections.count == 3 && second.agentUpdatePhase == owner.phase }
        #expect(launches == 1)
        #expect(projections[1].working && !projections[1].attention)
        #expect(!projections[2].working && projections[2].attention)
        #expect(first.railActivity.title == "Hermes Agent update failed")
        #expect(first.activity.agentUpdatePhase == .idle)
        #expect(first.tasks.isEmpty && second.tasks.isEmpty)
        #expect(!first.showingAnnouncement && !second.showingAnnouncement)

        let unrelated = HermesUpdateService(launchUpdate: { _ in throw LaunchFailure.mocked })
        unrelated.performUpdate()
        NotificationCenter.default.post(name: .hermAgentUpdatePhase, object: nil,
            userInfo: ["phase": HermesUpdatePhase.upToDate])
        try await Task.sleep(for: .milliseconds(20))
        #expect(projections.count == 3)
        #expect(first.agentUpdatePhase == owner.phase)

        // Late observers seed from the actual owner's current failure.
        let late = EdgeNotchState()
        let lateObservation = late.observeAgentUpdates(from: owner) {}
        defer { lateObservation.cancel() }
        #expect(late.railActivity.attention)
        owner.checkForUpdates()
        owner.performUpdate()
        try await waitUntil { first.agentUpdatePhase == .checking && second.agentUpdatePhase == .checking }
        #expect(launches == 1)
        #expect(!first.railActivity.working && !first.railActivity.attention)
        #expect(!late.railActivity.attention)
        await gate.open()
        try await waitUntil { first.agentUpdatePhase == .upToDate && second.agentUpdatePhase == .upToDate }
        #expect(first.railActivity.quiet && second.railActivity.quiet)
        #expect(first.tasks.isEmpty && second.tasks.isEmpty)
        #expect(!first.activity.shouldAnnounce(after: EdgeNotchActivity()))
        firstObservation.cancel()
        let count = projections.count
        owner.performUpdate()
        try await Task.sleep(for: .milliseconds(20))
        #expect(projections.count == count)
        // Break the test launcher's owner capture; no process was launched.
        owner = nil
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), "Production notification did not propagate")
    }
}

private actor UpdateVersionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
