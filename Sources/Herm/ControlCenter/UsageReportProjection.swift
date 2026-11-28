import Foundation

enum UsageReportProjection {
    nonisolated static func monthly(_ input: sending [String: Any]) async -> TokenUsageReport {
        ControlCenterModel.parseTokenUsage(input)
    }

    nonisolated static func enrich(_ base: TokenUsageReport, models: sending [String: Any]) async -> TokenUsageReport {
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
            updated.providers = providers[model.model] ?? []
            return updated
        }
        report.costRankedProviders = ControlCenterModel.parseProviderCosts(models, days: base.days)
        return report
    }

    nonisolated static func daily(_ input: sending [String: Any]) async -> [TokenUsageReport.Day]? {
        guard let rows = input["daily"] as? [[String: Any]] else { return nil }
        return ControlCenterModel.parseUsageDays(rows)
    }
}
