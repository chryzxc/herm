import Foundation
import Testing

@testable import Herm

struct HermesSessionControlTests {
    @Test func parsesAutomationAndEmptySnapshot() throws {
        let control: [String: Any] = [
            "revision": "abc",
            "goal": [
                "title": "Ship", "status": "active", "turns_used": 2, "max_turns": 20,
                "subgoals": ["Test"], "wait_barrier": ["type": "session", "reason": "Waiting"],
            ],
            "loop": [
                "prompt": "Check", "status": "active", "interval_seconds": 30,
                "ticks_fired": 1, "max_ticks": 4, "deferred_by_goal": true,
            ],
            "heartbeat": ["prompt": "Watch", "status": "paused", "interval_seconds": 60, "fire_count": 3],
        ]
        let result = try #require(HermesSessionControl.parse(["control": control]))
        #expect(result.goal?.turnsUsed == 2)
        #expect(result.goal?.waitBarrier?.reason == "Waiting")
        #expect(result.loop?.deferredByGoal == true)
        #expect(result.heartbeat?.fireCount == 3)
        let empty: [String: Any] = ["revision": "", "goal": NSNull(), "loop": NSNull(), "heartbeat": NSNull()]
        #expect(HermesSessionControl.parse(["control": empty])?.goal == nil)
        #expect(HermesSessionControl.parse(["control": ["revision": ""]]) == nil)
    }

    @MainActor @Test func eventRequiresCurrentSessionAndValidSnapshot() {
        let model = DockModel()
        model.sessionID = "one"
        let empty: [String: Any] = ["revision": "", "goal": NSNull(), "loop": NSNull(), "heartbeat": NSNull()]
        model.applySessionControlEvent(["control": empty], sessionID: "other")
        #expect(model.sessionControl == nil)
        model.applySessionControlEvent(["control": empty], sessionID: "one")
        #expect(
            model.sessionControlOwner
                == model.sessionControlKey(sessionID: "one", profileID: model.sessionProfileID ?? model.profileScopeID))
        #expect(model.sessionControlEventGeneration == 1)
        model.applySessionControlEvent(["control": [:]], sessionID: "one")
        #expect(model.sessionControlEventGeneration == 1)
    }
}
