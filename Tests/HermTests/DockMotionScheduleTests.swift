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
