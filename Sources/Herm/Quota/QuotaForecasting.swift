import Foundation

/// Pace forecasts derived from a provider quota window. All estimates compare
/// the reported balance against an even-consumption baseline; providers do not
/// report actual consumption-rate data.
enum QuotaForecasting {
    /// Estimates when the current consumption pace would exhaust a window.
    /// Intentionally nil when the forecast lands after the real reset or when
    /// there is not enough elapsed cycle time to derive a pace.
    static func limitForecast(for window: ProviderQuotaWindow, now: Date = .now) -> Date? {
        guard let remaining = window.remainingPercent,
            let reset = window.resetsAt,
            remaining > 0, remaining < 100,
            reset > now
        else { return nil }
        let duration: TimeInterval
        switch window.label.lowercased() {
        case let label where label.contains("session") || label.contains("rolling"): duration = 5 * 60 * 60
        case let label where label.contains("week"): duration = 7 * 24 * 60 * 60
        case let label where label.contains("month"): duration = 30 * 24 * 60 * 60
        default: return nil
        }
        let elapsed = duration - reset.timeIntervalSince(now)
        guard elapsed > 10 * 60 else { return nil }
        let forecast = now.addingTimeInterval((remaining / (100 - remaining)) * elapsed)
        return forecast < reset ? forecast : nil
    }

    /// Amount of quota that can be spent today while staying on the original
    /// even-use budget for the current cycle. Any balance above the cumulative
    /// budget line is carried forward, so an unused day increases today's
    /// available budget.
    ///
    /// A provider may call a multi-day window “Session” (Codex does this for
    /// its account-wide allowance). Only suppress the daily notice for
    /// genuinely short rolling windows.
    static func dailyAllowance(for window: ProviderQuotaWindow, now: Date = .now) -> Int? {
        guard let remaining = window.remainingPercent,
            remaining > 0,
            let marker = dailyBudgetMarker(for: window, now: now)
        else { return nil }

        return max(0, Int(floor(remaining - marker)))
    }

    /// Remaining balance that should be left after spending the cumulative
    /// budget available through the end of today. This is the yellow marker
    /// shown on the quota meter.
    static func dailyBudgetMarker(for window: ProviderQuotaWindow, now: Date = .now) -> Double? {
        guard let reset = window.resetsAt,
            reset > now,
            let duration = cycleDuration(for: window.label)
        else { return nil }

        let daysInCycle = max(1, Int(duration / 86_400))
        let elapsed = max(0, duration - reset.timeIntervalSince(now))
        let currentDay = min(daysInCycle, max(1, Int(floor(elapsed / 86_400)) + 1))
        let spentByEndOfToday = Double(currentDay) / Double(daysInCycle) * 100
        return max(0, min(100, 100 - spentByEndOfToday))
    }

    /// The daily-budget marker to draw on a meter, or nil when the window has
    /// no daily budget to show (short rolling windows, or nothing left).
    static func visibleDailyBudgetMarker(for window: ProviderQuotaWindow, now: Date = .now) -> Double? {
        dailyAllowance(for: window, now: now) == nil ? nil : dailyBudgetMarker(for: window, now: now)
    }

    /// Expected remaining percentage if the window's allowance were consumed
    /// evenly throughout its cycle. Deliberately separate from the daily
    /// allowance: the marker compares actual balance to the pace line (for
    /// example, ~71% expected after two days of a seven-day window).
    static func expectedRemainingMarker(for window: ProviderQuotaWindow, now: Date = .now) -> Double? {
        guard let reset = window.resetsAt, reset > now, reset.timeIntervalSince(now) > 24 * 60 * 60 else { return nil }
        guard let duration = cycleDuration(for: window.label) else { return nil }
        let elapsed = min(max(0, duration - reset.timeIntervalSince(now)), duration)
        return max(0, min(100, 100 * (1 - elapsed / duration)))
    }

    private static func cycleDuration(for label: String) -> TimeInterval? {
        switch label.lowercased() {
        case let label where label.contains("week"): return 7 * 86_400
        case let label where label.contains("month"): return 30 * 86_400
        default: return nil
        }
    }
}
