import Foundation

enum SessionRecentsType: Hashable {
    case conversations, automation

    var rowName: String { self == .conversations ? "conversations" : "automations" }

    func matching(_ sessions: [HermesSession]) -> [HermesSession] {
        sessions.filter { $0.isAutomationSession == (self == .automation) }
    }
}

struct SessionRecentsPresentation: Equatable {
    let conversations: [HermesSession]
    let automations: [HermesSession]

    init(_ sessions: [HermesSession]) {
        var conversations: [HermesSession] = []
        var automations: [HermesSession] = []
        for session in sessions {
            if session.isAutomationSession {
                automations.append(session)
            } else {
                conversations.append(session)
            }
        }
        self.conversations = conversations
        self.automations = automations
    }
}

extension HermesSession {
    var isAutomationSession: Bool {
        ["cron", "cron_output", "automation"].contains(
            source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
