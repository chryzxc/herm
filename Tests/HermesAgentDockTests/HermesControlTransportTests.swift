import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct HermesControlTransportTests {
    @Test func routesEventsToSubscribers() {
        let router = HermesEventRouter()
        var received: [(String, String)] = []
        _ = router.subscribe { type, params in
            received.append((type, params["session_id"] as? String ?? ""))
        }

        router.route(type: "approval.request", params: ["session_id": "session-7"])

        #expect(received.count == 1)
        #expect(received.first?.0 == "approval.request")
        #expect(received.first?.1 == "session-7")
    }

    @Test func unsubscribedHandlersStopReceivingEvents() {
        let router = HermesEventRouter()
        var callCount = 0
        let subscription = router.subscribe { _, _ in callCount += 1 }

        router.unsubscribe(subscription)
        router.route(type: "message.complete", params: [:])

        #expect(callCount == 0)
    }
}
