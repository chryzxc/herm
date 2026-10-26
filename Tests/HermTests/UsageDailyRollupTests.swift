import Foundation
import Testing

@testable import Herm

struct UsageDailyRollupTests {
    private func day(_ offset: Int, cost: Double) -> TokenUsageReport.Day {
        .init(
            day: Date(timeIntervalSince1970: Double(offset) * 86_400), inputTokens: 100,
            outputTokens: 20, cacheReadTokens: 0, reasoningTokens: 0,
            estimatedCost: cost, sessions: 1, apiCalls: 1)
    }

    @Test func sortsReplacesDuplicatesAndDoesNotInventMissingDays() {
        let rollup = UsageDailyRollup(daily: [day(5, cost: 9), day(1, cost: 2), day(5, cost: 4)])
        #expect(rollup.points.map(\.cost) == [2, 4])
        #expect(rollup.points.map(\.cumulativeCost) == [2, 6])
        #expect(rollup.total == 6)
        #expect(rollup.average == 3)
        #expect(rollup.peak?.date == day(5, cost: 4).day)
    }

    @Test func emptyAndReportedZeroRemainDifferent() {
        #expect(UsageDailyRollup(daily: []).average == nil)
        #expect(UsageDailyRollup(daily: []).peak == nil)
        let zero = UsageDailyRollup(daily: [day(1, cost: 0)])
        #expect(zero.average == 0)
        #expect(zero.points.count == 1)
    }
}
