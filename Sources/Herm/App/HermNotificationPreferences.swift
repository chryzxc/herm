import Foundation
import UserNotifications

/// Local delivery preferences; runtime events and pending decisions remain owned by Hermes.
enum HermNotificationPreferences {
    static let soundKey = "herm.notifications.sound.v1"
    static let snoozeKey = "herm.notifications.snooze-until.v1"
    static let attentionKey = "herm.notifications.attention.v1"
    static let failureKey = "herm.notifications.failure.v1"
    static let automationKey = "herm.notifications.automation.v1"
    static let kanbanKey = "herm.notifications.kanban.v1"
    static let quotaKey = "herm.notifications.quota.v1"
    static let pullRequestKey = "herm.notifications.pull-request.v1"
    static let completionKey = "hermes.control.notifications.completion.v1"

    static func enabled(_ key: String, defaults: UserDefaults, fallback: Bool = false) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    static func allows(_ notice: HermNotice, defaults: UserDefaults, now: Date = Date()) -> Bool {
        guard defaults.double(forKey: snoozeKey) <= now.timeIntervalSince1970 else { return false }
        let key: String
        switch notice.source {
        case .routine: key = automationKey
        case .kanban: key = kanbanKey
        case .quota: key = quotaKey
        case .repository: key = pullRequestKey
        case .session, .activity:
            switch notice.kind {
            case .approval, .clarification: return enabled(attentionKey, defaults: defaults, fallback: true)
            case .failure: return enabled(failureKey, defaults: defaults, fallback: true)
            default: key = completionKey
            }
        }
        return enabled(key, defaults: defaults)
    }

    static func sound(defaults: UserDefaults) -> UNNotificationSound? {
        enabled(soundKey, defaults: defaults, fallback: true) ? .default : nil
    }
}
