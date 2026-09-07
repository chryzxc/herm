import Foundation
import Testing
@testable import HermesAgentDock

struct QuotaForecastingTests {
    private func window(
        label: String,
        remaining: Double?,
        resetAfter seconds: TimeInterval
    ) -> ProviderQuotaWindow {
        ProviderQuotaWindow(
            id: label.lowercased(),
            label: label,
            remainingPercent: remaining,
            remainingDisplay: nil,
            limitDisplay: nil,
            resetsAt: Date(timeIntervalSinceNow: seconds),
            resetsDisplay: nil
        )
    }

    @Test func forecastExtrapolatesConsumptionPace() {
        let now = Date()
        let forecast = QuotaForecasting.limitForecast(
            for: window(label: "Weekly", remaining: 25, resetAfter: 3.5 * 86_400),
            now: now
        )

        #expect(forecast != nil)
        let expected = now.addingTimeInterval((25.0 / 75.0) * 3.5 * 86_400)
        #expect(abs(forecast!.timeIntervalSince(expected)) < 1)
    }

    @Test func forecastHiddenWhenPaceOutlastsReset() {
        #expect(QuotaForecasting.limitForecast(
            for: window(label: "Weekly", remaining: 50, resetAfter: 3.5 * 86_400)
        ) == nil)
    }

    @Test func forecastRequiresKnownCycleDuration() {
        #expect(QuotaForecasting.limitForecast(
            for: window(label: "Web searches", remaining: 25, resetAfter: 3.5 * 86_400)
        ) == nil)
    }

    @Test func forecastRequiresElapsedCycleTime() {
        #expect(QuotaForecasting.limitForecast(
            for: window(label: "Weekly", remaining: 25, resetAfter: 7 * 86_400 - 5 * 60)
        ) == nil)
    }

    @Test func dailyAllowanceStopsOverBudgetUsage() {
        #expect(QuotaForecasting.dailyAllowance(
            for: window(label: "Weekly", remaining: 70, resetAfter: 7 * 86_400)
        ) == 0)
    }

    @Test func dailyAllowanceCarriesUnusedBudgetForward() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let quotaWindow = ProviderQuotaWindow(
            id: "weekly",
            label: "Weekly",
            remainingPercent: 60,
            remainingDisplay: nil,
            limitDisplay: nil,
            resetsAt: now.addingTimeInterval(2.5 * 86_400),
            resetsDisplay: nil
        )

        // At 4.5 days into a seven-day cycle, the balance target after
        // today's budget is 28.57%. The 60% remaining balance therefore
        // carries roughly 31% of quota into today's spendable budget.
        #expect(QuotaForecasting.dailyAllowance(for: quotaWindow, now: now) == 31)
        #expect(abs(QuotaForecasting.dailyBudgetMarker(for: quotaWindow, now: now)! - (2.0 / 7.0 * 100)) < 0.01)
    }

    @Test func dailyAllowanceHiddenForShortWindows() {
        #expect(QuotaForecasting.dailyAllowance(
            for: window(label: "Session", remaining: 70, resetAfter: 12 * 3_600)
        ) == nil)
    }

    @Test func markerTracksEvenConsumptionBaseline() {
        let marker = QuotaForecasting.expectedRemainingMarker(
            for: window(label: "Weekly", remaining: nil, resetAfter: 5.5 * 86_400)
        )

        #expect(marker != nil)
        #expect(abs(marker! - 100 * (1 - 1.5 / 7)) < 0.01)
    }

    @Test func markerUsesThirtyDayBaselineForMonthlyWindows() {
        let marker = QuotaForecasting.expectedRemainingMarker(
            for: window(label: "Monthly", remaining: nil, resetAfter: 15 * 86_400)
        )

        #expect(marker != nil)
        #expect(abs(marker! - 50) < 0.01)
    }
}
