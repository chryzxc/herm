import Foundation
import SwiftUI
import Testing

@testable import Herm

struct DockMotionScheduleTests {
    @Test func viewsStartedAtDifferentMomentsShareOneTickSchedule() {
        let first = Array(
            DockMotionSchedule().entries(from: Date(timeIntervalSinceReferenceDate: 100.004), mode: .normal).prefix(4))
        let second = Array(
            DockMotionSchedule().entries(from: Date(timeIntervalSinceReferenceDate: 100.04), mode: .normal).prefix(3))

        #expect(Array(first.dropFirst()) == second)
        #expect(Array(DockMotionSchedule(paused: true).entries(from: first[0], mode: .normal)) == [first[0]])
        let slow = Array(DockMotionSchedule().entries(from: first[0], mode: .lowFrequency).prefix(2))
        #expect(slow[1].timeIntervalSince(slow[0]) == 1)
    }
}

extension DockMotionScheduleTests {
    @Test func slowerRatesLandOnTheSharedThirtyFrameInstants() {
        let start = Date(timeIntervalSinceReferenceDate: 784_512_345.678)
        for rate in [1, 2, 3, 5, 6, 10, 15] {
            let slow = Array(DockMotionSchedule(rate: rate).entries(from: start, mode: .normal).prefix(6))
            let fast = Set(DockMotionSchedule().entries(from: slow[0], mode: .normal).prefix(6 * 30 / rate + 2))
            #expect(slow.allSatisfy(fast.contains), "rate \(rate)")
            #expect(slow[1].timeIntervalSince(slow[0]).isApproximatelyEqual(to: 1 / Double(rate)))
        }
    }
}

extension Double {
    fileprivate func isApproximatelyEqual(to other: Double) -> Bool { abs(self - other) < 1e-6 }
}

extension DockMotionScheduleTests {
    @MainActor
    @Test func visibleMotionKeepsItsCadenceDuringScroll() {
        guard DockMotionBudgetMonitor.shared.budget.visible else { return }
        let start = Date()
        let scrollTime = ProcessInfo.processInfo.systemUptime
        DockScrollActivity.recordScroll(at: scrollTime)
        defer { DockScrollActivity.recordScroll(at: -.infinity) }
        #expect(DockScrollActivity.isScrolling(at: scrollTime))

        for rate in [15, 30] {
            let every = 1 / Double(rate)
            let entries = Array(DockMotionSchedule(rate: rate).entries(from: start, mode: .normal).prefix(3))
            #expect(entries[0] <= start)
            #expect(entries[1].timeIntervalSince(entries[0]).isApproximatelyEqual(to: every))
            #expect(entries[2].timeIntervalSince(entries[1]).isApproximatelyEqual(to: every))
        }
    }
}
