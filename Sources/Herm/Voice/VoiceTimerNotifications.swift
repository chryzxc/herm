import Foundation
import UserNotifications

/// Only a confirmed Hermes inventory can add or remove pending alerts for its profile.
@MainActor
final class VoiceTimerNotifications {
    static let shared = VoiceTimerNotifications()
    private var work: [String: Task<Bool, Never>] = [:]

    func reconcile(_ timers: [VoiceTimer], profileID: String?) {
        _ = schedule(timers, profileID: profileID)
    }

    func apply(_ timers: [VoiceTimer], profileID: String?) async -> Bool {
        await schedule(timers, profileID: profileID).value
    }

    private func schedule(_ timers: [VoiceTimer], profileID: String?) -> Task<Bool, Never> {
        let profile = DockModel.normalizedProfileID(profileID) ?? "default"
        let previous = work[profile]
        let task = Task {
            _ = await previous?.value
            return await Self.reconcile(timers, prefix: "voice-timer/\(profile)/")
        }
        work[profile] = task
        return task
    }

    private static func reconcile(_ timers: [VoiceTimer], prefix: String) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let now = Date()
        let upcoming = timers.filter { $0.due > now }
        let wanted = Set(upcoming.map { identifier(for: $0, prefix: prefix) })
        let stale = pending.filter { request in
            guard request.identifier.hasPrefix(prefix), !wanted.contains(request.identifier),
                let due = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
            else { return false }
            return due > now
        }.map(\.identifier)
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        guard !upcoming.isEmpty else { return true }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return false
        }
        var successful = true
        for timer in upcoming {
            let identifier = identifier(for: timer, prefix: prefix)
            let body = String(timer.name.prefix(240))
            if pending.contains(where: { $0.identifier == identifier && $0.content.body == body }) { continue }
            let content = UNMutableNotificationContent()
            content.title = "Reminder"
            content.body = body
            content.sound = HermNotificationPreferences.sound(defaults: .standard)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            let components = calendar.dateComponents(
                [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: timer.due)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            } catch {
                successful = false
                DebugLog.write(
                    "voice: reminder scheduling failed: "
                        + HermesDiagnosticsService.safeSummary(error.localizedDescription))
            }
        }
        return successful
    }

    private static func identifier(for timer: VoiceTimer, prefix: String) -> String {
        "\(prefix)\(timer.id)@\(Int(timer.due.timeIntervalSince1970))"
    }
}
