import Foundation

enum UsageReportProjection {
    nonisolated static func monthly(_ input: Data) async throws -> TokenUsageReport {
        try ControlCenterModel.parseTokenUsage(decode(input))
    }

    nonisolated static func enrich(_ base: TokenUsageReport, models input: Data) async throws -> TokenUsageReport {
        let models = try decode(input)
        var providers: [String: [String]] = [:]
        for row in models["models"] as? [[String: Any]] ?? [] {
            guard let model = row["model"] as? String, let provider = row["provider"] as? String,
                !provider.isEmpty, providers[model]?.contains(provider) != true
            else { continue }
            providers[model, default: []].append(provider)
        }
        var report = base
        report.models = base.models.map { model in
            var updated = model
            updated.providers = providers[model.providerLookupKey] ?? []
            return updated
        }
        report.costRankedProviders = ControlCenterModel.parseProviderCosts(models, days: base.days)
        return report
    }

    nonisolated static func daily(_ input: Data) async throws -> [TokenUsageReport.Day]? {
        let report = try decode(input)
        guard let rows = report["daily"] as? [[String: Any]] else { return nil }
        return ControlCenterModel.parseUsageDays(rows)
    }

    nonisolated private static func decode(_ input: Data) throws -> [String: Any] {
        let parsed = try? JSONSerialization.jsonObject(with: input)
        guard let json = parsed as? [String: Any] ?? (parsed as? [Any]).map({ ["items": $0] }) else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        return json
    }
}
