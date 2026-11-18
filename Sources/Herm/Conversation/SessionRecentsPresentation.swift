import Foundation

enum SessionRecentsType: Hashable {
    case conversations, automation

    var title: String { self == .conversations ? "Conversations" : "Automation" }

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
