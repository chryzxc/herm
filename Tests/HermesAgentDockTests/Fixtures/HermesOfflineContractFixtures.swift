import Foundation
@testable import HermesAgentDock

/// Sanitized, deterministic payloads used to exercise the control transport
/// without starting Hermes or contacting a live endpoint.
enum HermesOfflineContractFixtures {
    enum Scenario: CaseIterable {
        case available
        case unavailable
        case denied
        case malformed
        case stale
        case transient
        case successAfterMutation
    }

    static let sessionID = "fixture-session"
    static let projectID = "fixture-project"

    static func payload(for scenario: Scenario, method: String = "session.active_list") -> [String: Any] {
        switch scenario {
        case .available:
            return ["sessions": [["id": sessionID, "title": "Fixture session", "state": "active"]]]
        case .malformed:
            return ["sessions": "not-an-array"]
        case .stale:
            return ["sessions": [["id": sessionID, "title": "Previous snapshot", "state": "stale"]], "stale": true]
        case .successAfterMutation:
            return method == "session.title"
                ? ["session_id": sessionID, "title": "Updated fixture title"]
                : ["ok": true]
        case .unavailable, .denied, .transient:
            return [:]
        }
    }

    static func error(for scenario: Scenario) -> HermesOfflineTransportError? {
        switch scenario {
        case .unavailable: .unavailable
        case .denied: .denied
        case .transient: .transient
        case .available, .malformed, .stale, .successAfterMutation: nil
        }
    }
}

@MainActor
final class HermesOfflineFixtureRPCClient: HermesRPCClientProtocol {
    struct Call {
        let method: String
        let params: [String: Any]
    }

    private(set) var calls: [Call] = []
    private var scenario: HermesOfflineContractFixtures.Scenario
    private var mutationApplied = false

    init(scenario: HermesOfflineContractFixtures.Scenario) {
        self.scenario = scenario
    }

    var onEvent: ((String, [String: Any]) -> Void)?

    func connect() async throws {
        if let error = HermesOfflineContractFixtures.error(for: scenario) { throw error }
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append(Call(method: method, params: params))
        if let error = HermesOfflineContractFixtures.error(for: scenario) { throw error }
        if scenario == .successAfterMutation, method == "session.title", params["title"] as? String != nil {
            mutationApplied = true
            return ["ok": true]
        }
        if scenario == .successAfterMutation, method == "session.title", mutationApplied {
            return HermesOfflineContractFixtures.payload(for: scenario, method: method)
        }
        if scenario == .successAfterMutation, method == "session.title" {
            return ["session_id": HermesOfflineContractFixtures.sessionID, "title": "Original fixture title"]
        }
        return HermesOfflineContractFixtures.payload(for: scenario, method: method)
    }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        calls.append(Call(method: "HTTP \(path)", params: [:]))
        if let error = HermesOfflineContractFixtures.error(for: scenario) { throw error }
        return HermesOfflineContractFixtures.payload(for: scenario)
    }

    func close() {}

    func applyFixtureMutation() {
        mutationApplied = true
    }
}

enum HermesOfflineTransportError: LocalizedError, Equatable {
    case unavailable
    case denied
    case transient

    var errorDescription: String? {
        switch self {
        case .unavailable: "Fixture transport unavailable."
        case .denied: "Fixture transport denied."
        case .transient: "Fixture transport transient failure."
        }
    }
}
