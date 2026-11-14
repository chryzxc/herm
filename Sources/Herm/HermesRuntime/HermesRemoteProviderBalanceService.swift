import Foundation

/// Projects only the documented, non-secret OpenRouter credits field.
@MainActor
enum HermesRemoteProviderBalanceService {
    static func supports(_ help: String) -> Bool {
        help.contains("--provider") && help.contains("--json")
    }

    static func read(client: HermesRPCClientProtocol, profile: String?) async throws -> ProviderQuotaSnapshot {
        let cli = HermesCLIAdapter(rpc: HermesControlRPC(client: client))
        let help = try await cli.openRouterUsageHelp(profileID: profile)
        guard help.succeeded, supports(help.stdout) else { throw unavailable() }
        let result = try await cli.openRouterUsage(profileID: profile)
        guard result.succeeded else { throw unavailable() }
        return try decode(result.stdout)
    }

    static func decode(_ text: String) throws -> ProviderQuotaSnapshot {
        guard text.utf8.count <= 4000, let data = text.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data), let json = value as? [String: Any],
            json["provider"] as? String == "openrouter", json["source"] as? String == "credits_api",
            let dateString = json["fetched_at"] as? String, let date = QuotaJSON.iso8601Date(dateString),
            (json["unavailable_reason"] as? String ?? "").isEmpty,
            let details = json["details"] as? [String]
        else { throw unavailable() }
        let prefix = "Credits balance: $"
        let balances = details.filter { $0.hasPrefix(prefix) }
        guard balances.count == 1 else { throw unavailable() }
        let amountText = String(balances[0].dropFirst(prefix.count))
        let parts = amountText.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].count == 2,
            parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
            let amount = Double(amountText), amount.isFinite
        else { throw unavailable() }
        let window = ProviderQuotaWindow(
            id: "credits", label: "Credits", remainingPercent: nil, remainingDisplay: "$" + amountText,
            limitDisplay: nil, resetsAt: nil, resetsDisplay: nil, amount: amount)
        return ProviderQuotaSnapshot(
            provider: "openrouter", displayName: "OpenRouter", model: nil, updatedAt: date,
            windows: [window], safeDetail: "Hermes backend")
    }

    private static func unavailable() -> NSError {
        NSError(
            domain: "HermesRemoteBalance", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Backend OpenRouter balance is unavailable. Refresh or check the backend."
            ])
    }
}
