import Testing

@testable import Herm

struct AgentUpdateVisibilityTests {
    @MainActor @Test func ambientPhaseNeverBecomesSessionActivity() {
        let state = EdgeNotchState()
        let session = state.activity
        for phase: HermesUpdatePhase in [.updating, .updateFailed("exit 1"), .checking, .upToDate, .updateSucceeded] {
            state.agentUpdatePhase = phase
            #expect(state.activity == session)
            #expect(!state.activity.shouldAnnounce(after: session))
            #expect(state.tasks.isEmpty)
            #expect(state.railActivity.agentUpdatePhase == phase)
            #expect(state.railActivity.working == (phase == .updating))
            #expect(state.railActivity.attention == (phase.ambientStatus?.isRunning == false))
        }
    }

    @MainActor @Test func railPreservesDecisionsAndConcurrentSessionWork() {
        let state = EdgeNotchState()
        state.tasks = [
            EdgeNotchTask(
                id: "other", title: "Other session", phase: .working,
                statusLabel: "Working", detail: nil, updatedAt: nil, isCurrent: false,
                isStatusCurrent: true, session: nil)
        ]
        for phase: HermesUpdatePhase in [.updating, .updateFailed("exit 1"), .checking] {
            state.agentUpdatePhase = phase
            for status: HermesStatus in [.needsApproval, .needsClarification] {
                state.activity = EdgeNotchActivity(status: status)
                #expect(state.railActivity.title == status.title)
                #expect(state.railActivity.attention)
                #expect(state.railActivity.working)
                #expect(state.railActivity.workingCount == 1)
            }
        }
    }

    @Test func ambientStatusOnlySpinsDuringInstallation() {
        #expect(HermesUpdatePhase.updating.ambientStatus?.title == "Updating Hermes Agent…")
        #expect(HermesUpdatePhase.updating.ambientStatus?.isRunning == true)
        #expect(HermesUpdatePhase.updateSucceeded.ambientStatus == nil)
        #expect(HermesUpdatePhase.checking.ambientStatus == nil)
        #expect(HermesUpdatePhase.idle.ambientStatus == nil)
        #expect(HermesUpdatePhase.upToDate.ambientStatus == nil)
        #expect(HermesUpdatePhase.updateAvailable.ambientStatus == nil)
        #expect(HermesUpdatePhase.checkFailed("offline").ambientStatus == nil)
    }

    @Test func failureStopsSpinnerAndKeepsRecoveryVisible() {
        let status = HermesUpdatePhase.updateFailed("exit 1").ambientStatus
        #expect(status?.title == "Hermes Agent update failed")
        #expect(status?.isRunning == false)
    }

    @Test func notchUpdateIsWorkingEvenWhileSessionIsIdleOrOffline() {
        for status: HermesStatus in [.idle, .offline] {
            var activity = EdgeNotchActivity(status: status)
            activity.agentUpdatePhase = .updating
            #expect(activity.working)
            #expect(!activity.quiet)
            #expect(activity.title == "Updating Hermes Agent…")
            activity.agentUpdatePhase = .updateSucceeded
            #expect(!activity.working)
        }
    }

    @Test func notchFailureNeedsAttentionWithoutHidingSessionApproval() {
        var activity = EdgeNotchActivity()
        activity.agentUpdatePhase = .updateFailed("exit 1")
        #expect(activity.attention)
        #expect(!activity.working)
        #expect(activity.title == "Hermes Agent update failed")
        activity.status = .needsApproval
        #expect(activity.title == HermesStatus.needsApproval.title)
    }

    @Test func updateStatusPreservesSessionAttentionAndActivityInputs() {
        for phase: HermesUpdatePhase in [.updating, .updateFailed("exit 1")] {
            for status: HermesStatus in [.needsApproval, .needsClarification] {
                let activity = EdgeNotchActivity(status: status, agentUpdatePhase: phase)
                #expect(activity.title == status.title)
                #expect(activity.attention)
                #expect(activity.symbol == status.icon)
            }
        }
        var activity = EdgeNotchActivity(status: .working, agentUpdatePhase: .updateFailed("exit 1"))
        #expect(activity.working)
        #expect(activity.attention)
        activity.status = .idle
        #expect(!activity.working)
        #expect(!activity.quiet)
        #expect(activity.symbol == .warningCircle)
        activity.agentUpdatePhase = .checking
        #expect(!activity.attention)
        #expect(activity.quiet)
    }
}
