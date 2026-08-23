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
              reset > now else { return nil }
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

    /// Conservative amount of the remaining quota that can be used per day
    /// before the provider reset.
    ///
    /// A provider may call a multi-day window “Session” (Codex does this for
    /// its account-wide allowance). Only suppress the daily notice for
    /// genuinely short rolling windows.
    static func dailyAllowance(for window: ProviderQuotaWindow, now: Date = .now) -> Int? {
        guard let remaining = window.remainingPercent,
              let reset = window.resetsAt,
              remaining > 0,
              reset > now,
              reset.timeIntervalSince(now) > 24 * 60 * 60 else { return nil }

        let daysRemaining = max(1, Int(ceil(reset.timeIntervalSince(now) / 86_400)))
        return max(1, Int(floor(remaining / Double(daysRemaining))))
    }

    /// Expected remaining percentage if the window's allowance were consumed
    /// evenly throughout its cycle. Deliberately separate from the daily
    /// allowance: the marker compares actual balance to the pace line (for
    /// example, ~71% expected after two days of a seven-day window).
    static func expectedRemainingMarker(for window: ProviderQuotaWindow, now: Date = .now) -> Double? {
        guard let reset = window.resetsAt, reset > now, reset.timeIntervalSince(now) > 24 * 60 * 60 else { return nil }
        let label = window.label.lowercased()
        let duration: TimeInterval = label.contains("month") ? 30 * 86_400 : 7 * 86_400
        let elapsed = min(max(0, duration - reset.timeIntervalSince(now)), duration)
        return max(0, min(100, 100 * (1 - elapsed / duration)))
    }
}
