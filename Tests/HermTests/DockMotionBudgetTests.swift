import Foundation
import Testing

@testable import Herm

struct DockMotionBudgetTests {
    @Test func onlyHiddenWindowsHoldTheClock() {
        #expect(DockMotionBudget().hold == 0)
        #expect(DockMotionSchedule.tick(3_000, rate: 30, now: 100, heldFor: DockMotionBudget().hold) == 3_000)
        let hidden = DockMotionBudget(visible: false)
        #expect(hidden.hold == DockMotionBudget.hiddenRecheck)
        let held = DockMotionSchedule.tick(3_000, rate: 30, now: 100, heldFor: hidden.hold)
        #expect(held / 30 >= 100 + DockMotionBudget.hiddenRecheck)
    }
}
