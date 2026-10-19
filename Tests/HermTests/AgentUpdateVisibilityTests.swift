import Testing
@testable import Herm

struct AgentUpdateVisibilityTests {
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
}
