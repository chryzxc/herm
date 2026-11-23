import Combine
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

    @MainActor @Test func identicalAutomationReadsAndEventsDoNotInvalidateTheConversation() async {
        let client = SessionControlReadClient()
        let model = DockModel(loadArchives: false, rpcClient: client)
        defer { model.shutdown() }
        model.sessionID = "one"
        let profile = model.sessionProfileID ?? model.profileScopeID
        await model.refreshSessionControl(sessionID: "one", profileID: profile)
        let verified = model.sessionControl
        #expect(verified != nil)
        var updates = 0
        let subscription = model.objectWillChange.sink { updates += 1 }
        defer { subscription.cancel() }

        for _ in 0..<20 { await model.refreshSessionControl(sessionID: "one", profileID: profile) }
        model.applySessionControlEvent(client.reply, sessionID: "one")
        #expect(updates == 0)
        #expect(model.sessionControlEventGeneration == 1)

        client.reply = [:]
        await model.refreshSessionControl(sessionID: "one", profileID: profile)
        #expect(model.sessionControlStale)
        #expect(model.sessionControl == verified)
        #expect(updates == 1)
        await model.refreshSessionControl(sessionID: "one", profileID: profile)
        #expect(updates == 1)
        client.reply = SessionControlReadClient.emptyControl
        await model.refreshSessionControl(sessionID: "one", profileID: profile)
        #expect(!model.sessionControlStale)
        #expect(updates == 2)
    }

    @Test func trayActionsFollowHermesStatus() {
        typealias Action = HermesSessionControl.Action
        #expect(Action.available(goalStatus: "active") == [.goalPause, .goalClear])
        #expect(Action.available(goalStatus: "paused") == [.goalResume, .goalClear])
        #expect(Action.available(goalStatus: "done") == [.goalClear])
        #expect(Action.available(loopStatus: "active") == [.loopPause, .loopStop])
        #expect(Action.available(loopStatus: "paused") == [.loopResume, .loopStop])
        #expect(Action.available(heartbeatStatus: "paused") == [.heartbeatResume, .heartbeatClear])
        #expect(Action.goalPause.rawValue == "goal.pause")
        #expect(Action.loopStop.rawValue == "loop.stop")
    }
}

@MainActor
private final class SessionControlReadClient: HermesRPCClientProtocol {
    static let emptyControl: [String: Any] = [
        "control": ["revision": "", "goal": NSNull(), "loop": NSNull(), "heartbeat": NSNull()]
    ]
    var reply = emptyControl
    var onEvent: ((String, [String: Any]) -> Void)?

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { reply }
    func fetchHTTP(_ path: String) async throws -> [String: Any] { [:] }
}
