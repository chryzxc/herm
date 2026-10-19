import Foundation
import SwiftUI

/// Fixed daily peak windows a provider publishes (billing or quota-burn rates
/// differ inside them). Everything outside the windows is off-peak.
struct ProviderPeakSchedule {
    struct Status: Equatable {
        let isPeak: Bool
        /// When the current period ends and the other begins.
        let changesAt: Date
        /// The current or next peak window, as absolute instants.
        let peak: Range<Date>
    }

    /// Peak windows as whole local hours, e.g. `9..<12`.
    let peakHours: [Range<Int>]
    /// Calendar weekdays (1 = Sunday) the windows apply on.
    let weekdays: Set<Int>
    let timeZone: TimeZone
    /// What peak costs, shown as a tooltip.
    let peakNote: String

    func status(at now: Date) -> Status? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        var nextPeak: Range<Date>?
        // ponytail: scans 8 days; a schedule with no weekday in range returns nil.
        for dayOffset in -1...8 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today),
                  weekdays.contains(calendar.component(.weekday, from: day)) else { continue }
            for hours in peakHours {
                guard let start = calendar.date(byAdding: .hour, value: hours.lowerBound, to: day),
                      let end = calendar.date(byAdding: .hour, value: hours.upperBound, to: day) else { continue }
                if start <= now, now < end { return Status(isPeak: true, changesAt: end, peak: start..<end) }
                if start > now, nextPeak.map({ start < $0.lowerBound }) ?? true { nextPeak = start..<end }
            }
        }
        return nextPeak.map { Status(isPeak: false, changesAt: $0.lowerBound, peak: $0) }
    }

    /// Built-in schedules, used until the first web sync.
    static let defaults: [String: ProviderPeakSchedule] = [
        // Peak is billed at 2x off-peak. 09:00-12:00 and 14:00-18:00 Beijing time, daily.
        "deepseek": ProviderPeakSchedule(
            peakHours: [9..<12, 14..<18],
            weekdays: Set(1...7),
            timeZone: TimeZone(secondsFromGMT: 8 * 3600)!,
            peakNote: "Peak API rates are 2x off-peak."
        ),
        // GLM-5.x burns 3x quota in peak, Mon-Fri 14:00-18:00 UTC+8.
        "glm": ProviderPeakSchedule(
            peakHours: [14..<18],
            weekdays: Set(2...6),
            timeZone: TimeZone(secondsFromGMT: 8 * 3600)!,
            peakNote: "GLM-5.x models burn quota 3x faster in peak."
        ),
    ]
}

// MARK: Web sync

extension ProviderPeakSchedule {
    private static let storeKey = "quota.peakSchedules"
    private static let syncedAtKey = "quota.peakSchedulesSyncedAt"

    static var syncedAt: Date? { UserDefaults.standard.object(forKey: syncedAtKey) as? Date }

    private static let names = ["deepseek": "DeepSeek", "glm": "GLM"]

    /// Tooltip text: when the sync happened and the windows it produced, in the
    /// provider's timezone plus the viewer's local time.
    static func syncSummary(syncedAt: Date, now: Date = .now) -> String {
        let when = syncedAt.formatted(date: .abbreviated, time: .shortened)
        let ago = syncedAt.formatted(.relative(presentation: .named, unitsStyle: .wide))
        let lines = names.sorted { $0.key < $1.key }.compactMap { id, name in
            schedule(for: id).map { "\(name): \($0.windowText(now: now))" }
        }
        return (["Peak hours synced \(when) (\(ago))."] + lines + ["Click to ask Hermes to search the web again."])
            .joined(separator: "\n")
    }

