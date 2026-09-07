import Foundation

/// Gateway event names that can arrive at very high rates while a response
/// streams. Per-event logging, bookkeeping, and projection rebuilds skip
/// these so the main actor stays free for UI work. Gateway, DockModel, and
/// the control center share this predicate so their filters cannot drift.
enum HermesHighFrequencyEvent {
    static func includes(_ type: String) -> Bool {
        switch type {
        case "message.delta", "reasoning.delta", "thinking.delta", "voice.status": return true
        default: return false
        }
    }
}
