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
    /// The intent-level `session.control` actions Herm exposes in the composer tray.
    enum Action: String, CaseIterable {
        case goalPause = "goal.pause"
        case goalResume = "goal.resume"
        case goalClear = "goal.clear"
        case loopPause = "loop.pause"
        case loopResume = "loop.resume"
        case loopStop = "loop.stop"
        case heartbeatPause = "heartbeat.pause"
        case heartbeatResume = "heartbeat.resume"
        case heartbeatClear = "heartbeat.clear"

        var label: String {
            switch self {
            case .goalPause, .loopPause, .heartbeatPause: "Pause"
            case .goalResume, .loopResume, .heartbeatResume: "Resume"
            case .goalClear, .heartbeatClear: "Clear"
            case .loopStop: "Stop"
            }
        }

        /// Pause or resume (matching `status`), then the terminal action.
        /// Finished goals offer only Clear: Hermes refuses to resume them.
        static func available(goalStatus status: String) -> [Self] {
            switch status {
            case "active": [.goalPause, .goalClear]
            case "paused": [.goalResume, .goalClear]
            default: [.goalClear]
            }
        }

        static func available(loopStatus status: String) -> [Self] {
            switch status {
            case "active": [.loopPause, .loopStop]
            case "paused": [.loopResume, .loopStop]
            default: [.loopStop]
            }
        }

        static func available(heartbeatStatus status: String) -> [Self] {
            switch status {
            case "active": [.heartbeatPause, .heartbeatClear]
            case "paused": [.heartbeatResume, .heartbeatClear]
            default: [.heartbeatClear]
            }
        }
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