    private func windowText(now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.startOfDay(for: now)
        let remote = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)
        let local = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: .current)
        let parts = peakHours.compactMap { hours -> String? in
            guard let start = calendar.date(byAdding: .hour, value: hours.lowerBound, to: day),
                  let end = calendar.date(byAdding: .hour, value: hours.upperBound, to: day) else { return nil }
            return "\(start.formatted(remote))–\(end.formatted(remote)) (your time \(start.formatted(local))–\(end.formatted(local)))"
        }
        let abbrev = timeZone.abbreviation(for: now) ?? timeZone.identifier
        let days = weekdays.count == 7 ? "daily" : "Mon–Fri"
        return "peak \(parts.joined(separator: ", ")) \(abbrev), \(days)"
    }

    /// The synced schedule for a provider, falling back to the built-in one.
    static func schedule(for providerID: String) -> ProviderPeakSchedule? {
        let stored = UserDefaults.standard.data(forKey: storeKey).flatMap(parse)
        return stored?[providerID] ?? defaults[providerID]
    }

    /// Asks Hermes (web toolset) for the providers' current peak windows and
    /// stores the validated answer. Returns an error message on failure.
    @MainActor
    static func syncFromWeb() async -> String? {
        let prompt = """
        Search the web for the CURRENT official peak / off-peak hours of: \
        DeepSeek API (platform.deepseek.com) and Z.ai GLM Coding Plan (docs.z.ai). \
        Reply with ONLY one JSON object, no prose, shaped exactly like \
        {"deepseek":{"utc_offset_hours":8,"peak":[[9,12],[14,18]],"days":[1,2,3,4,5,6,7],"note":"short effect of peak"},"glm":{...}}. \
        "peak" is local-hour [start,end) windows in that UTC offset; "days" are ISO weekdays (1=Mon..7=Sun) the windows apply on. \
        Omit a provider you cannot confirm from an official source.
        """
        let result = await HermesUpdateService.runHermes(arguments: ["chat", "-Q", "--oneshot", "-t", "web", "-q", prompt], timeout: 240)
        guard result.succeeded else { return "Hermes could not complete the search." }
        guard let data = jsonObject(in: result.text), let parsed = parse(data), !parsed.isEmpty else {
            return "Hermes returned no readable schedule."
        }
        UserDefaults.standard.set(data, forKey: storeKey)
        UserDefaults.standard.set(Date(), forKey: syncedAtKey)
        return nil
    }

    private static func jsonObject(in text: String) -> Data? {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return nil }
        return String(text[open...close]).data(using: .utf8)
    }

    /// Only providers that pass validation are kept; bad entries are dropped.
    static func parse(_ data: Data) -> [String: ProviderPeakSchedule]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return nil }
        var out: [String: ProviderPeakSchedule] = [:]
        for (id, entry) in root {
            guard let offset = (entry["utc_offset_hours"] as? NSNumber)?.intValue, (-12...14).contains(offset),
                  let zone = TimeZone(secondsFromGMT: offset * 3600),
                  let rawPeak = entry["peak"] as? [[Int]], !rawPeak.isEmpty,
                  let days = entry["days"] as? [Int], !days.isEmpty else { continue }
            let windows = rawPeak.compactMap { pair -> Range<Int>? in
                guard pair.count == 2, (0...24).contains(pair[0]), (0...24).contains(pair[1]), pair[0] < pair[1] else { return nil }
                return pair[0]..<pair[1]
            }
            guard windows.count == rawPeak.count, days.allSatisfy({ (1...7).contains($0) }) else { continue }
            out[id] = ProviderPeakSchedule(
                peakHours: windows,
                // ISO 1=Mon..7=Sun -> Calendar 2=Mon..7=Sat,1=Sun.
                weekdays: Set(days.map { $0 % 7 + 1 }),
                timeZone: zone,
                peakNote: (entry["note"] as? String) ?? ""
            )
        }
        return out
    }
}

// MARK: Presentation

extension ProviderPeakSchedule {
    struct Notice {
        let text: String
        let help: String
        let isPeak: Bool
    }

    /// Maps a Hermes model-picker provider name to its quota provider id.
    static func quotaID(forProvider provider: String) -> String? {
        let name = provider.lowercased()
        if name.contains("deepseek") { return "deepseek" }
        if name.contains("glm") || name.contains("zai") || name.contains("z.ai") || name.contains("z-ai") { return "glm" }
        return nil
    }

    /// Peak is the warning case; off-peak is informational with the time left.
    static func notice(forQuotaID id: String, now: Date = .now) -> Notice? {
        guard let schedule = schedule(for: id), let status = schedule.status(at: now) else { return nil }
        let left = QuotaWorkspacePresentation.compactDuration(from: now, to: status.changesAt)
        // Formatted in the device's current time zone, so travel needs no refresh.
        let time = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: .autoupdatingCurrent)
        let window = "Peak \(status.peak.lowerBound.formatted(time)) – \(status.peak.upperBound.formatted(time)) your time."
        return status.isPeak
            ? Notice(text: "Peak hours · off-peak in \(left)", help: "\(window) \(schedule.peakNote)", isPeak: true)
            : Notice(text: "Off-peak now · \(left) left", help: "Peak starts in \(left). \(window) \(schedule.peakNote)", isPeak: false)
    }
}

/// Green "ok to use" / amber "peak" capsule, ticking every minute.
struct PeakNoticeBadge: View {
    let quotaID: String
    var compact = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            if let notice = ProviderPeakSchedule.notice(forQuotaID: quotaID, now: context.date) {
                let color = notice.isPeak ? Color.dockWarning : Color.dockSuccess
                HStack(spacing: 5) {
                    DockIcon(notice.isPeak ? .warning : .checkCircle, size: compact ? 10 : 12, color: color)
                    Text(notice.text)
                        .font(compact ? .system(size: 10, weight: .medium) : DockTypography.control)
                        .foregroundStyle(color)
                        .lineLimit(1)
                }
                .padding(.horizontal, compact ? 7 : 10)
                .padding(.vertical, compact ? 3 : 5)
                .background(Capsule().fill(color.opacity(0.14)))
                .help(notice.help)
            }
        }
    }
}
