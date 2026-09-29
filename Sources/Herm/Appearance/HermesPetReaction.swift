import Foundation

/// One mapping for notch announcements, live status and local interactions.
/// Add new semantic reactions here and cover them in HermesPetTests.
enum HermesPetReaction: CaseIterable {
    case idle, working, thinking, attention, quota, update, failed, greeting, petting

    var pose: String {
        switch self {
        case .idle: "idle"
        case .working: "run"
        case .thinking, .quota: "review"
        case .attention: "waiting"
        case .update, .greeting: "wave"
        case .failed: "failed"
        case .petting: "jump"
        }
    }

    static func announcement(activity: EdgeNotchActivity, quota: Bool) -> Self {
        if quota { return .quota }
        if activity.attention { return .attention }
        if activity.hasUpdate { return .update }
        if activity.working { return .working }
        return .update
    }
}
