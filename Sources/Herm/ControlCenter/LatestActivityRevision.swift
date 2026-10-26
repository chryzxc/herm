import Foundation

/// Reuse only explicit recency plus message count; a creation date cannot prove freshness.
struct LatestActivityRevision: Equatable {
    let profile: String?
    let updated: Date
    let messages: Int

    @MainActor
    init?(_ row: [String: Any]) {
        guard
            let updated = ControlCenterModel.activityDate(row["updated_at"])
                ?? ControlCenterModel.activityDate(row["last_active"])
                ?? ControlCenterModel.activityDate(row["last_message_at"]),
            let messages = row["message_count"] as? Int, messages >= 0,
            !(row["message_count"] is Bool)
        else { return nil }
        profile = row["profile"] as? String ?? row["profile_id"] as? String
        self.updated = updated
        self.messages = messages
    }
}

struct LatestActivityCacheEntry {
    let revision: LatestActivityRevision
    let steps: [SessionActivityStep]
}
