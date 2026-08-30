import Foundation

enum HermesWebhookInputFormat: Sendable { case json, humanTable }

enum HermesWebhookState: String, Codable, Equatable, Sendable { case ready, unavailable, unsupported, malformed, stale }

struct HermesWebhookDeliverySummary: Equatable, Sendable {
    let delivered: Int
    let failed: Int
}

struct HermesWebhookSubscriptionSummary: Equatable, Sendable, Identifiable {
    let id: String
    let event: String
    let target: String
    let state: HermesWebhookState
    let deliveries: HermesWebhookDeliverySummary
    /// Always nil: signing material is intentionally never projected.
    let signingSecret: String?
}

struct HermesWebhookSnapshot: Equatable, Sendable {
    let state: HermesWebhookState
    let subscriptions: [HermesWebhookSubscriptionSummary]
    let peers: [HermesPeerSummary]
    let diagnostic: String
}
