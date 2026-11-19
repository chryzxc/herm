import Foundation
import Testing

@testable import Herm

@MainActor
struct DockHostLayoutTimingTests {
    @Test func nestedHostLayoutIsNotCountedInItsParentsSelfTime() {
        DockHostLayoutTiming.begin()
        DockHostLayoutTiming.begin()
        let pane = DockHostLayoutTiming.end(role: "workspace", since: 10, now: 10.004)
        let root = DockHostLayoutTiming.end(role: "root", since: 9.99, now: 10.01)
        #expect(abs(pane - 0.004) < 1e-9)
        #expect(abs(root - 0.016) < 1e-9)
    }
}
