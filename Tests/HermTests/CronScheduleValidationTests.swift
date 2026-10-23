import Foundation
import Testing

@testable import Herm

struct CronScheduleValidationTests {
    @Test(arguments: ["30m", "every 2h", "every monday 9am", "0 9 * * *"])
    func acceptsHermesSupportedScheduleForms(schedule: String) {
        #expect(CronSchedule.isValid(schedule))
    }

    @Test(arguments: ["", "   ", "\n\t", "every\u{0000}2h", "0 9 * * *\u{001B}"])
    func rejectsOnlyLocallyUnsafeScheduleInput(schedule: String) {
        #expect(!CronSchedule.isValid(schedule))
    }

    @Test
    func leavesHermesScheduleGrammarUnrestrictedLocally() {
        #expect(CronSchedule.isValid("a schedule Hermes understands"))
    }
}
