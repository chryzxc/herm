import Testing

@testable import Herm

struct SessionTraceActionTests {
    @Test func failureNavigationSkipsParentSummaryAndWraps() {
        let rows = [
            SessionTraceRow(id: "request", kind: .turn, title: "Request", timing: .unavailable, outcome: "Failed"),
            SessionTraceRow(id: "a", kind: .tool, title: "A", timing: .unavailable, outcome: "Failed"),
            SessionTraceRow(id: "ok", kind: .tool, title: "OK", timing: .unavailable),
            SessionTraceRow(id: "b", kind: .agent, title: "B", timing: .unavailable, outcome: "Error"),
        ]
        #expect(SessionTraceNavigation.nextFailure(in: rows, after: nil) == "a")
        #expect(SessionTraceNavigation.nextFailure(in: rows, after: "a") == "b")
        #expect(SessionTraceNavigation.nextFailure(in: rows, after: "b") == "a")
        #expect(SessionTraceNavigation.nextFailure(in: [], after: nil) == nil)
    }
}
