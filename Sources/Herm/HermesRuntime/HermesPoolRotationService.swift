import Foundation

@MainActor
struct HermesPoolRotationService {
    enum Strategy: String, CaseIterable {
        case fillFirst = "fill_first"
        case roundRobin = "round_robin"
        case leastUsed = "least_used"
        case random

        var title: String {
            switch self {
            case .fillFirst: "Fill first"
            case .roundRobin: "Round robin"
            case .leastUsed: "Least used"
            case .random: "Random"
            }
        }
    }

    struct Pool: Equatable, Identifiable {
        let id: String
        var strategy: Strategy
    }

    struct Scope: Hashable {
        let client: ObjectIdentifier
        let profile: String?
    }

    let rpc: HermesControlRPC
    let profile: String?

    var scope: Scope { Scope(client: ObjectIdentifier(rpc), profile: profile) }

    func pools() async throws -> [Pool] {
        let inventory = try await rpc.fetchHTTP(path("/api/credentials/pool"))
        guard let rows = inventory["providers"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        let config = try await rpc.fetchHTTP(path("/api/config"))
        let strategies = config["credential_pool_strategies"] as? [String: Any] ?? [:]
        var seen = Set<String>()
        return try rows.compactMap { row in
            guard let id = row["provider"] as? String, !id.isEmpty,
                let entries = row["entries"] as? [[String: Any]], seen.insert(id).inserted
            else { throw HermesGateway.GatewayError.malformedResponse }
            guard !entries.isEmpty else { return nil }
            let value = (strategies[id] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return Pool(id: id, strategy: Strategy(rawValue: value) ?? .fillFirst)
        }
        .sorted { $0.id < $1.id }
    }

    func save(_ strategy: Strategy, for pool: Pool) async throws {
        let result = try await rpc.sendHTTP(
            "PUT", path: path("/api/config"),
            body: ["config": ["credential_pool_strategies": [pool.id: strategy.rawValue]]])
        guard result["ok"] as? Bool == true else { throw HermesGateway.GatewayError.malformedResponse }
    }

    private func path(_ path: String) -> String {
        guard let profile, !profile.isEmpty else { return path }
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "profile", value: profile)]
        return path + "?" + (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }
}
