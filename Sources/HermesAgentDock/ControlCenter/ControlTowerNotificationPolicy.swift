import Foundation

struct ControlTowerNotification: Identifiable, Equatable {
    let id: String
    let title: String
    let body: String
    let referenceID: String
}

enum ControlTowerNotificationPolicy {
    static func newlyNotifiableAttention(_ items: [AttentionItem], previouslyNotified: Set<String>) -> [ControlTowerNotification] {
        items.filter { item in
            item.state == .open && [.approval, .clarification, .failure].contains(item.kind) && !previouslyNotified.contains(key(for: item))
        }.map { item in
            let title: String
            switch item.kind {
            case .approval: title = "Approval required"
            case .clarification: title = "Clarification required"
            case .failure: title = "Hermes reported a failure"
            default: title = "Hermes attention"
            }
            return ControlTowerNotification(id: key(for: item), title: title, body: genericBody(for: item.kind), referenceID: item.id)
        }
    }

    static func terminalBackgroundResult(id: String, succeeded: Bool, previouslyNotified: Set<String>) -> ControlTowerNotification? {
        let key = "background:\(id):\(succeeded ? "success" : "failure")"
        guard !previouslyNotified.contains(key) else { return nil }
        return ControlTowerNotification(id: key, title: succeeded ? "Background task completed" : "Background task failed", body: succeeded ? "A background Hermes task completed." : "A background Hermes task requires review.", referenceID: id)
    }

    static func cronFailure(id: String, previouslyNotified: Set<String>) -> ControlTowerNotification? {
        let key = "cron:\(id):failure"
        guard !previouslyNotified.contains(key) else { return nil }
        return ControlTowerNotification(id: key, title: "Automation failed", body: "A scheduled Hermes automation requires review.", referenceID: id)
    }

    static func capabilityDegraded(id: String, available: Bool, previouslyNotified: Set<String>) -> ControlTowerNotification? {
        guard !available else { return nil }
        let key = "capability:\(id):unavailable"
        guard !previouslyNotified.contains(key) else { return nil }
        return ControlTowerNotification(id: key, title: "Dock capability unavailable", body: "A live Hermes capability is unavailable; no health state was inferred.", referenceID: id)
    }

    private static func key(for item: AttentionItem) -> String { "attention:\(item.id):\(item.kind.rawValue)" }
    private static func genericBody(for kind: AttentionKind) -> String {
        switch kind {
        case .approval: return "A Hermes action is waiting for your approval."
        case .clarification: return "Hermes needs an answer before continuing."
        case .failure: return "A Hermes operation failed and needs review."
        default: return "Hermes work needs review."
        }
    }
}
