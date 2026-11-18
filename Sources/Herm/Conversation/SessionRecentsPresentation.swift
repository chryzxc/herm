import Foundation

enum SessionRecentsType: Hashable {
    case conversations, automation

    var rowName: String { self == .conversations ? "conversations" : "automations" }

    func matching(_ sessions: [HermesSession]) -> [HermesSession] {
        sessions.filter { $0.isAutomationSession == (self == .automation) }
    }
}

extension HermesSession {
    var isAutomationSession: Bool {
        ["cron", "cron_output", "automation"].contains(
            source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
