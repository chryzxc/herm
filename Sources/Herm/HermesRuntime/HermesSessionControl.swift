import Foundation

/// The allowlisted, session-owned automation snapshot exposed by Hermes.
struct HermesSessionControl: Decodable, Equatable {
    struct Goal: Decodable, Equatable {
        struct Barrier: Decodable, Equatable {
            let type: String
            let reason: String?
        }
        let title: String
        let status: String
        let turnsUsed: Int
        let maxTurns: Int
        let subgoals: [String]
        let pausedReason: String?
        let lastVerdict: String?
        let lastReason: String?
        let waitBarrier: Barrier?
    }
    struct Loop: Decodable, Equatable {
        let prompt: String
        let status: String
        let intervalSeconds: Double
        let ticksFired: Int
        let maxTicks: Int
        let deferredByGoal: Bool
        let pausedReason: String?
    }
    struct Heartbeat: Decodable, Equatable {
        let prompt: String
        let status: String
        let intervalSeconds: Int
        let fireCount: Int
    }
    let goal: Goal?
    let loop: Loop?
    let heartbeat: Heartbeat?
    let revision: String

    static func parse(_ envelope: [String: Any]) -> Self? {
        guard let control = envelope["control"] as? [String: Any],
            control.keys.contains("goal"), control.keys.contains("loop"), control.keys.contains("heartbeat"),
            JSONSerialization.isValidJSONObject(control),
            let data = try? JSONSerialization.data(withJSONObject: control)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Self.self, from: data)
    }
}
